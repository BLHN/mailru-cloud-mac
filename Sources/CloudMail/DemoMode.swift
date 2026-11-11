import SwiftUI

/// Dev `--dev-demo --dev-demo-promo`: the demo shows a calm, presentable data set for the demo
/// film (no failed or refused rows, no alert, no unmounted disk, neutral names). Never on outside
/// the dev build.
enum DevPromo {
    static let on: Bool = {
        let dev = DevArgs.parse(Array(CommandLine.arguments.dropFirst()))
        return AppPaths.isDev && dev.demo && dev.demoPromo
    }()
    /// Moment the promo data started: ticking numbers are a function of the time since then.
    static let started = Date()
}

/// Dev `--dev-demo` and `--dev-play`: fake queue entries in every state (no rclone is started and
/// the queue is not saved, see `UploadManager.init(demo:)`), the two running ones animate, and the
/// signature choreographies can be played on cue for screenshots.
@MainActor
final class DemoMode {
    private let manager: UploadManager
    private let status: CloudStatus
    private let nav: AppNavigation
    /// «Облако»: `--dev-play download` there selects the first item and queues it.
    var cloud: CloudBrowserModel?
    private var timer: Timer?
    private var finishing: Set<UUID> = []

    init(manager: UploadManager, status: CloudStatus, nav: AppNavigation) {
        self.manager = manager
        self.status = status
        self.nav = nav
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let gb: Int64 = 1_000_000_000

    func start(empty: Bool = false) {
        status.startDemo()
        manager.jobs = empty ? [] : (DevPromo.on ? Self.promoJobs() : Self.jobs())
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        AppLog.write("dev: demo queue with \(manager.jobs.count) jobs")
    }

    /// Running jobs creep forward (never finish by themselves); the speed wobbles a little.
    private func tick() {
        for i in manager.jobs.indices where manager.jobs[i].state == .running {
            let id = manager.jobs[i].id
            guard !finishing.contains(id), !manager.jobs[i].verifying else { continue }
            var j = manager.jobs[i]
            let speed = (j.isDownload ? 21_000_000.0 : 8_400_000.0) * Double.random(in: 0.85...1.15)
            let cap = Int64(Double(j.totalBytes) * 0.97)
            j.bytes = min(cap, j.bytes + Int64(speed * 0.5))
            j.speed = speed
            j.eta = Double(j.totalBytes - j.bytes) / speed
            if j.filesTotal > 1 {
                j.filesDone = min(j.filesTotal - 1, Int(Double(j.filesTotal) * j.fraction))
            }
            manager.jobs[i] = j
        }
    }

    // MARK: Choreographies

    func play(_ name: String) {
        AppLog.write("dev: play \(name)")
        switch name {
        case "drop": playDrop()
        case "done": playDone()
        case "fail": playFail()
        case "download": playDownload()
        case "gauge": status.demoRevealStorage()
        default: AppLog.write("dev: unknown --dev-play \(name)")
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Files dragged over the window, held for a moment, dropped: the overlay collapses toward
    /// «Передачи», the badge bounces and a new queued row appears.
    private func playDrop() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.small) { nav.dropTargeted = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let center = CGPoint(x: nav.windowSize.width / 2, y: nav.windowSize.height / 2 - 38)
            withAnimation(.easeOut(duration: 0.22)) { nav.dropTargeted = false }
            nav.flyToTransfers(symbol: "icloud.and.arrow.up", from: center, size: 64,
                               toast: "Загружается в «\(manager.destinationFolder)»", reduceMotion: reduceMotion)
            try? await Task.sleep(nanoseconds: 350_000_000)
            var j = UploadJob(kind: .copy, source: Self.home.appendingPathComponent("Desktop/Презентация клиенту.pdf"),
                              isDirectory: false, destinationFolder: manager.destinationFolder)
            j.totalBytes = 48_000_000
            withAnimation(Motion.layout) { manager.jobs.insert(j, at: 0) }
        }
    }

    /// The running upload completes: the bar fills, fades, the row gets its checkmark and moves to
    /// «Готово»; the gauge settles to the new level.
    private func playDone() {
        guard let i = manager.jobs.firstIndex(where: { $0.state == .running && !$0.isDownload && !$0.verifying }) else { return }
        let id = manager.jobs[i].id
        finishing.insert(id)
        Task { @MainActor in
            // Last stretch of the bar in a few quick steps.
            for step in 1...4 {
                guard let k = manager.jobs.firstIndex(where: { $0.id == id }) else { return }
                var j = manager.jobs[k]
                let left = j.totalBytes - j.bytes
                j.bytes += left * Int64(step) / 4 - (step > 1 ? left * Int64(step - 1) / 4 : 0)
                j.filesDone = step == 4 ? j.filesTotal : j.filesDone
                manager.jobs[k] = j
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let k = manager.jobs.firstIndex(where: { $0.id == id }) else { return }
            var j = manager.jobs[k]
            j.bytes = j.totalBytes
            j.filesDone = j.filesTotal
            j.speed = 0; j.eta = nil; j.currentFile = nil
            j.state = .done
            j.finishedAt = Date()
            j.activeSeconds = 1_260
            manager.jobs[k] = j
            status.demoAddUsed(400 * Self.gb)
        }
    }

    /// The running download fails: its icon shakes once, the status turns red and the row moves
    /// to «Нужно внимание».
    private func playFail() {
        guard let i = manager.jobs.firstIndex(where: { $0.state == .running && $0.isDownload && !$0.verifying }) else { return }
        var j = manager.jobs[i]
        j.speed = 0; j.eta = nil; j.currentFile = nil
        j.finishedAt = Date()
        j.state = .failed("Облако не отвечает: связь оборвалась на середине. Недокачанное лежит рядом в скрытой папке, «Повторить» докачает.")
        manager.jobs[i] = j
    }

    /// A download queued from «Облако»: the symbol flies to «Передачи», a toast offers the jump.
    private func playDownload() {
        if nav.section == .cloud, let cloud {
            CloudDownload.devPlay(model: cloud, manager: manager, nav: nav)
            return
        }
        let from = CGPoint(x: nav.windowSize.width * 0.62, y: nav.windowSize.height * 0.35)
        nav.flyToTransfers(symbol: "arrow.down.circle", from: from, size: 32,
                           toast: "Скачивается в Загрузки", reduceMotion: reduceMotion)
        var j = UploadJob(kind: .download, source: Self.home.appendingPathComponent("Downloads/Договор аренды.pdf"),
                          isDirectory: false, destinationFolder: "Документы")
        j.restoreRemotePath = "Документы/Договор аренды.pdf"
        j.totalBytes = 2_400_000
        withAnimation(Motion.layout) { manager.jobs.insert(j, at: 0) }
    }

    // MARK: Fake queue

    /// `--dev-demo-promo`: two running jobs, one queued, two done; nothing failed or refused.
    static func promoJobs() -> [UploadJob] {
        let now = Date()
        var list: [UploadJob] = []

        var up = UploadJob(kind: .copy, source: home.appendingPathComponent("Pictures/Фото 2026"), isDirectory: true,
                           destinationFolder: UploadManager.defaultFolder)
        up.state = .running
        up.totalBytes = 38 * gb; up.sourceBytes = up.totalBytes
        up.bytes = Int64(Double(up.totalBytes) * 0.62)
        up.filesTotal = 380; up.filesDone = 235
        up.speed = 8_400_000; up.eta = Double(up.totalBytes - up.bytes) / up.speed
        up.currentFile = "IMG_4031.HEIC"
        up.startedAt = now.addingTimeInterval(-2_900)
        list.append(up)

        var down = UploadJob(kind: .download, source: home.appendingPathComponent("Downloads/Монтаж финал.mp4"),
                             isDirectory: false, destinationFolder: "Видео")
        down.state = .running
        down.restoreRemotePath = "Видео/Монтаж финал.mp4"
        down.totalBytes = 12 * gb; down.sourceBytes = down.totalBytes; down.expectedFiles = 1
        down.bytes = Int64(Double(down.totalBytes) * 0.43)
        down.speed = 21_000_000; down.eta = Double(down.totalBytes - down.bytes) / down.speed
        down.startedAt = now.addingTimeInterval(-260)
        list.append(down)

        var queued = UploadJob(kind: .copy, source: home.appendingPathComponent("Desktop/Договоры.zip"), isDirectory: false,
                               destinationFolder: UploadManager.defaultFolder)
        queued.totalBytes = 640_000_000
        list.append(queued)

        var doneUp = UploadJob(kind: .copy, source: home.appendingPathComponent("Desktop/Отчёт за октябрь.numbers"), isDirectory: false,
                               destinationFolder: UploadManager.defaultFolder)
        doneUp.state = .done
        doneUp.totalBytes = 3_800_000; doneUp.bytes = doneUp.totalBytes
        doneUp.activeSeconds = 4
        doneUp.finishedAt = now.addingTimeInterval(-1_800)
        list.append(doneUp)

        var doneDown = UploadJob(kind: .download, source: home.appendingPathComponent("Downloads/Исходники звука"), isDirectory: true,
                                 destinationFolder: "Музыка")
        doneDown.state = .done
        doneDown.restoreRemotePath = "Музыка/Исходники звука"
        doneDown.totalBytes = 7_300_000_000; doneDown.bytes = doneDown.totalBytes
        doneDown.expectedFiles = 1_284; doneDown.filesTotal = 1_284
        doneDown.finishedAt = now.addingTimeInterval(-3_600)
        list.append(doneDown)

        return list
    }

    /// One entry per state (newest first, like the real queue).
    static func jobs() -> [UploadJob] {
        let now = Date()
        var list: [UploadJob] = []

        // Running upload of a folder at 62 %.
        var up = UploadJob(kind: .copy, source: home.appendingPathComponent("Pictures/Фото 2026"), isDirectory: true,
                           destinationFolder: "Mac/Входящие")
        up.state = .running
        up.totalBytes = 38 * gb; up.sourceBytes = up.totalBytes
        up.bytes = Int64(Double(up.totalBytes) * 0.62)
        up.filesTotal = 380; up.filesDone = 214
        up.speed = 8_400_000; up.eta = Double(up.totalBytes - up.bytes) / up.speed
        up.currentFile = "IMG_4031.HEIC"
        up.startedAt = now.addingTimeInterval(-2_900)
        list.append(up)

        // Running download at 43 %.
        var down = UploadJob(kind: .download, source: home.appendingPathComponent("Downloads/Монтаж финал.mp4"),
                             isDirectory: false, destinationFolder: "Mac/Movies")
        down.state = .running
        down.restoreRemotePath = "Mac/Movies/Монтаж финал.mp4"
        down.totalBytes = 12 * gb; down.sourceBytes = down.totalBytes; down.expectedFiles = 1
        down.bytes = Int64(Double(down.totalBytes) * 0.43)
        down.speed = 21_000_000; down.eta = Double(down.totalBytes - down.bytes) / down.speed
        down.startedAt = now.addingTimeInterval(-260)
        list.append(down)

        // Restore still listing the cloud (indeterminate sweep).
        var restore = UploadJob(kind: .restore, source: home.appendingPathComponent("Documents/Архив 2024"), isDirectory: true,
                                destinationFolder: "Mac/Documents")
        restore.state = .running
        restore.verifying = true
        restore.restoreRemotePath = "Mac/Documents/Архив 2024"
        restore.totalBytes = 3 * gb
        restore.placeholderPath = home.appendingPathComponent("Documents/Архив 2024.mailcloud").path
        list.append(restore)

        // Queued.
        var queued = UploadJob(kind: .copy, source: home.appendingPathComponent("Desktop/Договоры.zip"), isDirectory: false,
                               destinationFolder: "Mac/Входящие")
        queued.totalBytes = 640_000_000
        list.append(queued)

        // Paused, in quiet mode.
        var paused = UploadJob(kind: .copy, source: home.appendingPathComponent("Movies/Лекция, запись.mov"), isDirectory: false,
                               destinationFolder: "Mac/Movies")
        paused.state = .paused
        paused.quiet = true
        paused.totalBytes = 21 * gb; paused.bytes = Int64(Double(paused.totalBytes) * 0.31)
        list.append(paused)

        // Failed with a long message.
        var failed = UploadJob(kind: .evict, source: home.appendingPathComponent("Desktop/Старые проекты"), isDirectory: true,
                               destinationFolder: "Mac/Входящие")
        failed.state = .failed("Облако ответило «недостаточно прав» на файле «Проект 7/render_final_v3.mov». Похоже, кончился срок входа в аккаунт: открой cloud.mail.ru в браузере и войди заново, потом нажми «Повторить». Оригинал оставлен на месте.")
        failed.totalBytes = 54 * gb; failed.bytes = 9 * gb
        failed.finishedAt = now.addingTimeInterval(-600)
        list.append(failed)

        // Blocked by the background upload.
        var blocked = UploadJob(kind: .copy, source: home.appendingPathComponent("Movies"), isDirectory: true,
                                destinationFolder: "Mac/Входящие")
        blocked.state = .blocked(UploadManager.blockReason(path: home.appendingPathComponent("Movies").path,
                                                           busy: [home.appendingPathComponent("Movies").path]) ?? "")
        list.append(blocked)

        // Refused.
        var refused = UploadJob(kind: .evict, source: home.appendingPathComponent("Desktop"), isDirectory: true,
                                destinationFolder: "Mac/Входящие")
        refused.state = .refused("Папку «Рабочий стол» целиком освобождать нельзя: это системная папка Мака. Выбери файлы или папки внутри неё.")
        list.append(refused)

        // Done upload.
        var doneUp = UploadJob(kind: .copy, source: home.appendingPathComponent("Desktop/Отчёт за октябрь.numbers"), isDirectory: false,
                               destinationFolder: "Mac/Входящие")
        doneUp.state = .done
        doneUp.totalBytes = 3_800_000; doneUp.bytes = doneUp.totalBytes
        doneUp.activeSeconds = 4
        doneUp.finishedAt = now.addingTimeInterval(-1_800)
        list.append(doneUp)

        // Done, verified download of a folder.
        var doneDown = UploadJob(kind: .download, source: home.appendingPathComponent("Downloads/Исходники звука"), isDirectory: true,
                                 destinationFolder: "Mac/Music")
        doneDown.state = .done
        doneDown.restoreRemotePath = "Mac/Music/Исходники звука"
        doneDown.totalBytes = 7_300_000_000; doneDown.bytes = doneDown.totalBytes
        doneDown.expectedFiles = 1_284; doneDown.filesTotal = 1_284
        doneDown.finishedAt = now.addingTimeInterval(-3_600)
        list.append(doneDown)

        // Done evict with its placeholder.
        var evict = UploadJob(kind: .evict, source: URL(fileURLWithPath: "/Volumes/Внешний SSD/Отпуск 2026"), isDirectory: true,
                              destinationFolder: "Mac/Movies")
        evict.state = .done
        evict.totalBytes = 186 * gb; evict.bytes = evict.totalBytes
        evict.activeSeconds = 6_840
        evict.placeholderPath = "/Volumes/Внешний SSD/Отпуск 2026.mailcloud"
        evict.freedBytes = evict.totalBytes
        evict.note = "Это внешний диск: оригинал уйдёт в Корзину этого диска, а ярлык будет работать, только пока диск подключён."
        evict.finishedAt = now.addingTimeInterval(-7_200)
        list.append(evict)

        // Cancelled.
        var cancelled = UploadJob(kind: .copy, source: home.appendingPathComponent("Downloads/macOS установщик.dmg"), isDirectory: false,
                                  destinationFolder: "Mac/Входящие")
        cancelled.state = .cancelled
        cancelled.totalBytes = 14 * gb; cancelled.bytes = 2 * gb
        list.append(cancelled)

        return list
    }
}
