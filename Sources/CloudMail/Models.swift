import Foundation

/// Lifecycle of one drop (a file or a folder) in the upload queue.
enum JobState: Equatable {
    case queued
    case running
    /// Paused by the user: the rclone process is stopped (terminated), resume queues the job again
    /// and rclone skips what is already uploaded. It does not count as running for the queue pump.
    case paused
    case done
    case failed(String)
    case cancelled
    /// The same folder is already being uploaded by the background script; user may force it.
    case blocked(String)
    /// The app will not do this at all (e.g. free up space by moving ~/Desktop to the Trash).
    /// Nothing was started and "retry" is not offered.
    case refused(String)

    var isActive: Bool { self == .queued || self == .running || self == .paused }
    var canRetry: Bool {
        switch self {
        case .failed, .cancelled, .blocked: return true
        default: return false
        }
    }
}

extension JobState: Codable {
    private enum Kind: String, Codable { case queued, running, paused, done, failed, cancelled, blocked, refused }
    static let knownKinds: Set<String> = Set(["queued", "running", "paused", "done", "failed", "cancelled", "blocked", "refused"])
    private enum CodingKeys: String, CodingKey { case kind, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        // A kind written by another app version (newer or older) must not make the whole queue
        // unreadable: it becomes a failed entry the user can retry or remove.
        let raw = try c.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: raw) else {
            self = .failed("Запись из другой версии приложения (\(raw)). Можно нажать «Повторить».")
            return
        }
        switch kind {
        case .queued: self = .queued
        case .running: self = .running
        case .paused: self = .paused
        case .done: self = .done
        case .failed: self = .failed(message)
        case .cancelled: self = .cancelled
        case .blocked: self = .blocked(message)
        case .refused: self = .refused(message)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try c.encode(Kind.queued, forKey: .kind)
        case .running: try c.encode(Kind.running, forKey: .kind)
        case .paused: try c.encode(Kind.paused, forKey: .kind)
        case .done: try c.encode(Kind.done, forKey: .kind)
        case .failed(let m): try c.encode(Kind.failed, forKey: .kind); try c.encode(m, forKey: .message)
        case .cancelled: try c.encode(Kind.cancelled, forKey: .kind)
        case .blocked(let m): try c.encode(Kind.blocked, forKey: .kind); try c.encode(m, forKey: .message)
        case .refused(let m): try c.encode(Kind.refused, forKey: .kind); try c.encode(m, forKey: .message)
        }
    }
}

/// What a queue entry does.
enum JobKind: String, Codable {
    /// Plain upload (the original behaviour): the local item stays where it is.
    case copy
    /// Upload, verify, move the original to the Trash and leave a `.mailcloud` placeholder.
    case evict
    /// Download the item a placeholder points to back next to it, verify, trash the placeholder.
    case restore
    /// Download any cloud file or folder into a chosen local folder ("Облако -> Мак"), verify,
    /// then rename it from its hidden staging item to a free name there.
    case download
}

