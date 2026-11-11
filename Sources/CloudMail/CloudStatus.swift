import Foundation
import SwiftUI

/// Header status: free space in the cloud (`rclone about mailru: --json`) and, only on a Mac where an
/// optional background upload supervisor publishes `~/Library/Logs/cloudsup_status.json`, the state of
/// that background upload (its status file, or its logs and `ps`). Refreshed on launch, after each
/// finished job and every 10 s while the main window exists.
@MainActor
final class CloudStatus: ObservableObject {
    /// e.g. "Свободно 612 ГБ из 1 ТБ"; nil until the first answer.
    @Published private(set) var freeSpace: String?
    /// e.g. "Фоновая выгрузка: Movies, 12 ГБ из 100 ГБ, 8 МБ/с" or "Фоновая выгрузка не идёт".
    @Published private(set) var background: String?
    /// Numbers behind `freeSpace`, for the cloud gauge in the sidebar; nil until the first answer.
    @Published private(set) var storage: CloudStorage?
    /// State of the Mac copy (the supervisor), for the sidebar status dot and the menu bar popover.
    @Published private(set) var backup: BackupState = .unknown

    /// True when the optional background upload supervisor's status file exists (always in the demo).
    /// Without it «Копия Мака», its menu bar line and every background read (`ps`, logs) are off.
    @Published private(set) var hasSupervisor = SupervisorStatus.isPresent

    /// Re-reads `hasSupervisor` (launch and every activation). Returns true when it changed.
    @discardableResult
    func recheckSupervisor() -> Bool {
        let now = (demo && !Self.demoHidesSupervisor) || SupervisorStatus.isPresent
        guard now != hasSupervisor else { return false }
        hasSupervisor = now
        if !now { background = nil; backup = .unknown; samples = [:] }
        return true
    }

    /// Dev `--dev-demo`: fixed numbers, no `rclone about`.
    private var demo = false
    /// Dev `CLOUDMAIL_DEV_DEMO_NO_SUPERVISOR=1`: the demo looks like a Mac without the supervisor
    /// (no «Копия Мака»), as a new user sees the app. Used for the README screenshots.
    private static let demoHidesSupervisor =
        AppPaths.isDev && ProcessInfo.processInfo.environment["CLOUDMAIL_DEV_DEMO_NO_SUPERVISOR"] != nil
    /// Demo `--dev-play gauge`: the storage numbers are held back until the cue.
    private var demoStorageHeld = false

    func startDemo() {
        demo = true
        hasSupervisor = !Self.demoHidesSupervisor || SupervisorStatus.isPresent
        if !demoStorageHeld {
            storage = CloudStorage(total: 1_000_000_000_000, used: 388_000_000_000)
            freeSpace = "Свободно \(Fmt.size(storage!.free)) из \(Fmt.size(storage!.total))"
        }
        backup = DemoBackup.status().backupState
        background = "Фоновая выгрузка: Movies 12 ГБ из 100 ГБ, файлов 214, 8,4 МБ/с"
        if DevPromo.on { background = "Фоновая выгрузка: Фильмы, 24 ГБ из 63 ГБ, 31 МБ/с" }
        if !hasSupervisor { background = nil; backup = .unknown }
    }

    /// Demo `--dev-play gauge`: the gauge starts empty («узнаю, сколько места») until the cue.
    func demoHideStorage() {
        guard demo else { return }
        demoStorageHeld = true
        storage = nil
        freeSpace = nil
    }

    /// Demo `--dev-play gauge`: the numbers arrive and the gauge rises from empty.
    func demoRevealStorage() {
        guard demo else { return }
        demoStorageHeld = false
        let s = CloudStorage(total: 1_000_000_000_000, used: 388_000_000_000)
        withAnimation(.easeInOut(duration: 0.3)) {
            storage = s
            freeSpace = "Свободно \(Fmt.size(s.free)) из \(Fmt.size(s.total))"
        }
    }

    /// «Копия Мака» read the status file itself (every 5 s while shown): the dot follows it.
    func noteBackup(_ state: BackupState) {
        if !demo { backup = state }
    }

    /// Demo only: a finished upload adds its bytes to the used space.
    func demoAddUsed(_ bytes: Int64) {
        guard demo, let s = storage else { return }
        storage = CloudStorage(total: s.total, used: min(s.total, s.used + bytes))
    }

    /// Logs of optional background upload scripts (one for the Mac, one for an external disk). Read only
    /// when `hasSupervisor` is true.
    static let logURLs: [URL] = ["cloud_upload.log", "cloud_upload_t5.log"].map {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\($0)")
    }
    static let interval: TimeInterval = 10
    /// Free space changes slowly: on the timer it is re-read at most this often.
    static let freeSpaceInterval: TimeInterval = 300

