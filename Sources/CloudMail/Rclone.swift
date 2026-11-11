import Foundation

/// Thin wrapper around the rclone binary. The app never reads rclone.conf itself: with an account
/// signed in through the app, rclone gets the remote from its environment (see `Account`); with a
/// remote "mailru" set up in the user's own rclone.conf, rclone reads that file as usual.
enum Rclone {
    static let remote = "mailru"
    /// Known places of a separately installed rclone (Homebrew on Apple silicon and Intel, MacPorts).
    static let systemCandidates = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/opt/local/bin/rclone"]

    /// The copy shipped inside the app bundle, then the known system places.
    static var candidates: [String] {
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone").path] + systemCandidates
    }

    static var binary: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Environment of every rclone

    /// Set by `Account`, read from any thread when a child is spawned.
    private final class EnvironmentBox: @unchecked Sendable {
        let lock = NSLock()
        var environment: [String: String]?
        var legacyRemote = false
    }
    private static let box = EnvironmentBox()

    /// The whole environment of every rclone the app starts. nil: the app's own environment, so
    /// rclone reads the user's rclone.conf (legacy remote, or no account yet).
    static var environment: [String: String]? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.environment
    }

    /// True while the cloud is reached through the remote "mailru" of the user's own rclone.conf.
    static var usesLegacyRemote: Bool {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.legacyRemote
    }

    static func setEnvironment(_ environment: [String: String]?, legacyRemote: Bool) {
        box.lock.lock(); defer { box.lock.unlock() }
        box.environment = environment
        box.legacyRemote = legacyRemote
    }

    /// Transfer flags tuned by benchmarks against Mail.ru WebDAV, plus the JSON log the progress is
    /// parsed from. No filters: valid for `copyto` too.
    /// - 16 transfers / 16 checkers: small files scale almost linearly with parallel requests;
    ///   16 leaves room for other rclone processes on the same link.
    /// - `--webdav-pacer-min-sleep 0`: the default 10 ms pacer cost ~20 % at 32 transfers;
    ///   backoff on 429/5xx still works.
    /// - `--contimeout 10s`: a dead connect fails fast (a normal one takes ~0.06 s).
    /// - `--timeout`: uploads 10m (default 5m): after the body of a big file the server needs ~20 s per GiB to
    ///   finalize; 10m covers ~30 GiB and still catches dead connections. Downloads 2m: nothing waits on the
    ///   server after the last byte, so a dead connection is noticed sooner.
    /// - `--low-level-retries 2` (was 20): mail.ru's nginx answers 504 about 60 s after the last byte of a
    ///   PUT of ~3 GiB or more, the file usually lands a few minutes later, but rclone's pacer treats the 504
    ///   as retryable and re-sends the WHOLE file (up to 20 times, measured waste 3-14x, and every re-PUT races
    ///   the server's still-running finalize of the previous one). With 2 a big file costs at most one extra send.
    /// - `--retries 1`: the app owns retries (UploadManager: cloud gate, stall watchdog, requeue on network
    ///   errors). rclone's own `--retries 4 --retries-sleep 3m` slept up to 3 minutes after the network was back.
    ///   A requeued pass skips files that are complete in the cloud by size.
    /// - Downloads add `--multi-thread-streams 0`: rclone's ranged multi-thread download of files >= 256 MiB
    ///   fails on mail.ru, which answers "Content-Range: bytes=A-B/T" (not RFC), rejected as "invalid Content-Range".
    /// - `--skip-links` (a local backend option, not a filter) skips symlinks silently instead of
    ///   reporting them as errors.
    private static let baseTransferFlags: [String] = [
        "--transfers", "16", "--checkers", "16",
        "--webdav-pacer-min-sleep", "0", "--use-mmap", "--contimeout", "10s",
        "--retries", "1", "--low-level-retries", "2",
        "--skip-links",
        "--use-json-log", "--stats", "1s", "--stats-log-level", "NOTICE", "--log-level", "NOTICE",
    ]

    /// Flags of one transfer run. No filters: valid for `copyto` too.
    static func transferFlags(download: Bool) -> [String] {
        baseTransferFlags + (download ? ["--timeout", "2m", "--multi-thread-streams", "0"] : ["--timeout", "10m"])
    }

    /// Filters for folder copies. rclone refuses any filter with `copyto` ("can't limit to single
    /// files when using filters"), so single-file transfers use `transferFlags(download:)` alone.
    static let filterFlags: [String] = ["--exclude", ".DS_Store"]

    /// `rclone copy` of a folder (or of a file into a folder). `--order-by size,mixed,25`: a quarter
    /// of the slots take the largest files (they fill the link), the rest grind through the small
    /// ones at the same time. Not in `transferFlags`: a single-file `copyto` has nothing to order.
    static func copyFlags(download: Bool) -> [String] {
        transferFlags(download: download) + ["--order-by", "size,mixed,25"] + filterFlags
    }

    enum RcloneError: LocalizedError {
        case notInstalled
        /// A text that is already meant for the user.
        case failed(String)
        /// rclone exited non-zero: the stderr tail as is. Shown humanized (`errorDescription`), logged raw
        /// (`logText`), classified on the whole tail (`isNetwork`), never shown raw to the user.
        case exit(command: String, status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "В приложении не хватает компонента rclone. Скачайте \(AppInfo.name) заново."
            case .failed(let m): return m
            case .exit(_, _, let err): return Humanize.error(from: err)
            }
        }

        /// For the app log: the raw rclone text (paths and messages, never credentials).
        var logText: String {
            switch self {
            case .exit(let command, let status, let err): return "\(command) exit \(status): \(Rclone.tail(err))"
            default: return errorDescription ?? ""
            }
        }

        /// What rclone said (stderr), or the user-facing text for the other cases: for classification.
        var rawText: String {
            if case .exit(_, _, let err) = self { return err }
            return errorDescription ?? ""
        }

        /// The cloud could not be reached (as opposed to "not found", "forbidden", "no space").
        var isNetwork: Bool {
            if case .exit(_, _, let err) = self { return Humanize.isNetwork(err, listing: true) }
            return false
        }
    }

    /// Runs rclone to completion and returns stdout (used for lsjson / mkdir / listremotes / about).
    /// A non-zero exit becomes `RcloneError.exit` (shown humanized).
    static func run(_ args: [String]) async throws -> Data {
        let r = try await capture(args)
        if r.status == 0 { return r.out }
        throw RcloneError.exit(command: args.first ?? "rclone", status: r.status, stderr: r.err)
    }

    struct Output: Sendable {
        let status: Int32
        let out: Data
        let err: String
    }

    /// Runs rclone to completion and returns exit status, stdout and stderr; throws only when it
    /// cannot be started. stdout and stderr are drained while the process runs: reading them only
    /// after exit would deadlock as soon as rclone writes more than a pipe buffer (a big `lsjson`).
    /// `stdin`: bytes for the child's stdin (a secret for `obscure -`), else `/dev/null`.
    /// `environment`: overrides the account environment (`Rclone.environment`) for this call.
    static func capture(_ args: [String], stdin: Data? = nil,
                        environment explicitEnvironment: [String: String]?? = nil) async throws -> Output {
        guard let bin = binary else { throw RcloneError.notInstalled }
        let env = explicitEnvironment ?? environment
        return try await withCheckedThrowingContinuation { cont in
            // posix_spawn, not Process: Process decomposes ё/й in arguments (see ChildProcess).
            let p = ChildProcess(executable: bin, arguments: args, environment: env,
                                 stdin: stdin.map { .data($0) } ?? .null, stdout: .pipe, stderr: .pipe)
            do { try p.run() } catch { cont.resume(throwing: error); return }
            guard let out = p.stdoutHandle, let err = p.stderrHandle else {
                cont.resume(throwing: RcloneError.failed("rclone: no output pipes")); return
            }
            DispatchQueue.global(qos: .utility).async {
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = err.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: Output(status: p.terminationStatus, out: data,
                                              err: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }

    /// Holds the stderr bytes read on another thread; written once before `group.leave()`.
    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Whether the user's own rclone.conf (rclone's default config, never read by the app) has the
    /// remote "mailru". Always asked with the app's own environment, whatever account is signed in.
    /// nil when rclone could not tell (it failed to start, exited non-zero, for example on an
    /// encrypted or half-written config): that is not a sign that the remote is gone.
    static func hasRemote() async -> Bool? {
        guard let r = try? await capture(["listremotes"], environment: .some(nil)) else { return nil }
        guard r.status == 0, let s = String(data: r.out, encoding: .utf8) else {
            AppLog.write("rclone listremotes failed (exit \(r.status)): \(tail(r.err))")
            return nil
        }
        return s.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "\(remote):" }
    }

    /// `rclone obscure -`: the secret goes in through stdin, never through argv. Returns rclone's
    /// reversible obscured form, checked by its length (base64 of a 16-byte IV plus the secret).
    /// A wrong length would mean rclone obscured something else (for example the "-" itself).
    static func obscure(_ secret: String) async -> String? {
        let bytes = Data(secret.utf8)
        guard !bytes.isEmpty,
              let r = try? await capture(["obscure", "-"], stdin: bytes,
                                         environment: .some(["RCLONE_CONFIG": "/dev/null", "PATH": "/usr/bin:/bin",
                                                             "HOME": NSHomeDirectory()])),
              r.status == 0 else { return nil }
        let out = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = Int(ceil(Double(16 + bytes.count) * 4 / 3))
        return out.count == expected ? out : nil
    }

    static func listFolders(_ path: String) async throws -> [RcloneEntry] {
        let data = try await run(["lsjson", "--dirs-only"] + listingTimeouts + ["\(remote):\(path)"])
        let entries = try JSONDecoder().decode([RcloneEntry].self, from: data)
        return entries.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
    }

    /// Timeouts for short listing calls: a dead connection fails within a minute instead of
    /// hanging the row or the cloud browser.
    static let listingTimeouts: [String] = ["--contimeout", "10s", "--timeout", "60s"]

    /// Timeouts for a cloud folder the browser has never listed (placeholder rows on screen) and for
    /// prefetches: a normal listing takes about 0.5 s, so a stuck one is given up sooner and retried
    /// once instead of leaving the screen waiting for a full minute.
    static let firstListingTimeouts: [String] = ["--contimeout", "10s", "--timeout", "20s"]

    /// Folders AND files of one cloud folder (not recursive): folders first, then files, each in
    /// Finder order (`localizedStandardCompare`). Entries carry Name, Path (relative to `path`),
    /// IsDir, Size (-1 for folders) and ModTime. Throws the humanized rclone error.
    static func list(_ path: String, timeouts: [String] = listingTimeouts) async throws -> [RcloneEntry] {
        let data = try await run(["lsjson", "--no-mimetype"] + timeouts
                                 + ["\(remote):\(UploadJob.cloudPath(path))"])
        let entries = try JSONDecoder().decode([RcloneEntry].self, from: data)
        return entries.sorted { a, b in
            if a.IsDir != b.IsDir { return a.IsDir }
            return a.Name.localizedStandardCompare(b.Name) == .orderedAscending
        }
    }

    /// Number of files and bytes of a cloud file or folder (recursive), counted by
    /// `rclone size --json` with the same filters a folder copy uses (.DS_Store excluded).
    static func size(_ path: String) async -> Result<(count: Int64, bytes: Int64), RcloneError> {
        struct Answer: Decodable { let count: Int64?; let bytes: Int64? }
        do {
            let r = try await capture(["size", "--json"] + listingTimeouts + filterFlags
                                      + ["\(remote):\(UploadJob.cloudPath(path))"])
            guard r.status == 0 else { return .failure(.exit(command: "size", status: r.status, stderr: r.err)) }
            guard let a = try? JSONDecoder().decode(Answer.self, from: r.out), let count = a.count, let bytes = a.bytes else {
                return .failure(.failed("Облако ответило непонятно, посчитать размер не вышло."))
            }
            return .success((count, bytes))
        } catch let e as RcloneError {
            return .failure(e)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    static func mkdir(_ path: String) async throws {
        _ = try await run(["mkdir", "\(remote):\(path)"])
    }

    static func webURL(for path: String) -> URL {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        if encoded.isEmpty { return URL(string: "https://cloud.mail.ru/home/")! }
        return URL(string: "https://cloud.mail.ru/home/\(encoded)/")!
    }

    // MARK: Evict / restore verification

    /// Flags shared by `rclone check`: the same exclusions as `copyFlags`, plain NOTICE text
    /// output (the summary lines are parsed).
    static let checkFlags: [String] = [
        "--size-only", "--one-way", "--checkers", "8", "--skip-links", "--log-level", "NOTICE",
    ] + filterFlags

    /// Result of a verification: nil when everything matches, else a reason for the log.
    typealias VerifyFailure = String?

    /// Size of one cloud item via `rclone lsjson --stat`; the error text when it cannot be read.
    static func remoteInfo(_ path: String) async -> Result<RcloneItemInfo, RcloneError> {
        do {
            let r = try await capture(["lsjson", "--stat"] + listingTimeouts + ["\(remote):\(path)"])
            guard r.status == 0 else { return .failure(.exit(command: "lsjson", status: r.status, stderr: r.err)) }
            guard let info = try? JSONDecoder().decode(RcloneItemInfo.self, from: r.out) else {
                return .failure(.failed("lsjson: unreadable answer"))
            }
            return .success(info)
        } catch let e as RcloneError {
            return .failure(e)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// Whether something named `name` already sits in the cloud folder `folder`. Names are compared
    /// in NFC and ignoring case (mail.ru does not tell "video.mov" from "VIDEO.MOV").
    /// `.success(existing name or nil)`; a folder that does not exist yet is free (nil);
    /// `.failure` carries the humanized reason when the cloud could not be listed.
    static func existingName(_ name: String, inFolder folder: String) async -> Result<String?, RcloneError> {
        do {
            let r = try await capture(["lsjson", "--no-modtime", "--no-mimetype"] + listingTimeouts + ["\(remote):\(folder)"])
            if r.status == 3 || r.status == 4 || (r.status != 0 && r.err.lowercased().contains("not found")) {
                return .success(nil)
            }
            guard r.status == 0 else { return .failure(.exit(command: "lsjson", status: r.status, stderr: r.err)) }
            guard let entries = try? JSONDecoder().decode([RcloneEntry].self, from: r.out) else {
                return .failure(.failed("Облако ответило непонятно, проверить папку не вышло."))
            }
            let wanted = UploadJob.cloudPath(name).lowercased()
            return .success(entries.first { UploadJob.cloudPath($0.Name).lowercased() == wanted }?.Name)
        } catch let e as RcloneError {
            return .failure(e)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// File: the cloud copy exists, is a file and has exactly `localSize` bytes.
    static func verifyFile(remotePath: String, localSize: Int64) async -> VerifyFailure {
        switch await remoteInfo(remotePath) {
        case .failure(let e):
            return "cannot stat \(remotePath): \(e.logText)"
        case .success(let info):
            if info.IsDir == true { return "\(remotePath) is a folder in the cloud" }
            guard let size = info.Size, size == localSize else {
                return "size mismatch: cloud \(info.Size.map(String.init) ?? "?"), local \(localSize)"
            }
            return nil
        }
    }

    /// Folder: `rclone check <source> <dest> --size-only --one-way` exits 0 and reports
    /// "0 differences found". Every file of `source` must be in `dest` with the same size.
    /// Pass local → cloud after an upload and cloud → local after a download.
    static func verifyFolder(source: String, dest: String) async -> VerifyFailure {
        do {
            let r = try await capture(["check", source, dest] + checkFlags)
            guard r.status == 0 else { return "check exit \(r.status): \(tail(r.err))" }
            guard let n = differences(in: r.err) else { return "check: no differences summary" }
            return n == 0 ? nil : "check: \(n) differences"
        } catch {
            return "check could not run: \(error.localizedDescription)"
        }
    }

    /// "…: 3 differences found" in `rclone check` output (the last such line).
    static func differences(in text: String) -> Int? {
        var result: Int?
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: " differences found") else { continue }
            let head = line[..<r.lowerBound]
            let digits = head.reversed().prefix { $0.isNumber }
            if let n = Int(String(digits.reversed())) { result = n }
        }
        return result
    }

    /// The end of rclone's stderr for the log and for classification: the last lines, not just the
    /// last one (the reason is often a line above the summary), at most 1500 characters.
    static func tail(_ text: String) -> String {
        let lines = text.split(separator: "\n").suffix(6).joined(separator: " | ")
        return lines.count > 1500 ? "…" + String(lines.suffix(1500)) : lines
    }

    /// Source folders of other `rclone copy ... mailru:` processes currently running on this Mac
    /// (the background bulk upload). Used to avoid starting a second upload of the same folder.
    static func busySources() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "args="]
        // ps prints non-ASCII paths as escapes unless the locale is UTF-8.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [String] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            // `rclone copy <folder>` (bulk script or the supervisor's small-file lane) and `rclone copyto <file>`
            // (the supervisor's big-file workers: the busy "source" is then that single file).
            guard let r = s.range(of: "rclone copy ") ?? s.range(of: "rclone copyto "),
                  let d = s.range(of: " \(remote):"), r.upperBound < d.lowerBound else { continue }
            // Skip our own uploads: they carry --use-json-log.
            if s.contains("--use-json-log") { continue }
            let src = String(s[r.upperBound..<d.lowerBound]).trimmingCharacters(in: .whitespaces)
            if src.hasPrefix("/") { result.append(src) }
        }
        return result
    }

    /// True when one path is the other or lies inside it (either direction).
    static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

/// Turns rclone's English error text into a short Russian explanation a non-programmer can act on.
enum Humanize {
    /// HTTP status codes as standalone tokens ("403 Forbidden", "status code: 507"), not digits
    /// inside a file name such as IMG_4031.MOV.
    private static func hasStatus(_ text: String, _ codes: [String]) -> Bool {
        let pattern = "(?<![\\w./-])(" + codes.joined(separator: "|") + ")(?![\\w./-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// `raw` should be rclone's message without the object (file) prefix, so names do not count.
    /// `download`: the job writes to this Mac (restore or download), so "no space" means the Mac's
    /// disk. `restore`: a missing cloud item is worded for "Вернуть на Мак" rather than a download.
    static func error(from raw: String, download: Bool = false, restore: Bool = false) -> String {
        let t = raw.lowercased()
        if download {
            if t.contains("no space left") || t.contains("disk full") {
                return "На Маке закончилось место. Освободи место и нажми «Повторить»."
            }
            if t.contains("object not found") || t.contains("directory not found") || hasStatus(t, ["404"]) {
                return restore
                    ? "В Облаке этого больше нет (переместили или удалили). Вернуть нечего."
                    : "В Облаке такого нет: путь неверный, или это переместили или удалили. Скачивать нечего."
            }
        }
        if isNetwork(t, listing: false)
            || (!endsWithDefiniteError(t) && (t.contains("tls handshake") || t.contains("request timeout"))) {
            return "Нет связи с Облаком. Проверь интернет и нажми «Повторить»."
        }
        if hasStatus(t, ["401", "403"]) || t.contains("unauthorized") || t.contains("forbidden") {
            return Rclone.usesLegacyRemote
                ? "Облако не пустило: пароль для приложения не подошёл. Проверьте remote «mailru» в rclone.conf."
                : "Облако не пустило: пароль для приложения не подошёл."
        }
        if hasStatus(t, ["507"]) || t.contains("insufficient storage") || t.contains("quota") || t.contains("no space") {
            return "В Облаке закончилось место."
        }
        if t.contains("immutable file modified") {
            return "В Облаке по этому пути уже лежит другой файл с тем же именем. Заменять его не стал."
        }
        if t.contains("didn't find section in config file") || t.contains("config file not found") {
            return "Подключение к Облаку не настроено."
        }
        if t.contains("directory not found") {
            return "Такой папки в Облаке нет."
        }
        if t.contains("no such file or directory") || t.contains("permission denied") {
            return "Файл не читается с диска (перемещён или нет доступа)."
        }
        if !download, isGatewayAfterUpload(t) {
            return "Облако так и не подтвердило приём файла (ошибка шлюза на стороне Mail.ru). Нажми «Повторить» чуть позже: если файл уже долетел, он просто пропустится."
        }
        // Fall back to the last meaningful line, trimmed, with readable paths (URLs are percent-encoded).
        let lines = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var last = lines.last ?? "Неизвестная ошибка"
        if let data = last.data(using: .utf8), let j = try? JSONDecoder().decode(RcloneLogLine.self, from: data), let m = j.msg {
            last = m
        }
        // Never the command wrapper ("lsjson exit 1: …"): that part is for the log only.
        last = last.replacingOccurrences(of: "^[a-z]+ exit [0-9]+: ", with: "", options: .regularExpression)
        last = last.removingPercentEncoding ?? last
        if last.count > 220 { last = String(last.prefix(220)) + "…" }
        return "Ошибка: \(last)"
    }

    /// True when the text says the cloud could not be reached at all: the app then waits for the
    /// network (UploadManager's cloud gate) instead of failing the job. `listing`: the text comes
    /// from a listing / check call, where 502, 503 and 504 also mean "the cloud is not answering"
    /// (during a big upload a 504 can be the server still finalizing, which rclone handles itself).
    static func isNetwork(_ raw: String, listing: Bool) -> Bool {
        let t = raw.lowercased()
        // The run ended on a real answer of the cloud or the disk (no space, forbidden, not found):
        // that is the reason, even if a timeout of another file was said a few lines above.
        if endsWithDefiniteError(t) { return false }
        let phrases = ["connection refused", "no such host", "network is unreachable", "network is down",
                       "no route to host", "i/o timeout", "connection reset", "tls handshake timeout",
                       "proxyconnect", "context deadline exceeded", "client.timeout", "dial tcp"]
        if phrases.contains(where: { t.contains($0) }) { return true }
        // Codes and "eof" only outside quoted paths, and never as part of a name like "eof.txt".
        let bare = t.replacingOccurrences(of: "\"[^\"\\n]*\"", with: "\"\"", options: .regularExpression)
        if bare.range(of: "(?<![\\w./-])(unexpected )?eof(?![\\w-]|\\.\\w)", options: .regularExpression) != nil { return true }
        if hasStatus(bare, ["408"]) { return true }
        return listing && hasStatus(bare, ["502", "503", "504"])
    }

    /// True when an upload run ended on a gateway answer of the cloud on a transfer (502, 503,
    /// 504, "Gateway Time-out", "Bad Gateway", or 408 "Request Time-out" after the body) and on
    /// nothing definite (401/403/404/507, not found, immutable, permission, no space) anywhere in
    /// the text. Mail.ru answers like this about a minute after the last byte of a big PUT while it
    /// is still finalizing the file, which usually lands by itself shortly after: UploadManager
    /// then starts the job again after a delay instead of failing it.
    static func isGatewayAfterUpload(_ raw: String) -> Bool {
        let t = raw.lowercased()
        if t.split(separator: "\n").contains(where: { isDefiniteLine(String($0)) }) { return false }
        let bare = t.replacingOccurrences(of: "\"[^\"\\n]*\"", with: "\"\"", options: .regularExpression)
        if hasStatus(bare, ["502", "503", "504", "408"]) { return true }
        let phrases = ["gateway time-out", "gateway timeout", "bad gateway", "service unavailable",
                       "request time-out", "request timeout"]
        return phrases.contains(where: { bare.contains($0) })
    }

    /// The last meaningful line of the (lowercased) text names an error that is not about the
    /// connection.
    private static func endsWithDefiniteError(_ t: String) -> Bool {
        guard let last = t.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return false }
        return isDefiniteLine(String(last))
    }

    /// One (lowercased) line names an error that is not about the connection.
    private static func isDefiniteLine(_ raw: String) -> Bool {
        let line = raw.replacingOccurrences(of: "\"[^\"\\n]*\"", with: "\"\"", options: .regularExpression)
        let phrases = ["no space left", "disk full", "insufficient storage", "quota", "unauthorized", "forbidden",
                       "object not found", "directory not found", "immutable file modified", "permission denied",
                       "didn't find section in config file", "config file not found"]
        return phrases.contains(where: { line.contains($0) }) || hasStatus(line, ["401", "403", "404", "507"])
    }
}
