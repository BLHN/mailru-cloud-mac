import SwiftUI
import AppKit

/// State of the «Облако» section: the shown cloud folder, its listing (cached per folder, so going
/// back is instant while a refresh runs in the background), navigation history, selection, filter
/// and the lazily computed sizes of selected folders. Lives as long as the app, so switching
/// sections keeps the place.
@MainActor
final class CloudBrowserModel: ObservableObject {
    enum Load: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum Direction { case forward, back }

    enum SizeState: Equatable {
        case counting
        case done(count: Int64, bytes: Int64)
        case failed(String)
    }

    /// Shown folder, "" = the root of the cloud.
    @Published private(set) var path = ""
    @Published private(set) var entries: [RcloneEntry] = []
    @Published private(set) var load: Load = .loading
    /// A listing runs while cached entries are shown.
    @Published private(set) var refreshing = false
    /// Direction of the last navigation (the slide transition).
    @Published private(set) var direction: Direction = .forward
    @Published var selection: Set<String> = []
    @Published var filter = ""
    /// Sizes of folders (by full cloud path), computed only for the selection.
    @Published private(set) var sizes: [String: SizeState] = [:]
    @Published private(set) var canGoBack = false

    /// How long the placeholder rows have been waiting for an uncached listing: `.slow` after 3 s,
    /// `.verySlow` after 12 s (the view then offers «Повторить»).
    enum Wait: Equatable { case none, slow, verySlow }
    @Published private(set) var wait: Wait = .none

    /// Dev `--dev-demo`: a built-in fake tree, rclone is never started.
    var demo = false
    /// Dev `--dev-select-first`: select the first item once the first listing is there.
    var devSelectFirst = false
    /// Frames (global coordinates) of selected rows: where a queued download's flight starts.
    var rowFrames: [String: CGRect] = [:]
    var listFrame: CGRect = .zero

    /// One folder's listing and when it was read from the cloud.
    struct CachedListing: Codable {
        var entries: [RcloneEntry]
        var read: Date
    }

    private var cache: [String: CachedListing] = [:]
    /// Folders whose cached listing came from the disk and has not been read again this session.
    private var fromDisk: Set<String> = []
    private var history: [String] = []
    private var started = false
    private var devOpenedFirst = false
    private var listingToken = 0
    private var sizeTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    // Prefetch of the shown folder's subfolders.
    private static let prefetchLimit = 12
    private static let prefetchParallel = 3
    /// The folder whose subfolders are queued; the queue stops once another folder is shown.
    private var prefetchParent: String?
    private var prefetchQueue: [String] = []
    /// Folders listed by a prefetch right now.
    private var prefetching: Set<String> = []
    /// Folders listed for the screen right now (count: a superseded listing may still run).
    private var listingNow: [String: Int] = [:]
    /// The shown folder was being prefetched when it was opened: its result is shown when it lands.
    private var awaitingPrefetch: String?
    /// A cached listing younger than this is shown without an immediate background refresh
    /// (it was typically prefetched a moment ago).
    private static let freshFor: TimeInterval = 10

    static let lastPanelFolderKey = "cloudDownloadPanelFolder"

    // MARK: Navigation

    /// First appearance: open the start folder (dev `--dev-cloud-path`, else the root).
    func start(at initial: String?) {
        guard !started else { return }
        started = true
        loadDiskCache()
        path = Self.clean(initial ?? "")
        showCachedOrLoad()
    }