    private var timer: Timer?
    private var lastFreeSpace: Date?

    /// Called when the main window becomes visible / hidden.
    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            refresh()
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh(forceFreeSpace: Bool = false) {
        if demo { return }
        if hasSupervisor { Task { await refreshBackground() } }
        if forceFreeSpace || lastFreeSpace.map({ Date().timeIntervalSince($0) >= Self.freeSpaceInterval }) ?? true {
            // Marked before the task runs, so two refreshes in a row (launch + window shown)
            // start only one `rclone about`.
            lastFreeSpace = Date()
            Task { await refreshFreeSpace() }
        }
    }

    // MARK: Free space

    func refreshFreeSpace() async {
        guard let data = try? await Rclone.run(["about", "\(Rclone.remote):", "--json"]),
              let about = try? JSONDecoder().decode(RcloneAbout.self, from: data),
              let free = about.free else { return }
        if let total = about.total, total > 0 {
            freeSpace = "Свободно \(Fmt.size(free)) из \(Fmt.size(total))"
            storage = CloudStorage(total: total, used: about.used ?? max(0, total - free))
        } else {
            freeSpace = "Свободно \(Fmt.size(free))"
        }
    }

    // MARK: Background bulk upload

    /// Last stats sample per source folder, to compute the speed over the last interval
    /// instead of rclone's average since the start of the run.
    private var samples: [String: (done: Int64, at: Date, speed: Double)] = [:]

    func refreshBackground() async {
        backup = await Task.detached(priority: .utility, operation: { SupervisorStatus.backupState() }).value
        // The supervisor publishes its own status file; when it is fresh it is the truth.
        // Missing, stale (> 60 s) or unreadable: fall back to `ps` + the legacy logs below.
        if let text = await Task.detached(priority: .utility, operation: { SupervisorStatus.headerText() }).value {
            background = text
            samples = [:]
            return
        }
        let logURLs = Self.logURLs
        let entries = await Task.detached(priority: .utility) { () -> [BackgroundLog.Entry] in
            let busy = Rclone.busySources()
            guard !busy.isEmpty else { return [] }
            let tails = logURLs.map { BackgroundLog.readTail(of: $0) }
            return BackgroundLog.entries(busySources: busy, logTails: tails)
        }.value
        guard !entries.isEmpty else { background = "Фоновая выгрузка не идёт"; samples = [:]; return }
        var parts: [String] = []
        for e in entries {
            var text = URL(fileURLWithPath: e.source).lastPathComponent
            if let st = e.stats {
                var speed = st.speed
                if let at = e.at {
                    if let prev = samples[e.source], at > prev.at, st.done >= prev.done {
                        speed = Double(st.done - prev.done) / at.timeIntervalSince(prev.at)
                        samples[e.source] = (st.done, at, speed)
                    } else if let prev = samples[e.source], at == prev.at {
                        speed = prev.speed   // same log line as last time: keep the last live value
                    } else {
                        samples[e.source] = (st.done, at, st.speed)
                    }
                }
                text += " \(Fmt.size(st.done)) из \(Fmt.size(st.total))"
                if speed > 0 { text += ", \(Fmt.speed(speed))" }
            }
            parts.append(text)
        }
        background = (entries.count == 1 ? "Фоновая выгрузка: " : "Фоновые выгрузки: ") + parts.joined(separator: " · ")
    }
}

/// Cloud storage numbers from `rclone about`.
struct CloudStorage: Equatable {
    var total: Int64
    var used: Int64
    var free: Int64 { max(0, total - used) }
    var usedFraction: Double { total > 0 ? min(1, max(0, Double(used) / Double(total))) : 0 }
}

/// What the sidebar dot of «Копия Мака» says about the supervisor.
enum BackupState: Equatable {
    /// Not read yet.
    case unknown
    /// Everything is in the cloud (green).
    case ok
    /// Uploading right now (accent, breathing).
    case syncing
    /// Alerts or a job with an error (orange).
    case attention
    /// The status file is missing or older than 60 s (gray).
    case silent
}

private struct RcloneAbout: Decodable {
    let total: Int64?
    let used: Int64?
    let free: Int64?
}

