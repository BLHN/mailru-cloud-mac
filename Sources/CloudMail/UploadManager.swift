import Foundation
import AppKit
import Network

/// Owns the upload queue. One rclone process at a time (rclone itself moves 16 files in parallel),
/// so the app never competes with itself or floods the connection next to other uploads.
@MainActor
final class UploadManager: ObservableObject {
    @Published var jobs: [UploadJob] = [] {
        didSet { scheduleSave() }
    }
    @Published var destinationFolder: String {
        didSet { UserDefaults.standard.set(destinationFolder, forKey: "destinationFolder") }
    }
    /// "Тихий режим": jobs started while it is on get `--bwlimit 2M`.
    @Published var quietMode: Bool {
        didSet { UserDefaults.standard.set(quietMode, forKey: "quietMode") }
    }
    /// "Освобождать место после загрузки": new drops become evict jobs. Off by default.
    @Published var evictAfterUpload: Bool {
        didSet { UserDefaults.standard.set(evictAfterUpload, forKey: Self.evictKey) }
    }
    /// "Освобождено на Маке": bytes moved to the Trash by finished evict jobs, persisted.
    @Published private(set) var freedBytes: Int64
    @Published var rcloneReady = true
    /// The cloud gate: false while the cloud cannot be reached. Nothing starts then; running jobs
    /// went back to the queue and continue by themselves once a probe gets through (see «Cloud gate»).
    @Published private(set) var cloudReachable = true
    @Published var setupMessage: String?
    /// Why nothing can start (nil: rclone and an account are there). Drives the banner in «Передачи»,
    /// the menu bar line and the «ждёт подключения к Облаку» rows.
    @Published private(set) var setupIssue: SetupIssue?
    private var loggedRclonePath: String?
    /// Set once the first setup check has decided (until then `rcloneReady` is false only because
    /// the account is not known yet).
    private var setupChecked = false
    private var activationObserver: NSObjectProtocol?
    /// Dev launch argument `--dev-section <name>`: the window section the UI should open first.
    @Published var initialSection: String?
    /// Dev launch argument `--dev-exit-when-idle`: quit once the queue was loaded and nothing is
    /// queued or running any more (queue.json is saved first).
    var exitWhenIdle = false {
        didSet { if exitWhenIdle { checkIdleExit() } }
    }
    private var idleExitStarted = false

    /// Called after a job finishes successfully (the header re-reads free space).
    var onJobDone: (() -> Void)?

    private var processes: [UUID: ChildProcess] = [:] {
        didSet { updateSleepActivity() }
    }
    private var buffers: [UUID: Data] = [:]
    /// Per rclone run: how to turn the run's stats into whole-job progress.
    private var runs: [UUID: RunProgress] = [:]
    /// Number of the job's current run, bumped by every `start`. A check or verification that
    /// began in an earlier run (paused and resumed meanwhile) sees a different number and stops.
    private var runIDs: [UUID: Int] = [:]
    private var nextRunID = 0
    /// Evict: the source as it was when the current run's upload started (taken off the main
    /// thread). The original goes to the Trash only if it still looks exactly like this.
    private var snapshots: [UUID: SourceSnapshot] = [:]
    private var saveScheduled = false
    /// Set on quit: termination handlers must not rewrite the saved queue.
    private var quitting = false
    /// Drops are examined off the main thread (ps, placeholders, refusals) one batch after another,
    /// so batches keep their order.
    private var intakeTask: Task<Void, Never>?
    /// Set once queue.json has been read (off the main thread, at launch): saving before that
    /// would overwrite the saved queue with an empty list.
    private var queueLoaded = false

    // Cloud gate, stall watchdog, wake (see the «Cloud gate» section).
    private var gateClosedAt: Date?
    private var gateLoop: Task<Void, Never>?
    /// The probe in flight: everyone who needs an answer meanwhile waits for this one.
    private var probeTask: Task<ProbeResult, Never>?
    /// A transfer just ended with a network-class error: nothing starts until the probe has answered.
    private var checkingAfterNetworkError = false
    /// Network-class failures of a job in a row while the probes got through.
    private var networkStrikes: [UUID: Int] = [:]
    /// Recent rclone error messages of each running job (without file names), for classification.
    private var errorTails: [UUID: [String]] = [:]
    private var watch: [UUID: TransferWatch] = [:]
    private var watchdogTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied: Bool?
    private var sleptAt: Date?
    private var wakeSignal: DispatchSourceSignal?
    private var sleepActivity: NSObjectProtocol?
    /// Uploads waiting for the cloud to finish a big file (see «Cloud finishing a big file»):
    /// job id -> token of the pending delayed start. `pump` skips these jobs; a cancel, remove or
    /// retry drops the entry, so the delay that ends later finds another token and does nothing.
    /// Not persisted: after a relaunch the job is simply queued.
    private var cloudFinishingHolds: [UUID: Int] = [:]
    private var nextHoldToken = 0
    /// Gateway answers after an upload in a row, per job (reset by a run that ends without one).
    private var gatewayStrikes: [UUID: Int] = [:]
    /// Dev only (`CLOUDMAIL_DEV_FAKE_GATEWAY=N`): the next N finished upload runs of this process
    /// are treated as if rclone had exited with "504 Gateway Time-out".
    private var devFakeGatewayLeft = 0
    /// Delay before such a job starts again; dev `CLOUDMAIL_DEV_GATEWAY_DELAY=<seconds>` overrides it.
    private var gatewayDelay: TimeInterval = 180

    static let defaultFolder = "Mac/Входящие"
    static let quietBandwidth = "2M"
    static let evictKey = "evictAfterUpload"
    static let freedKey = "freedBytes"
    /// Production: ~/Library/Application Support/CloudMail/queue.json; dev: …/CloudMail-Dev/ (AppPaths).
    nonisolated static var queueURL: URL { AppPaths.queueURL }

    /// Default local folder for downloads from the cloud ("Скачать на Мак"), a path.
    @Published var downloadFolder: String {
        didSet { UserDefaults.standard.set(downloadFolder, forKey: Self.downloadFolderKey) }
    }
    /// Dev `--dev-demo`: the queue holds fake jobs, rclone is never started and queue.json is
    /// neither read nor written (`queueLoaded` stays false, `rcloneReady` is false).
    let isDemo: Bool

    static let downloadFolderKey = "downloadFolder"

