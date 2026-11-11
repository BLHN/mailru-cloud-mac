import AppKit
import Combine
import Network
import SwiftUI

// MARK: - Password heuristics

/// Local checks of what the user typed or copied. Nothing here is shown or logged.
enum PasswordHints {
    /// Mail.ru never puts whitespace into app passwords: all of it is dropped silently.
    static func normalized(_ raw: String) -> String { raw.filter { !$0.isWhitespace } }

    /// «Похоже на пароль приложения»: after dropping whitespace 16 to 32 characters, only Latin
    /// letters and digits, at least one of each. The exact format is not documented by Mail.ru, so
    /// this only decides whether to offer the clipboard; it never blocks a check.
    static func looksLikeAppPassword(_ raw: String) -> Bool {
        let s = normalized(raw)
        guard (16...32).contains(s.count) else { return false }
        var letter = false, digit = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x30...0x39: digit = true
            case 0x41...0x5A, 0x61...0x7A: letter = true
            default: return false
            }
        }
        return letter && digit
    }

    enum Warning: Equatable {
        case looksLikeMailPassword
        case isEmail
    }

    /// A soft hint under the password field (never blocks): Cyrillic, spaces inside or fewer than 12
    /// characters look like the ordinary mail password; the e-mail itself in the field.
    static func warning(password raw: String, email: String) -> Warning? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !e.isEmpty, trimmed.lowercased() == e { return .isEmail }
        let cyrillic = trimmed.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let innerSpace = trimmed.contains { $0.isWhitespace }
        if cyrillic || innerSpace || normalized(trimmed).count < 12 { return .looksLikeMailPassword }
        return nil
    }
}

// MARK: - Problems of the live check (texts 3.1 to 3.8 of the onboarding design)

enum SignInProblem: Equatable {
    /// 3.1. `again`: a second refusal in a row with another password.
    case wrongPassword(again: Bool)
    /// 3.2 (403 / 402, meaning assumed).
    case accessDenied
    /// 3.3
    case offline
    /// 3.4
    case notResponding
    /// 3.5
    case tls
    /// 3.6
    case server
    /// 3.7, the OSStatus goes to the log only. `denied`: the user refused the system prompt.
    case keychain(denied: Bool)
    /// 3.8
    case missingComponent
    /// Anything else (an unexpected HTTP answer, another URL error): the probe's own text.
    case other(String)

    init(_ failure: Account.ConnectFailure, again: Bool) {
        switch failure {
        case .input: self = .other(failure.message)
        case .noRclone, .obscure: self = .missingComponent
        case .keychain(let status): self = .keychain(denied: KeychainNotice.isDenial(status))
        case .probe(let f):
            switch f {
            case .wrongPassword: self = .wrongPassword(again: again)
            case .accessDenied: self = .accessDenied
            case .serverError: self = .server
            case .offline: self = .offline
            case .notResponding: self = .notResponding
            case .tls: self = .tls
            case .noWebDAV, .other: self = .other(f.message)
            }
        }
    }

    var symbol: String {
        switch self {
        case .wrongPassword: return "exclamationmark.triangle.fill"
        case .accessDenied: return "lock.fill"
        case .offline: return "wifi.slash"
        case .notResponding: return "icloud.slash"
        case .tls: return "exclamationmark.shield"
        case .server: return "exclamationmark.icloud"
        case .keychain: return "key.slash"
        case .missingComponent: return "shippingbox"
        case .other: return "exclamationmark.triangle.fill"
        }
    }

    /// Orange for what the user can fix, secondary for the network.
    var isQuiet: Bool {
        switch self {
        case .offline, .notResponding: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .wrongPassword: return "Mail.ru не принял пароль"
        case .accessDenied: return "Облако не пускает внешние приложения"
        case .offline: return "Нет интернета"
        case .notResponding: return "Облако не отвечает"
        case .tls: return "Сеть перехватывает соединение"
        case .server: return "У Облака Mail.ru временный сбой"
        case .keychain: return "Не получилось сохранить пароль"
        case .missingComponent: return "Не хватает части приложения"
        case .other: return "Не получилось проверить вход"
        }
    }