    func open(_ newPath: String, direction d: Direction = .forward, record: Bool = true) {
        let target = Self.clean(newPath)
        guard target != path else { return }
        // Prefetches still queued for the folder being left are dropped (running ones finish).
        prefetchQueue = []
        if record { history.append(path) }
        canGoBack = !history.isEmpty
        // The direction must be in place one update before the path changes: the outgoing list
        // takes its removal transition from the last update it was part of.
        direction = d
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(Self.slide) {
                self.path = target
                self.selection = []
                self.filter = ""
                self.showCachedOrLoad()
            }
        }
    }

    func openEntry(_ e: RcloneEntry) {
        guard e.IsDir else { return }
        open(fullPath(e))
    }

    func back() {
        guard let prev = history.popLast() else { return }
        open(prev, direction: .back, record: false)
        canGoBack = !history.isEmpty
    }

    /// Cmd+Up: the parent folder.
    func up() {
        guard !path.isEmpty else { return }
        open((path as NSString).deletingLastPathComponent, direction: .back)
    }

    var isRoot: Bool { path.isEmpty }

    /// Breadcrumb: («Облако», ""), («Mac», "Mac"), («Movies», "Mac/Movies").
    var crumbs: [(title: String, path: String)] {
        var out: [(String, String)] = [("Облако", "")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc = acc.isEmpty ? String(part) : acc + "/" + part
            out.append((String(part), acc))
        }
        return out
    }

    func fullPath(_ e: RcloneEntry) -> String {
        path.isEmpty ? e.Name : path + "/" + e.Name
    }

    static let slide = Animation.easeInOut(duration: 0.25)

    private static func clean(_ p: String) -> String {
        p.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    // MARK: Listing

    private static func name(_ p: String) -> String { p.isEmpty ? "/" : p }

    private func showCachedOrLoad() {
        if let cached = cache[path] {
            stopWaitClock()
            entries = cached.entries
            load = .loaded
            let age = Date().timeIntervalSince(cached.read)
            AppLog.write(String(format: "cloud: shown %@ from cache (%@, read %.0f s ago, %d entries)",
                                Self.name(path), fromDisk.contains(path) ? "disk" : "memory", age, cached.entries.count))
            startPrefetch(of: path, cached.entries)
            if age < Self.freshFor {
                // Just read (prefetched): no second listing right away. Any listing still running
                // for the previous folder is superseded, as a new listing would do.
                listingToken += 1
                awaitingPrefetch = nil
                refreshing = false
            } else {
                reload(background: true)
            }
        } else {
            entries = []
            load = .loading
            reload(background: false)
        }
    }

    /// Lists the shown folder. `background`: cached entries stay on screen meanwhile.
    /// A folder without a cached listing gets the short timeouts and one automatic retry on a
    /// network error; while its placeholder rows wait, `wait` tells the view how long it has been.
    func reload(background: Bool = true) {
        listingToken += 1
        let token = listingToken
        let p = path
        let first = cache[p] == nil
        awaitingPrefetch = nil
        refreshing = true
        if !background && first { load = .loading }
        if load == .loading { startWaitClock() } else { stopWaitClock() }
        if first, prefetching.contains(p) {
            // A prefetch of this folder is already on its way: wait for it instead of a second rclone.
            awaitingPrefetch = p
            AppLog.write("cloud: \(Self.name(p)) is being prefetched, waiting for it")
            return
        }
        let began = Date()
        listingNow[p, default: 0] += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.fetch(p, first: first) { [weak self] in self?.listingToken == token }
            self.listingNow[p, default: 1] -= 1
            if self.listingNow[p] == 0 { self.listingNow[p] = nil }
            let took = Date().timeIntervalSince(began)
            if case .success(let list) = result {
                AppLog.write(String(format: "cloud: listed %@ in %.1f s, %d entries%@", Self.name(p), took, list.count,
                                    token == self.listingToken ? "" : " (superseded)"))
            }
            guard token == self.listingToken else { return }
            switch result {
            case .success(let list):
                self.show(list, for: p)
            case .failure(let error):
                self.refreshing = false
                let detail = (error as? Rclone.RcloneError)?.logText ?? error.localizedDescription
                AppLog.write(String(format: "cloud: listing %@ failed after %.1f s: %@", Self.name(p), took, detail))
                guard p == self.path, self.cache[p] == nil else { return }
                self.stopWaitClock()
                self.load = .failed(error.localizedDescription)
            }
        }
    }

    /// One listing; an uncached folder (`first`) uses the short timeouts and is tried once more
    /// after a network-class failure, unless the listing is no longer wanted by then.
    private func fetch(_ p: String, first: Bool, stillWanted: @escaping () -> Bool) async -> Result<[RcloneEntry], Error> {
        if demo {
            // Demo folders named "…_loading" / "…_error" show those states for visual QA.
            let slow = p.hasSuffix("_loading")
            try? await Task.sleep(nanoseconds: slow ? 600_000_000_000 : 250_000_000)
            if p.hasSuffix("_error") {
                return .failure(NSError(domain: "CloudMailDemo", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Нет связи с Облаком. Проверь интернет и нажми «Повторить»."]))
            }
            return .success(DemoCloud.list(p))
        }
        let timeouts = first ? Rclone.firstListingTimeouts : Rclone.listingTimeouts
        do {
            return .success(try await Rclone.list(p, timeouts: timeouts))
        } catch {
            guard first, let e = error as? Rclone.RcloneError, e.isNetwork, stillWanted() else { return .failure(error) }
            AppLog.write("cloud: listing \(Self.name(p)) failed (\(e.logText)), retrying once")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard stillWanted() else { return .failure(error) }
            do { return .success(try await Rclone.list(p, timeouts: timeouts)) } catch { return .failure(error) }
        }
    }

    /// A fresh listing of `p` for the screen: cached, and shown when `p` is the shown folder.
    private func show(_ list: [RcloneEntry], for p: String) {
        refreshing = false
        store(list, for: p)
        // Dev test hook: walk into the first folder the way a double click does.
        if AppPaths.isDev, !devOpenedFirst, ProcessInfo.processInfo.environment["CLOUDMAIL_DEV_OPEN_FIRST"] != nil,
           let folder = list.first(where: { $0.IsDir }) {
            devOpenedFirst = true
            // CLOUDMAIL_DEV_OPEN_FIRST_DELAY=<seconds> instead of 1.5 s (recorded takes need calm first).
            let delay = ProcessInfo.processInfo.environment["CLOUDMAIL_DEV_OPEN_FIRST_DELAY"].flatMap { Double($0) } ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.openEntry(folder) }
        }
        guard p == path else { return }
        stopWaitClock()
        withAnimation(.easeInOut(duration: 0.2)) {
            entries = list
            load = .loaded
        }
        let ids = Set(list.map(\.id))
        selection = selection.intersection(ids)
        if devSelectFirst, let first = visibleEntries.first {
            devSelectFirst = false
            selection = [first.id]
        }
        startPrefetch(of: p, list)
    }

    private func store(_ list: [RcloneEntry], for p: String) {
        cache[p] = CachedListing(entries: list, read: Date())
        fromDisk.remove(p)
        scheduleSave()
    }

    // MARK: Slow listing clock

    private func startWaitClock() {
        waitTask?.cancel()
        wait = .none
        let token = listingToken
        let p = path
        waitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.listingToken == token, self.load == .loading else { return }
            AppLog.write("cloud: listing \(Self.name(p)) is slow (3 s)")
            withAnimation(.easeInOut(duration: 0.35)) { self.wait = .slow }
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled, self.listingToken == token, self.load == .loading else { return }
            AppLog.write("cloud: listing \(Self.name(p)) is very slow (12 s)")
            withAnimation(.easeInOut(duration: 0.35)) { self.wait = .verySlow }
        }
    }

    private func stopWaitClock() {
        waitTask?.cancel()
        waitTask = nil
        if wait != .none { wait = .none }
    }

    // MARK: Prefetch

    /// Lists the first subfolders of `parent` in the background into the cache, so opening one
    /// shows its content at once. Never in demo mode; failures are only logged.
    private func startPrefetch(of parent: String, _ list: [RcloneEntry]) {
        guard !demo, parent == path else { return }
        // Folders come first in Finder order: the display order of the default sort.
        let folders = list.filter(\.IsDir).prefix(Self.prefetchLimit)
            .map { parent.isEmpty ? $0.Name : parent + "/" + $0.Name }
        prefetchParent = parent
        prefetchQueue = folders.filter { cache[$0] == nil && !prefetching.contains($0) && listingNow[$0] == nil }
        pumpPrefetch()
    }

    private func pumpPrefetch() {
        while prefetching.count < Self.prefetchParallel, prefetchParent == path, !prefetchQueue.isEmpty {
            let p = prefetchQueue.removeFirst()
            guard cache[p] == nil, !prefetching.contains(p), listingNow[p] == nil else { continue }
            prefetching.insert(p)
            Task { @MainActor [weak self] in await self?.prefetch(p) }
        }
    }

    private func prefetch(_ p: String) async {
        let began = Date()
        let result: Result<[RcloneEntry], Error>
        do { result = .success(try await Rclone.list(p, timeouts: Rclone.firstListingTimeouts)) } catch { result = .failure(error) }
        prefetching.remove(p)
        let took = Date().timeIntervalSince(began)
        let awaited = awaitingPrefetch == p
        if awaited { awaitingPrefetch = nil }
        switch result {
        case .success(let list):
            AppLog.write(String(format: "cloud: listed %@ in %.1f s, %d entries (prefetch)", Self.name(p), took, list.count))
            if awaited {
                AppLog.write("cloud: shown \(Self.name(p)) from the prefetch it waited for")
                show(list, for: p)
            } else if cache[p] == nil {
                store(list, for: p)
            }
        case .failure(let error):
            let detail = (error as? Rclone.RcloneError)?.logText ?? error.localizedDescription
            AppLog.write(String(format: "cloud: prefetch of %@ failed after %.1f s: %@", Self.name(p), took, detail))
            if awaited, p == path { reload(background: false) }
        }
        pumpPrefetch()
    }

    // MARK: Disk cache

    nonisolated private static let diskLimit = 300
    /// Folders with more entries than this stay in memory only (keeps the file small).
    nonisolated private static let diskEntryLimit = 5000
    private static let diskQueue = DispatchQueue(label: "ru.blhn.cloudmail.listings", qos: .utility)
    nonisolated static var diskCacheURL: URL { AppPaths.supportFolder.appendingPathComponent("cloud-listings.json") }

    private struct DiskCache: Codable {
        var version = 1
        var folders: [String: CachedListing]
    }

    /// Reads the listings saved by an earlier run (never in demo mode).
    private func loadDiskCache() {
        guard !demo else { return }
        let url = Self.diskCacheURL
        guard let data = try? Data(contentsOf: url) else { return }
        guard let disk = try? JSONDecoder().decode(DiskCache.self, from: data) else {
            AppLog.write("cloud: disk cache unreadable, ignored")
            return
        }
        for (p, listing) in disk.folders where cache[p] == nil {
            cache[p] = listing
            fromDisk.insert(p)
        }
        AppLog.write("cloud: disk cache loaded, \(disk.folders.count) folders, \(data.count / 1024) KB")
    }

    /// Saves the cache 2 s after the last change, encoded and written off the main thread.
    private func scheduleSave() {
        guard !demo else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.cache
            Self.diskQueue.async { Self.write(snapshot) }
        }
    }

    /// The newest `diskLimit` folders into cloud-listings.json (atomic write).
    nonisolated private static func write(_ all: [String: CachedListing]) {
        let kept = all.filter { $0.value.entries.count <= diskEntryLimit }
            .sorted { $0.value.read > $1.value.read }
            .prefix(diskLimit)
        let disk = DiskCache(folders: Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }))
        do {
            let data = try JSONEncoder().encode(disk)
            try FileManager.default.createDirectory(at: AppPaths.supportFolder, withIntermediateDirectories: true)
            try data.write(to: diskCacheURL, options: .atomic)
        } catch {
            AppLog.write("cloud: disk cache not saved: \(error.localizedDescription)")
        }
    }

    /// «Обновить»: the folder and the sizes counted inside it are read again.
    func refresh() {
        let prefix = path.isEmpty ? "" : path + "/"
        sizes = sizes.filter { !$0.key.hasPrefix(prefix) }
        reload(background: true)
        selectionChanged()
    }

    /// Entries after the filter (folders first, Finder order: as listed).
    var visibleEntries: [RcloneEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return entries }
        return entries.filter { $0.Name.localizedCaseInsensitiveContains(f) }
    }

    var selectedEntries: [RcloneEntry] {
        entries.filter { selection.contains($0.id) }
    }

    // MARK: Sizes of selected folders

    /// Called when the selection changes: after a short pause, `rclone size` runs for each selected
    /// folder whose size is not known yet (results are kept for the session).
    func selectionChanged() {
        sizeTask?.cancel()
        let folders = selectedEntries.filter(\.IsDir).map(fullPath)
        guard !folders.isEmpty else { return }
        sizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            for f in folders where self.sizes[f] == nil {
                self.sizes[f] = .counting
                Task { @MainActor [weak self] in
                    let r: SizeState
                    if self?.demo == true {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        let d = DemoCloud.size(f)
                        r = .done(count: d.count, bytes: d.bytes)
                    } else {
                        switch await Rclone.size(f) {
                        case .success(let s): r = .done(count: s.count, bytes: s.bytes)
                        case .failure(let e): r = .failed(e.localizedDescription)
                        }
                    }
                    withAnimation(.easeInOut(duration: 0.2)) { self?.sizes[f] = r }
                }
            }
        }
    }

    // MARK: New folder

    /// Problem with a new folder name, nil when it is fine.
    func folderNameProblem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Нужно имя" }
        if name.contains("/") { return "Без косой черты, пожалуйста" }
        if name == "." || name == ".." { return "Такое имя Облако не примет" }
        let wanted = UploadJob.cloudPath(name).lowercased()
        if entries.contains(where: { UploadJob.cloudPath($0.Name).lowercased() == wanted }) {
            return "Здесь уже есть «\(name)»"
        }
        return nil
    }

    /// Creates the folder in the shown folder, then selects it. Returns the error text.
    func createFolder(_ raw: String) async -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let p = folderNameProblem(name) { return p }
        let full = path.isEmpty ? name : path + "/" + name
        if demo {
            DemoCloud.extra[path, default: []].append(name)
        } else {
            do { try await Rclone.mkdir(UploadJob.cloudPath(full)) } catch { return error.localizedDescription }
            AppLog.write("cloud: created folder \(full)")
        }
        cache[path] = nil
        reload(background: true)
        // The new folder's id is its name (lsjson paths are relative to the listed folder).
        selection = [UploadJob.cloudPath(name)]
        return nil
    }

    // MARK: Download

    /// «Скачать на Мак»: asks where (NSOpenPanel, starting in the last used folder), then returns
    /// the chosen folder; nil when the user cancels.
    func askDownloadFolder(count: Int, firstName: String, defaultFolder: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Скачать сюда"
        panel.message = count == 1 ? "Куда скачать «\(firstName)»?" : "Куда скачать выбранное (\(count))?"
        let last = UserDefaults.standard.string(forKey: Self.lastPanelFolderKey) ?? defaultFolder
        panel.directoryURL = URL(fileURLWithPath: last, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: Self.lastPanelFolderKey)
        return url
    }

    /// Where a flight from the selection starts (global coordinates): the first selected row's
    /// icon, else the list center.
    func flightOrigin(for ids: [String]) -> CGPoint {
        for id in ids {
            if let f = rowFrames[id], f != .zero { return CGPoint(x: f.minX + 9, y: f.midY) }
        }
        return CGPoint(x: listFrame.midX, y: listFrame.midY)
    }
}