    init(demo: Bool = false) {
        isDemo = demo
        destinationFolder = UserDefaults.standard.string(forKey: "destinationFolder") ?? Self.defaultFolder
        quietMode = UserDefaults.standard.bool(forKey: "quietMode")
        evictAfterUpload = UserDefaults.standard.bool(forKey: Self.evictKey)
        freedBytes = (UserDefaults.standard.object(forKey: Self.freedKey) as? NSNumber)?.int64Value ?? 0
        downloadFolder = UserDefaults.standard.string(forKey: Self.downloadFolderKey)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        if demo {
            rcloneReady = false
            return
        }
        if AppPaths.isDev {
            let env = ProcessInfo.processInfo.environment
            devFakeGatewayLeft = env["CLOUDMAIL_DEV_FAKE_GATEWAY"].flatMap { Int($0) }.map { max(0, $0) } ?? 0
            if let d = env["CLOUDMAIL_DEV_GATEWAY_DELAY"].flatMap({ Double($0) }), d >= 0 { gatewayDelay = d }
            if devFakeGatewayLeft > 0 || gatewayDelay != 180 {
                AppLog.write("dev: fake gateway errors \(devFakeGatewayLeft), gateway delay \(Int(gatewayDelay)) s")
            }
        }
        // Reading the queue checks every saved source on disk and runs `ps`: off the main thread.
        // Drops that arrive meanwhile wait for it (they chain on `intakeTask`).
        intakeTask = Task { @MainActor [weak self] in await self?.loadQueue() }
        // Nothing starts before the account is known.
        rcloneReady = false
        Account.shared.onChange = { [weak self] in self?.applyAccountState() }
        Task { await checkSetup() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkSetup() }
        }
        startResilience()
    }

    enum SetupIssue: Equatable {
        /// No rclone in the bundle or in the known places.
        case noRclone
        /// No account in the app and no remote "mailru" in rclone.conf.
        case notConnected
        /// The Keychain item is there but could not be read.
        case keychainLocked
        /// The cloud no longer accepts the password.
        case authFailed(legacy: Bool)

        var message: String {
            switch self {
            case .noRclone: return Rclone.RcloneError.notInstalled.errorDescription ?? ""
            case .notConnected: return "Подключение к Облаку не настроено."
            case .keychainLocked: return "Не получилось прочитать пароль из связки ключей."
            case .authFailed(let legacy):
                return legacy
                    ? "Облако больше не принимает пароль. Проверьте remote «mailru» в rclone.conf."
                    : "Облако больше не принимает пароль. Войдите заново с новым паролем для приложения."
            }
        }
    }

    /// At launch, on every activation of the app and after sign-in or sign-out: is rclone there, and
    /// how does it reach the cloud (see `Account`).
    func checkSetup() async {
        guard !isDemo else { return }
        guard let bin = Rclone.binary else {
            setSetupIssue(.noRclone)
            return
        }
        if loggedRclonePath != bin {
            loggedRclonePath = bin
            log("rclone: \(bin)")
        }
        await Account.shared.refresh()
        applyAccountState()
    }

    /// Follows the account: ready when signed in (Keychain) or on a legacy remote; otherwise the
    /// running transfer is stopped (its job goes back to the queue) and nothing starts.
    func applyAccountState() {
        guard !isDemo else { return }
        guard Rclone.binary != nil else { setSetupIssue(.noRclone); return }
        let account = Account.shared
        guard account.resolved else { return }
        if account.keychainReadFailed {
            setSetupIssue(.keychainLocked)
            return
        }
        switch account.state {
        case .keychain, .legacyRemote: setSetupIssue(nil)
        case .none: setSetupIssue(.notConnected)
        case .authFailed(let email): setSetupIssue(.authFailed(legacy: email == nil))
        }
    }

    private func setSetupIssue(_ issue: SetupIssue?) {
        let changed = issue != setupIssue || !setupChecked
        setupChecked = true
        setupIssue = issue
        setupMessage = issue?.message
        rcloneReady = issue == nil
        if issue == nil {
            if changed { log("setup ready") }
            pump()
            return
        }
        if changed { log("setup issue: \(issue!)") }
        for i in jobs.indices where jobs[i].state == .running && !jobs[i].committing {
            requeue(i)
        }
        if changed, case .authFailed = issue {
            Notifier.shared.notice(issue!.message)
        }
        checkIdleExit()
    }

    /// Queued jobs wait for sign-in rather than for the queue.
    var waitingForAccount: Bool { !isDemo && setupIssue != nil }

    // MARK: Queue

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    var runningJob: UploadJob? { jobs.first { $0.state == .running } }
    var pausedJob: UploadJob? { jobs.first { $0.state == .paused } }
    /// True while any rclone process of ours exists (running, or still stopping after pause/cancel).
    var hasLiveProcess: Bool { !processes.isEmpty }

    /// Entry point for drops, the Dock, "Open with", argv and the Finder services. `.mailcloud`
    /// placeholders always become restore jobs; other items are uploaded, and with `evict`
    /// (default: the "Освобождать место после загрузки" setting) their space is freed afterwards.
    /// Everything that touches the disk or runs `ps` happens off the main thread.
    /// `folder`: an explicit cloud folder for this batch («Загрузить сюда» and drops in «Облако»);
    /// nil uses the saved default (`destinationFolder`), which is never changed here.
    func add(urls: [URL], evict: Bool? = nil, folder explicitFolder: String? = nil) {
        guard !urls.isEmpty else { return }
        let evictMode = evict ?? evictAfterUpload
        let folder = explicitFolder ?? destinationFolder
        let previous = intakeTask
        intakeTask = Task { @MainActor [weak self] in
            await previous?.value
            let planned = await Task.detached(priority: .userInitiated) {
                UploadManager.plan(urls: urls, evict: evictMode, folder: folder)
            }.value
            self?.accept(planned)
        }
    }

    /// Builds the queue entries for a batch of dropped items. Runs off the main thread.
    nonisolated private static func plan(urls: [URL], evict: Bool, folder: String) -> [UploadJob] {
        var busyCache: [String]?
        func busy() -> [String] {
            if let b = busyCache { return b }
            let b = Rclone.busySources()
            busyCache = b
            return b
        }
        var result: [UploadJob] = []
        for url in urls {
            if Placeholder.isPlaceholder(url) {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                result.append(restoreJob(placeholderURL: url))
                continue
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            var job = UploadJob(kind: evict ? .evict : .copy, source: url, isDirectory: isDir.boolValue,
                                destinationFolder: folder)
            if evict {
                if let refusal = LocalItems.evictRefusal(url, busy: busy(), ownRemotePath: nil) {
                    job.state = .refused(refusal)
                } else {
                    job.note = LocalItems.evictWarning(url)
                }
            } else if let reason = blockReason(path: url.path, busy: busy()) {
                job.state = .blocked(reason)
            }
            result.append(job)
        }
        return result
    }

    /// A restore entry for a placeholder; an unreadable placeholder becomes a refused entry.
    nonisolated private static func restoreJob(placeholderURL url: URL) -> UploadJob {
        do {
            let p = try Placeholder.read(from: url)
            let destination = p.destination(besides: url)
            let remoteFolder = (p.remotePath as NSString).deletingLastPathComponent
            var job = UploadJob(kind: .restore, source: destination, isDirectory: p.isDirectory,
                                destinationFolder: remoteFolder)
            job.restoreRemotePath = UploadJob.cloudPath(p.remotePath)
            job.placeholderPath = url.path
            job.sourceBytes = p.size
            job.totalBytes = p.size
            job.filesTotal = p.fileCount
            return job
        } catch {
            var job = UploadJob(kind: .restore, source: url, isDirectory: false, destinationFolder: "")
            job.placeholderPath = url.path
            job.state = .refused(error.localizedDescription)
            return job
        }
    }

    private func accept(_ planned: [UploadJob]) {
        for job in planned {
            if jobs.contains(where: { $0.state.isActive && ($0.source == job.source
                || (job.placeholderPath != nil && $0.placeholderPath == job.placeholderPath)) }) { continue }
            var job = job
            if job.note == nil { job.note = evictCollisionNote(for: job) }
            jobs.insert(job, at: 0)
            if case .refused(let m) = job.state {
                log("refused \(job.kind.rawValue) \(job.source.path): \(m)")
                continue
            }
            if !job.isDownload { measureSize(job.id) }
        }
        pump()
    }

    /// "Облако -> Мак": queues a download of any cloud file or folder into `localFolder`.
    /// The local item is "<localFolder>/<last path component>", or the first free Finder-style
    /// name ("<name> 2", "<name> 3"…) when that one is taken on disk or by another active job.
    /// The name check runs off the main thread; batches keep their order (`intakeTask`).
    func download(remotePath: String, isDirectory: Bool, to localFolder: URL) {
        let cloud = UploadJob.cloudPath(remotePath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = (cloud as NSString).lastPathComponent
        guard !cloud.isEmpty, !name.isEmpty, name != ".", name != ".." else { return }
        let folder = localFolder.standardizedFileURL
        let previous = intakeTask
        intakeTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let reserved = self.reservedLocalPaths(except: nil)
            let target = await Task.detached(priority: .userInitiated) {
                LocalItems.freeItemURL(in: folder, name: name, isDirectory: isDirectory, reserved: reserved)
            }.value
            var job = UploadJob(kind: .download, source: target, isDirectory: isDirectory,
                                destinationFolder: (cloud as NSString).deletingLastPathComponent)
            job.restoreRemotePath = cloud
            job.stagingPath = folder.appendingPathComponent(UploadJob.stagingName(for: target.lastPathComponent, id: job.id),
                                                            isDirectory: isDirectory).path
            self.jobs.insert(job, at: 0)
            self.log("queued download \(Rclone.remote):\(cloud) -> \(target.path)")
            self.pump()
        }
    }

    /// Resolves once every drop and download queued so far has been examined and added.
    func waitForIntake() async {
        await intakeTask?.value
    }

    /// Local paths (lowercased) other active jobs will create or upload from: a new download must
    /// not pick one of them as its name.
    private func reservedLocalPaths(except id: UUID?) -> Set<String> {
        Set(jobs.filter { $0.state.isActive && $0.id != id }.map { $0.source.standardizedFileURL.path.lowercased() })
    }

    /// "Показать в Finder" on a finished download row.
    func revealInFinder(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([job.source])
    }

    /// "Вернуть на Мак" on a finished evict row: queues a restore from the placeholder that job
    /// wrote. The existence check runs off the main thread; a missing placeholder is reported on
    /// the row instead of silently doing nothing.
    func restoreEvicted(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.kind == .evict, job.state == .done,
              let ph = job.placeholderPath, restoreJob(forPlaceholder: ph)?.state.isActive != true else { return }
        let url = URL(fileURLWithPath: ph)
        Task { @MainActor [weak self] in
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: url.path)
            }.value
            guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            if exists {
                if self.jobs[i].note?.hasPrefix("Ярлык «") == true { self.jobs[i].note = nil }
                self.add(urls: [url])
            } else {
                self.jobs[i].note = "Ярлык «\(url.lastPathComponent)» не нашёлся: его переименовали, переместили или уже вернули файл. Двойной клик по ярлыку тоже возвращает файл."
            }
        }
    }

    /// Plain upload to a cloud path where (or inside / around which) an item freed by an evict in
    /// this list lives: the upload may replace it, and that placeholder would bring back other data.
    private func evictCollisionNote(for job: UploadJob) -> String? {
        guard job.kind == .copy else { return nil }
        let mine = job.remoteItemPath.lowercased()
        guard let other = jobs.first(where: { $0.kind == .evict && $0.id != job.id
            && ($0.state == .done || $0.state.isActive)
            && Rclone.overlaps(mine, $0.remoteItemPath.lowercased()) }) else { return nil }
        return "В Облаке по пути «\(other.remoteItemPath)» лежит то, что освобождено с Мака (там остался ярлык). Эта загрузка может заменить те файлы, и ярлык вернёт уже другие."
    }

    /// The newest restore entry started from this placeholder (the list is newest first).
    func restoreJob(forPlaceholder path: String) -> UploadJob? {
        jobs.first { $0.kind == .restore && $0.placeholderPath == path }
    }

    func retry(_ id: UUID, force: Bool = false) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A refusal is final: retrying would start exactly what was refused.
        if case .refused = jobs[i].state { return }
        guard !jobs[i].state.isActive else { return }
        jobs[i].state = .queued
        jobs[i].phase = nil
        // `bytes` is kept: rclone skips what is already in the cloud, so progress continues from there.
        jobs[i].speed = 0; jobs[i].eta = nil; jobs[i].lastError = nil; jobs[i].lastErrorMessage = nil
        jobs[i].filesDone = 0; jobs[i].currentFile = nil; jobs[i].finishedAt = nil
        jobs[i].forced = force
        jobs[i].restarting = false
        networkStrikes[id] = nil
        gatewayStrikes[id] = nil
        pump()
    }

    func cancel(_ id: UUID) {
        // The original / placeholder is being moved right now: that step finishes first.
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].committing else { return }
        // A job waiting for the cloud to finish a big file: its pending delayed start is dropped.
        if cloudFinishingHolds.removeValue(forKey: id) != nil {
            jobs[i].phase = nil
            log("\(jobs[i].name): delayed start dropped (cancelled)")
        }
        if let p = processes[id] {
            jobs[i].state = .cancelled
            terminate(p)
        } else if jobs[i].state == .queued || jobs[i].state == .paused {
            jobs[i].state = .cancelled
        } else if jobs[i].state == .running, jobs[i].kind != .copy {
            // Evict / restore / download between rclone runs (preparing or verifying): the pending step
            // sees the new state and does nothing (no trashing).
            jobs[i].state = .cancelled
            jobs[i].phase = nil
            jobs[i].finishedAt = Date()
            log("cancelled \(jobs[i].name)")
            pump()
        }
    }

    /// Pauses by stopping the rclone process. Freezing it with SIGSTOP is not an option: the open
    /// WebDAV PUTs time out on the server (408) and every pause burns one of rclone's retries.
    /// The paused job no longer counts as running, so the next queued job may start.
    func pause(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running,
              !jobs[i].committing else { return }
        jobs[i].state = .paused
        jobs[i].phase = nil
        jobs[i].speed = 0
        jobs[i].eta = nil
        jobs[i].currentFile = nil
        if let p = processes[id] { terminate(p) }
        log("paused \(jobs[i].name)")
        pump()
    }

    /// Queues a paused job again; rclone skips the files that are already uploaded.
    /// If its old process is still stopping, `pump` waits for it to exit first.
    func resume(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .paused else { return }
        jobs[i].state = .queued
        log("resumed \(jobs[i].name)")
        pump()
    }

    func remove(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.committing else { return }
        cancel(id)
        jobs.removeAll { $0.id == id }
        cloudFinishingHolds[id] = nil
        gatewayStrikes[id] = nil
        if processes[id] == nil { runIDs[id] = nil; snapshots[id] = nil }
        if job.isDownload, job.state != .done { trashStagingWhenIdle(of: job) }
    }

    /// A removed, unfinished download or restore has no row left that could continue it: its
    /// hidden staging item would sit next to the target forever. It goes to the Trash (never a
    /// permanent delete) once the job's rclone has exited and no longer writes into it.
    private func trashStagingWhenIdle(of job: UploadJob) {
        let id = job.id, staging = job.restoreStagingURL
        Task { @MainActor [weak self] in
            var waited = 0
            while let self, self.processes[id] != nil, waited < 150 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 1
            }
            guard let self, self.processes[id] == nil else { return }
            let outcome = await Task.detached(priority: .utility) { () -> String? in
                guard FileManager.default.fileExists(atPath: staging.path) else { return nil }
                do {
                    try FileManager.default.trashItem(at: staging, resultingItemURL: nil)
                    return "moved to the Trash"
                } catch {
                    return "left in place (\(error.localizedDescription))"
                }
            }.value
            if let outcome { self.log("removed \(job.name): staging \(staging.path) \(outcome)") }
        }
    }

    /// Called on quit: never leave orphan rclone processes behind. Job states stay as they are,
    /// so running/queued jobs resume on the next launch.
    func stopAllForQuit() {
        guard !quitting else { return }
        quitting = true
        saveNow()
        for p in processes.values { terminate(p) }
    }

    /// SIGTERM to our own rclone. One that is still there after `killGrace` seconds (stopped by
    /// SIGSTOP, or hung) gets SIGKILL through the same handle: it is not reaped yet, so its pid
    /// cannot belong to another process. Until it exits, `pump` cannot start the job again.
    private func terminate(_ p: ChildProcess) {
        guard p.isRunning else { return }
        p.terminate()
        guard !quitting else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.killGrace * 1_000_000_000))
            guard p.isRunning, p.forceKill() else { return }
            self?.log("rclone \(p.processIdentifier) ignored SIGTERM for \(Int(Self.killGrace)) s, sent SIGKILL")
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    /// Why a path must wait: it is (inside) the folder rclone uploads in the background right now,
    /// or that folder lies inside it. Either way a second rclone would upload the same files.
    nonisolated static func blockReason(path: String, busy: [String]) -> String? {
        guard let b = busy.first(where: { Rclone.overlaps(path, $0) }) else { return nil }
        let name = URL(fileURLWithPath: b).lastPathComponent
        if path == b || path.hasPrefix(b + "/") {
            return path == b
                ? "Эту папку уже выгружает другая программа (rclone). Чтобы не гнать её дважды, загрузка отложена."
                : "Это лежит внутри папки «\(name)», которую уже выгружает другая программа (rclone). Чтобы не гнать это дважды, загрузка отложена."
        }
        return "Внутри неё другая программа (rclone) уже выгружает «\(name)». Чтобы не гнать это дважды, загрузка отложена."
    }


    private func pump() {
        defer { checkIdleExit() }
        // A job whose previous process is still exiting (paused and resumed quickly) waits for it.
        guard rcloneReady, cloudReachable, !checkingAfterNetworkError, runningJob == nil,
              let i = jobs.lastIndex(where: { $0.state == .queued && processes[$0.id] == nil
                                              && cloudFinishingHolds[$0.id] == nil }) else { return }
        start(index: i)
    }

    /// Dev `--dev-exit-when-idle`: quits once nothing is queued or running and no rclone of ours
    /// is alive (a missing rclone / remote counts as idle: nothing would ever start).
    private func checkIdleExit() {
        guard exitWhenIdle, AppPaths.isDev, queueLoaded, setupChecked, !quitting, !idleExitStarted else { return }
        let pending = jobs.contains { $0.state == .running || ($0.state == .queued && rcloneReady) }
        guard !pending, processes.isEmpty else { return }
        idleExitStarted = true
        log("dev: queue idle, exiting")
        saveNow()
        Task { @MainActor in NSApplication.shared.terminate(nil) }
    }

    // MARK: rclone process

    private func start(index i: Int) {
        guard Rclone.binary != nil else { return }
        Notifier.shared.requestAuthorizationIfNeeded()
        var job = jobs[i]
        job.state = .running
        // Keep the first start: a resumed or retried job continues the same upload.
        if job.startedAt == nil { job.startedAt = Date() }
        job.quiet = quietMode
        nextRunID += 1
        runIDs[job.id] = nextRunID
        snapshots[job.id] = nil
        if job.kind == .copy, job.note == nil { job.note = evictCollisionNote(for: job) }
        jobs[i] = job
        if job.kind == .copy {
            launch(id: job.id)
            return
        }
        // Evict / restore / download check the disk first (off the main thread); the job counts as running
        // meanwhile, so the queue does not start anything else.
        jobs[i].phase = "Готовлюсь…"
        let id = job.id, run = nextRunID
        Task { @MainActor [weak self] in await self?.prepareAndLaunch(id, run: run) }
    }

    private enum Preflight: Sendable {
        /// Evict: the source as it is right before the upload starts.
        case ok(SourceSnapshot?)
        case refused(String)
        case failed(String)
        /// Evict: the original is already gone and its placeholder is there (a run cut short by a
        /// quit or crash after trashing).
        case alreadyEvicted
        /// A cloud check could not reach the cloud (the raw text, for the log): the job waits behind
        /// the cloud gate instead of failing.
        case network(String)
    }

    private func prepareAndLaunch(_ id: UUID, run: Int) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        var check: Preflight
        switch job.kind {
        case .copy:
            check = .ok(nil)
        case .evict:
            let url = job.source, remote = job.remoteItemPath, name = job.name
            check = await Task.detached(priority: .userInitiated) { () -> Preflight in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    let ph = Placeholder.url(for: url)
                    if let p = try? Placeholder.read(from: ph), p.points(to: remote) { return .alreadyEvicted }
                    return .failed("Не нашёл «\(name)» на диске: его переместили или удалили.")
                }
                if let r = LocalItems.evictRefusal(url, busy: Rclone.busySources(), ownRemotePath: remote) {
                    return .refused(r)
                }
                guard let snapshot = SourceSnapshot.take(url) else {
                    return .failed("«\(name)» не читается с диска. Оригинал оставлен на месте.")
                }
                return .ok(snapshot)
            }.value
            if case .ok = check, !job.remoteClaimed {
                guard stillRunning(id, run: run) != nil else { return }
                check = await claimCloudPath(job, run: run) ?? check
            }
        case .restore:
            guard let ph = job.placeholderPath else { check = .refused("Нет ярлыка, откуда возвращать."); break }
            let dest = job.source, size = job.sourceBytes ?? 0
            check = await Task.detached(priority: .userInitiated) { () -> Preflight in
                if let problem = LocalItems.restoreProblem(destination: dest, placeholderURL: URL(fileURLWithPath: ph),
                                                           size: size) {
                    return .failed(problem)
                }
                return .ok(nil)
            }.value
            if case .ok = check, let problem = await restoreCloudMismatch(job) {
                check = problem
            }
        case .download:
            check = await downloadPreflight(job, run: run)
        }
        guard let i = stillRunning(id, run: run) else {
            // Paused, cancelled or quit while checking.
            return
        }
        jobs[i].phase = nil
        switch check {
        case .ok(let snapshot):
            snapshots[id] = snapshot
            launch(id: id)
        case .alreadyEvicted:
            jobs[i].state = .done
            jobs[i].finishedAt = Date()
            jobs[i].placeholderPath = Placeholder.url(for: jobs[i].source).path
            jobs[i].bytes = jobs[i].totalBytes
            log("evict \(jobs[i].name): original already in the Trash, placeholder present")
            pump()
        case .refused(let m):
            jobs[i].state = .refused(m)
            jobs[i].finishedAt = Date()
            log("refused \(jobs[i].kind.rawValue) \(jobs[i].source.path): \(m)")
            pump()
        case .failed(let m):
            jobs[i].state = .failed(m)
            jobs[i].finishedAt = Date()
            log("failed \(jobs[i].name): \(m)")
            Notifier.shared.jobFailed(jobs[i], message: m)
            pump()
        case .network(let raw):
            waitForNetwork(i, text: raw,
                           logLine: "\(jobs[i].name): cloud check could not reach the cloud (\(raw)), requeued")
        }
    }

    /// Evict, before its first upload: the cloud path must be free. rclone compares by size only
    /// on mail.ru, so it would overwrite a different item of the same name (or skip one of the
    /// same size), the check would pass and the original would go to the Trash next to a
    /// placeholder that brings back someone else's data. Also refuses a path another evict in the
    /// list already uses. Marks the job as owning the path when it is free.
    /// Returns a failure, or nil when the job may go on.
    private func claimCloudPath(_ job: UploadJob, run: Int) async -> Preflight? {
        let id = job.id, path = job.remoteItemPath
        let folder = UploadJob.cloudPath(job.destinationFolder)
        if jobs.contains(where: { $0.id != id && $0.kind == .evict && $0.remoteClaimed
            && $0.remoteItemPath.lowercased() == path.lowercased() }) {
            return .failed("В Облаке «\(path)» уже занято другой выгрузкой с освобождением. Чтобы не затереть её, освобождать не стал: переименуй «\(job.name)» на Маке и перетащи снова. Оригинал оставлен на месте.")
        }
        if let i = stillRunning(id, run: run) { jobs[i].phase = "Проверяю, свободно ли имя в Облаке…" }
        let result = await Rclone.existingName(job.name, inFolder: folder)
        guard let i = stillRunning(id, run: run) else { return nil }
        jobs[i].phase = nil
        switch result {
        case .failure(let e) where e.isNetwork:
            return .network(e.logText)
        case .failure(let e):
            log("evict \(job.name): cloud folder check failed: \(e.logText)")
            return .failed("\(e.localizedDescription) Оригинал оставлен на месте.")
        case .success(let existing?):
            let shownFolder = folder.isEmpty ? "корне Облака" : "«\(folder)»"
            return .failed("В Облаке в \(shownFolder) уже есть «\(existing)». Чтобы не затереть его, освобождать не стал: переименуй «\(job.name)» на Маке или выбери другую папку в Облаке и перетащи снова. Оригинал оставлен на месте.")
        case .success(nil):
            jobs[i].remoteClaimed = true
            log("evict \(job.name): cloud path \(path) is free, claimed")
            return nil
        }
    }

    /// Restore of a file: the cloud item must still be what the placeholder recorded (same kind,
    /// same size). Otherwise someone replaced it and the download would bring back other data.
    /// A cloud item that cannot be read is left to rclone (it explains "not found"); no connection
    /// makes the job wait behind the cloud gate.
    private func restoreCloudMismatch(_ job: UploadJob) async -> Preflight? {
        let info: RcloneItemInfo
        switch await Rclone.remoteInfo(job.remoteItemPath) {
        case .failure(let e) where e.isNetwork: return .network(e.logText)
        case .failure: return nil
        case .success(let v): info = v
        }
        let isDir = info.IsDir == true
        if isDir != job.isDirectory {
            return .failed("В Облаке по этому пути теперь \(isDir ? "папка" : "файл"), а ярлык ждёт \(job.isDirectory ? "папку" : "файл"). Возвращать не стал, ярлык оставлен на месте.")
        }
        if !isDir, let want = job.sourceBytes, let size = info.Size, size != want {
            return .failed("В Облаке лежит другой файл с этим именем (размер не совпал: в Облаке \(Fmt.size(size)), в ярлыке \(Fmt.size(want))). Возвращать не стал, ярлык оставлен на месте.")
        }
        return nil
    }

    /// Download, before every run: the destination folder exists and is writable, the cloud item
    /// exists and is what the job expects (file / folder), its size and file count are recorded on
    /// the job (persisted: the verification needs them), and the Mac has room for it plus 1 GiB.
    /// Already downloaded parts in the staging item count as room taken.
    private func downloadPreflight(_ job: UploadJob, run: Int) async -> Preflight {
        let id = job.id, folder = job.source.deletingLastPathComponent(), remote = job.remoteItemPath
        let name = (remote as NSString).lastPathComponent
        if let i = stillRunning(id, run: run) { jobs[i].phase = "Проверяю папку на Маке…" }
        if let problem = await Task.detached(priority: .userInitiated, operation: {
            LocalItems.downloadFolderProblem(folder)
        }).value {
            return .failed(problem)
        }
        guard let i = stillRunning(id, run: run) else { return .failed("") }
        jobs[i].phase = "Проверяю, что лежит в Облаке…"
        let info: RcloneItemInfo
        switch await Rclone.remoteInfo(remote) {
        case .failure(let e) where e.isNetwork:
            return .network(e.logText)
        case .failure(let e):
            // The user sees the humanized text, the log keeps rclone's own words.
            log("download \(name): cloud check failed: \(e.logText)")
            return .failed(Humanize.error(from: e.rawText, download: true))
        case .success(let v):
            info = v
        }
        let isDir = info.IsDir == true
        if isDir != job.isDirectory {
            return .failed("В Облаке «\(name)» теперь \(isDir ? "папка" : "файл"), а не \(job.isDirectory ? "папка" : "файл"). Скачивать не стал.")
        }
        var bytes: Int64, files: Int
        if isDir {
            guard let k = stillRunning(id, run: run) else { return .failed("") }
            jobs[k].phase = "Считаю размер в Облаке…"
            switch await Rclone.size(remote) {
            case .failure(let e) where e.isNetwork:
                return .network(e.logText)
            case .failure(let e):
                log("download \(name): cloud size failed: \(e.logText)")
                return .failed("Не смог посчитать размер «\(name)» в Облаке: \(e.localizedDescription)")
            case .success(let r):
                bytes = r.bytes; files = Int(r.count)
            }
        } else {
            bytes = max(0, info.Size ?? 0); files = 1
        }
        guard let k = stillRunning(id, run: run) else { return .failed("") }
        jobs[k].sourceBytes = bytes
        jobs[k].totalBytes = bytes
        jobs[k].expectedFiles = files
        jobs[k].bytes = min(jobs[k].bytes, bytes)
        log("download \(name): cloud has \(files) files, \(bytes) bytes")
        let staging = job.restoreStagingURL
        let room = await Task.detached(priority: .userInitiated) { () -> (free: Int64?, have: Int64) in
            (LocalItems.availableCapacity(at: folder), SourceSize.stats(staging)?.bytes ?? 0)
        }.value
        let margin: Int64 = 1 << 30
        let need = max(0, bytes - room.have)
        if let free = room.free, free <= need + margin {
            return .failed("На Маке не хватает места: нужно \(Fmt.size(need)) и ещё 1 ГБ запаса, а свободно \(Fmt.size(free)). Освободи место и нажми «Повторить».")
        }
        return .ok(nil)
    }

    /// rclone arguments of one run of the job.
    private static func arguments(for job: UploadJob) -> [String] {
        let remote = "\(Rclone.remote):\(job.remotePath)"
        var args: [String]
        switch job.kind {
        case .copy:
            args = ["copy", job.source.path, remote] + Rclone.copyFlags(download: false)
        case .evict:
            // Empty subfolders must reach the cloud too: the original goes to the Trash.
            // --immutable: never replace a cloud file that differs (by size, all mail.ru offers);
            // fail instead. Same-size files left by an earlier run of this job are skipped.
            args = ["copy", job.source.path, remote] + Rclone.copyFlags(download: false) + ["--immutable"]
            if job.isDirectory { args.append("--create-empty-src-dirs") }
        case .restore, .download:
            // Into the job's own hidden staging item; renamed into place after verification.
            let staging = job.restoreStagingURL.path
            if job.isDirectory {
                args = ["copy", remote, staging] + Rclone.copyFlags(download: true) + ["--create-empty-src-dirs"]
            } else {
                // A single file: no filters (rclone refuses them with copyto).
                args = ["copyto", remote, staging] + Rclone.transferFlags(download: true)
            }
        }
        if job.quiet { args += ["--bwlimit", quietBandwidth] }
        return args
    }

    private func launch(id: UUID) {
        guard let bin = Rclone.binary, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        // Errors of an earlier run must not decide how this one ends.
        jobs[i].lastError = nil
        jobs[i].lastErrorMessage = nil
        let job = jobs[i]
        // A run that continues earlier work (resume, retry) only reports what is left to upload.
        runs[id] = RunProgress(fromRemaining: job.bytes > 0, startedAt: Date(), baseSeconds: job.activeSeconds,
                               heldBytes: job.bytes)
        if job.sourceBytes == nil, !job.isDownload { measureSize(id) }

        // posix_spawn, not Process: Process decomposes ё/й in arguments, and mail.ru keeps
        // names precomposed, so folder copy/check of "Съёмка" found nothing (see ChildProcess).
        let p = ChildProcess(executable: bin, arguments: Self.arguments(for: job), environment: Rclone.environment,
                             stdout: .null, stderr: .pipe)
        buffers[id] = Data()
        p.stderrHandle?.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor in self?.consume(id: id, data: d) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            let err = proc.stderrHandle
            err?.readabilityHandler = nil
            let rest = err?.readDataToEndOfFile() ?? Data()
            Task { @MainActor in
                self?.consume(id: id, data: rest)
                self?.finish(id: id, status: status, reason: reason)
            }
        }
        do {
            try p.run()
            processes[id] = p
            // Saved at once: if the app dies now, the next launch can stop exactly this process.
            let pid = p.processIdentifier
            jobs[i].rclonePid = pid
            jobs[i].rcloneStartMicros = ProcessFacts.startMicros(pid)
            watch[id] = TransferWatch(now: Date())
            errorTails[id] = []
            saveNow()
            let route = job.isDownload
                ? "\(Rclone.remote):\(job.remotePath) -> \(job.restoreStagingURL.path)"
                : "\(job.source.path) -> \(Rclone.remote):\(job.remotePath)"
            log("start \(job.kind.rawValue) \(route)\(job.quiet ? " (quiet)" : "")")
        } catch {
            p.stderrHandle?.readabilityHandler = nil
            jobs[i].state = .failed("Не удалось запустить rclone: \(error.localizedDescription)")
            pump()
        }
    }

    private func consume(id: UUID, data: Data) {
        var buf = (buffers[id] ?? Data()) + data
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            handle(id: id, line: line)
        }
        buffers[id] = buf
    }

    private func handle(id: UUID, line: Data) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        watch[id]?.lastReport = Date()
        guard let entry = try? JSONDecoder().decode(RcloneLogLine.self, from: line) else {
            if let s = String(data: line, encoding: .utf8), !s.isEmpty {
                // A line that could carry a credential is never written to the log.
                let lower = s.lowercased()
                log(lower.contains("pass") || lower.contains("authorization") ? "raw: [скрыто]" : "raw: \(s)")
                noteError(id: id, s)
            }
            return
        }
        if let m = entry.msg, m.hasPrefix("Attempt "), m.contains(" failed") {
            // rclone retries the whole copy and keeps adding to its stats: from now on count
            // progress from what is left, not from the inflated byte counter.
            runs[id]?.fromRemaining = true
            runs[id]?.restartListing(heldBytes: jobs[i].bytes)
        }
        if let st = entry.stats {
            noteProgress(st, id: id, index: i)
            // Updated on every stats tick, so a run cut short by kill -9 still counts (saved queue).
            updateActiveTime(id: id, index: i)
            applyProgress(st, index: i, id: id)
            if let s = st.speed { jobs[i].speed = s }
            if let e = st.eta {
                jobs[i].eta = e
            } else if let s = st.speed, s > 0, let t = st.totalBytes, let b = st.bytes, t > b {
                jobs[i].eta = Double(t - b) / s
            } else {
                jobs[i].eta = nil
            }
            if let d = st.transfers { jobs[i].filesDone = d }
            if let t = st.totalTransfers { jobs[i].filesTotal = t }
            jobs[i].currentFile = st.transferring?.first?.name
            if let e = st.lastError, !e.isEmpty { jobs[i].lastError = e; jobs[i].lastErrorMessage = e }
        } else if ["error", "critical", "fatal"].contains(entry.level ?? ""), let m = entry.msg {
            jobs[i].lastError = (entry.object.map { "\($0): " } ?? "") + m
            jobs[i].lastErrorMessage = m
            noteError(id: id, m)
            log("rclone error: \(jobs[i].lastError ?? m)")
        }
    }

    /// Keeps the last few error messages of the run: a network outage is often said a few lines
    /// above the final summary.
    private func noteError(id: UUID, _ message: String) {
        var tail = errorTails[id] ?? []
        tail.append(message)
        if tail.count > 8 { tail.removeFirst(tail.count - 8) }
        errorTails[id] = tail
    }

    /// Watchdog bookkeeping for one stats tick: when the run last gained bytes or files, and
    /// whether a file is still being sent (an upload that sent everything waits for the server).
    private func noteProgress(_ st: RcloneStats, id: UUID, index i: Int) {
        guard var w = watch[id] else { return }
        let now = Date()
        let bytes = st.bytes ?? 0
        let progress = bytes + Int64(st.transfers ?? 0) + Int64(st.checks ?? 0)
        if progress > w.progress {
            if w.progress >= 0 || progress > 0 { w.lastGain = now }
            w.progress = progress
        }
        // While rclone lists the cloud nothing moves yet, but its totals grow: that is activity too.
        let listed = (st.totalBytes ?? 0) + Int64(st.totalTransfers ?? 0) + Int64(st.totalChecks ?? 0)
        if listed > w.listed {
            w.listed = listed
            w.lastGain = now
        }
        if bytes > w.bytes {
            w.bytes = bytes
            w.lastByteGain = now
        }
        w.midBody = st.transferring?.contains { ($0.bytes ?? 0) < ($0.size ?? 0) } ?? false
        watch[id] = w
        if w.lastGain == now, jobs[i].phase == Self.stallPhase { jobs[i].phase = nil }
        if bytes > 0, jobs[i].restarting { jobs[i].restarting = false }
    }

    /// Turns one rclone stats line into whole-job progress. rclone's own counters describe only
    /// the current run: a resumed run that skips uploaded files reports a small (or zero) total,
    /// and `--retries` attempts add up, so they can exceed the real size.
    private func applyProgress(_ st: RcloneStats, index i: Int, id: UUID) {
        let runBytes = st.bytes ?? 0
        let runTotal = st.totalBytes ?? 0
        let size = jobs[i].sourceBytes ?? max(jobs[i].totalBytes, runTotal)
        jobs[i].totalBytes = size
        var done: Int64
        if runs[id]?.fromRemaining == true {
            // rclone's total grows while its checkers list the cloud, so "what is left" starts small
            // and grows: progress would jump to ~99% and slide back. Hold the earlier value
            // (and say "checking") until the total stops growing.
            let listed = runs[id]?.observe(total: runTotal, checks: st.checks ?? 0, totalChecks: st.totalChecks ?? 0) ?? true
            jobs[i].verifying = !listed
            guard listed, runTotal > 0 else {
                jobs[i].bytes = min(runs[id]?.heldBytes ?? jobs[i].bytes, size > 0 ? size : .max)
                return
            }
            done = size - max(0, runTotal - runBytes)
            // Never more than really happened: what was done before this run plus what this run
            // moved. rclone's totals can shrink (failed transfers drop out) and would show 100 %.
            done = min(done, (runs[id]?.heldBytes ?? 0) + runBytes)
        } else {
            done = runBytes
        }
        done = max(0, done)
        if size > 0 { done = min(done, size) }
        // In-flight files begin again from zero after a restart: the bar steps back once, honestly.
        if done + Self.stepBackNotice < jobs[i].bytes { jobs[i].fileRestartedAt = Date() }
        jobs[i].bytes = done
    }

    /// Measures the source size once, in the background.
    private func measureSize(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let url = job.source
        Task { @MainActor [weak self] in
            guard let size = await SourceSize.measure(url),
                  let self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            self.jobs[i].sourceBytes = size
            self.jobs[i].totalBytes = size
            self.jobs[i].bytes = self.jobs[i].state == .done ? size : min(self.jobs[i].bytes, size)
        }
    }

    /// Run time so far = time of earlier runs + time since this run started.
    private func updateActiveTime(id: UUID, index i: Int) {
        guard let r = runs[id] else { return }
        jobs[i].activeSeconds = r.baseSeconds + Date().timeIntervalSince(r.startedAt)
    }

    private func finish(id: UUID, status: Int32, reason: ChildProcess.TerminationReason) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { updateActiveTime(id: id, index: i) }
        processes[id] = nil
        buffers[id] = nil
        runs[id] = nil
        let movedBytes = watch.removeValue(forKey: id)?.bytes ?? 0
        var errorText = (errorTails.removeValue(forKey: id) ?? []).joined(separator: "\n")
        var status = status
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].verifying = false }
        // On quit the saved queue already says "running": leave it so the job resumes next launch.
        if quitting { return }
        if devFakeGatewayLeft > 0, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running,
           status == 0, reason == .exit, jobs[i].kind == .copy || jobs[i].kind == .evict {
            // Dev test hook: this successful upload run counts as a gateway answer after the body.
            devFakeGatewayLeft -= 1
            status = 1
            errorText = "Failed to copy: 504 Gateway Time-out (dev fake)"
            log("dev: run of \(jobs[i].name) finished fine, treated as 504 Gateway Time-out (\(devFakeGatewayLeft) fakes left)")
        }
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].rclonePid = nil
            jobs[i].rcloneStartMicros = nil
            if jobs[i].state == .running, status == 0, reason == .exit, jobs[i].kind != .copy {
                // rclone is done; the job is not: verify, then trash the original / placeholder.
                // It stays "running" so the queue waits for it.
                gatewayStrikes[id] = nil
                jobs[i].speed = 0
                jobs[i].eta = nil
                jobs[i].currentFile = nil
                jobs[i].phase = "Сверяю с Облаком…"
                let run = runIDs[id] ?? 0
                Task { @MainActor [weak self] in await self?.finalize(id, run: run) }
                return
            }
            jobs[i].speed = 0
            jobs[i].eta = nil
            switch jobs[i].state {
            case .paused, .queued:
                // Stopped by pause, the cloud gate or a restart (and maybe already queued again):
                // not an outcome of the job.
                let why = jobs[i].waitingForNetwork ? "to wait for the network"
                    : jobs[i].restarting ? "for a restart" : "for pause"
                log("stopped \(jobs[i].name) \(why)")
            case .cancelled:
                jobs[i].finishedAt = Date()
                log("cancelled \(jobs[i].name)")
            case .running where status == 0 && reason == .exit:
                networkStrikes[id] = nil
                gatewayStrikes[id] = nil
                jobs[i].finishedAt = Date()
                jobs[i].state = .done
                if let size = jobs[i].sourceBytes { jobs[i].totalBytes = size }
                jobs[i].bytes = jobs[i].totalBytes
                log("done \(jobs[i].name) \(Fmt.size(jobs[i].totalBytes))")
                Notifier.shared.jobDone(jobs[i])
                onJobDone?()
            case .done, .failed, .refused, .blocked:
                // The outcome is already set (e.g. an evict that finished): a late exit of an
                // old process never turns "done" into "failed".
                log("ignored exit \(status) of \(jobs[i].name): job already finished")
            case .running:
                // Classify the messages only: the file name may contain digits like 403 or 507.
                let text = [errorText, jobs[i].lastErrorMessage ?? jobs[i].lastError ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                if Account.isAuthError(text) {
                    // 401/403 on a run: one probe of the cloud root tells a refused password (the
                    // job waits for sign-in) from a single forbidden file (the job fails).
                    requeue(i)
                    confirmAuthFailure(id: id, text: text, status: status)
                    return
                }
                if Humanize.isNetwork(text, listing: false) {
                    gatewayStrikes[id] = nil
                    // A run that was advancing before it broke: earlier network errors do not count.
                    if movedBytes >= Self.strikeResetBytes { networkStrikes[id] = nil }
                    requeue(i)
                    networkFailure(id: id, text: text, logLine: "network error on \(jobs[i].name), requeued: \(Rclone.tail(text))")
                    return
                }
                if jobs[i].kind == .copy || jobs[i].kind == .evict, Humanize.isGatewayAfterUpload(text) {
                    let strikes = (gatewayStrikes[id] ?? 0) + 1
                    if strikes <= Self.gatewayRetryLimit {
                        gatewayStrikes[id] = strikes
                        holdForCloudFinishing(i, attempt: strikes, text: text)
                        break
                    }
                    gatewayStrikes[id] = nil
                    log("\(jobs[i].name): gateway answer again after \(Self.gatewayRetryLimit) delayed restarts, giving up")
                } else {
                    gatewayStrikes[id] = nil
                }
                failRun(i, text: text.isEmpty ? "rclone exit code \(status)" : text, status: status)
            }
        }
        pump()
    }

    // MARK: Cloud finishing a big file

    /// Mail.ru answers 504 (sometimes 502/503/408) about a minute after the last byte of a big PUT
    /// while it is still finalizing the file; the file usually lands by itself 5-190 s later. rclone
    /// runs with `--retries 1`, so the app starts such an upload again later itself: rclone then
    /// skips the landed file by size and the normal completion (and an evict's verification) decides.
    static let gatewayRetryLimit = 4

    /// The row's line while the job waits for its delayed start.
    private var cloudFinishingPhase: String {
        let wait = gatewayDelay >= 60 ? "\(Int((gatewayDelay / 60).rounded())) мин" : "\(Int(gatewayDelay)) с"
        return "Облако доделывает большой файл, проверю через \(wait)"
    }

    /// The job's rclone has exited with a gateway answer: back to the queue, but `pump` does not
    /// start it before `gatewayDelay` has passed. The cloud gate stays open and other queued jobs
    /// may run meanwhile. A cancel, remove or retry drops the hold (its token no longer matches).
    private func holdForCloudFinishing(_ i: Int, attempt: Int, text: String) {
        let id = jobs[i].id, name = jobs[i].name, delay = gatewayDelay
        requeue(i)
        jobs[i].phase = cloudFinishingPhase
        nextHoldToken += 1
        let token = nextHoldToken
        cloudFinishingHolds[id] = token
        log("\(name): gateway answer after the upload (\(Rclone.tail(text))), the cloud may still be finishing the file: starting again in \(Int(delay)) s (\(attempt) of \(Self.gatewayRetryLimit))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.endCloudFinishingHold(id, token: token)
        }
    }

    private func endCloudFinishingHold(_ id: UUID, token: Int) {
        // Cancelled, removed or retried meanwhile: another token (or none) is there now.
        guard cloudFinishingHolds[id] == token else { return }
        cloudFinishingHolds[id] = nil
        guard !quitting, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].phase == cloudFinishingPhase { jobs[i].phase = nil }
        guard jobs[i].state == .queued else { return }
        log("\(jobs[i].name): delay over, queued to start again")
        pump()
    }

    /// The job's rclone failed for good: the humanized reason on the row and in a notification.
    private func failRun(_ i: Int, text: String, status: Int32) {
        jobs[i].finishedAt = Date()
        var msg = Humanize.error(from: text, download: jobs[i].isDownload, restore: jobs[i].kind == .restore)
        switch jobs[i].kind {
        case .copy, .download: break
        case .evict: msg += " Оригинал оставлен на месте."
        case .restore: msg += " Ярлык оставлен на месте."
        }
        jobs[i].state = .failed(msg)
        log("failed \(jobs[i].name): \(text.isEmpty ? (jobs[i].lastError ?? "exit \(status)") : Rclone.tail(text))")
        Notifier.shared.jobFailed(jobs[i], message: msg)
    }

    /// A job (already requeued) ended on 401/403. The probe sees the same refusal on the cloud root:
    /// the account is marked (the probe does it) and the job waits for sign-in. It gets through:
    /// the refusal was about this job, which fails. It cannot reach the cloud: the gate closes.
    private func confirmAuthFailure(id: UUID, text: String, status: Int32) {
        checkingAfterNetworkError = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.probeResult()
            self.checkingAfterNetworkError = false
            guard let k = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[k].state == .queued else {
                self.pump(); return
            }
            switch result {
            case .auth:
                self.log("\(self.jobs[k].name): the cloud refused the password, waiting for sign-in")
            case .ok:
                self.failRun(k, text: text, status: status)
            case .network:
                self.jobs[k].waitingForNetwork = true
                self.closeGate(reason: "auth-like error on \(self.jobs[k].name), probe failed")
            }
            self.pump()
        }
    }

    /// A job (already requeued) hit a network-class error: in its rclone run, in a cloud check
    /// before it, or in the verification after it. One probe decides. The cloud does not answer:
    /// the gate closes and the job waits. It answers: the job starts again, but the third such
    /// failure in a row (the cloud answering each time) is a real failure.
    private func networkFailure(id: UUID, text: String, logLine: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let name = jobs[i].name
        log(logLine)
        checkingAfterNetworkError = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.probe()
            self.checkingAfterNetworkError = false
            guard ok else {
                if let k = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[k].state == .queued {
                    self.jobs[k].waitingForNetwork = true
                }
                self.closeGate(reason: "network error on \(name), probe failed")
                return
            }
            let strikes = (self.networkStrikes[id] ?? 0) + 1
            self.networkStrikes[id] = strikes
            if let k = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[k].state == .queued {
                if strikes >= Self.networkStrikeLimit {
                    self.networkStrikes[id] = nil
                    self.failRun(k, text: text, status: 1)
                } else {
                    self.log("cloud answers, starting \(name) again (network error \(strikes) of \(Self.networkStrikeLimit))")
                }
            }
            self.pump()
        }
    }

    // MARK: Evict / restore: after rclone

    private func finalize(_ id: UUID, run: Int) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.kind {
        case .copy: break
        case .evict: await finalizeEvict(job, run: run)
        case .restore: await finalizeRestore(job, run: run)
        case .download: await finalizeDownload(job, run: run)
        }
        // A newer run (paused and resumed meanwhile) owns the row's phase now.
        if runIDs[id] == run, let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].phase = nil
            jobs[i].committing = false
        }
        pump()
    }

    /// Index of the job if it is still running in the same run and the app is not quitting:
    /// a pause, cancel or quit while verifying stops the pipeline before anything is trashed,
    /// and a verification from before a pause never acts on the run started by "Продолжить".
    private func stillRunning(_ id: UUID, run: Int) -> Int? {
        guard !quitting, runIDs[id] == run, let i = jobs.firstIndex(where: { $0.id == id }),
              jobs[i].state == .running else { return nil }
        return i
    }

    /// A verification that could not reach the cloud is not a verdict: the job waits behind the
    /// cloud gate and runs again (rclone skips what is complete), then verifies again.
    private func deferVerifyForNetwork(_ i: Int, _ failure: String) -> Bool {
        guard Humanize.isNetwork(failure, listing: true) else { return false }
        waitForNetwork(i, text: failure,
                       logLine: "\(jobs[i].name): verification could not reach the cloud (\(failure)), requeued")
        return true
    }

    private func finishFailed(_ i: Int, _ message: String, logText: String) {
        jobs[i].state = .failed(message)
        jobs[i].finishedAt = Date()
        log("failed \(jobs[i].kind.rawValue) \(jobs[i].name): \(logText)")
        Notifier.shared.jobFailed(jobs[i], message: message)
    }

    /// Upload verified → placeholder written → original moved to the Trash. Any doubt leaves the
    /// original where it is.
    private func finalizeEvict(_ job: UploadJob, run: Int) async {
        let id = job.id, url = job.source, remote = job.remoteItemPath
        let notAll = "Не всё долетело в Облако, оригинал оставлен на месте"
        let stats = await Task.detached(priority: .userInitiated) { SourceSize.stats(url) }.value
        guard stillRunning(id, run: run) != nil else { return }
        guard let stats, let expected = snapshots[id] else {
            if let i = stillRunning(id, run: run) { finishFailed(i, notAll, logText: "cannot measure local item") }
            return
        }
        let failure: String?
        if job.isDirectory {
            failure = await Rclone.verifyFolder(source: url.path, dest: "\(Rclone.remote):\(remote)")
        } else {
            failure = await Rclone.verifyFile(remotePath: remote, localSize: stats.bytes)
        }
        guard let i = stillRunning(id, run: run) else { return }
        if let failure {
            if deferVerifyForNetwork(i, failure) { return }
            finishFailed(i, notAll, logText: "verify: \(failure)")
            return
        }
        // From here on pause and cancel wait: the move to the Trash is not interrupted halfway.
        jobs[i].committing = true
        jobs[i].phase = "Убираю оригинал в Корзину…"
        let placeholder = Placeholder(remotePath: remote, originalName: job.name, isDirectory: job.isDirectory,
                                      size: stats.bytes, fileCount: stats.files, evictedAt: Date())
        let outcome = await Task.detached(priority: .userInitiated) {
            LocalItems.trashOriginal(url, placeholder: placeholder, expected: expected)
        }.value
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[j].committing = false
        switch outcome {
        case .failed(let m):
            finishFailed(j, m, logText: m)
        case .done(let placeholderURL, let freed):
            jobs[j].state = .done
            jobs[j].finishedAt = Date()
            jobs[j].placeholderPath = placeholderURL.path
            jobs[j].freedBytes = freed
            if let size = jobs[j].sourceBytes { jobs[j].totalBytes = size }
            jobs[j].bytes = jobs[j].totalBytes
            addFreed(freed)
            log("evicted \(job.name) \(Fmt.size(freed)) -> \(Rclone.remote):\(remote), placeholder \(placeholderURL.path)")
            Notifier.shared.jobDone(jobs[j])
            onJobDone?()
        }
    }

    /// Download verified → renamed from the staging name into place (never over an existing item)
    /// → placeholder moved to the Trash.
    private func finalizeRestore(_ job: UploadJob, run: Int) async {
        let id = job.id, dest = job.source, remote = job.remoteItemPath
        let staging = job.restoreStagingURL
        let ph = job.placeholderPath.map { URL(fileURLWithPath: $0) }
        var failure: String?
        /// Shown instead of the generic text: the cloud holds other data than the placeholder says.
        var replacedInCloud = false
        if job.isDirectory {
            failure = await Rclone.verifyFolder(source: "\(Rclone.remote):\(remote)", dest: staging.path)
            if failure == nil {
                // `rclone check` passes on an empty or unlistable cloud folder (nothing to compare),
                // so also require what the placeholder says was evicted to be back on the Mac.
                let expectedBytes = job.sourceBytes ?? 0
                failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    let p = ph.flatMap { try? Placeholder.read(from: $0) }
                    let wantBytes = p?.size ?? expectedBytes, wantFiles = p?.fileCount ?? 0
                    guard let got = SourceSize.stats(staging) else { return "local folder missing after download" }
                    if got.files < wantFiles || got.bytes < wantBytes {
                        return "restored \(got.files) files / \(got.bytes) bytes, placeholder says \(wantFiles) / \(wantBytes)"
                    }
                    return nil
                }.value
            }
        } else {
            // The placeholder's size is the last record of what was evicted: the cloud file may
            // have been replaced since (same name, other data), and then it must not come back.
            let expectedBytes = job.sourceBytes
            let sizes = await Task.detached(priority: .userInitiated) { () -> (local: Int64?, want: Int64?) in
                let want = ph.flatMap { try? Placeholder.read(from: $0) }?.size ?? expectedBytes
                guard let v = try? staging.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { return (nil, want) }
                return (Int64(v.fileSize ?? 0), want)
            }.value
            if let localSize = sizes.local {
                if let want = sizes.want, localSize != want {
                    failure = "downloaded \(localSize) bytes, placeholder says \(want)"
                    replacedInCloud = true
                } else {
                    failure = await Rclone.verifyFile(remotePath: remote, localSize: localSize)
                }
            } else {
                failure = "local file missing after download"
            }
        }
        guard let i = stillRunning(id, run: run) else { return }
        if let failure {
            if !replacedInCloud, deferVerifyForNetwork(i, failure) { return }
            if replacedInCloud {
                // The download is someone else's data: out of the way (to the Trash), placeholder kept.
                _ = await Task.detached(priority: .userInitiated) { LocalItems.trashPlaceholder(staging) }.value
                guard let k = stillRunning(id, run: run) else { return }
                finishFailed(k, "В Облаке лежит другой файл с этим именем (размер не совпал с ярлыком). Возвращать не стал: скачанное убрал в Корзину, ярлык оставлен на месте.",
                             logText: "verify: \(failure)")
            } else {
                finishFailed(i, "Скачалось не всё: на Маке не то же, что в Облаке. Ярлык оставлен, можно нажать «Повторить».",
                             logText: "verify: \(failure)")
            }
            return
        }
        jobs[i].committing = true
        jobs[i].phase = "Кладу на место…"
        let moveError = await Task.detached(priority: .userInitiated) {
            LocalItems.moveIntoPlace(staging: staging, destination: dest)
        }.value
        if let moveError {
            guard let k = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[k].committing = false
            finishFailed(k, moveError, logText: "rename \(staging.path) -> \(dest.path) failed")
            return
        }
        if let k = jobs.firstIndex(where: { $0.id == id }) { jobs[k].phase = "Убираю ярлык в Корзину…" }
        var trashError: String?
        if let ph {
            trashError = await Task.detached(priority: .userInitiated) { LocalItems.trashPlaceholder(ph) }.value
        }
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[j].committing = false
        jobs[j].state = .done
        jobs[j].finishedAt = Date()
        jobs[j].bytes = jobs[j].totalBytes
        if let trashError {
            jobs[j].note = "Файл вернулся, но ярлык не убрался в Корзину (\(trashError)). Его можно удалить самому."
        }
        log("restored \(job.name) <- \(Rclone.remote):\(remote)\(trashError.map { ", placeholder kept: \($0)" } ?? "")")
        Notifier.shared.jobDone(jobs[j])
        onJobDone?()
    }

    /// Download verified against what preflight recorded (file: exact size; folder: `rclone check`
    /// with 0 differences, and at least the expected files and bytes on the Mac) → renamed from the
    /// staging item to the planned name, or the next free one, never over an existing item.
    /// A failed verification leaves the staging item where it is: "Повторить" continues into it.
    private func finalizeDownload(_ job: UploadJob, run: Int) async {
        let id = job.id, remote = job.remoteItemPath, staging = job.restoreStagingURL
        let wantBytes = job.sourceBytes ?? 0, wantFiles = job.expectedFiles ?? (job.isDirectory ? 0 : 1)
        let kept = "Недокачанное лежит рядом в скрытом «\(staging.lastPathComponent)», «Повторить» докачает."
        var problem: String?
        var logText = ""
        if job.isDirectory {
            if let f = await Rclone.verifyFolder(source: "\(Rclone.remote):\(remote)", dest: staging.path) {
                problem = "при сверке с Облаком нашлись отличия"
                logText = f
            } else {
                let got = await Task.detached(priority: .userInitiated) { SourceSize.stats(staging) }.value
                if let got {
                    if got.files < wantFiles || got.bytes < wantBytes {
                        problem = "на Маке \(Fmt.files(got.files)) (\(Fmt.size(got.bytes))), а в Облаке \(Fmt.files(wantFiles)) (\(Fmt.size(wantBytes)))"
                        logText = "local \(got.files) files / \(got.bytes) bytes, expected \(wantFiles) / \(wantBytes)"
                    }
                } else {
                    problem = "скачанная папка не нашлась"
                    logText = "staging folder missing after download"
                }
            }
        } else {
            let local = await Task.detached(priority: .userInitiated) { () -> Int64? in
                guard let v = try? staging.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      v.isRegularFile == true else { return nil }
                return Int64(v.fileSize ?? 0)
            }.value
            if let local {
                if local != wantBytes {
                    problem = "на Маке \(Fmt.size(local)), а в Облаке \(Fmt.size(wantBytes))"
                    logText = "local \(local) bytes, expected \(wantBytes)"
                }
            } else {
                problem = "скачанный файл не нашёлся"
                logText = "staging file missing after download"
            }
        }
        guard let i = stillRunning(id, run: run) else { return }
        if let problem {
            if deferVerifyForNetwork(i, logText) { return }
            finishFailed(i, "Скачалось не всё: \(problem). \(kept)", logText: "verify: \(logText)")
            return
        }
        jobs[i].committing = true
        jobs[i].phase = "Кладу на место…"
        let preferred = job.source, originalName = (remote as NSString).lastPathComponent
        let isDir = job.isDirectory, reserved = reservedLocalPaths(except: id)
        let moved = await Task.detached(priority: .userInitiated) {
            LocalItems.moveIntoFreeName(staging: staging, preferred: preferred, originalName: originalName,
                                        isDirectory: isDir, reserved: reserved)
        }.value
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[j].committing = false
        switch moved {
        case .failure(let e):
            finishFailed(j, e.message, logText: "rename \(staging.path) -> \(preferred.path) failed")
        case .success(let final):
            if final.path != preferred.path {
                jobs[j].note = "Имя «\(preferred.lastPathComponent)» заняли, пока шло скачивание: положил как «\(final.lastPathComponent)»."
            }
            jobs[j].source = final
            jobs[j].state = .done
            jobs[j].finishedAt = Date()
            jobs[j].totalBytes = wantBytes
            jobs[j].bytes = wantBytes
            log("downloaded \(Rclone.remote):\(remote) -> \(final.path), verified \(wantFiles) files, \(wantBytes) bytes")
            // Not the debounced save: a crash right after the rename must not find the job still
            // "running" in queue.json and download the whole item a second time.
            saveNow()
            Notifier.shared.jobDone(jobs[j])
            onJobDone?()
        }
    }

    private func addFreed(_ bytes: Int64) {
        freedBytes += max(0, bytes)
        UserDefaults.standard.set(NSNumber(value: freedBytes), forKey: Self.freedKey)
    }

    // MARK: Cloud gate, stall watchdog, wake

    /// Shown on a running row whose rclone has gained nothing for `stallNotice` seconds.
    static let stallPhase = "Нет ответа от Облака, проверяю связь…"
    /// No gain for this long: the row says so and one probe runs.
    static let stallNotice: TimeInterval = 30
    /// The cloud answers but a download gained nothing for this long: it is restarted.
    static let downloadStall: TimeInterval = 90
    /// The same for an upload that is still sending a file (one that sent everything and waits
    /// for the server is left to rclone's --timeout).
    static let uploadStall: TimeInterval = 180
    /// A folder download that has not received its first byte yet may still be listing the cloud
    /// (copy lists everything before it sends, and one big folder can answer slowly): longer limit.
    static let listingStall: TimeInterval = 300
    /// A stopped rclone that is still alive this long after SIGTERM gets SIGKILL.
    static let killGrace: TimeInterval = 5
    /// A run that moved at least this much before its network error was advancing: the
    /// network-error count of the job starts again from this failure.
    static let strikeResetBytes: Int64 = 32 << 20
    /// After a wake: jobs that gained no bytes since before the sleep this long after it restart.
    static let wakeGrace: TimeInterval = 20
    /// Probe interval while the gate is closed: 15 s for the first 2 minutes, then 30 s.
    static let gateFastProbe: TimeInterval = 15
    static let gateSlowProbe: TimeInterval = 30
    static let gateFastPeriod: TimeInterval = 120
    /// Network-class failures in a row (with the cloud answering) before a job fails for real.
    static let networkStrikeLimit = 3
    /// A drop of the shown progress by more than this is announced as «начал файл заново».
    static let stepBackNotice: Int64 = 1 << 20

    /// Watchdog timer, network path changes, sleep and wake. The dev build also takes SIGUSR1
    /// as a simulated wake (tests cannot put the Mac to sleep).
    private func startResilience() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        // The tick returns at once while nothing runs; the tolerance lets the system batch it.
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        watchdogTimer = t

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleptAt = Date()
                AppLog.write("sleep: the Mac goes to sleep")
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake(source: "system") }
        }

        if AppPaths.isDev {
            signal(SIGUSR1, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.handleWake(source: "dev SIGUSR1") }
            }
            src.resume()
            wakeSignal = src
        }
    }

    enum ProbeResult { case ok, network, auth }

    /// Pause before a refused probe is asked once more: a single 401/403 (a short anti-abuse
    /// block, a load balancer hiccup) must not park the whole queue.
    static let authConfirmDelay: TimeInterval = 10

    /// One probe of the cloud: `rclone lsjson --stat mailru:` with short timeouts. It gets the
    /// app's environment like every rclone (so a test proxy cuts it too). Callers that ask while a
    /// probe runs share its answer. A refused password (401/403) is not a network problem: the cloud
    /// answers, so the gate stays open. Only a second refusal in a row, `authConfirmDelay` later,
    /// marks the account (nothing starts until the password is accepted again); a probe that gets
    /// through clears that mark.
    private func probeResult() async -> ProbeResult {
        if let running = probeTask { return await running.value }
        let task = Task { @MainActor () -> ProbeResult in
            // One attempt only: with rclone's default 10 low-level retries a probe on a link that
            // drops packets takes about a minute instead of the 5-10 s the gate cadence assumes.
            func once() async -> ProbeResult {
                let r = try? await Rclone.capture(["lsjson", "--stat", "\(Rclone.remote):", "--contimeout", "5s", "--timeout", "10s",
                                                   "--low-level-retries", "1", "--retries", "1"])
                guard let r else { return .network }
                if r.status == 0 { return .ok }
                return Account.isAuthError(r.err) ? .auth : .network
            }
            var result = await once()
            if result == .auth, Account.shared.state.isConnected {
                AppLog.write("probe: the cloud refused the password, asking again in \(Int(Self.authConfirmDelay)) s")
                try? await Task.sleep(nanoseconds: UInt64(Self.authConfirmDelay * 1_000_000_000))
                result = await once()
            }
            switch result {
            case .ok: Account.shared.cloudAccepted()
            case .auth: Account.shared.markAuthFailed()
            case .network: break
            }
            return result
        }
        probeTask = task
        let result = await task.value
        if probeTask == task { probeTask = nil }
        return result
    }

    #if CLOUDMAIL_DEV
    /// Dev self-test: one probe as the gate runs it.
    func devProbeResult() async -> ProbeResult { await probeResult() }
    #endif

    /// True when the cloud answered (also with a refused password: see `probeResult`).
    private func probe() async -> Bool {
        await probeResult() != .network
    }

    /// Puts a running job back into the queue, stopping its rclone (SIGTERM, as pause does). The
    /// progress stays; rclone skips complete files and begins in-flight ones again from zero.
    private func requeue(_ i: Int, restarting: Bool = false) {
        jobs[i].state = .queued
        jobs[i].phase = nil
        jobs[i].speed = 0
        jobs[i].eta = nil
        jobs[i].currentFile = nil
        jobs[i].verifying = false
        if restarting { jobs[i].restarting = true }
        if let p = processes[jobs[i].id] { terminate(p) }
    }

    /// A cloud check or verification of a job could not reach the cloud: the job goes back to the
    /// queue and one probe decides, with the same three-in-a-row rule as a failed rclone run (a
    /// path that times out every time while the cloud answers must not loop forever).
    private func waitForNetwork(_ i: Int, text: String, logLine: String) {
        requeue(i)
        networkFailure(id: jobs[i].id, text: text, logLine: logLine)
    }

    /// Closes the cloud gate: every running job goes back to the queue (its rclone is stopped),
    /// nothing starts, and a probe runs every 15 s (30 s after 2 minutes) until the cloud answers.
    /// The gate never gives up and never fails a job.
    private func closeGate(reason: String) {
        if cloudReachable {
            cloudReachable = false
            gateClosedAt = Date()
            log("cloud unreachable (\(reason)): gate closed, transfers wait for the network")
        }
        networkStrikes.removeAll()
        for i in jobs.indices where jobs[i].state == .running && !jobs[i].committing {
            requeue(i)
        }
        for i in jobs.indices where jobs[i].state == .queued { jobs[i].waitingForNetwork = true }
        if gateLoop == nil { startGateLoop(probeNow: false) }
    }

    private func openGate() {
        gateLoop?.cancel()
        gateLoop = nil
        guard !cloudReachable else { return }
        let closedFor = gateClosedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        cloudReachable = true
        gateClosedAt = nil
        for i in jobs.indices where jobs[i].waitingForNetwork { jobs[i].waitingForNetwork = false }
        log("cloud reachable again after \(closedFor) s: gate open")
        pump()
    }

    /// The probe loop of a closed gate. `probeNow`: the network just came back or the Mac woke up.
    private func startGateLoop(probeNow: Bool) {
        gateLoop?.cancel()
        gateLoop = Task { @MainActor [weak self] in
            var now = probeNow
            while let self, !self.cloudReachable, !Task.isCancelled {
                if !now {
                    let closedFor = Date().timeIntervalSince(self.gateClosedAt ?? Date())
                    let wait = closedFor < Self.gateFastPeriod ? Self.gateFastProbe : Self.gateSlowProbe
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                now = false
                if await self.probe() {
                    self.openGate()
                    return
                }
            }
        }
    }

    private func pathChanged(satisfied: Bool) {
        defer { pathSatisfied = satisfied }
        guard let was = pathSatisfied, was != satisfied else { return }
        log("network path \(satisfied ? "satisfied" : "unsatisfied")")
        if satisfied, !cloudReachable { startGateLoop(probeNow: true) }
    }

    /// Every 5 s: a running rclone that gained nothing for 30 s gets one probe (at most every 30 s).
    private func watchdogTick() {
        let now = Date()
        for i in jobs.indices {
            if let t = jobs[i].fileRestartedAt, now.timeIntervalSince(t) > 6 { jobs[i].fileRestartedAt = nil }
        }
        guard cloudReachable else { return }
        for (id, w) in watch where !w.probing && processes[id] != nil {
            guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running else { continue }
            let idle = now.timeIntervalSince(w.lastGain)
            guard idle >= Self.stallNotice else { continue }
            if let last = w.lastProbe, now.timeIntervalSince(last) < Self.stallNotice { continue }
            watch[id]?.probing = true
            watch[id]?.lastProbe = now
            // An upload that sent everything is waiting for the server: probe quietly, it is not stuck.
            // A folder download before its first byte may still be listing: probe quietly as well.
            if (jobs[i].isDownload && !Self.mayBeListing(jobs[i], w)) || w.midBody { jobs[i].phase = Self.stallPhase }
            log("\(jobs[i].name): no progress for \(Int(idle)) s (last rclone report \(Int(now.timeIntervalSince(w.lastReport))) s ago), probing the cloud")
            Task { @MainActor [weak self] in await self?.stallCheck(id) }
        }
    }

    /// A folder download whose run has received no byte and finished no file yet: rclone may
    /// still be listing the cloud.
    private static func mayBeListing(_ job: UploadJob, _ w: TransferWatch) -> Bool {
        job.isDownload && job.isDirectory && w.bytes == 0 && w.progress <= 0
    }

    private func stallCheck(_ id: UUID) async {
        let ok = await probe()
        watch[id]?.probing = false
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running,
              processes[id] != nil, let w = watch[id] else { return }
        let name = jobs[i].name
        guard ok else {
            closeGate(reason: "no progress from \(name), probe failed")
            return
        }
        let idle = Date().timeIntervalSince(w.lastGain)
        let limit: TimeInterval?
        if jobs[i].isDownload {
            limit = Self.mayBeListing(jobs[i], w) ? Self.listingStall : Self.downloadStall
        } else {
            limit = w.midBody ? Self.uploadStall : nil
        }
        if let limit, idle >= limit {
            log("\(name): stalled for \(Int(idle)) s while the cloud answers, restarting")
            requeue(i, restarting: true)
            pump()
        } else if jobs[i].phase == Self.stallPhase {
            // The cloud answers: say nothing until the next check (or until bytes flow again).
            jobs[i].phase = nil
        }
    }

    /// After a sleep every running transfer is suspect (its connections are likely dead): probe at
    /// once; no answer closes the gate. With an answer, jobs that gained no bytes since before the
    /// sleep are restarted 20 s later. A closed gate just probes now.
    private func handleWake(source: String) {
        guard !isDemo else { return }
        let wokeAt = Date()
        let reference = sleptAt ?? wokeAt
        sleptAt = nil
        let running = jobs.filter { $0.state == .running && processes[$0.id] != nil }.map(\.id)
        log("wake (\(source)): \(running.count) running, probing the cloud")
        if !cloudReachable {
            startGateLoop(probeNow: true)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.probe() else {
                self.closeGate(reason: "wake, probe failed")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.wakeGrace * 1_000_000_000))
            guard self.cloudReachable else { return }
            for id in running {
                guard let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .running,
                      self.processes[id] != nil, let w = self.watch[id], w.lastByteGain < reference else { continue }
                self.log("\(self.jobs[i].name): no bytes since before the wake, restarting")
                self.requeue(i, restarting: true)
            }
            self.pump()
        }
    }

    /// While any rclone of ours runs the Mac does not idle-sleep (the display still may).
    private func updateSleepActivity() {
        if !processes.isEmpty, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                  reason: "\(AppInfo.name): идёт передача")
        } else if processes.isEmpty, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
    }

    // MARK: Misc

    func openInBrowser(_ path: String? = nil) {
        NSWorkspace.shared.open(Rclone.webURL(for: path ?? destinationFolder))
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.url])
    }

    private func log(_ s: String) { AppLog.write(s) }

    // MARK: Persistence (queue.json)

    /// Writes at most about once a second while progress ticks.
    private func scheduleSave() {
        guard queueLoaded, !saveScheduled, !quitting else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.saveScheduled = false
            if !self.quitting { self.saveNow() }
        }
    }

    func saveNow() {
        guard queueLoaded else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let dir = Self.queueURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encoder.encode(jobs).write(to: Self.queueURL, options: .atomic)
        } catch {
            log("queue save failed: \(error.localizedDescription)")
        }
    }

    /// Puts the saved queue back (read off the main thread) and starts what was waiting.
    private func loadQueue() async {
        let loaded = await Task.detached(priority: .userInitiated) { UploadManager.readQueue() }.value
        queueLoaded = true
        // Nothing can be added meanwhile (drops wait for this task), but keep anything just in case.
        jobs = jobs + loaded.jobs
        for job in loaded.jobs where job.state.isActive && job.sourceBytes == nil && !job.isDownload {
            measureSize(job.id)
        }
        log("queue restored: \(loaded.jobs.count) jobs, \(loaded.resumed) to resume")
        pump()
    }

    /// Reads queue.json. Jobs that were queued/running go back to the queue (rclone skips what is
    /// already in the cloud), but only if their source still exists. Paused jobs stay paused
    /// (their process is gone; "resume" queues them again). File system and `ps`: call it off the
    /// main thread (a source on ~/Desktop may raise the macOS privacy prompt).
    nonisolated private static func readQueue() -> (jobs: [UploadJob], resumed: Int) {
        guard let data = try? Data(contentsOf: queueURL) else { return ([], 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let lossy = try? decoder.decode([LossyJob].self, from: data) else {
            // Not even a list: move it aside before the first save would overwrite it.
            backUpQueue(move: true, reason: "unreadable")
            return ([], 0)
        }
        var restored = lossy.compactMap(\.job)
        // Entries that did not decode, or states from another app version, would be lost (or
        // rewritten) by the next save: keep a copy of the original file next to it.
        if restored.count < lossy.count || hasUnknownKinds(data) {
            backUpQueue(move: false, reason: "\(lossy.count - restored.count) unreadable entries or unknown states")
        }
        // Orphan guard, before anything starts: an rclone of an earlier run that outlived the app
        // (frozen, or deaf to SIGPIPE) would upload or download next to the new one.
        for i in restored.indices {
            if let pid = restored[i].rclonePid, let start = restored[i].rcloneStartMicros {
                stopOrphan(pid: pid, start: start, job: restored[i].name)
            }
            restored[i].rclonePid = nil
            restored[i].rcloneStartMicros = nil
        }
        var busy: [String]?
        var resumed = 0
        for i in restored.indices where restored[i].state.isActive {
            restored[i].speed = 0
            restored[i].eta = nil
            restored[i].currentFile = nil
            if restored[i].kind != .copy {
                // Evict / restore / download re-check the disk (and the background upload) when they start:
                // their source may legitimately be gone already.
                if restored[i].state == .paused { continue }
                restored[i].state = .queued
                resumed += 1
                continue
            }
            guard FileManager.default.fileExists(atPath: restored[i].source.path) else {
                restored[i].state = .failed("Не нашёл «\(restored[i].name)» на диске: его переместили или удалили. Докачать нельзя.")
                restored[i].finishedAt = Date()
                continue
            }
            if restored[i].state == .paused { continue }
            if busy == nil { busy = Rclone.busySources() }
            let path = restored[i].source.path
            if !restored[i].forced, let reason = blockReason(path: path, busy: busy ?? []) {
                restored[i].state = .blocked(reason)
                continue
            }
            restored[i].state = .queued
            resumed += 1
        }
        return (restored, resumed)
    }

    /// Stops a saved rclone of ours only if that pid is still alive, is an rclone binary and started
    /// at exactly the saved time (so it is that very process, not a recycled pid): SIGTERM, up to
    /// 3 s for it to go, then SIGKILL (a frozen process never handles SIGTERM).
    nonisolated private static func stopOrphan(pid: Int32, start: Int64, job: String) {
        guard ProcessFacts.startMicros(pid) == start,
              let path = ProcessFacts.executablePath(pid), (path as NSString).lastPathComponent == "rclone" else { return }
        kill(pid, SIGTERM)
        var waited = 0
        while waited < 30, ProcessFacts.startMicros(pid) == start {
            usleep(100_000)
            waited += 1
        }
        if ProcessFacts.startMicros(pid) == start {
            kill(pid, SIGKILL)
            AppLog.write("orphan guard: rclone \(pid) of \(job) left by an earlier run ignored SIGTERM for 3 s, killed")
        } else {
            AppLog.write("orphan guard: rclone \(pid) of \(job) left by an earlier run stopped")
        }
    }

    /// Keeps the current queue.json as queue.json.unreadable-<date> (moved or copied).
    nonisolated private static func backUpQueue(move: Bool, reason: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = queueURL.deletingLastPathComponent()
            .appendingPathComponent("queue.json.unreadable-\(f.string(from: Date()))")
        do {
            if move {
                try FileManager.default.moveItem(at: queueURL, to: backup)
            } else {
                try FileManager.default.copyItem(at: queueURL, to: backup)
            }
            AppLog.write("queue restore: \(reason), kept \(backup.lastPathComponent)")
        } catch {
            AppLog.write("queue restore: \(reason), backup failed: \(error.localizedDescription)")
        }
    }

    /// True if some entry's state kind is not one this version knows.
    nonisolated private static func hasUnknownKinds(_ data: Data) -> Bool {
        let known = JobState.knownKinds
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard let state = entry["state"] as? [String: Any], let kind = state["kind"] as? String else { return true }
            return !known.contains(kind)
        }
    }
}