    var text: String {
        switch self {
        case .wrongPassword:
            return "Так бывает, если вставлен пароль от почты, а не пароль для приложения, или в адресе опечатка."
        case .accessDenied:
            return "Пароль подошёл, но Mail.ru не открыл доступ к Облаку для этого ящика. Возможно, на вашем тарифе это закрыто или у пароля нет доступа к Облаку."
        case .offline:
            return "Проверьте подключение. Как только сеть появится, проверка повторится сама."
        case .notResponding:
            return "Mail.ru сейчас недоступен или сеть что-то блокирует. Попробуйте через минуту."
        case .tls:
            return "Похоже, Wi-Fi требует вход (в кафе, в отеле) или мешает VPN. Откройте любой сайт в браузере и попробуйте снова."
        case .server:
            return "Сервер ответил ошибкой. Обычно это проходит за пару минут."
        case .keychain(let denied):
            return denied
                ? "macOS не дала записать пароль в связку ключей, потому что доступ не разрешили. Нажмите «Войти» ещё раз, введите пароль от Мака и выберите «Всегда разрешать»."
                : "macOS не дала записать пароль в связку ключей. Попробуйте ещё раз. Если не поможет, перезагрузите Мак."
        case .missingComponent:
            return "Внутри \(AppInfo.name) нет нужного компонента. Скачайте приложение заново."
        case .other(let t):
            return t
        }
    }

    /// Added under 3.1 on the second refusal in a row with another password.
    static let againText = "Если пароль точно новый, возможно, Mail.ru закрыл внешние приложения для вашего ящика. Так бывает у части новых ящиков без подписки Mail Space. Загляните на страницу паролей: если там предлагают подписку, приложение это не обойдёт."

    /// Which of the three marks failed: 0 «Связь с Облаком», 1 «Пароль», 2 «Место в Облаке».
    var failedMark: Int {
        switch self {
        case .offline, .notResponding, .tls, .server, .other: return 0
        case .wrongPassword: return 1
        case .accessDenied, .keychain, .missingComponent: return 2
        }
    }
}

// MARK: - The sign-in form (screen 3, also the sheet)

/// State of «Вход в Облако»: e-mail, app password, the clipboard offer and the live check with its
/// three marks. Used by the onboarding and by the compact sign-in sheet. The password lives only in
/// memory, and only until the check has finished.
@MainActor
final class SignInModel: ObservableObject {
    enum Mark: Equatable { case idle, running, ok, failed }

    enum ClipboardOffer: Equatable {
        case none
        /// Something new was copied that may be the password («Вставить пароль из буфера?»).
        case available
        /// The clipboard went into the field.
        case inserted
        /// The copied text does not look like an app password.
        case notPassword
    }

    @Published var email = ""
    @Published var password = ""
    /// The e-mail field lost focus without a full address.
    @Published var emailNeedsDomain = false
    @Published private(set) var marks: [Mark] = [.idle, .idle, .idle]
    @Published private(set) var checking = false
    @Published private(set) var problem: SignInProblem?
    /// Bumped on each new problem: the plaque's symbol shakes once.
    @Published private(set) var problemCount = 0
    @Published private(set) var succeeded = false
    @Published private(set) var quota: WebDAVProbe.Quota?
    @Published private(set) var clipboardOffer: ClipboardOffer = .none
    /// The pasted password was removed from the clipboard after a successful sign-in
    /// («Пароль убрали из буфера обмена»).
    @Published private(set) var clipboardCleared = false

    /// Called once the check passed and the 0.4 s pause after the marks is over.
    var onConnected: ((WebDAVProbe.Quota) -> Void)?

    /// The pasteboard to watch; a private one in the dev self-test.
    let pasteboard: NSPasteboard
    /// `changeCount` when «Открыть Mail.ru» was pressed; nil while not armed.
    private var clipboardBaseline: Int?
    /// `changeCount` at which the password was read by «Вставить» and a fingerprint of that
    /// password (in memory only): after a successful sign-in the clipboard is cleared only if it
    /// still holds exactly that copy and that password was the one used.
    private var pastedChangeCount: Int?
    private var pastedFingerprint: Int?
    private var checkTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Fingerprint of the last refused password (in memory, per launch), to tell "again with
    /// another password" from a plain retry.
    private var lastRefused: Int?

    #if CLOUDMAIL_DEV
    /// Dev `--dev-onboarding-error`: the check ends with this result instead of asking Mail.ru.
    var devForcedProblem: SignInProblem?
    #endif

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    static let domains = ["@mail.ru", "@bk.ru", "@inbox.ru", "@list.ru", "@internet.ru"]

