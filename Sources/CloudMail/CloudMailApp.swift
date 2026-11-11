import SwiftUI
import AppKit
import Combine

/// Owns the single main window (AppKit, so it reliably appears even when the app is launched
/// by dropping files on its Dock icon) and receives files from Dock drops / "Open with" / argv.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch arguments: dev flags are stripped from the file arguments and acted on only in the dev build.
    static let devArgs = DevArgs.parse(Array(CommandLine.arguments.dropFirst()))
    static let isDemo = AppPaths.isDev && devArgs.demo

    let manager = UploadManager(demo: AppDelegate.isDemo)
    let cloudStatus = CloudStatus()
    let loginItem = LoginItem()
    let nav = AppNavigation()
    let cloud = CloudBrowserModel()
    let backupMonitor = BackupMonitor()
    let onboarding = Onboarding()
    lazy var motion = TransferMotion(manager: manager)
    private var dockProgress: DockProgress?
    private var setupObserver: AnyCancellable?
    private var demo: DemoMode?
    private var window: NSWindow?
    private lazy var servicesProvider = ServicesProvider(manager: manager)

    /// The one instance. `NSApp.delegate` is SwiftUI's adaptor, not this class, so views reach the
    /// delegate through here.
    private(set) static weak var shared: AppDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Registered before launch completes so a service request that launched the app is not lost.
        NSApplication.shared.servicesProvider = servicesProvider
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // The dev build declares no services (build.sh --dev strips NSServices).
        if !AppPaths.isDev { NSUpdateDynamicServices() }
        manager.onJobDone = { [weak self] in self?.cloudStatus.refresh(forceFreeSpace: true) }
        // Signed in (or the legacy remote found): the free space is read with the right account.
        setupObserver = manager.$setupIssue.removeDuplicates().dropFirst().sink { [weak self] issue in
            guard issue == nil else { return }
            DispatchQueue.main.async { self?.cloudStatus.refresh(forceFreeSpace: true) }
        }
        dockProgress = DockProgress(manager: manager)
        // The first-run flow follows the account (shown while nothing is set up).
        onboarding.demo = Self.isDemo
        onboarding.bind(Account.shared)
        let dev = Self.devArgs
        if AppPaths.isDev { applyDevLook(dev) }
        // Before the first refresh: the demo never starts `rclone about`.
        if Self.isDemo { cloudStatus.startDemo() }
        // The demo never checks the setup; only an invented demo account is shown as signed in.
        if Self.isDemo, Account.demoEmail != nil { Task { await Account.shared.refresh() } }
        // `--dev-play gauge`: the gauge waits empty for its cue (hidden before the window is built).
        if Self.isDemo && dev.play == "gauge" { cloudStatus.demoHideStorage() }
        cloud.demo = Self.isDemo
        backupMonitor.demo = Self.isDemo
        backupMonitor.onState = { [weak self] state in self?.cloudStatus.noteBackup(state) }
        // «Копия Мака» and the background reads exist only where the supervisor's status file does.
        updateSupervisorPresence()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSupervisorPresence() }
        }
        // A launch that is not "default" (started by a Finder service request, to open files, or
        // to restore state) must not pull focus away from the app the user is in. The service
        // handler and application(_:open:) decide about activation themselves.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        showWindow(activate: isDefaultLaunch)
        // The window may open on another Space or behind other windows, so the visibility-driven
        // refresh would not run: fill the header once on launch regardless.
        cloudStatus.refresh()
        // Dev flags and their values (a cloud path, a folder) are never taken for files to upload.
        let args = dev.rest.filter { !$0.hasPrefix("-") }
        if !args.isEmpty { manager.add(urls: args.map { URL(fileURLWithPath: $0) }) }
        if AppPaths.isDev { startDevArguments(dev) }
    }

    /// Starts or stops the supervisor's background reads to follow its status file.
    private func updateSupervisorPresence() {
        cloudStatus.recheckSupervisor()
        if cloudStatus.hasSupervisor {
            backupMonitor.startBackground()
        } else {
            backupMonitor.stopBackground()
            if nav.section == .backup { nav.section = .transfers }
        }
    }

    /// Dev build only: queue the `--dev-download` pairs (the kind of each cloud item is read with
    /// `lsjson --stat`), store `--dev-section`, and arm `--dev-exit-when-idle` once all of them
    /// are in the queue.
    private func startDevArguments(_ dev: DevArgs) {
        manager.initialSection = dev.section
        #if CLOUDMAIL_DEV
        if dev.selfTest {
            Task { @MainActor in
                await DevSelfTest.run()
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let step = dev.onboarding {
            onboarding.devForce(step: step, problem: dev.onboardingError)
        }
        if let panel = dev.guidePanel {
            onboarding.devForce(step: "password", problem: nil)
            if panel == "copied" { onboarding.form.devOfferClipboard() }
            PasswordGuidePanel.shared.show(form: onboarding.form, handlers: onboarding.guideHandlers)
        }
        if let sheet = dev.keychainSheet {
            // A sheet of a window kept at the back is not drawn for `screencapture`: in the dev build
            // the sheet's content is also shown as an ordinary window of its own.
            let notice: KeychainNotice = sheet == "denied" ? .denied : .beforeRead
            devShowAsWindow(KeychainNoticeSheet(notice: notice).environmentObject(nav))
        }
        if dev.moveNow {
            // Dev: screen 0's button pressed at launch (the target comes from CLOUDMAIL_DEV_MOVE_TARGET).
            onboarding.devForce(step: "move", problem: nil)
            onboarding.moveToApplications()
        }
        if dev.signInSheet {
            devShowAsWindow(SignInSheet().environmentObject(nav))
        }
        #endif
        if dev.demo {
            let d = DemoMode(manager: manager, status: cloudStatus, nav: nav)
            d.cloud = cloud
            d.start(empty: dev.demoEmpty)
            demo = d
        }
        if let play = dev.play {
            Task { @MainActor [weak self] in
                let delay = max(0, dev.playAt ?? 2)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if let d = self.demo {
                    d.play(play)
                } else {
                    AppLog.write("dev: --dev-play needs --dev-demo")
                }
            }
        }
        guard !dev.downloads.isEmpty || dev.exitWhenIdle else { return }
        let manager = self.manager
        Task { @MainActor in
            for (cloud, folder) in dev.downloads {
                let isDirectory: Bool
                switch await Rclone.remoteInfo(UploadJob.cloudPath(cloud)) {
                case .failure(let e):
                    // Queue it anyway (kind guessed from the extension): the job's own preparation
                    // re-checks the cloud and fails the row with the user-facing message.
                    isDirectory = (cloud as NSString).pathExtension.isEmpty
                    AppLog.write("dev: cloud item check failed for \(cloud) (\(e.localizedDescription)), queuing as \(isDirectory ? "folder" : "file")")
                case .success(let info):
                    isDirectory = info.IsDir == true
                }
                manager.download(remotePath: cloud, isDirectory: isDirectory,
                                 to: URL(fileURLWithPath: folder, isDirectory: true))
            }
            await manager.waitForIntake()
            if dev.exitWhenIdle { manager.exitWhenIdle = true }
        }
    }

    #if CLOUDMAIL_DEV
    private var devWindows: [NSWindow] = []

    /// Dev: a view in a plain titled window at the back (for screenshots of sheet contents).
    private func devShowAsWindow<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view.tint(.appTint))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        w.orderBack(nil)
        devWindows.append(w)
    }
    #endif

    /// Dev build: appearance, start section and forced hover row, before the window is built.
    private func applyDevLook(_ dev: DevArgs) {
        switch dev.appearance {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let s = dev.section, let section = AppSection(rawValue: s) { nav.section = section }
        // `--dev-cloud-path` opens «Облако» at that folder (unless another section is asked for).
        if dev.cloudPath != nil && dev.section == nil { nav.section = .cloud }
        cloud.devSelectFirst = dev.selectFirst
        nav.devHoverRow = dev.hover
    }

    /// The button next to a setup problem: download page, sign-in sheet, or Settings.
    func resolveSetupIssue() {
        switch manager.setupIssue {
        case .noRclone:
            Onboarding.openPage(AppInfo.downloadPage)
        case .keychainLocked:
            Task { await manager.checkSetup() }
        case .authFailed(legacy: true):
            showSettings()
        case .notConnected:
            // The window shows the onboarding while nothing is set up.
            showWindow()
        case .authFailed(legacy: false):
            showWindow()
            nav.signInPresented = true
        case nil:
            showWindow()
        }
    }

    /// The standard About panel with what the app is.
    func showAbout() {
        let credits = NSAttributedString(string: "\(AppInfo.tagline)\n\(AppInfo.disclaimer)\n\(AppInfo.includesNotice)",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        if !AppPaths.isDev { NSApplication.shared.activate() }
    }

    /// Cmd+, and the sidebar row: the «Настройки» section of the main window.
    func showSettings() {
        nav.section = .settings
        showWindow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        manager.add(urls: urls)
        showWindow(activate: !AppPaths.isDev)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(activate: !AppPaths.isDev)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard manager.hasLiveProcess else { return .terminateNow }
        // Log out, restart and shut down must never be blocked by a modal question: the queue is
        // saved and the upload resumes on the next launch anyway.
        if Self.isSystemQuit {
            manager.stopAllForQuit()
            return .terminateNow
        }
        let alert = NSAlert()
        // Say what is actually running: a download back to the Mac or an upload.
        let downloading = manager.runningJob.map { $0.isDownload || $0.kind == .restore } ?? false
        alert.messageText = downloading ? "Скачивание ещё идёт" : "Загрузка ещё идёт"
        alert.informativeText = downloading
            ? "Если выйти сейчас, скачивание остановится и продолжится само при следующем запуске."
            : "Если выйти сейчас, загрузка остановится и продолжится сама при следующем запуске."
        alert.addButton(withTitle: "Выйти и остановить")
        alert.addButton(withTitle: downloading ? "Продолжить скачивание" : "Продолжить загрузку")
        if alert.runModal() == .alertFirstButtonReturn {
            manager.stopAllForQuit()
            return .terminateNow
        }
        return .terminateCancel
    }

    /// True when the quit Apple event comes from log out / restart / shut down
    /// (the `kAEQuitReason` attribute of the 'quit' event).
    private static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        let systemReasons: [OSType] = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                                       kAERestart, kAEShutDown].map { OSType($0) }
        return systemReasons.contains(reason)
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopAllForQuit()
    }

    /// `activate: false` puts the window in front without taking focus from the app the user is in
    /// (used by the Finder service: the user stays in Finder, the menu bar icon shows progress).
    func showWindow(activate: Bool = true) {
        if window == nil {
            let root = MainWindowView()
                .environmentObject(manager)
                .environmentObject(cloudStatus)
                .environmentObject(loginItem)
                .environmentObject(nav)
                .environmentObject(motion)
                .environmentObject(cloud)
                .environmentObject(backupMonitor)
                .environmentObject(onboarding)
            let dev = Self.devArgs
            #if CLOUDMAIL_DEV
            let windowClass: NSWindow.Type = AppPaths.isDev && dev.activeLook ? DevActiveLookWindow.self : NSWindow.self
            #else
            let windowClass: NSWindow.Type = NSWindow.self
            #endif
            let w = windowClass.init(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            w.title = AppInfo.name
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            let host = NSHostingView(rootView: root)
            // SwiftUI owns the title and the toolbar (sidebar toggle, section title).
            host.sceneBridgingOptions = [.title, .toolbars]
            w.contentView = host
            w.contentMinSize = NSSize(width: 760, height: 480)
            w.isReleasedWhenClosed = false
            let exactSize = AppPaths.isDev ? dev.windowSize.flatMap(Self.parseSize) : nil
            if let exactSize {
                // `--dev-window-size`: this run only, the saved frame is neither read nor written.
                w.setContentSize(exactSize)
                w.center()
            } else {
                // A new autosave name: frames saved by the old narrow window are below the new minimum.
                w.setFrameAutosaveName("MainWindowV2")
                if !w.setFrameUsingName("MainWindowV2") {
                    w.setContentSize(NSSize(width: 920, height: 600))
                    w.center()
                }
                if AppPaths.isDev, let size = dev.size.flatMap(Self.parseSize) { w.setContentSize(size) }
            }
            #if CLOUDMAIL_DEV
            if AppPaths.isDev && dev.activeLook { DevActiveLookWindow.prepareForRecording(w) }
            #endif
            window = w
        }
        if AppPaths.isDev {
            // The dev build runs next to the developer's own apps: it never activates itself and never
            // comes above other apps. Ordered to the back it still has a window id, so
            // `screencapture -l <id>` can capture it.
            window?.orderBack(nil)
        } else if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
        } else {
            window?.orderFront(nil)
        }
        updateStatusActivity()
    }

    /// "920x600" -> 920 x 600 pt (dev size flags).
    private static func parseSize(_ text: String) -> NSSize? {
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    /// The header refresh is cheap (ps + two log tails), so it runs all the time the window exists:
    /// the window is often behind other apps and must still show fresh numbers when it comes up.
    private func updateStatusActivity() {
        cloudStatus.setActive(window != nil)
    }
}