/// Watchdog record of one running rclone.
private struct TransferWatch {
    /// Last gain of bytes, files or checks, and last gain of bytes alone.
    var lastGain: Date
    var lastByteGain: Date
    /// Last line of any kind from rclone.
    var lastReport: Date
    /// bytes + transfers + checks of the last stats tick (-1 before the first one).
    var progress: Int64 = -1
    var bytes: Int64 = 0
    /// Highest totalBytes + totalTransfers + totalChecks seen (grows while rclone lists).
    var listed: Int64 = 0
    /// A file is still being sent (or received).
    var midBody = false
    var probing = false
    var lastProbe: Date?

    init(now: Date) {
        lastGain = now
        lastByteGain = now
        lastReport = now
    }
}

private struct RunProgress {
    var fromRemaining: Bool
    /// When this rclone run started, and the job's run time before it.
    let startedAt: Date
    let baseSeconds: TimeInterval
    /// Progress shown while rclone is still listing (the value from before this run / attempt).
    var heldBytes: Int64
    private var lastTotal: Int64 = -1
    private var lastTotalChecks = -1
    private var stableTicks = 0
    private(set) var listed = false

    /// Stats ticks (1 s each) with an unchanged total before the listing counts as finished.
    static let stableTicksNeeded = 3

    init(fromRemaining: Bool, startedAt: Date, baseSeconds: TimeInterval, heldBytes: Int64) {
        self.fromRemaining = fromRemaining
        self.startedAt = startedAt
        self.baseSeconds = baseSeconds
        self.heldBytes = heldBytes
    }

    /// After "Attempt N failed" rclone lists everything again.
    mutating func restartListing(heldBytes: Int64) {
        self.heldBytes = heldBytes
        lastTotal = -1; lastTotalChecks = -1; stableTicks = 0; listed = false
    }

    /// Feeds one stats tick; true once the total has stopped growing and all checks are done.
    /// Once listed, it stays listed for this run (or until the next attempt).
    mutating func observe(total: Int64, checks: Int, totalChecks: Int) -> Bool {
        guard !listed else { return true }
        if total == lastTotal, totalChecks == lastTotalChecks, checks >= totalChecks {
            stableTicks += 1
        } else {
            stableTicks = 0
        }
        lastTotal = total
        lastTotalChecks = totalChecks
        if stableTicks >= Self.stableTicksNeeded { listed = true }
        return listed
    }
}

/// Plain-text app log (paths and outcomes only, never credentials).
enum AppLog {
    /// ~/Library/Logs/CloudMail.log, or CloudMail-Dev.log in the dev build (AppPaths).
    static var url: URL { AppPaths.logURL }

    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: url)
        }
    }
}
