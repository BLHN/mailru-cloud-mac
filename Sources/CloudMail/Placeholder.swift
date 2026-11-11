import Foundation

/// The `.mailcloud` file left where an evicted item was. It only says where the item lives in the
/// cloud; opening it (double-click, Dock drop, Finder service, drop into the window) restores it.
/// Declared in Packaging/Info.plist as `ru.blhn.cloudmail.placeholder`.
struct Placeholder: Codable, Equatable {
    static let fileExtension = "mailcloud"
    static let typeIdentifier = "ru.blhn.cloudmail.placeholder"
    static let currentVersion = 1
    /// A placeholder is a few hundred bytes; anything much larger is not ours.
    static let maxFileSize = 64 * 1024

    var version: Int = Placeholder.currentVersion
    /// Cloud path of the item without the remote, e.g. "Mac/Входящие/Стрим 05.11.mov".
    var remotePath: String
    var originalName: String
    var isDirectory: Bool
    var size: Int64
    var fileCount: Int
    var evictedAt: Date

    enum PlaceholderError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let m): return m
            }
        }
    }

    // MARK: Paths

    static func isPlaceholder(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// "<original name>.mailcloud" next to the original.
    static func url(for original: URL) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(original.lastPathComponent + "." + fileExtension)
    }

    /// True when this placeholder points to `cloudPath`. Compared in NFC: placeholders written
    /// before the paths were normalized may hold the decomposed form of the same name.
    func points(to cloudPath: String) -> Bool {
        UploadJob.cloudPath(remotePath) == UploadJob.cloudPath(cloudPath)
    }

    /// Where the item comes back: the placeholder's folder, under the original name.
    func destination(besides placeholderURL: URL) -> URL {
        placeholderURL.deletingLastPathComponent().appendingPathComponent(originalName, isDirectory: isDirectory)
    }

    // MARK: JSON

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Reads and validates a placeholder. File system work: call off the main thread.
    nonisolated static func read(from url: URL) throws -> Placeholder {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize else {
            throw PlaceholderError.unreadable("«\(url.lastPathComponent)» не похож на ярлык-облако (слишком большой).")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PlaceholderError.unreadable("Не смог прочитать ярлык «\(url.lastPathComponent)»: \(error.localizedDescription)")
        }
        let p: Placeholder
        do {
            p = try decoder.decode(Placeholder.self, from: data)
        } catch {
            throw PlaceholderError.unreadable("«\(url.lastPathComponent)» не похож на ярлык-облако: внутри не то.")
        }
        if let problem = p.validationProblem {
            throw PlaceholderError.unreadable("Ярлык «\(url.lastPathComponent)» испорчен: \(problem)")
        }
        return p
    }

    /// The JSON comes from a file anyone could edit: refuse names and paths that would write
    /// outside the placeholder's folder or point at the whole cloud.
    var validationProblem: String? {
        if version > Self.currentVersion { return "он из более новой версии приложения." }
        let name = originalName
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            return "неправильное имя файла."
        }
        let parts = remotePath.split(separator: "/", omittingEmptySubsequences: false)
        if remotePath.isEmpty || remotePath.hasPrefix("/") || remotePath.contains("\0")
            || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            return "неправильный путь в Облаке."
        }
        if size < 0 || fileCount < 0 { return "неправильный размер." }
        return nil
    }

    /// Writes the placeholder, never over an existing file. Call off the main thread.
    nonisolated func write(to url: URL) throws {
        try Self.encoder.encode(self).write(to: url, options: .withoutOverwriting)
    }
}

/// Local file system side of evict and restore. Every function touches the disk (and may run into
/// a macOS privacy prompt for Desktop / Documents / Downloads): call them off the main thread.
enum LocalItems {
    // MARK: Safety refusals (spec v1.2, section 5)

    static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Library"]
    /// Finder's Russian names (hardcoded: asking the system would read those folders).
    static let russianNames = ["Desktop": "Рабочий стол", "Documents": "Документы", "Downloads": "Загрузки",
                               "Movies": "Фильмы", "Music": "Музыка", "Pictures": "Изображения", "Library": "Библиотека"]