    var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var emailValid: Bool {
        let e = normalizedEmail
        guard let at = e.firstIndex(of: "@"), at != e.startIndex else { return false }
        let domain = e[e.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !e.contains(" ")
    }

    var canConnect: Bool { emailValid && !PasswordHints.normalized(password).isEmpty && !checking }

    /// Domain chips while the part before "@" is typed (and those that match a started domain).
    var domainSuggestions: [String] {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, !e.hasPrefix("@") else { return [] }
        guard let at = e.firstIndex(of: "@") else { return Self.domains }
        let typed = String(e[at...]).lowercased()
        if Self.domains.contains(typed) { return [] }
        return Self.domains.filter { $0.hasPrefix(typed) }
    }

    func applyDomain(_ domain: String) {
        let local = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        email = local.trimmingCharacters(in: .whitespaces).lowercased() + domain
        emailNeedsDomain = false
    }

    /// Focus left the e-mail field: trim and lowercase silently, ask for the domain when missing.
    func commitEmail() {
        let e = normalizedEmail
        if e != email { email = e }
        emailNeedsDomain = !e.isEmpty && !e.contains("@")
    }

    var passwordWarning: PasswordHints.Warning? {
        problem == nil ? PasswordHints.warning(password: password, email: email) : nil
    }

    // MARK: Clipboard

    /// «Открыть Mail.ru»: remember the clipboard's change count. Its content is not read.
    func armClipboard() {
        clipboardBaseline = pasteboard.changeCount
        if clipboardOffer != .inserted { clipboardOffer = .none }
    }

    /// Something was copied since `armClipboard()` and it is text.
    var clipboardChanged: Bool {
        guard let base = clipboardBaseline else { return false }
        return pasteboard.changeCount != base && pasteboard.availableType(from: [.string]) != nil
    }

    /// Looks at the change count and the types only, plus the system's pattern detection (which
    /// does not hand the content to the app and does not trigger the paste prompt): a link, an
    /// e-mail address or a phone number is not an app password, so no offer then.
    func refreshClipboard() {
        guard clipboardOffer != .inserted, clipboardChanged else { return }
        guard clipboardOffer != .available else { return }
        let count = pasteboard.changeCount
        if #available(macOS 15.4, *) {
            let pb = pasteboard
            Task { @MainActor [weak self] in
                let found: Set<PartialKeyPath<NSPasteboard.DetectedValues>>
                do {
                    // Not `number`: it also matches mixed letters and digits, like an app password.
                    found = try await pb.detectedPatterns(for: [\.probableWebURL, \.links, \.emailAddresses,
                                                               \.phoneNumbers])
                } catch {
                    if AppPaths.isDev { AppLog.write("dev: clipboard pattern detection failed: \(error.localizedDescription)") }
                    found = []
                }
                if AppPaths.isDev { AppLog.write("dev: clipboard patterns found: \(found.count)") }
                guard let self, pb.changeCount == count, self.clipboardOffer == .none || self.clipboardOffer == .notPassword else { return }
                if found.isEmpty {
                    self.clipboardOffer = .available
                } else {
                    // Not the password: wait for the next copy.
                    self.clipboardBaseline = count
                }
            }
        } else {
            clipboardOffer = .available
        }
    }

    /// The user's click («Вставить», «Вставить и подключить»): reads the clipboard once. A string that
    /// looks like an app password goes into the field and the check starts; anything else leaves the
    /// field alone. The value is never shown or logged. Returns whether it was taken.
    @discardableResult
    func pasteFromClipboard(connectAfter: Bool = true) -> Bool {
        let text = pasteboard.string(forType: .string) ?? ""
        clipboardBaseline = pasteboard.changeCount
        guard PasswordHints.looksLikeAppPassword(text) else {
            clipboardOffer = .notPassword
            return false
        }
        password = PasswordHints.normalized(text)
        pastedChangeCount = clipboardBaseline
        pastedFingerprint = password.hashValue
        clipboardOffer = .inserted
        if connectAfter, canConnect { connect() }
        return true
    }

    // MARK: Live check

