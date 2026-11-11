import Foundation
import Security

/// The sheet «macOS спросит пароль от Мака» (plan A8). With an ad-hoc signature the Keychain item's
/// access list is bound to the exact build, so after every update macOS asks the user whether this
/// app may read the cloud password again. The sheet explains that before the first read of a new
/// build, and after a denied read offers to try again or to sign in anew. With a stable signing
/// identity the item survives updates and the "before" sheet is not shown at all.
enum KeychainNotice: String, Identifiable, Sendable {
    /// About to read the item in a new build: explain the coming system prompt.
    case beforeRead
    /// The user denied access (or it is not allowed right now).
    case denied

    var id: String { rawValue }

    /// The running build's `CFBundleVersion`.
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// Explain before reading: an ad-hoc signed build that has not read the item yet. The dev
    /// bundle never waits for the sheet (its self-test reads items unattended); `--dev-keychain-sheet`
    /// shows it on demand.
    static var shouldExplainBeforeRead: Bool {
        guard !AppPaths.isDev, isAdHocSigned else { return false }
        return UserDefaults.standard.string(forKey: Account.lastReadBuildKey) != build
    }

    static func noteReadSucceeded() {
        UserDefaults.standard.set(build, forKey: Account.lastReadBuildKey)
    }

    /// Statuses that mean the user said no (or could not be asked), as opposed to a missing item.
    static func isDenial(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed
    }

    /// True when the app's own signature is ad-hoc (no certificate), read from its code signature.
    /// Unknown counts as ad-hoc: the sheet then shows once per build, which is harmless.
    static let isAdHocSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        let codeFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = dict[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 || certificates.isEmpty
    }()
}
