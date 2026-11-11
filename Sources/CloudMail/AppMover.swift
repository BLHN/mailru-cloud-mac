import AppKit
import Darwin

/// Screen 0 of the onboarding: an app started from Downloads or straight from the disk image
/// (macOS then runs it from a randomized read-only "App Translocation" copy) cannot launch at login
/// and does not offer its Finder services. «Перенести и открыть» copies the bundle into the
/// Applications folder, takes the quarantine flag off the copy, opens the copy and quits. An older
/// copy at the destination and the original go to the Trash, never a permanent delete; the original
/// only after the copy has launched.
enum AppMover {
    enum MoveError: Error, Equatable {
        /// Neither /Applications nor ~/Applications could take the copy.
        case noAccess
        /// An instance of the app runs from the destination: it has to be closed first.
        case destinationRunning
        /// The copy is there but did not open.
        case launchFailed
        /// The dev bundle never touches /Applications (it moves only into `CLOUDMAIL_DEV_MOVE_TARGET`).
        case devRefused
    }

    /// The bundle as it was started (may be the translocated copy).
    static var bundleURL: URL { Bundle.main.bundleURL }

    /// True when the app lives in /Applications or ~/Applications (launch at login works there).
    static var isInApplications: Bool { !needsMove(path: bundleURL.path, home: NSHomeDirectory()) }

    /// Whether to offer screen 0. The dev bundle (built into dist/) is never offered it on its own;
    /// `--dev-onboarding move` shows the screen.
    static var shouldOffer: Bool {
        guard !AppPaths.isDev else { return false }
        return needsMove(path: bundleURL.path, home: NSHomeDirectory())
    }

    /// Pure, for tests: translocated, or outside both Applications folders.
    static func needsMove(path: String, home: String) -> Bool {
        if path.contains("/AppTranslocation/") { return true }
        let p = (path as NSString).standardizingPath
        let roots = ["/Applications/", (home as NSString).appendingPathComponent("Applications") + "/"]
        return !roots.contains { p.hasPrefix($0) }
    }

    /// Where the bundle really is: for a translocated run, the original path on disk or on the image.
    static var originalURL: URL { original(of: bundleURL) }

    /// Copies, unquarantines, launches the copy. On success the caller quits the app.
    static func move() async -> Result<URL, MoveError> {
        let fm = FileManager.default
        let source = bundleURL
        let name = source.lastPathComponent
        var targets = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications")]
        if AppPaths.isDev {
            #if CLOUDMAIL_DEV
            // The dev build only ever moves into a scratch folder given explicitly.
            guard let t = ProcessInfo.processInfo.environment["CLOUDMAIL_DEV_MOVE_TARGET"], !t.isEmpty else {
                AppLog.write("dev: move refused (no CLOUDMAIL_DEV_MOVE_TARGET)")
                return .failure(.devRefused)
            }
            targets = [URL(fileURLWithPath: t, isDirectory: true)]
            #else
            return .failure(.devRefused)
            #endif
        }
        var placed: URL?
        for dir in targets {
            let dest = dir.appendingPathComponent(name)
            if isRunning(at: dest) { return .failure(.destinationRunning) }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    // The previous version goes to the Trash.
                    try fm.trashItem(at: dest, resultingItemURL: nil)
                }
                try fm.copyItem(at: source, to: dest)
                placed = dest
                break
            } catch {
                AppLog.write("move: \(dir.path) not usable: \(error.localizedDescription)")
            }
        }
        guard let dest = placed else { return .failure(.noAccess) }
        removeQuarantine(under: dest)
        AppLog.write("move: copied to \(dest.path)")

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // The dev build never comes to the front.
        config.activates = !AppPaths.isDev
        config.addsToRecentItems = false
        do {
            let app = try await NSWorkspace.shared.openApplication(at: dest, configuration: config)
            AppLog.write("move: the copy runs (pid \(app.processIdentifier))")
        } catch {
            AppLog.write("move: the copy did not open: \(error.localizedDescription)")
            return .failure(.launchFailed)
        }
        // Only now does the original go: to the Trash, and only when it is a writable place (a
        // disk image is read-only and simply stays as it is).
        let original = originalURL
        if original.standardizedFileURL != dest.standardizedFileURL,
           fm.isWritableFile(atPath: original.deletingLastPathComponent().path) {
            do {
                try fm.trashItem(at: original, resultingItemURL: nil)
                AppLog.write("move: the original went to the Trash")
            } catch {
                AppLog.write("move: the original stays (\(error.localizedDescription))")
            }
        }
        return .success(dest)
    }

    /// «Показать в Finder» for the manual way.
    static func revealOriginal() {
        NSWorkspace.shared.activateFileViewerSelecting([originalURL])
    }

    private static func isRunning(at url: URL) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let target = url.standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
            $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL.path == target
        }
    }

    /// Takes `com.apple.quarantine` off the bundle and everything inside it.
    private static func removeQuarantine(under root: URL) {
        let attr = "com.apple.quarantine"
        var paths = [root.path]
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let rel as String in e { paths.append(root.appendingPathComponent(rel).path) }
        }
        var removed = 0
        for p in paths where removexattr(p, attr, XATTR_NOFOLLOW) == 0 { removed += 1 }
        AppLog.write("move: quarantine removed from \(removed) items")
    }

    /// The original location of a translocated bundle (Security framework, looked up at run time so
    /// a missing symbol only means "use the path as it is").
    private static func original(of url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let out = fn(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return out as URL
    }
}