    func connect() {
        guard canConnect else { return }
        commitEmail()
        checkTask?.cancel()
        stopPathMonitor()
        problem = nil
        succeeded = false
        clipboardCleared = false
        checking = true
        withAnimation(.easeOut(duration: 0.15)) { marks = [.running, .running, .running] }
        let email = normalizedEmail
        let password = PasswordHints.normalized(self.password)
        let fingerprint = password.hashValue
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: Account.ConnectResult
            #if CLOUDMAIL_DEV
            if let forced = self.devForcedProblem {
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.finishForced(forced)
                return
            }
            #endif
            result = await Account.shared.connect(email: email, password: password) { [weak self] in
                self?.tick(0)
                self?.tick(1)
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .connected(let quota):
                await self.didConnect(quota: quota, fingerprint: fingerprint)
            case .failed(let failure):
                var again = false
                if case .probe(.wrongPassword) = failure {
                    again = self.lastRefused != nil && self.lastRefused != fingerprint
                    self.lastRefused = fingerprint
                }
                self.fail(SignInProblem(failure, again: again))
            }
        }
    }

    /// Mail.ru accepted the pair: forget the password, clear the clipboard if it still holds the
    /// pasted copy, show the third mark and move on after a short pause.
    private func didConnect(quota: WebDAVProbe.Quota, fingerprint: Int) async {
        lastRefused = nil
        password = ""
        self.quota = quota
        clipboardCleared = clearPastedPassword(fingerprint: fingerprint)
        tick(2)
        succeeded = true
        checking = false
        // A little longer when there is the clipboard line to read (the sheet closes after it).
        try? await Task.sleep(nanoseconds: clipboardCleared ? 1_200_000_000 : 400_000_000)
        onConnected?(quota)
    }

    /// Clears the clipboard when the password used for the sign-in came from «Вставить» and nothing
    /// was copied since (the change count is still the one at which it was read). The content is
    /// not read again. Returns whether it was cleared.
    private func clearPastedPassword(fingerprint: Int) -> Bool {
        defer { pastedChangeCount = nil; pastedFingerprint = nil }
        guard let count = pastedChangeCount, pastedFingerprint == fingerprint,
              pasteboard.changeCount == count else { return false }
        pasteboard.clearContents()
        AppLog.write("sign-in: the pasted password was removed from the clipboard")
        return true
    }

    /// «Отменить» while checking.
    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        checking = false
        withAnimation(.easeOut(duration: 0.15)) { marks = [.idle, .idle, .idle] }
    }

    /// A fresh form (the onboarding shown again after a sign-out). The e-mail stays.
    func reset() {
        checkTask?.cancel()
        checkTask = nil
        stopPathMonitor()
        checking = false
        succeeded = false
        problem = nil
        password = ""
        quota = nil
        clipboardBaseline = nil
        clipboardOffer = .none
        clipboardCleared = false
        pastedChangeCount = nil
        pastedFingerprint = nil
        marks = [.idle, .idle, .idle]
    }

    private func tick(_ i: Int) {
        guard marks.indices.contains(i) else { return }
        withAnimation(Motion.small) { marks[i] = .ok }
    }

    private func fail(_ p: SignInProblem) {
        checking = false
        var m: [Mark] = [.idle, .idle, .idle]
        for i in 0..<p.failedMark { m[i] = .ok }
        m[p.failedMark] = .failed
        withAnimation(Motion.small) { marks = m }
        problem = p
        problemCount += 1
        if p == .offline { startPathMonitor() }
    }

    #if CLOUDMAIL_DEV
    private func finishForced(_ p: SignInProblem) {
        fail(p)
    }

    /// Dev: show a problem right away (screenshots of 3.1 to 3.8).
    func devShow(_ p: SignInProblem) {
        fail(p)
        // Offline auto-retry must not fire for a staged plaque.
        stopPathMonitor()
    }

    /// Dev: the "checking" state for a screenshot (marks running, nothing asked).
    func devShowChecking(ticked: Int) {
        checking = true
        marks = (0..<3).map { $0 < ticked ? .ok : .running }
    }

    /// Dev: the success state with a made-up quota (screen 4 screenshots).
    func devSucceed(_ quota: WebDAVProbe.Quota) {
        self.quota = quota
        succeeded = true
        marks = [.ok, .ok, .ok]
    }

    /// Dev self-test: the success path of `connect()` without asking Mail.ru, with the password
    /// now in the field (the clipboard rule runs exactly as after a real sign-in).
    func devFinishConnected(_ quota: WebDAVProbe.Quota) async {
        await didConnect(quota: quota, fingerprint: PasswordHints.normalized(password).hashValue)
    }

    /// Dev self-test: the clipboard baseline as if «Открыть Mail.ru» was pressed earlier.
    var devClipboardArmed: Bool { clipboardBaseline != nil }
    #endif

    // 3.3: the check repeats by itself once the network is back.
    private func startPathMonitor() {
        stopPathMonitor()
        let m = NWPathMonitor()
        // The first update reports the current path; only a return of the network after it counts,
        // so a "no internet" answer while the path looks fine cannot loop.
        let seenDown = SeenFlag()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { seenDown.value = true; return }
            guard seenDown.value else { return }
            seenDown.value = false
            Task { @MainActor [weak self] in
                guard let self, self.problem == .offline, !self.checking else { return }
                AppLog.write("sign-in: network is back, checking again")
                self.connect()
            }
        }
        m.start(queue: .global(qos: .utility))
        pathMonitor = m
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}