/// Short names of local folders for captions: the standard home folders by their Russian names
/// (Finder shows them so), anything else by its display name.
enum LocalFolderName {
    static func display(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let known: [String: String] = [
            "Downloads": "Загрузки", "Documents": "Документы", "Desktop": "Рабочий стол",
            "Movies": "Фильмы", "Pictures": "Изображения", "Music": "Музыка",
        ]
        if p == home { return FileManager.default.displayName(atPath: p) }
        if (p as NSString).deletingLastPathComponent == home, let ru = known[(p as NSString).lastPathComponent] {
            return ru
        }
        return FileManager.default.displayName(atPath: p)
    }
}

/// Dev `--dev-demo`: a small fake cloud for «Облако» (no rclone).
@MainActor
enum DemoCloud {
    /// Folders created in the demo session, by parent path.
    static var extra: [String: [String]] = [:]

    private static let gb: Int64 = 1_000_000_000

    private static func dir(_ name: String) -> RcloneEntry {
        RcloneEntry(Path: name, Name: name, IsDir: true, Size: -1, ModTime: "2000-01-01T00:00:00Z")
    }

    private static func file(_ name: String, _ size: Int64, daysAgo: Double) -> RcloneEntry {
        let d = Date().addingTimeInterval(-daysAgo * 86_400)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return RcloneEntry(Path: name, Name: name, IsDir: false, Size: size, ModTime: f.string(from: d))
    }

