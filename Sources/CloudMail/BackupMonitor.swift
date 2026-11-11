import AppKit

/// «Копия Мака»: reads the supervisor's status file (read-only) every 5 s while the section is
/// shown. In demo mode a built-in status is shown instead.
@MainActor
final class BackupMonitor: ObservableObject {
    struct Snapshot {
        /// nil: the file is missing or unreadable.
        var status: SupervisorStatus?
        /// Modification time of the status file.
        var modified: Date?
        var exists: Bool
        /// Names of jobs whose volume (/Volumes/<name>) is not mounted.
        var unmounted: Set<String>
        var readAt: Date

        /// The supervisor writes every 10 s; older than 60 s means it is silent.
        var isStale: Bool {
            guard let m = modified else { return true }
            return readAt.timeIntervalSince(m) > SupervisorStatus.maxAge
        }
    }

    @Published private(set) var snapshot: Snapshot?
    var demo = false
    /// The sidebar dot follows each read.
    var onState: ((BackupState) -> Void)?

    /// The promo demo re-reads twice a second so the numbers of the files in flight tick.
    static var interval: TimeInterval { DevPromo.on ? 0.5 : 5 }
    private var timer: Timer?
    private var reading = false

    // Notifications (see `notifyChanges`). The status file is read every 30 s in the background
    // as well, so they come while the section is not shown.
    private var backgroundTimer: Timer?
    private var previousAlerts: Set<String> = []
    private var silenceNotified = false
    /// Silence is counted from the later of the file's mtime and this moment: the launch or the
    /// last wake. A Mac that slept (or an app that was not running) saw no updates either, so the
    /// supervisor gets the full 3 minutes after either before it is called silent.
    private var watchingSince = Date()
    private var wakeObserver: NSObjectProtocol?
    /// Previous read: a gap far longer than the 30 s timer means the Mac slept (in case the timer
    /// fires before the wake notification arrives).
    private var lastReadAt: Date?
    /// No status file update for this long while the app runs: «супервизор не отвечает».
    static let silenceLimit: TimeInterval = 180
    /// The same alert text is never notified twice within this time (kept across launches).
    static let alertRepeat: TimeInterval = 6 * 3600
    private static let alertsKey = "backupAlertsNotified"

    /// Background reads for the notifications; not in demo mode.
    func startBackground() {
        guard !demo, backgroundTimer == nil else { return }
        watchingSince = Date()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchingSince = Date() }
        }
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        backgroundTimer = t
    }

    /// The status file is gone (the supervisor was removed): no more background reads.
    func stopBackground() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if demo {
            snapshot = Snapshot(status: DemoBackup.status(), modified: Date(), exists: true,
                                unmounted: DevPromo.on ? [] : ["Внешний SSD"], readAt: Date())
            return
        }
        guard !reading else { return }
        reading = true
        Task { @MainActor [weak self] in
            let snap = await Task.detached(priority: .utility) { Self.read() }.value
            guard let self else { return }
            self.reading = false
            self.snapshot = snap
            self.onState?(snap.isStale || snap.status == nil ? .silent : snap.status!.backupState)
            self.notifyChanges(snap)
        }
    }

    /// One notification per new alert text (never the same text twice within 6 hours), one when
    /// the supervisor has been silent for 3 minutes, and one when it is back.
    private func notifyChanges(_ snap: Snapshot) {
        if let last = lastReadAt, snap.readAt.timeIntervalSince(last) > 90 { watchingSince = snap.readAt }
        lastReadAt = snap.readAt
        if snap.exists, let m = snap.modified {
            let silentFor = snap.readAt.timeIntervalSince(m)
            let silentWhileWatched = snap.readAt.timeIntervalSince(max(m, watchingSince))
            if silentWhileWatched > Self.silenceLimit, !silenceNotified {
                silenceNotified = true
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                AppLog.write("backup: supervisor silent for \(Int(silentFor)) s")
                Notifier.shared.notice("Копия Мака: супервизор не отвечает с \(f.string(from: m))")
            } else if silentFor <= SupervisorStatus.maxAge, silenceNotified {
                silenceNotified = false
                AppLog.write("backup: supervisor is back")
                Notifier.shared.notice("Копия Мака: супервизор снова работает")
            }
        }
        guard let alerts = snap.status?.alerts, !snap.isStale else { return }
        let current = Set(alerts.filter { !$0.isEmpty })
        let fresh = current.subtracting(previousAlerts)
        previousAlerts = current
        guard !fresh.isEmpty else { return }
        let now = Date()
        var notified = (UserDefaults.standard.dictionary(forKey: Self.alertsKey) as? [String: Double]) ?? [:]
        notified = notified.filter { now.timeIntervalSince1970 - $0.value < Self.alertRepeat }
        for alert in alerts where fresh.contains(alert) && notified[alert] == nil {
            notified[alert] = now.timeIntervalSince1970
            Notifier.shared.notice("Копия Мака: \(alert)")
        }
        UserDefaults.standard.set(notified, forKey: Self.alertsKey)
    }

    nonisolated private static func read() -> Snapshot {
        let url = SupervisorStatus.url
        let fm = FileManager.default
        let now = Date()
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return Snapshot(status: nil, modified: nil, exists: false, unmounted: [], readAt: now)
        }
        let modified = attrs[.modificationDate] as? Date
        let status = (try? Data(contentsOf: url)).flatMap(SupervisorStatus.decode)
        var unmounted: Set<String> = []
        for j in status?.jobs ?? [] {
            if let src = j.src, let volume = SupervisorStatus.volumeRoot(of: src), !fm.fileExists(atPath: volume) {
                unmounted.insert(j.name ?? src)
            }
        }
        return Snapshot(status: status, modified: modified, exists: true, unmounted: unmounted, readAt: now)
    }
}