/// Set and read on the path monitor's serial queue only.
private final class SeenFlag: @unchecked Sendable {
    var value = false
}

// MARK: - Onboarding flow

/// The first-run flow in the main window while no account is set up (`AccountState.none`):
/// 0 move to Applications (when needed), 1 welcome, 2 app password (with the floating guide 2A),
/// 2B phone, 3 sign-in with the live check, 4 done.
@MainActor
final class Onboarding: ObservableObject {
    enum Step: Int, Comparable {
        case move, welcome, password, phone, signIn, done
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        /// Index for the step dots «Пароль · Вход · Готово» (nil: no dots).
        var dot: Int? {
            switch self {
            case .move, .welcome: return nil
            case .password, .phone: return 0
            case .signIn: return 1
            case .done: return 2
            }
        }
    }

    @Published private(set) var isShown = false
    @Published private(set) var step: Step = .welcome
    /// Direction of the last step change (forward slides in from the trailing edge).
    @Published private(set) var forward = true
    /// Screen 0: the move is running / its error.
    @Published private(set) var moving = false
    @Published private(set) var moveError: AppMover.MoveError?
    /// Opened Mail.ru from screen 2 at least once (for the return to the app).
    private(set) var openedMailRu = false

    let form = SignInModel()
    private var cancellables: Set<AnyCancellable> = []
    private var wasConnected = false
    private var moveDismissed = false
    /// Dev `--dev-onboarding`: shown regardless of the account.
    private var devForced = false
    var demo = false

    static let passwordsPage = URL(string: "https://account.mail.ru/user/2-step-auth/passwords/")!
    static let contactsPage = URL(string: "https://id.mail.ru/contacts")!

    #if CLOUDMAIL_DEV
    /// Dev self-test: links are only logged, no browser comes up.
    static var devDryLinks = false
    static var devLastOpened: URL?
    #endif