    /// Why this item must never be evicted, in Russian; nil when it may be.
    /// `busy`: source folders of the background bulk upload (`Rclone.busySources()`).
    /// `ownRemotePath`: a placeholder next to the item that points to this cloud path is the job's
    /// own (left by an earlier run) and does not count as "something is in the way".
    nonisolated static func evictRefusal(_ url: URL, busy: [String], ownRemotePath: String?) -> String? {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let name = url.lastPathComponent
        if Placeholder.isPlaceholder(url) {
            return "«\(name)» уже ярлык Облака: файл и так в Облаке. Двойной клик по ярлыку вернёт его на Мак."
        }
        if path == "/" || path == home {
            return "Домашнюю папку целиком освобождать нельзя. Выбери конкретные файлы или папки внутри."
        }
        if protectedHomeFolders.contains(where: { path == home + "/" + $0 }) {
            let shown = russianNames[name] ?? name
            return "Папку «\(shown)» целиком освобождать нельзя: это системная папка Мака. Выбери файлы или папки внутри неё."
        }
        if path.hasPrefix(home + "/Library/") {
            return "Файлы из папки «Библиотека» освобождать нельзя: ими пользуются программы."
        }
        if url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return "Программы (.app) освобождать нельзя: после этого они перестанут запускаться."
        }
        if let refusal = systemLocationRefusal(path) { return refusal }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isVolumeKey]) {
            if values.isSymbolicLink == true {
                return "«\(name)» только ссылка на другой файл, а не сам файл. Освобождать нечего."
            }
            if values.isVolume == true {
                return "Диск целиком освобождать нельзя. Выбери папки или файлы на нём."
            }
        }
        if let b = busy.first(where: { Rclone.overlaps(path, $0) }) {
            let busyName = URL(fileURLWithPath: b).lastPathComponent
            return "Другая программа (rclone) уже выгружает «\(busyName)». Пока она не закончит, освобождать здесь место нельзя."
        }
        let placeholder = Placeholder.url(for: url)
        if FileManager.default.fileExists(atPath: placeholder.path) {
            if let own = ownRemotePath, let p = try? Placeholder.read(from: placeholder), p.points(to: own) {
                return nil
            }
            return "Рядом уже лежит «\(placeholder.lastPathComponent)». Убери или переименуй его, потом попробуй снова."
        }
        return nil
    }

    /// macOS's own folders: programs and the system read them, a placeholder there breaks things.
    /// Both spellings of the /private links (`standardizedFileURL` may drop the prefix).
    static let systemRoots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt", "/cores",
                              "/dev", "/Network", "/etc", "/var", "/private/etc", "/private/var"]

    /// Refuses system locations and the top-level folders of the disk (/Users, /Volumes,
    /// /private, /tmp…) as a whole. Everything else outside the home folder is allowed: a temp
    /// folder such as /private/tmp, the Shared folder inside Users, an external disk.
    nonisolated static func systemLocationRefusal(_ path: String) -> String? {
        if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Системные папки Мака освобождать нельзя: ими пользуются macOS и программы."
        }
        let parts = path.split(separator: "/")
        if parts.count < 2 || (parts.count == 2 && parts[0] == "private") {
            return "Папку в корне диска целиком освобождать нельзя. Выбери файлы или папки внутри неё."
        }
        return nil
    }

    /// Warning shown on the row (the evict still runs): the item is on an external disk.
    nonisolated static func evictWarning(_ url: URL) -> String? {
        let internalVolume = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? nil
        if internalVolume == false || url.standardizedFileURL.path.hasPrefix("/Volumes/") {
            return "Это внешний диск: оригинал уйдёт в Корзину этого диска, а ярлык будет работать, только пока диск подключён."
        }
        return nil
    }

    // MARK: Evict: after the upload is verified

    enum EvictOutcome {
        /// Original in the Trash, placeholder written; `freed` bytes counted.
        case done(placeholder: URL, freed: Int64)
        /// Nothing was trashed; the message is for the row (Russian).
        case failed(String)
    }

    /// Writes the placeholder, then moves the original to the Trash (never `removeItem`).
    /// The placeholder goes first so the cloud path is on disk before the original leaves; if the
    /// Trash refuses, the new placeholder is trashed again and the original stays as it was.
    /// A placeholder left by an earlier run of the same job (same cloud path) is reused.
    /// `expected`: the item as it was when the verified upload started. If it changed since (a file
    /// added, removed or written while uploading or verifying), nothing is trashed: the cloud copy
    /// would not be complete.
    nonisolated static func trashOriginal(_ original: URL, placeholder: Placeholder,
                                          expected: SourceSnapshot) -> EvictOutcome {
        let fm = FileManager.default
        let placeholderURL = Placeholder.url(for: original)
        let changed = "«\(original.lastPathComponent)» менялся во время выгрузки, оригинал оставлен на месте. Нажми «Повторить», когда с ним закончат работать."
        guard SourceSnapshot.take(original) == expected else { return .failed(changed) }
        var wroteNew = false
        if fm.fileExists(atPath: placeholderURL.path) {
            guard let existing = try? Placeholder.read(from: placeholderURL),
                  existing.points(to: placeholder.remotePath) else {
                return .failed("Рядом уже лежит «\(placeholderURL.lastPathComponent)». Оригинал оставлен на месте.")
            }
        } else {
            do {
                try placeholder.write(to: placeholderURL)
                wroteNew = true
            } catch {
                return .failed("Не смог создать ярлык рядом с файлом (\(error.localizedDescription)). Оригинал оставлен на месте.")
            }
        }
        // Once more right before the move: the placeholder write may have taken a moment.
        guard SourceSnapshot.take(original) == expected else {
            if wroteNew { try? fm.trashItem(at: placeholderURL, resultingItemURL: nil) }
            return .failed(changed)
        }
        let freed = expected.bytes
        do {
            try fm.trashItem(at: original, resultingItemURL: nil)
        } catch {
            if wroteNew { try? fm.trashItem(at: placeholderURL, resultingItemURL: nil) }
            return .failed("Не смог убрать оригинал в Корзину (\(error.localizedDescription)). Он остался на месте, в Облаке есть копия.")
        }
        return .done(placeholder: placeholderURL, freed: freed)
    }

    // MARK: Restore

    /// Free space on the volume that holds `folder`, for "important" data (what Finder shows).
    nonisolated static func availableCapacity(at folder: URL) -> Int64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Why a restore cannot start now (Russian), or nil.
    /// The download goes to a staging item of the job (see `UploadJob.restoreStagingURL`), so an
    /// existing destination is always a refusal, on the first run and on every retry.
    nonisolated static func restoreProblem(destination: URL, placeholderURL: URL, size: Int64) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: placeholderURL.path) else {
            return "Ярлык «\(placeholderURL.lastPathComponent)» пропал с диска: его переместили или удалили."
        }
        if fm.fileExists(atPath: destination.path) {
            return "На этом месте уже есть «\(destination.lastPathComponent)». Перезаписывать не стал: переименуй или убери его и нажми «Повторить»."
        }
        // rclone needs room for the whole item; keep 1 GB spare for the system.
        let spare: Int64 = 1 << 30
        if let free = availableCapacity(at: destination.deletingLastPathComponent()), free < size + spare {
            return "На Маке не хватает места: нужно \(Fmt.size(size)), свободно \(Fmt.size(free))."
        }
        return nil
    }

    /// Renames the verified download from its staging name to the destination, never over an
    /// existing item (`renamex_np` with `RENAME_EXCL`). Returns an error text (Russian) or nil.
    nonisolated static func moveIntoPlace(staging: URL, destination: URL) -> String? {
        let rc = staging.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return renamex_np(src, dst, UInt32(RENAME_EXCL))
            }
        }
        if rc == 0 { return nil }
        let code = errno
        if code == EEXIST {
            return "Пока шло скачивание, на этом месте появился другой «\(destination.lastPathComponent)». Перезаписывать не стал: скачанная копия лежит рядом в скрытом «\(staging.lastPathComponent)», ярлык оставлен."
        }
        return "Не смог переименовать скачанное в «\(destination.lastPathComponent)» (\(String(cString: strerror(code)))). Скачанная копия лежит рядом в скрытом «\(staging.lastPathComponent)», ярлык оставлен."
    }

    // MARK: Download (cloud -> a chosen folder)

    /// True when something (a file, a folder, even a dangling symlink) is at `url`.
    nonisolated static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return lstat(p, &st) == 0
        }
    }

    /// Finder-style candidate names: "Видео.mov", "Видео 2.mov", "Видео 3.mov"… (files keep their
    /// extension at the end), "Папка", "Папка 2"… for folders. `n` starts at 1.
    nonisolated static func candidateName(_ name: String, isDirectory: Bool, n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        if isDirectory || ext.isEmpty || base.isEmpty { return "\(name) \(n)" }
        return "\(base) \(n).\(ext)"
    }

    /// The first free name for `name` in `folder`: not on disk and not in `reserved` (lowercased
    /// paths of other active jobs).
    nonisolated static func freeItemURL(in folder: URL, name: String, isDirectory: Bool,
                                        reserved: Set<String>) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent(candidateName(name, isDirectory: isDirectory, n: n),
                                                    isDirectory: isDirectory)
            if n > 9999 || (!itemExists(url) && !reserved.contains(url.path.lowercased())) { return url }
            n += 1
        }
    }

    /// Why a download into `folder` cannot start (Russian), or nil: the folder must exist, be a
    /// folder and be writable.
    nonisolated static func downloadFolderProblem(_ folder: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            return "Папки «\(folder.path)» на Маке нет: её переместили или удалили."
        }
        guard isDir.boolValue else { return "«\(folder.path)» не папка, скачать туда нельзя." }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return "В папку «\(folder.lastPathComponent)» нельзя записывать (нет прав). Выбери другую."
        }
        return nil
    }

    /// Renames the verified download from its staging name to `preferred`, or, when that name is
    /// taken (by anything, or by another active job in `reserved`), to the next free Finder-style
    /// name. Never replaces an existing item (`renamex_np` with `RENAME_EXCL`).
    nonisolated static func moveIntoFreeName(staging: URL, preferred: URL, originalName: String,
                                             isDirectory: Bool, reserved: Set<String>) -> Result<URL, DownloadMoveError> {
        let folder = preferred.deletingLastPathComponent()
        // The planned name first, then "<name> 2", "<name> 3"… of the cloud item's own name.
        var n = 1
        while n < 10000 {
            let target = n == 1 ? preferred
                : folder.appendingPathComponent(candidateName(originalName, isDirectory: isDirectory, n: n),
                                                isDirectory: isDirectory)
            n += 1
            if reserved.contains(target.path.lowercased()) { continue }
            let rc = staging.withUnsafeFileSystemRepresentation { src in
                target.withUnsafeFileSystemRepresentation { dst -> Int32 in
                    guard let src, let dst else { return -1 }
                    return renamex_np(src, dst, UInt32(RENAME_EXCL))
                }
            }
            if rc == 0 { return .success(target) }
            let code = errno
            if code == EEXIST || code == ENOTEMPTY { continue }
            return .failure(DownloadMoveError(message: "Не смог переименовать скачанное в «\(target.lastPathComponent)» (\(String(cString: strerror(code)))). Скачанная копия лежит рядом в скрытом «\(staging.lastPathComponent)»."))
        }
        return .failure(DownloadMoveError(message: "Не нашёл свободного имени для «\(originalName)». Скачанная копия лежит рядом в скрытом «\(staging.lastPathComponent)»."))
    }

    struct DownloadMoveError: Error, Sendable { let message: String }

    /// Moves the restored item's placeholder to the Trash. Returns an error text or nil.
    nonisolated static func trashPlaceholder(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