extension SupervisorStatus {
    /// "/Volumes/Внешний SSD/Фото" -> "/Volumes/Внешний SSD"; nil for paths on the system disk.
    static func volumeRoot(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// "2026-11-09 17:54:15" in local time.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return timestampFormatter.date(from: text)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Last completed check over all jobs.
    var lastComplete: Date? {
        (jobs ?? []).compactMap { Self.date($0.last_complete) }.max()
    }

    var filesLeft: Int {
        (jobs ?? []).filter(\.isBusy).reduce(0) { $0 + ($1.files_left ?? 0) }
    }
}

extension SupervisorStatus.Job {
    var isBusy: Bool {
        ["listing", "running"].contains(phase ?? "") || small?.state == "running"
    }
}

/// Dev `--dev-demo`: a supervisor status with a syncing job and two workers, one alert, one job
/// on an unmounted disk and two finished jobs.
enum DemoBackup {
    private static let gb: Int64 = 1_000_000_000

    static func status(now: Date = Date()) -> SupervisorStatus {
        if DevPromo.on { return promoStatus(now: now) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func stamp(_ secondsAgo: TimeInterval) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: now.addingTimeInterval(-secondsAgo))
        }
        let hms: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm:ss"
            return f.string(from: now.addingTimeInterval(-95))
        }()
        var movies = SupervisorStatus.Job()
        movies.name = "Movies"; movies.src = home + "/Movies"; movies.phase = "running"; movies.note = ""
        movies.last_complete = stamp(26 * 3600); movies.cycle = "incremental"
        movies.big_total = 63 * gb; movies.big_done = 24 * gb
        movies.files_left = 214; movies.active = 2; movies.probing = 0; movies.parked = []
        movies.small = SupervisorStatus.Small(state: "running", bytes: 1_200_000_000, total: 3_400_000_000, mibps: 2.4, xfr: "1204/3310")

        var external = SupervisorStatus.Job()
        external.name = "Внешний SSD"; external.src = "/Volumes/Внешний SSD"; external.phase = "waiting_mount"
        external.note = "source /Volumes/Внешний SSD is not mounted"; external.last_complete = stamp(3 * 86_400)

        var docs = SupervisorStatus.Job()
        docs.name = "Documents"; docs.src = home + "/Documents"; docs.phase = "idle"; docs.note = ""
        docs.last_complete = stamp(10 * 3600)

        var pictures = SupervisorStatus.Job()
        pictures.name = "Pictures"; pictures.src = home + "/Pictures"; pictures.phase = "idle"; pictures.note = ""
        pictures.last_complete = stamp(40 * 60)