    static func list(_ path: String) -> [RcloneEntry] {
        var out = DevPromo.on ? promoList(path) : demoList(path)
        for name in extra[path] ?? [] { out.append(dir(name)) }
        return out.sorted { a, b in
            if a.IsDir != b.IsDir { return a.IsDir }
            return a.Name.localizedStandardCompare(b.Name) == .orderedAscending
        }
    }

    private static func demoList(_ path: String) -> [RcloneEntry] {
        switch path {
        case "":
            return [dir("Mac"), dir("Документы"), dir("Фото"), dir("Видео"),
                   file("Резюме 2026.pdf", 1_240_000, daysAgo: 12), file("Счёт за октябрь.xlsx", 86_000, daysAgo: 3)]
        case "Mac":
            return [dir("Desktop"), dir("Documents"), dir("Movies"), dir("Pictures"), dir("Входящие")]
        case "Mac/Movies":
            return [dir("Отпуск 2026"), dir("Проект"),
                   file("Монтаж финал.mp4", 12 * gb, daysAgo: 0.1), file("Лекция, запись.mov", 21 * gb, daysAgo: 1.2),
                   file("Тизер.mov", 2_300_000_000, daysAgo: 6), file("Обложка.png", 4_800_000, daysAgo: 40)]
        case "Mac/Входящие":
            return []
        default:
            return [dir("Архив"), file("Заметки.txt", 12_000, daysAgo: 2), file("Фото 001.heic", 3_100_000, daysAgo: 9)]
        }
    }

