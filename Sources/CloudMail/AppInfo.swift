import Foundation

/// Name and description of the app. The name itself lives in exactly one place:
/// `CFBundleName` in Packaging/Info.plist (build.sh derives the .app name and the dev name from it).
enum AppInfo {
    /// «Облачко» (or «Облачко Dev» in the dev bundle). The literal is only a fallback for the bare
    /// binary started outside a bundle.
    static let name: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Облачко"

    /// What the app is, in words that name the service it works with.
    static let tagline = "клиент Облака Mail.ru для macOS"
    static let disclaimer = "неофициальный, не связан с VK"
    /// «Облачко · клиент Облака Mail.ru для macOS · неофициальный, не связан с VK».
    static var aboutLine: String { "\(name) · \(tagline) · \(disclaimer)" }

    /// Third-party code shipped in the bundle (Contents/Helpers/rclone).
    static let includesNotice = "Включает rclone (MIT)"
    /// The full licence texts, copied into the bundle by build.sh.
    static var thirdPartyNotices: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Where a fresh copy of the app can be downloaded.
    static let downloadPage = URL(string: "https://github.com/BLHN/mailru-cloud-mac/releases/latest")!
    /// The README (disclaimer, how to connect, limitations).
    static let readmePage = URL(string: "https://github.com/BLHN/mailru-cloud-mac#readme")!
}