/// One queue entry. A plain value: the rclone `Process` lives in `UploadManager`, never here,
/// so the job can be saved to queue.json as is.
struct UploadJob: Identifiable, Equatable {
    var id = UUID()
    var kind: JobKind = .copy
    /// Upload source. For a restore job: the local item to be created (next to the placeholder).
    /// For a download job: the local item to be created; updated to the name actually used when
    /// the verified download is renamed into place (the first free one).
    var source: URL
    let isDirectory: Bool
    /// Cloud folder the item is dropped into, e.g. "Mac/Входящие".
    let destinationFolder: String
    var state: JobState = .queued
    /// Uploaded so far (whole job, across runs), never above `totalBytes`.
    var bytes: Int64 = 0
    /// Size of the job: the measured source size once known, else the largest rclone total seen.
    var totalBytes: Int64 = 0
    /// Real size of the source on disk (regular files, without symlinks and .DS_Store), measured once.
    var sourceBytes: Int64?
    var speed: Double = 0          // bytes per second (current), not persisted
    var eta: Double?               // seconds, not persisted
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var currentFile: String?       // not persisted
    /// First start of the job (kept across pause, resume, retry and relaunch).
    var startedAt: Date?
    var finishedAt: Date?
    /// Time rclone actually ran for this job, summed over all its runs (idle gaps excluded).
    var activeSeconds: TimeInterval = 0
    /// Last rclone error for display and the log, "<file>: <message>".
    var lastError: String?
    /// The same error without the file name: what `Humanize` classifies (digits in names like
    /// IMG_4031.MOV must not read as HTTP 403).
    var lastErrorMessage: String?
    /// Warning shown on the row, e.g. the folder is also in the background script's list.
    var note: String?
    /// rclone is still listing what is already in the cloud: the row shows that instead of
    /// a jumping percentage. Not persisted.
    var verifying = false
    var forced = false
    /// Started with --bwlimit ("Тихий режим").
    var quiet = false
    /// Restore: cloud path of the item, read from the placeholder. Download: the cloud item to
    /// download (NFC).
    var restoreRemotePath: String?
    /// Download: number of files the cloud item had in preflight (a file: 1). `sourceBytes` holds
    /// its expected bytes. Both are what the verification requires on the Mac.
    var expectedFiles: Int?
    /// Download: the job's hidden staging item, fixed when the job is created, so a resumed,
    /// retried or relaunched download continues into the same place even if `source` changes.
    var stagingPath: String?
    /// Evict: the placeholder written next to the trashed original. Restore: the placeholder
    /// the job came from (trashed when the item is back).
    var placeholderPath: String?
    /// Evict: bytes moved to the Trash (added to the "freed on this Mac" counter once).
    var freedBytes: Int64?
    /// Evict: the cloud path was checked to be free before this job's first upload, so later
    /// runs (resume, retry, relaunch) may continue into it. Without it an evict never starts on
    /// top of something already in the cloud (rclone would overwrite or skip it by size).
    var remoteClaimed = false
    /// What happens after rclone finished (verifying, moving to the Trash…). Not persisted.
    var phase: String?
    /// The original / placeholder is being moved to the Trash right now: pause and cancel are
    /// ignored until that step has finished. Not persisted.
    var committing = false
    /// Queued behind the closed cloud gate (no connection to the cloud): the row says «ждёт связь».
    /// Not persisted: after a relaunch the job is simply queued.
    var waitingForNetwork = false
    /// Restarted by the app after a stall or a wake: the row says «перезапускаю» until bytes flow
    /// again. Not persisted.
    var restarting = false
    /// When the shown progress stepped back because rclone began in-flight files again from zero:
    /// the route line says «начал файл заново» for a few seconds. Not persisted.
    var fileRestartedAt: Date?
    /// The job's running rclone: pid and process start time (microseconds since 1970), so the next
    /// launch can stop exactly this process if it outlived the app (orphan guard). Persisted.
    var rclonePid: Int32?
    var rcloneStartMicros: Int64?

    var name: String { source.lastPathComponent }

    /// Restore and download write to this Mac (from the cloud); copy and evict upload.
    var isDownload: Bool { kind == .restore || kind == .download }

    /// Restore / download: rclone downloads into this hidden item next to the destination, owned
    /// by this job only (its id is in the name). After verification it is renamed to `source`
    /// without ever replacing an existing item, so a retry can never overwrite something the user
    /// put there.
    var restoreStagingURL: URL {
        if let stagingPath { return URL(fileURLWithPath: stagingPath, isDirectory: isDirectory) }
        return source.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingName(for: name, id: id), isDirectory: isDirectory)
    }

    /// ".<name>.<id8>.mailcloud-part": the hidden staging name of a restore / download.
    static func stagingName(for name: String, id: UUID) -> String {
        var base = name
        // Stay within the 255-byte file name limit.
        while base.utf8.count > 200 { base.removeLast() }
        let tag = id.uuidString.prefix(8).lowercased()
        return ".\(base).\(tag).mailcloud-part"
    }

    /// Final rclone destination: folders keep their own name inside the destination folder.
    /// For a restore job: the cloud item being downloaded. Always NFC (see `cloudPath`).
    var remotePath: String {
        if isDownload { return Self.cloudPath(restoreRemotePath ?? destinationFolder) }
        return Self.cloudPath(isDirectory ? Self.join(destinationFolder, name) : destinationFolder)
    }

    /// Cloud path of the item itself (a file's own path, not its folder). Always NFC.
    var remoteItemPath: String {
        if isDownload { return Self.cloudPath(restoreRemotePath ?? destinationFolder) }
        return Self.cloudPath(Self.join(destinationFolder, name))
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    /// A cloud path in the form mail.ru stores names: Unicode NFC. Local names on macOS often come
    /// decomposed (NFD: "е" + U+0308 instead of "ё"); the upload itself still lands under the NFC
    /// name, but `rclone check` / `lsjson` / `copy` of the NFD path find nothing there.
    static func cloudPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }

    var fraction: Double {
        guard totalBytes > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(bytes) / Double(totalBytes))
    }
}