#if CLOUDMAIL_DEV
/// Dev `--dev-active-look` (compiled only into `./build.sh --dev`): the main window reports itself as key and main, so it draws with the
/// active look (coloured traffic lights, accent selection, full-strength title) while the dev app
/// stays in the background behind the other apps. Used only for recording the demo film.
/// AppKit draws the titlebar, the traffic lights and the sidebar selection from its own
/// appearance queries rather than from `isKeyWindow`, so those are answered too (Objective-C
/// selectors of NSWindow, dev only).
final class DevActiveLookWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
    @objc func hasMainAppearance() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc(_hasActiveAppearanceForStandardWindowButton:) func devActiveForWindowButton(_ button: Int) -> Bool { true }
    // While the window is recorded with ScreenCaptureKit, macOS 26 swaps the traffic lights for a
    // window-sharing capsule; the recording should show the app as the user sees it.
    override var hasActiveWindowSharingSession: Bool { false }
    @objc func showsWindowSharingTitlebarButton() -> Bool { false }
    @objc func _updateButtonsForWindowSharingSession() {}
    @objc(_setInSharingSession:) func devSetInSharingSession(_ flag: Bool) {}

    private static var activity: NSObjectProtocol?

    /// A window on another Space (or a napping app) gets only a few animation frames per second.
    /// For a recording the window joins every Space, always at the back (it stays behind the
    /// other windows, out of the window cycle), and App Nap is held off.
    static func prepareForRecording(_ w: NSWindow) {
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "dev recording of the demo film")
    }
}
#endif

@main
struct CloudMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(delegate.manager)
                .environmentObject(delegate.cloudStatus)
        } label: {
            MenuBarLabel(manager: delegate.manager)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О программе \(AppInfo.name)") { delegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Открыть окно") { delegate.showWindow() }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { delegate.showSettings() }.keyboardShortcut(",")
            }
            CommandGroup(after: .toolbar) {
                Button("Открыть Облако в браузере") { delegate.manager.openInBrowser() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var manager: UploadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: manager.runningJob == nil ? "icloud.and.arrow.up" : "icloud.and.arrow.up.fill")
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: manager.runningJob != nil && !reduceMotion)
            .accessibilityLabel(AppInfo.name)
    }
}