/// Parses `~/Library/Logs/cloud_upload.log`. Folder lines look like
/// "--- 2026-11-07 22:42:10 /Volumes/Disk/Movies -> mailru:Mac/Movies",
/// rclone `--stats-one-line` lines like
/// "2026/11/07 22:47:10 NOTICE:    12.345 GiB / 100.000 GiB, 12%, 8.123 MiB/s, ETA 2h3m".
enum BackgroundLog {
    /// Last ~256 KB of the log is enough for the latest folder line and stats.
    static func readTail(of url: URL, maxBytes: UInt64 = 256 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    struct Entry {
        var source: String
        var stats: Stats?
        /// Time stamp of the stats line ("2026/11/08 02:02:36"), nil if it could not be parsed.
        var at: Date?
    }

    /// One entry per running background upload; each takes its stats from the log whose latest
    /// folder header names its source folder.
    static func entries(busySources: [String], logTails: [String]) -> [Entry] {
        let parsed = logTails.map(latest(in:))
        return busySources.enumerated().map { (_, src) in
            var log = parsed.first(where: { $0.source == src })
            if log == nil {
                // The log may have been rotated or truncated after its folder header was written:
                // fall back to the log that belongs to this kind of source (external disk vs Mac),
                // but only when that log names no other folder.
                let idx = src.hasPrefix("/Volumes/") ? 1 : 0
                if idx < parsed.count, parsed[idx].source == nil { log = parsed[idx] }
            }
            return Entry(source: src, stats: log?.stats, at: log?.at)
        }
    }

    /// Latest folder header in a log tail and the latest stats line printed after it.
    static func latest(in logTail: String) -> (source: String?, stats: Stats?, at: Date?) {
        let lines = logTail.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var stats: Stats?
        var at: Date?
        for line in lines.reversed() {
            if line.hasPrefix("--- "), let src = sourcePath(fromHeader: line) { return (src, stats, at) }
            if stats == nil, let st = parseStats(line) { stats = st; at = timestamp(of: line) }
        }
        return (nil, stats, at)
    }

    private static let logDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    /// rclone log lines start with "2026/11/08 02:02:36 ".
    static func timestamp(of line: String) -> Date? {
        guard line.count >= 19 else { return nil }
        return logDate.date(from: String(line.prefix(19)))
    }

    /// "--- <date> <time> <src> -> mailru:<dst>" -> "<src>".
    static func sourcePath(fromHeader line: String) -> String? {
        guard let arrow = line.range(of: " -> \(Rclone.remote):"),
              let slash = line.range(of: " /"), slash.lowerBound < arrow.lowerBound else { return nil }
        return String(line[line.index(after: slash.lowerBound)..<arrow.lowerBound])
    }

    struct Stats: Equatable {
        var done: Int64
        var total: Int64
        var speed: Double
    }

    private static let statsRegex = try! NSRegularExpression(
        pattern: #"([\d.]+)\s*([KMGTP]?i?B)\s*/\s*([\d.]+)\s*([KMGTP]?i?B),\s*(?:\d+%|-),\s*([\d.]+)\s*([KMGTP]?i?B)/s"#)

    static func parseStats(_ line: String) -> Stats? {
        let ns = line as NSString
        guard let m = statsRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        guard let done = bytes(g(1), g(2)), let total = bytes(g(3), g(4)), let speed = bytes(g(5), g(6)) else { return nil }
        return Stats(done: Int64(done), total: Int64(total), speed: speed)
    }

    /// "12.345" + "GiB" -> bytes. rclone prints binary units (KiB, MiB…) by default.
    static func bytes(_ number: String, _ unit: String) -> Double? {
        guard let v = Double(number) else { return nil }
        let binary = unit.contains("i")
        let base: Double = binary ? 1024 : 1000
        let power: Double
        switch unit.first {
        case "K": power = 1
        case "M": power = 2
        case "G": power = 3
        case "T": power = 4
        case "P": power = 5
        default: power = 0
        }
        return v * pow(base, power)
    }
}

/// `~/Library/Logs/cloudsup_status.json` written by an optional background upload supervisor (schema v1/v2). Decoding is tolerant: unknown keys are
/// ignored and every field is optional, so a newer supervisor never blanks the header.
struct SupervisorStatus: Decodable {
    struct Small: Decodable {
        var state: String?
        var bytes: Int64?
        var total: Int64?
        var mibps: Double?
        var xfr: String?
    }
    struct Job: Decodable {
        var name: String?
        /// Local folder the job protects, e.g. "~/Movies" or "/Volumes/Внешний SSD".
        var src: String?
        /// idle, blocked, listing, running, waiting_mount, error.
        var phase: String?
        var note: String?
        /// "2026-11-09 17:54:15" (local time) of the last completed cycle.
        var last_complete: String?
        /// "full" or "incremental" while a cycle runs.
        var cycle: String?
        var big_total: Int64?
        var big_done: Int64?
        var files_left: Int?
        var active: Int?
        var probing: Int?
        var parked: [String]?
        var small: Small?
    }
    struct Worker: Decodable {
        var job: String?
        var file: String?
        var size: Int64?
        var bytes: Int64?
        var mibps: Double?
        var avg60: Double?
        /// "body" while the file is sent, "final" while the server finalizes it.
        var phase: String?
        var age_s: Int?
        var attempt: Int?
    }
    var v: Int?
    /// "2026-11-10T03:44:53+0500".
    var updated: String?
    var pid: Int?
    var started: String?
    /// standby, draining, paused, network_down, running, idle.
    var state: String?
    var link_mibps: Double?
    var mem_level_pct: Int?
    var jobs: [Job]?
    var workers: [Worker]?
    var alerts: [String]?
    /// "20:11:12 network back after 60 s".
    var last_event: String?

    /// Dev builds may point it elsewhere with `CLOUDMAIL_DEV_SUPERVISOR_STATUS=<path>` (for example a
    /// path that does not exist, to see the app as on a Mac without the supervisor).
    static let url: URL = {
        if AppPaths.isDev, let path = ProcessInfo.processInfo.environment["CLOUDMAIL_DEV_SUPERVISOR_STATUS"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/cloudsup_status.json")
    }()

    /// The supervisor is set up on this Mac (its status file exists, fresh or not).
    static var isPresent: Bool { FileManager.default.fileExists(atPath: url.path) }

    // Fields read by «Копия Мака»: see BackupMonitor.
    static let maxAge: TimeInterval = 60

    /// Parses a status file body. Pure, for tests.
    static func decode(_ data: Data) -> SupervisorStatus? {
        try? JSONDecoder().decode(SupervisorStatus.self, from: data)
    }

    /// Header text from the live status file; nil when the file is missing/stale/malformed or the supervisor is in standby
    /// (then the caller falls back to the legacy `ps` + log path).
    static func headerText(now: Date = Date()) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date, now.timeIntervalSince(mtime) <= maxAge,
              let data = try? Data(contentsOf: url), let st = decode(data) else { return nil }
        return st.header()
    }

    /// State for the sidebar dot, read from the live status file (file system: off the main thread).
    static func backupState(now: Date = Date()) -> BackupState {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date, now.timeIntervalSince(mtime) <= maxAge,
              let data = try? Data(contentsOf: url), let st = decode(data) else { return .silent }
        return st.backupState
    }

    /// A job with an error needs attention first; then an upload in progress (the alerts are
    /// shown in «Копия Мака» meanwhile); then alerts alone; else everything is in the cloud.
    var backupState: BackupState {
        let list = jobs ?? []
        if list.contains(where: { ($0.phase ?? "") == "error" || ($0.phase ?? "") == "failed" }) { return .attention }
        if isBusy { return .syncing }
        if let a = alerts, a.contains(where: { !$0.isEmpty }) { return .attention }
        return .ok
    }

    var isBusy: Bool {
        (jobs ?? []).contains { $0.isBusy } || !(workers ?? []).isEmpty
    }

    func header() -> String? {
        if state == "standby" { return nil }
        var parts: [String] = []
        for j in jobs ?? [] {
            let busy = ["listing", "running"].contains(j.phase ?? "")
            let smallRunning = j.small?.state == "running"
            guard busy || smallRunning else { continue }
            var text = j.name ?? "?"
            let left = j.files_left ?? 0
            if (j.big_total ?? 0) > 0 {
                text += " \(Fmt.size(j.big_done ?? 0)) из \(Fmt.size(j.big_total ?? 0))"
            }
            if left > 0 { text += ", файлов \(left)" }
            if let sm = j.small, smallRunning {
                if let x = sm.xfr, !x.isEmpty { text += ", мелких \(x)" }
                if let v = sm.mibps, v > 0 { text += ", \(Fmt.speed(v * 1_048_576))" }
            }
            let mine = (workers ?? []).filter { $0.job == j.name }
            let speed = mine.reduce(0.0) { $0 + ($1.mibps ?? 0) }
            if speed > 0 { text += ", \(Fmt.speed(speed * 1_048_576))" }
            if (j.probing ?? 0) > 0 { text += ", ждёт сервер: \(j.probing ?? 0)" }
            if j.phase == "listing" { text += ", сверка списка" }
            parts.append(text)
        }
        var out: String
        if parts.isEmpty {
            out = state == "network_down" ? "Фоновая выгрузка ждёт сеть" : "Фоновая выгрузка не идёт"
        } else {
            out = (parts.count == 1 ? "Фоновая выгрузка: " : "Фоновые выгрузки: ") + parts.joined(separator: " · ")
        }
        if let a = alerts?.first, !a.isEmpty { out += "  ⚠ \(a)" }
        return out
    }
}