extension UploadJob: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, source, isDirectory, destinationFolder, state, bytes, totalBytes, sourceBytes
        case filesDone, filesTotal, startedAt, finishedAt, activeSeconds, lastError, lastErrorMessage, note, forced, quiet
        case kind, restoreRemotePath, placeholderPath, freedBytes, remoteClaimed
        case expectedFiles, stagingPath, rclonePid, rcloneStartMicros
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  source: URL(fileURLWithPath: try c.decode(String.self, forKey: .source)),
                  isDirectory: try c.decode(Bool.self, forKey: .isDirectory),
                  destinationFolder: try c.decode(String.self, forKey: .destinationFolder))
        state = try c.decode(JobState.self, forKey: .state)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        sourceBytes = try c.decodeIfPresent(Int64.self, forKey: .sourceBytes)
        filesDone = try c.decodeIfPresent(Int.self, forKey: .filesDone) ?? 0
        filesTotal = try c.decodeIfPresent(Int.self, forKey: .filesTotal) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        activeSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .activeSeconds) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        forced = try c.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        quiet = try c.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
        // Entries written before v1.2 have no kind: they are plain uploads. An unknown kind
        // fails this entry only (LossyJob), and the original file is backed up.
        kind = try c.decodeIfPresent(JobKind.self, forKey: .kind) ?? .copy
        restoreRemotePath = try c.decodeIfPresent(String.self, forKey: .restoreRemotePath)
        placeholderPath = try c.decodeIfPresent(String.self, forKey: .placeholderPath)
        freedBytes = try c.decodeIfPresent(Int64.self, forKey: .freedBytes)
        remoteClaimed = try c.decodeIfPresent(Bool.self, forKey: .remoteClaimed) ?? false
        expectedFiles = try c.decodeIfPresent(Int.self, forKey: .expectedFiles)
        stagingPath = try c.decodeIfPresent(String.self, forKey: .stagingPath)
        rclonePid = try c.decodeIfPresent(Int32.self, forKey: .rclonePid)
        rcloneStartMicros = try c.decodeIfPresent(Int64.self, forKey: .rcloneStartMicros)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source.path, forKey: .source)
        try c.encode(isDirectory, forKey: .isDirectory)
        try c.encode(destinationFolder, forKey: .destinationFolder)
        try c.encode(state, forKey: .state)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encodeIfPresent(sourceBytes, forKey: .sourceBytes)
        try c.encode(filesDone, forKey: .filesDone)
        try c.encode(filesTotal, forKey: .filesTotal)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encode(activeSeconds, forKey: .activeSeconds)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(forced, forKey: .forced)
        try c.encode(quiet, forKey: .quiet)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(restoreRemotePath, forKey: .restoreRemotePath)
        try c.encodeIfPresent(placeholderPath, forKey: .placeholderPath)
        try c.encodeIfPresent(freedBytes, forKey: .freedBytes)
        try c.encode(remoteClaimed, forKey: .remoteClaimed)
        try c.encodeIfPresent(expectedFiles, forKey: .expectedFiles)
        try c.encodeIfPresent(stagingPath, forKey: .stagingPath)
        try c.encodeIfPresent(rclonePid, forKey: .rclonePid)
        try c.encodeIfPresent(rcloneStartMicros, forKey: .rcloneStartMicros)
    }
}

/// Size of what `rclone copy` will upload: regular files only, the same exclusions as
/// `Rclone.copyFlags` (symlinks are skipped, .DS_Store is excluded). Runs off the main thread.
enum SourceSize {
    static func measure(_ url: URL) async -> Int64? {
        await Task.detached(priority: .utility) { compute(url) }.value
    }

    nonisolated static func compute(_ url: URL) -> Int64? {
        stats(url).map(\.bytes)
    }

    /// Bytes and number of regular files (same rules as `compute`).
    nonisolated static func stats(_ url: URL) -> (bytes: Int64, files: Int)? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if top.isSymbolicLink == true { return (0, 0) }
        if top.isRegularFile == true { return (Int64(top.fileSize ?? 0), 1) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        var files = 0
        for case let f as URL in e {
            guard f.lastPathComponent != ".DS_Store",
                  let v = try? f.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
            files += 1
        }
        return (total, files)
    }
}

