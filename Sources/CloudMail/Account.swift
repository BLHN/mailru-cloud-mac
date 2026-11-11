import Foundation
import Security

/// How the app reaches the cloud.
enum AccountState: Equatable {
    /// Not decided yet (launch) or nothing set up: no account in the app, no remote in rclone.conf.
    case none
    /// Signed in through the app: the app password is in the Keychain, rclone gets the remote only
    /// through its environment.
    case keychain(email: String)
    /// The user's own rclone.conf has a remote "mailru": rclone uses it as it is, the app passes
    /// neither `--config` nor any remote variables.
    case legacyRemote
    /// The cloud stopped accepting the password. `email` is nil for the legacy remote.
    case authFailed(email: String?)

    var isConnected: Bool {
        switch self {
        case .keychain, .legacyRemote: return true
        case .none, .authFailed: return false
        }
    }

    var email: String? {
        switch self {
        case .keychain(let e): return e
        case .authFailed(let e): return e
        case .none, .legacyRemote: return nil
        }
    }
}

/// The Mail.ru account of the app. The app password lives only in the Keychain (generic password,
/// service = the bundle id); it is read once per launch and turned into rclone's obscured form at
/// once, only that string stays in memory and reaches rclone, through the environment of each child
/// (`RCLONE_CONFIG_MAILRU_*`, never argv, never a file). The remote keeps the name "mailru", so every
/// `mailru:` path works the same in both modes. rclone.conf is never read by the app.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()

    @Published private(set) var state: AccountState = .none
    /// False until the first `refresh()` has decided the state.
    @Published private(set) var resolved = false
    /// The Keychain item exists but could not be read (the user denied access, or it is locked).
    @Published private(set) var keychainReadFailed = false

    /// Called on the main actor after every change of `state` or `keychainReadFailed`.
    var onChange: (() -> Void)?
    /// The explanation sheet about the system's Keychain prompt (see `KeychainNotice`), shown over
    /// the main window while set.
    @Published private(set) var keychainNotice: KeychainNotice?
    private var noticeContinuation: CheckedContinuation<Void, Never>?

    nonisolated static let emailKey = "account.email"
    /// `CFBundleVersion` of the build that last read (or wrote) the Keychain item without trouble.
    nonisolated static let lastReadBuildKey = "account.lastKeychainReadBuild"
    nonisolated static let webdavURL = "https://webdav.cloud.mail.ru"
    /// The dev bundle (`ru.blhn.cloudmail.dev`) keeps its own item, apart from the release one.
    nonisolated static var keychainService: String { Bundle.main.bundleIdentifier ?? "ru.blhn.cloudmail" }

    /// Dev `--dev-demo` only: `CLOUDMAIL_DEV_DEMO_ACCOUNT=<e-mail>` shows that (invented) address as
    /// signed in, without touching the Keychain or rclone (screenshots).
    static var demoEmail: String? {
        guard AppDelegate.isDemo,
              let e = ProcessInfo.processInfo.environment["CLOUDMAIL_DEV_DEMO_ACCOUNT"], !e.isEmpty else { return nil }
        return e
    }

    /// Obscured password of the signed-in account, in memory only.
    private var obscured: String?
    private var refreshing: Task<Void, Never>?

    private init() {}

    // MARK: State

    /// Decides the mode: (1) an e-mail in UserDefaults with its Keychain item → `.keychain`;
    /// (2) else rclone's default config has the remote "mailru" → `.legacyRemote`; (3) else `.none`.
    /// A known `.authFailed` stays until the user signs in again or the check passes.
    func refresh() async {
        if let running = refreshing { return await running.value }
        let task = Task { @MainActor in await self.decide() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func decide() async {
        let before = (state, keychainReadFailed)
        defer {
            resolved = true
            if before != (state, keychainReadFailed) { onChange?() }
        }
        // Dev demo with CLOUDMAIL_DEV_DEMO_ACCOUNT=<invented e-mail>: shown as signed in, no Keychain.
        if let demoEmail = Self.demoEmail {
            state = .keychain(email: demoEmail)
            return
        }
        if let email = UserDefaults.standard.string(forKey: Self.emailKey), !email.isEmpty,
           Keychain.exists(service: Self.keychainService, account: email) {
            if obscured == nil {
                // An ad-hoc signed new build: macOS is about to ask for the Mac password, say so first.
                if KeychainNotice.shouldExplainBeforeRead {
                    await explain(.beforeRead)
                }
                let service = Self.keychainService
                let read = await Task.detached(priority: .userInitiated) {
                    Keychain.read(service: service, account: email)
                }.value
                switch read {
                case .success(let password):
                    obscured = await Rclone.obscure(password)
                    if obscured == nil { AppLog.write("account: rclone obscure failed") }
                    else { KeychainNotice.noteReadSucceeded() }
                case .failure(.status(let status)):
                    AppLog.write("account: keychain read failed (OSStatus \(status))")
                    if KeychainNotice.isDenial(status) { keychainNotice = .denied }
                }
            }
            keychainReadFailed = obscured == nil
            if case .authFailed(let e) = state, e == email {
                // Stays until a check passes or the user signs in again.
            } else {
                state = .keychain(email: email)
            }
            applyEnvironment()
            return
        }
        keychainReadFailed = false
        obscured = nil
        let remote: Bool? = Rclone.binary != nil ? await Rclone.hasRemote() : false
        switch remote {
        case .some(true):
            if state != .authFailed(email: nil) { state = .legacyRemote }
        case .some(false):
            state = .none
        case .none:
            // rclone could not read its config just now (being rewritten, encrypted without the
            // password in the app's environment): a legacy remote already in use stays.
            if state != .legacyRemote && state != .authFailed(email: nil) { state = .none }
            else { AppLog.write("account: could not list rclone remotes, keeping the legacy remote") }
        }
        applyEnvironment()
    }

    /// Hands the current mode to every rclone the app starts from now on.
    private func applyEnvironment() {
        switch state {
        case .keychain(let email), .authFailed(.some(let email)):
            if let obscured {
                Rclone.setEnvironment(Self.environment(email: email, obscured: obscured), legacyRemote: false)
            } else {
                // No password to hand over: rclone must not fall back to some other config.
                Rclone.setEnvironment(Self.environment(email: email, obscured: ""), legacyRemote: false)
            }
        case .legacyRemote, .authFailed(.none):
            Rclone.setEnvironment(nil, legacyRemote: true)
        case .none:
            Rclone.setEnvironment(nil, legacyRemote: false)
        }
    }

    /// The app's environment without any inherited rclone config, plus the remote "mailru".
    nonisolated static func environment(email: String, obscured: String,
                                        base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("RCLONE_CONFIG") }
        env["RCLONE_CONFIG"] = "/dev/null"
        env["RCLONE_CONFIG_MAILRU_TYPE"] = "webdav"
        env["RCLONE_CONFIG_MAILRU_URL"] = webdavURL
        env["RCLONE_CONFIG_MAILRU_VENDOR"] = "other"
        env["RCLONE_CONFIG_MAILRU_USER"] = email
        env["RCLONE_CONFIG_MAILRU_PASS"] = obscured
        return env
    }

    // MARK: Keychain notice

    /// Shows the sheet and waits until the user has read it («Понятно»).
    private func explain(_ notice: KeychainNotice) async {
        AppLog.write("account: explaining the keychain prompt before reading")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            noticeContinuation?.resume()
            noticeContinuation = c
            keychainNotice = notice
        }
    }

    /// «Понятно» or the sheet closed: the waiting read goes on.
    func dismissKeychainNotice() {
        keychainNotice = nil
        noticeContinuation?.resume()
        noticeContinuation = nil
    }

    /// «Попробовать снова» after a denied read: one more read (the system asks again).
    func retryKeychain() async {
        dismissKeychainNotice()
        obscured = nil
        await decide()
    }

    #if CLOUDMAIL_DEV
    /// Dev `--dev-keychain-sheet`: shows the sheet without reading anything.
    func devShowKeychainNotice(_ notice: KeychainNotice) { keychainNotice = notice }
    #endif

    // MARK: Sign in / out

    enum ConnectResult: Equatable {
        case connected(WebDAVProbe.Quota)
        case failed(ConnectFailure)
    }

    /// Why a sign-in did not go through.
    enum ConnectFailure: Equatable, Sendable {
        /// No full e-mail or no password.
        case input
        /// Mail.ru answered, or could not be reached (see `WebDAVProbe.Failure`).
        case probe(WebDAVProbe.Failure)
        /// No rclone in the bundle or the known places.
        case noRclone
        /// `rclone obscure` failed: the bundled rclone is broken.
        case obscure
        /// The Keychain refused to store the password.
        case keychain(OSStatus)

        /// One text for the compact places (the log, a plain alert).
        var message: String {
            switch self {
            case .input: return "Введите почту и пароль для приложения."
            case .probe(let f): return f.message
            case .noRclone: return Rclone.RcloneError.notInstalled.errorDescription ?? ""
            case .obscure: return "Не получилось подготовить пароль для rclone. Скачайте приложение заново."
            case .keychain(let s):
                return KeychainNotice.isDenial(s)
                    ? "macOS не дал записать пароль в связку ключей. Нажмите «Войти» ещё раз и разрешите доступ."
                    : "Не получилось сохранить пароль в связке ключей (код \(s))."
            }
        }
    }

    /// Checks the e-mail and app password with a direct PROPFIND; only when Mail.ru accepts them is
    /// the password stored in the Keychain and the account switched over. A following
    /// `rclone about` is an extra check whose failure is only logged.
    /// `probePassed` is called once Mail.ru has accepted the pair (the onboarding ticks its first
    /// two marks then); the rest (rclone, Keychain) follows.
    func connect(email rawEmail: String, password rawPassword: String,
                 probePassed: (@MainActor () -> Void)? = nil) async -> ConnectResult {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // App passwords have no spaces: whitespace from copying is dropped silently.
        let password = rawPassword.filter { !$0.isWhitespace }
        guard email.contains("@"), !password.isEmpty else {
            return .failed(.input)
        }
        AppLog.write("account: checking sign-in for \(Self.masked(email))")
        switch await WebDAVProbe.check(email: email, password: password) {
        case .failed(let failure):
            AppLog.write("account: sign-in check failed for \(Self.masked(email)): \(failure)")
            return .failed(.probe(failure))
        case .ok(let quota):
            if Task.isCancelled { return .failed(.probe(.other("отменено"))) }
            probePassed?()
            guard Rclone.binary != nil else { return .failed(.noRclone) }
            guard let obscuredPassword = await Rclone.obscure(password) else {
                AppLog.write("account: rclone obscure failed")
                return .failed(.obscure)
            }
            // Last point where «Отмена» still undoes everything: from the Keychain write on, the
            // sign-in is finished as one piece and the caller gets its result.
            if Task.isCancelled { return .failed(.probe(.other("отменено"))) }
            let service = Self.keychainService
            let label = "\(AppInfo.name): Облако Mail.ru"
            // May show the system's Keychain prompt (an item written by an older ad-hoc build):
            // off the main thread, like the read.
            let status = await Task.detached(priority: .userInitiated) {
                Keychain.save(service: service, account: email, password: password, label: label)
            }.value
            guard status == errSecSuccess else {
                AppLog.write("account: keychain save failed (OSStatus \(status))")
                return .failed(.keychain(status))
            }
            // This build wrote the item, so it may read it without a prompt.
            KeychainNotice.noteReadSucceeded()
            // A different e-mail signed in before: its item goes.
            if let old = UserDefaults.standard.string(forKey: Self.emailKey), old != email {
                let deleted = await Task.detached(priority: .userInitiated) {
                    Keychain.delete(service: service, account: old)
                }.value
                if deleted != errSecSuccess && deleted != errSecItemNotFound {
                    AppLog.write("account: could not remove the item of \(Self.masked(old)) (OSStatus \(deleted))")
                }
            }
            UserDefaults.standard.set(email, forKey: Self.emailKey)
            obscured = obscuredPassword
            keychainReadFailed = false
            keychainNotice = nil
            state = .keychain(email: email)
            applyEnvironment()
            resolved = true
            AppLog.write("account: signed in as \(Self.masked(email))")
            onChange?()
            Task.detached(priority: .utility) {
                if let r = try? await Rclone.capture(["about", "\(Rclone.remote):", "--json"]), r.status != 0 {
                    AppLog.write("account: rclone about after sign-in failed: \(Rclone.tail(r.err))")
                }
            }
            return .connected(quota)
        }
    }

    /// Removes the Keychain item and the saved e-mail. Files, the queue and rclone.conf stay.
    /// Returns nil when signed out, else the text for the user: when the Keychain keeps the item
    /// (the user refused the system prompt), the account stays as it was, so no password is left
    /// behind that the app no longer knows about.
    @discardableResult
    func disconnect() async -> String? {
        if let email = state.email ?? UserDefaults.standard.string(forKey: Self.emailKey) {
            let service = Self.keychainService
            let status = await Task.detached(priority: .userInitiated) {
                Keychain.delete(service: service, account: email)
            }.value
            guard status == errSecSuccess || status == errSecItemNotFound else {
                AppLog.write("account: sign-out of \(Self.masked(email)) failed, keychain delete OSStatus \(status)")
                return KeychainNotice.isDenial(status)
                    ? "macOS не дал удалить пароль из связки ключей, поэтому выход отменён. Попробуйте ещё раз и разрешите доступ."
                    : "Не получилось удалить пароль из связки ключей (код \(status)), поэтому выход отменён."
            }
            AppLog.write("account: signed out \(Self.masked(email))")
        }
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        obscured = nil
        keychainNotice = nil
        state = .none
        applyEnvironment()
        onChange?()
        await refresh()
        return nil
    }

    /// The cloud answered 401/403 to rclone: the password is no longer accepted.
    func markAuthFailed() {
        let next: AccountState
        switch state {
        case .keychain(let e): next = .authFailed(email: e)
        case .legacyRemote: next = .authFailed(email: nil)
        default: return
        }
        state = next
        AppLog.write("account: the cloud no longer accepts the password")
        applyEnvironment()
        onChange?()
    }

    /// The cloud accepted the current credentials (a probe or «Проверить» got through): a known
    /// `.authFailed` is cleared, so one refusal never parks the queue for good.
    func cloudAccepted() {
        guard case .authFailed(let e) = state else { return }
        state = e.map { .keychain(email: $0) } ?? .legacyRemote
        AppLog.write("account: the cloud accepts the password again")
        applyEnvironment()
        onChange?()
    }

    /// «Проверить»: one listing of the cloud root through rclone with the current mode. Returns nil
    /// when it worked (an `.authFailed` state is cleared), else the text for the user.
    func recheck() async -> String? {
        if state == .none { await refresh() }
        guard state != .none else { return "Подключение к Облаку не настроено." }
        if keychainReadFailed {
            obscured = nil
            await decide()
            if keychainReadFailed { return "Не получилось прочитать пароль из связки ключей." }
        }
        do {
            let r = try await Rclone.capture(["lsjson", "--stat", "\(Rclone.remote):", "--contimeout", "5s",
                                              "--timeout", "15s", "--low-level-retries", "1", "--retries", "1"])
            if r.status == 0 {
                cloudAccepted()
                return nil
            }
            if Self.isAuthError(r.err) { markAuthFailed() }
            return Humanize.error(from: r.err)
        } catch {
            return error.localizedDescription
        }
    }

    /// rclone's stderr says the cloud refused the credentials (401/403), as opposed to the network.
    nonisolated static func isAuthError(_ stderr: String) -> Bool {
        let t = stderr.lowercased()
        if Humanize.isNetwork(t, listing: true) { return false }
        let pattern = "(?<![\\w./-])(401|403)(?![\\w./-])"
        return t.range(of: pattern, options: .regularExpression) != nil
            || t.contains("unauthorized") || t.contains("forbidden")
    }

    /// "ivan@mail.ru" -> "i***@mail.ru", for the log.
    nonisolated static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), let first = email.first, at != email.startIndex else { return "***" }
        return "\(first)***\(email[at...])"
    }
}

/// Generic-password items of the app in the login Keychain.
enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether the item exists, asked by its attributes only (does not need access to the secret).
    static func exists(service: String, account: String) -> Bool {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    enum ReadError: Error, CustomStringConvertible {
        case status(OSStatus)
        var description: String { if case .status(let s) = self { return "OSStatus \(s)" }; return "" }
    }

    /// The secret. May show the system's Keychain access prompt (blocks): call off the main thread.
    static func read(service: String, account: String) -> Result<String, ReadError> {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            return .failure(.status(status == errSecSuccess ? errSecDecode : status))
        }
        return .success(s)
    }

    /// Updates the item, or adds it when there is none.
    static func save(service: String, account: String, password: String, label: String) -> OSStatus {
        let data = Data(password.utf8)
        let q = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    static func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