    /// Opens a web page in the default browser and writes it to the log (so the dev log shows
    /// exactly which page a button opened).
    static func openPage(_ url: URL) {
        #if CLOUDMAIL_DEV
        if devDryLinks {
            devLastOpened = url
            AppLog.write("link: \(url.absoluteString) (dry run, not opened)")
            return
        }
        #endif
        AppLog.write("link: opening \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    init() {
        form.onConnected = { [weak self] _ in
            guard let self else { return }
            self.go(.done)
        }
    }

    /// Follows the account: shown while nothing is set up, hidden when a remote appears elsewhere.
    func bind(_ account: Account) {
        Publishers.CombineLatest(account.$state, account.$resolved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, resolved in self?.follow(state: state, resolved: resolved) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.appBecameActive() }
            .store(in: &cancellables)
    }

    private func follow(state: AccountState, resolved: Bool) {
        guard resolved, !demo, !devForced else { return }
        defer { if state.isConnected || state.email != nil { wasConnected = true } }
        if state == .none {
            guard !isShown else { return }
            // After a sign-out the welcome is skipped.
            let start: Step = AppMover.shouldOffer && !moveDismissed ? .move : (wasConnected ? .password : .welcome)
            step = start
            forward = true
            form.reset()
            if let e = UserDefaults.standard.string(forKey: Account.emailKey), form.email.isEmpty { form.email = e }
            withAnimation(.easeInOut(duration: 0.25)) { isShown = true }
            AppLog.write("onboarding: shown at \(start)")
        } else if isShown, step != .done, !form.checking, !form.succeeded {
            // A remote appeared in rclone.conf meanwhile, or the sheet signed in.
            withAnimation(.easeInOut(duration: 0.25)) { isShown = false }
            AppLog.write("onboarding: hidden, the account is set up elsewhere")
        }
    }

    func go(_ next: Step) {
        guard next != step else { return }
        forward = next > step || (step == .phone && next == .signIn)
        if step == .phone && next == .password { forward = false }
        if next == .signIn { form.refreshClipboard() }
        step = next
    }

    func back() {
        switch step {
        case .move, .welcome: break
        case .password: go(AppMover.shouldOffer && !moveDismissed ? .move : .welcome)
        case .phone, .signIn: go(.password)
        case .done: break
        }
    }

    // Screen 0

    func skipMove() {
        moveDismissed = true
        go(.welcome)
    }

    func moveToApplications() {
        moving = true
        moveError = nil
        Task { @MainActor in
            let result = await AppMover.move()
            moving = false
            switch result {
            case .success:
                AppLog.write("onboarding: moved, quitting this copy")
                NSApplication.shared.terminate(nil)
            case .failure(let e):
                moveError = e
            }
        }
    }

    // Screen 2

    /// «Открыть Mail.ru»: remembers the clipboard count, opens the passwords page in the default
    /// browser and shows the floating guide next to it.
    func openMailRu() {
        form.commitEmail()
        form.armClipboard()
        openedMailRu = true
        Onboarding.openPage(Self.passwordsPage)
        PasswordGuidePanel.shared.show(form: form, handlers: guideHandlers)
    }

    var guideHandlers: PasswordGuidePanel.Handlers {
        PasswordGuidePanel.Handlers(
            created: { [weak self] in
                self?.returnToApp()
                self?.go(.signIn)
            },
            pasteAndConnect: { [weak self] in
                guard let self else { return }
                self.returnToApp()
                self.go(.signIn)
                self.form.pasteFromClipboard()
            },
            phone: { [weak self] in
                self?.returnToApp()
                self?.go(.phone)
            },
            reopen: { Onboarding.openPage(Onboarding.passwordsPage) })
    }

    /// Back from the browser: when something was copied, straight to screen 3 with the offer.
    private func appBecameActive() {
        PasswordGuidePanel.shared.close()
        guard isShown else { return }
        if step == .password, openedMailRu, form.clipboardChanged {
            go(.signIn)
        }
        if step == .signIn { form.refreshClipboard() }
    }

    private func returnToApp() {
        PasswordGuidePanel.shared.close()
        AppDelegate.shared?.showWindow()
    }

    // Screen 4

    /// «Открыть Облако» / «Начать загрузку».
    func finish(nav: AppNavigation, startTransfers: Bool) {
        nav.section = startTransfers ? .transfers : .cloud
        withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
        form.password = ""
        AppLog.write("onboarding: finished")
    }

    #if CLOUDMAIL_DEV
    /// Dev `--dev-onboarding <step>` and `--dev-onboarding-error <code>`: shows a screen as it is
    /// for screenshots. Nothing is sent anywhere; the e-mail is an example.
    func devForce(step name: String, problem: String?) {
        devForced = true
        let steps: [String: Step] = ["move": .move, "welcome": .welcome, "password": .password,
                                     "phone": .phone, "signin": .signIn, "done": .done]
        step = steps[name] ?? .welcome
        if step >= .signIn || step == .password { form.email = "ivan@mail.ru" }
        if let problem {
            step = .signIn
            form.password = String(repeating: "x", count: 20)
            switch problem {
            case "checking": form.devShowChecking(ticked: 1)
            case "clipboard":
                form.password = ""
                form.devOfferClipboard()
            case "warning": form.password = "почта123"
            default:
                if let p = Self.devProblems[problem] { form.devShow(p) }
                form.devForcedProblem = Self.devProblems[problem]
            }
        }
        if step == .done {
            form.devSucceed(.init(available: 612_000_000_000, used: 388_000_000_000))
        }
        if name == "move-error" {
            step = .move
            moveError = .noAccess
        }
        isShown = true
    }

    static let devProblems: [String: SignInProblem] = [
        "3.1": .wrongPassword(again: false), "3.1b": .wrongPassword(again: true), "3.2": .accessDenied,
        "3.3": .offline, "3.4": .notResponding, "3.5": .tls, "3.6": .server, "3.7": .keychain(denied: false), "3.7b": .keychain(denied: true),
        "3.8": .missingComponent]
    #endif
}

#if CLOUDMAIL_DEV
extension SignInModel {
    /// Dev: the clipboard offer as if a password-like text was copied (nothing is read).
    func devOfferClipboard() { clipboardOffer = .available }
}
#endif
