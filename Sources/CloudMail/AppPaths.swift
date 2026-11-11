import Foundation

/// The one place that decides where the app keeps its state and log, and whether this is the dev
/// build. `./build.sh --dev` makes "<name> Dev.app" with the bundle id `ru.blhn.cloudmail.dev`:
/// it keeps its own queue, log and UserDefaults, so it can run next to the production app without
/// touching that app's queue.json or log.
enum AppPaths {
    /// True for the dev build (bundle id ends with ".dev").
    static let isDev: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// ~/Library/Application Support/CloudMail (production) or …/CloudMail-Dev (dev).
    static let supportFolder: URL = home
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(isDev ? "CloudMail-Dev" : "CloudMail", isDirectory: true)

    static let queueURL: URL = supportFolder.appendingPathComponent("queue.json")

    /// ~/Library/Logs/CloudMail.log (production) or ~/Library/Logs/CloudMail-Dev.log (dev).
    static let logURL: URL = home
        .appendingPathComponent("Library/Logs")
        .appendingPathComponent(isDev ? "CloudMail-Dev.log" : "CloudMail.log")
}

/// Dev-only launch arguments. They are always stripped from the file arguments (so a cloud path
/// is never mistaken for a local file to upload), but acted on only in the dev build.
///   --dev-download <cloudPath> --dev-to <localFolder>   (repeatable) queue a download at launch
///   --dev-exit-when-idle                                quit once the queue is idle
///   --dev-section transfers|cloud|backup|settings       section selected at launch
///   --dev-demo                                          fake jobs in every state, no rclone, queue not saved
///   --dev-demo-empty                                    the same demo mode with an empty queue
///   --dev-appearance light|dark                         forces the appearance
///   --dev-play drop|done|fail|download                  plays that choreography 2 s after launch
///   --dev-size <W>x<H>                                  window size at launch (for screenshots)
///   --dev-hover <n>                                     shows row n (0-based) of «Передачи» as hovered
///   --dev-play gauge                                    the sidebar cloud gauge rises from empty on cue
///   --dev-play-at <seconds>                             delay of --dev-play after launch instead of 2 s
///   --dev-window-size <W>x<H>                           exact window size for this run, never saved
///   --dev-active-look                                   the main window draws as key/main in the background
///   --dev-demo-promo                                    with --dev-demo: a presentable data set (demo film)
///   --dev-selftest                                      account plumbing checks with invented credentials, then quit
struct DevArgs {
    var downloads: [(cloudPath: String, localFolder: String)] = []
    var exitWhenIdle = false
    var section: String?
    var demo = false
    var demoEmpty = false
    var appearance: String?
    var play: String?
    var size: String?
    var hover: Int?
    /// `--dev-cloud-path <path>`: «Облако» opens at this cloud folder.
    var cloudPath: String?
    /// `--dev-select-first`: the first item of the shown cloud folder is selected once it loads.
    var selectFirst = false
    /// `--dev-play-at <seconds>`: when `--dev-play` fires after launch (default 2 s).
    var playAt: Double?
    /// `--dev-window-size <W>x<H>`: content size for this run; the frame is not autosaved.
    var windowSize: String?
    /// `--dev-active-look`: the window reports key/main, so it draws active while in the background.
    var activeLook = false
    /// `--dev-demo-promo`: the demo shows a calm, presentable data set (see `DemoMode.promo`).
    var demoPromo = false
    /// `--dev-selftest`: run `DevSelfTest` (dev build with CLOUDMAIL_DEV only) and quit.
    var selfTest = false
    /// `--dev-onboarding move|move-error|welcome|password|phone|signin|done`: the onboarding at that
    /// screen, whatever the account (screenshots).
    var onboarding: String?
    /// `--dev-onboarding-error 3.1|3.1b|3.2|...|3.8|checking|clipboard|warning`: screen 3 with that state.
    var onboardingError: String?
    /// `--dev-guide-panel waiting|copied`: the floating guide 2A (an ordinary window at the back).
    var guidePanel: String?
    /// `--dev-keychain-sheet before|denied`: the Keychain explanation sheet.
    var keychainSheet: String?
    /// `--dev-signin-sheet`: the compact sign-in sheet's content in a window of its own.
    var signInSheet = false
    /// `--dev-move-now`: runs «Перенести и открыть» at launch (only into CLOUDMAIL_DEV_MOVE_TARGET).
    var moveNow = false
    /// Everything that is not a dev flag or a dev flag's value, in order.
    var rest: [String] = []

    static func parse(_ args: [String]) -> DevArgs {
        var r = DevArgs()
        var pendingCloud: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            let next: String? = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--dev-download":
                pendingCloud = next
                i += 2
            case "--dev-to":
                if let cloud = pendingCloud, let folder = next {
                    r.downloads.append((cloud, folder))
                }
                pendingCloud = nil
                i += 2
            case "--dev-section":
                r.section = next
                i += 2
            case "--dev-exit-when-idle":
                r.exitWhenIdle = true
                i += 1
            case "--dev-demo":
                r.demo = true
                i += 1
            case "--dev-demo-empty":
                r.demo = true
                r.demoEmpty = true
                i += 1
            case "--dev-appearance":
                r.appearance = next
                i += 2
            case "--dev-play":
                r.play = next
                i += 2
            case "--dev-size":
                r.size = next
                i += 2
            case "--dev-cloud-path":
                r.cloudPath = next
                i += 2
            case "--dev-select-first":
                r.selectFirst = true
                i += 1
            case "--dev-play-at":
                r.playAt = next.flatMap { Double($0) }
                i += 2
            case "--dev-window-size":
                r.windowSize = next
                i += 2
            case "--dev-active-look":
                r.activeLook = true
                i += 1
            case "--dev-demo-promo":
                r.demoPromo = true
                i += 1
            case "--dev-selftest":
                r.selfTest = true
                i += 1
            case "--dev-onboarding":
                r.onboarding = next
                i += 2
            case "--dev-onboarding-error":
                r.onboardingError = next
                if r.onboarding == nil { r.onboarding = "signin" }
                i += 2
            case "--dev-guide-panel":
                r.guidePanel = next
                i += 2
            case "--dev-move-now":
                r.moveNow = true
                i += 1
            case "--dev-signin-sheet":
                r.signInSheet = true
                i += 1
            case "--dev-keychain-sheet":
                r.keychainSheet = next
                i += 2
            case "--dev-hover":
                r.hover = next.flatMap { Int($0) }
                i += 2
            default:
                r.rest.append(a)
                i += 1
            }
        }
        return r
    }
}