    /// `--dev-demo-promo`: neutral, pleasant names, no test or state folders. The first folder of
    /// the root is «Видео», whose first item is the folder «Отпуск, август».
    private static func promoList(_ path: String) -> [RcloneEntry] {
        switch path {
        case "":
            return [dir("Видео"), dir("Документы"), dir("Музыка"), dir("Проекты"), dir("Фото"),
                    file("План на неделю.pdf", 1_240_000, daysAgo: 1), file("Бюджет 2026.xlsx", 86_000, daysAgo: 3)]
        case "Видео":
            return [dir("Отпуск, август"), dir("Проект 2026"),
                    file("Монтаж финал.mp4", 12 * gb, daysAgo: 0.1), file("Тизер.mov", 2_300_000_000, daysAgo: 6),
                    file("Лекция, часть 2.mov", 6_900_000_000, daysAgo: 1.2), file("Обложка.png", 4_800_000, daysAgo: 40)]
        case "Документы":
            return [dir("Договоры"), file("Отчёт за октябрь.numbers", 3_800_000, daysAgo: 9),
                    file("Презентация клиенту.pdf", 48_000_000, daysAgo: 2)]
        case "Фото":
            return [dir("Горы"), dir("Море"), file("Закат.heic", 3_100_000, daysAgo: 20)]
        default:
            return [file("Заметки.txt", 12_000, daysAgo: 2), file("Кадр 001.heic", 3_100_000, daysAgo: 9)]
        }
    }

    static func size(_ path: String) -> (count: Int64, bytes: Int64) {
        if DevPromo.on, path.hasSuffix("Отпуск, август") { return (1_486, 64_200_000_000) }
        if path.hasSuffix("Отпуск 2026") { return (40_779, 82_400_000_000) }
        let h = abs(path.hashValue % 900)
        return (Int64(12 + h), Int64(h + 40) * 37_000_000)
    }
}