        var w1 = SupervisorStatus.Worker()
        w1.job = "Movies"; w1.file = "Отпуск 2026/IMG_2041.mov"; w1.size = 8_200_000_000; w1.bytes = 3_100_000_000
        w1.mibps = 18.6; w1.avg60 = 17.9; w1.phase = "body"; w1.age_s = 170; w1.attempt = 1
        var w2 = SupervisorStatus.Worker()
        w2.job = "Movies"; w2.file = "Лекция, запись.mov"; w2.size = 21_000_000_000; w2.bytes = 20_400_000_000
        w2.mibps = 11.2; w2.avg60 = 12.0; w2.phase = "body"; w2.age_s = 1_840; w2.attempt = 2

        var s = SupervisorStatus()
        s.v = 2; s.state = "running"; s.link_mibps = 29.8
        s.jobs = [movies, external, docs, pictures]
        s.workers = [w1, w2]
        s.alerts = ["Movies: файл «Проект/Монтаж_v3.mov» Облако не приняло три раза подряд, отложен до следующего круга"]
        s.last_event = "\(hms) Movies: worklist 214 big files, 63.0 GiB"
        return s
    }

    /// `--dev-demo-promo`: «Фильмы» is being sent with three files in flight whose numbers grow
    /// with the time since launch; the other folders are in the cloud. No alert, no unmounted disk.
    private static func promoStatus(now: Date) -> SupervisorStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let t = max(0, now.timeIntervalSince(DevPromo.started))
        func stamp(_ secondsAgo: TimeInterval) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: now.addingTimeInterval(-secondsAgo))
        }
        /// A speed in MiB/s that wobbles smoothly around `base`.
        func speed(_ base: Double, _ phase: Double) -> Double { base * (1 + 0.08 * sin(t * 1.7 + phase)) }
        let mib = 1_048_576.0

        func worker(_ file: String, size: Int64, start: Int64, base: Double, phase: Double) -> SupervisorStatus.Worker {
            var w = SupervisorStatus.Worker()
            w.job = "Movies"; w.file = file; w.size = size
            w.bytes = min(size - 1, start + Int64(base * mib * t))
            w.mibps = speed(base, phase); w.avg60 = base; w.phase = "body"; w.age_s = 120 + Int(t); w.attempt = 1
            return w
        }
        let w1 = worker("Отпуск, август/DJI_0412.mp4", size: 8_200_000_000, start: 3_100_000_000, base: 18.6, phase: 0)
        let w2 = worker("Проект, монтаж.mov", size: 4_600_000_000, start: 1_350_000_000, base: 12.4, phase: 2.1)
        let w3 = worker("Лекция, часть 2.mov", size: 6_900_000_000, start: 5_200_000_000, base: 9.8, phase: 4.2)
        let sent = Int64(t * (18.6 + 12.4 + 9.8) * mib)

        var movies = SupervisorStatus.Job()
        movies.name = "Movies"; movies.src = home + "/Movies"; movies.phase = "running"; movies.note = ""
        movies.last_complete = stamp(26 * 3600); movies.cycle = "incremental"
        movies.big_total = 63 * gb; movies.big_done = 24 * gb + sent
        movies.files_left = 214 - Int(t / 4); movies.active = 3; movies.probing = 0; movies.parked = []
        let smallDone = 1_204 + Int(t * 3)
        movies.small = SupervisorStatus.Small(state: "running", bytes: 1_200_000_000 + Int64(t * 2.5 * mib),
                                              total: 3_400_000_000, mibps: speed(2.5, 1.0), xfr: "\(smallDone)/3310")

        func idle(_ name: String, _ folder: String, _ ago: TimeInterval) -> SupervisorStatus.Job {
            var j = SupervisorStatus.Job()
            j.name = name; j.src = home + "/" + folder; j.phase = "idle"; j.note = ""
            j.last_complete = stamp(ago)
            return j
        }

        var s = SupervisorStatus()
        s.v = 2; s.state = "running"; s.link_mibps = speed(43.3, 0.5)
        s.jobs = [movies, idle("Documents", "Documents", 10 * 3600), idle("Pictures", "Pictures", 40 * 60),
                  idle("Desktop", "Desktop", 3 * 3600)]
        s.workers = [w1, w2, w3]
        s.alerts = []
        s.last_event = nil
        return s
    }
}