/// What a local item looked like at one moment: totals plus a digest of every regular file's
/// relative path, size and modification date (same rules as `SourceSize`). Two snapshots differ
/// when a file was added, removed, renamed or written in between. Compared within one app run only
/// (the digest uses `Hasher`, which is seeded per process).
struct SourceSnapshot: Equatable, Sendable {
    let bytes: Int64
    let files: Int
    let digest: Int

    /// File system work: call off the main thread.
    nonisolated static func take(_ url: URL) -> SourceSnapshot? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if top.isSymbolicLink == true { return SourceSnapshot(bytes: 0, files: 0, digest: 0) }
        if top.isRegularFile == true {
            var h = Hasher()
            h.combine(top.fileSize ?? 0)
            h.combine(top.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
            return SourceSnapshot(bytes: Int64(top.fileSize ?? 0), files: 1, digest: h.finalize())
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return nil }
        let rootCount = url.standardizedFileURL.pathComponents.count
        var entries: [(String, Int, Double)] = []
        var total: Int64 = 0
        for case let f as URL in e {
            guard f.lastPathComponent != ".DS_Store",
                  let v = try? f.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            let rel = f.standardizedFileURL.pathComponents.dropFirst(rootCount).joined(separator: "/")
            let size = v.fileSize ?? 0
            total += Int64(size)
            entries.append((rel, size, v.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0))
        }
        entries.sort { $0.0 < $1.0 }
        var h = Hasher()
        for (rel, size, date) in entries {
            h.combine(rel); h.combine(size); h.combine(date)
        }
        return SourceSnapshot(bytes: total, files: entries.count, digest: h.finalize())
    }
}

/// Decodes one queue.json entry without failing the whole list: a broken entry becomes nil.
struct LossyJob: Decodable {
    let job: UploadJob?
    init(from decoder: Decoder) throws {
        job = try? UploadJob(from: decoder)
    }
}

// MARK: - rclone --use-json-log line

struct RcloneLogLine: Decodable {
    let level: String?
    let msg: String?
    let object: String?
    let stats: RcloneStats?
}

struct RcloneStats: Decodable {
    let bytes: Int64?
    let totalBytes: Int64?
    let speed: Double?
    let eta: Double?
    let errors: Int?
    let transfers: Int?
    let totalTransfers: Int?
    let checks: Int?
    let totalChecks: Int?
    let fatalError: Bool?
    let retryError: Bool?
    let lastError: String?
    let transferring: [RcloneTransferring]?
}

struct RcloneTransferring: Decodable {
    let name: String?
    let bytes: Int64?
    let size: Int64?
    let percentage: Int?
}

/// `rclone lsjson --stat` of one item (verification of evict / restore).
struct RcloneItemInfo: Decodable {
    let Name: String?
    let Size: Int64?
    let IsDir: Bool?
}

/// One entry of `rclone lsjson`. `Size` is -1 for folders; `ModTime` is RFC 3339 text
/// (with nanoseconds), see `modDate`. Both are optional so listings made with
/// `--no-modtime` still decode.
struct RcloneEntry: Codable, Identifiable, Hashable {
    let Path: String
    let Name: String
    let IsDir: Bool
    var Size: Int64?
    var ModTime: String?
    var id: String { Path }

    var modDate: Date? {
        guard let t = ModTime else { return nil }
        // rclone writes up to nine fractional digits; ISO8601DateFormatter does not take that many.
        let whole = t.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: whole)
    }
}

// MARK: - Formatting helpers (Russian, short)

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func size(_ b: Int64) -> String { bytes.string(fromByteCount: b) }

    static func speed(_ bps: Double) -> String {
        guard bps > 0 else { return "0 КБ/с" }
        return bytes.string(fromByteCount: Int64(bps)) + "/с"
    }

    static func eta(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "неизвестно" }
        let t = Int(s)
        if t < 60 { return "\(t) с" }
        // Never a zero unit: "6 мин", not "6 мин 0 с"; seconds are dropped from 10 minutes on.
        if t < 3600 {
            let m = t / 60, sec = t % 60
            return (m >= 10 || sec == 0) ? "\(m) мин" : "\(m) мин \(sec) с"
        }
        let h = t / 3600, m = (t % 3600) / 60
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    /// "1 файл", "3 файла", "12 файлов".
    static func files(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "файл" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "файла" }
        else { word = "файлов" }
        return "\(n) \(word)"
    }
}
