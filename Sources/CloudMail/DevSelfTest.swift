#if CLOUDMAIL_DEV
import AppKit
import Security

/// `--dev-selftest` (dev build only): checks the account plumbing without a real account and logs
/// one line per check, never a secret. Uses only invented credentials, which Mail.ru must refuse,
/// and a Keychain item of the dev service that is removed again. Quits when done.
enum DevSelfTest {
    @MainActor
    static func run() async {
        var failures = 0
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            AppLog.write("selftest \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        AppLog.write("selftest: rclone \(Rclone.binary ?? "missing")")

        // 1. stdin as data: `rclone obscure -` of "abc" is base64 of 16 + 3 bytes = 26 characters
        //    (23 would mean the "-" itself was obscured).
        let ob = await Rclone.obscure("abc")
        report("obscure via stdin", ob?.count == 26, "length \(ob?.count ?? -1)")

        // 2. environment as data, with a precomposed Cyrillic value kept byte for byte.
        let value = "Съёмка"
        let p = ChildProcess(executable: "/usr/bin/printenv", arguments: ["CLOUDMAIL_SELFTEST"],
                             environment: ["CLOUDMAIL_SELFTEST": value], stdout: .pipe, stderr: .null)
        try? p.run()
        let out = p.stdoutHandle?.readDataToEndOfFile() ?? Data()
        p.waitUntilExit()
        let got = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
        report("environment passed", Array(got.utf8) == Array(value.utf8))

        // 3. Direct PROPFIND with invented credentials: Mail.ru refuses them (403 "Wrong credentials").
        let fakeEmail = "selftest-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let fakePassword = randomSecret()
        let probe = await WebDAVProbe.check(email: fakeEmail, password: fakePassword)
        report("webdav probe refuses invented credentials", probe == .failed(.wrongPassword), "\(probe)")
        // A redirect is the final answer, never followed to a 2xx elsewhere. Needs a local server
        // that answers 302 to another URL of its own that answers 207 (CLOUDMAIL_SELFTEST_REDIRECT).
        if let s = ProcessInfo.processInfo.environment["CLOUDMAIL_SELFTEST_REDIRECT"], let url = URL(string: s) {
            let redirected = await WebDAVProbe.check(email: fakeEmail, password: fakePassword, endpoint: url)
            report("webdav probe does not follow redirects", redirected == .failed(.noWebDAV(302)), "\(redirected)")
        }
        report("401 text", WebDAVProbe.Failure.wrongPassword.message.contains("не принял пароль"))
        report("status mapping", WebDAVProbe.outcome(status: 403, body: Data()) == .failed(.accessDenied(403))
               && WebDAVProbe.outcome(status: 503, body: Data()) == .failed(.serverError(503))
               && WebDAVProbe.outcome(status: 405, body: Data()) == .failed(.noWebDAV(405))
               && WebDAVProbe.outcome(status: 403, body: Data("Wrong credentials".utf8)) == .failed(.wrongPassword)
               && WebDAVProbe.outcome(status: 401, body: Data()) == .failed(.wrongPassword))
        let q = WebDAVProbe.quota(in: Data("<d:multistatus xmlns:d=\"DAV:\"><d:response><d:propstat><d:prop><d:quota-available-bytes>612000000000</d:quota-available-bytes><d:quota-used-bytes>388000000000</d:quota-used-bytes></d:prop></d:propstat></d:response></d:multistatus>".utf8))
        report("quota parsing", q.available == 612_000_000_000 && q.used == 388_000_000_000)

        // 4. rclone through the environment only (RCLONE_CONFIG=/dev/null) with invented
        //    credentials: the remote resolves, the cloud refuses (401), no config file warning.
        if let fakeObscured = await Rclone.obscure(fakePassword) {
            let env = Account.environment(email: fakeEmail, obscured: fakeObscured)
            let r = try? await Rclone.capture(["lsf", "--max-depth", "1", "--low-level-retries", "1", "--retries", "1",
                                               "--contimeout", "10s", "--timeout", "20s", "\(Rclone.remote):"],
                                              environment: .some(env))
            let err = r?.err ?? ""
            report("rclone env remote refused as auth error", r?.status != 0 && Account.isAuthError(err),
                   "exit \(r?.status ?? -1)")
            report("no config file notice", !err.lowercased().contains("config file") , "")
            report("env holds no raw password", !env.values.contains(fakePassword))
        } else {
            report("rclone env remote", false, "obscure failed")
        }

        // 5. Account.connect with invented credentials fails and stores nothing.
        let before = Account.shared.state
        let result = await Account.shared.connect(email: fakeEmail, password: fakePassword)
        report("connect refuses invented credentials", result == .failed(.probe(.wrongPassword)))
        report("connect stored nothing", !Keychain.exists(service: Account.keychainService, account: fakeEmail)
               && UserDefaults.standard.string(forKey: Account.emailKey) != fakeEmail && Account.shared.state == before)

        // 6. Keychain round trip under the dev service, removed again.
        let service = Account.keychainService
        report("keychain service is the dev one", service.hasSuffix(".dev"), service)
        if service.hasSuffix(".dev") {
            let saved = Keychain.save(service: service, account: fakeEmail, password: fakePassword, label: "\(AppInfo.name) selftest")
            let exists = Keychain.exists(service: service, account: fakeEmail)
            let read = Keychain.read(service: service, account: fakeEmail)
            var readOK = false
            if case .success(let s) = read { readOK = s == fakePassword }
            let updated = Keychain.save(service: service, account: fakeEmail, password: fakePassword + "x", label: "\(AppInfo.name) selftest")
            let deleted = Keychain.delete(service: service, account: fakeEmail)
            let gone = !Keychain.exists(service: service, account: fakeEmail)
            report("keychain add/read/update/delete", saved == errSecSuccess && exists && readOK
                   && updated == errSecSuccess && deleted == errSecSuccess && gone)
        }

        // 8. Keychain mode end to end with invented credentials stored under the dev service: the
        //    account resolves to `.keychain`, the cloud refuses them, the state turns `.authFailed`
        //    and the queue waits for sign-in; signing out removes the item and the saved e-mail.
        if service.hasSuffix(".dev"), UserDefaults.standard.string(forKey: Account.emailKey) == nil {
            let manager = AppDelegate.shared?.manager
            _ = Keychain.save(service: service, account: fakeEmail, password: fakePassword, label: "\(AppInfo.name) selftest")
            UserDefaults.standard.set(fakeEmail, forKey: Account.emailKey)
            await Account.shared.refresh()
            report("keychain mode resolves", Account.shared.state == .keychain(email: fakeEmail) && !Account.shared.keychainReadFailed)
            let env = Rclone.environment ?? [:]
            report("keychain env set", env["RCLONE_CONFIG"] == "/dev/null" && env["RCLONE_CONFIG_MAILRU_USER"] == fakeEmail
                   && (env["RCLONE_CONFIG_MAILRU_PASS"]?.count ?? 0) == Int(ceil(Double(16 + fakePassword.utf8.count) * 4 / 3))
                   && !env.values.contains(fakePassword))
            // A refused probe is asked again after a pause before the account is marked; a
            // probe (or check) that gets through clears the mark again.
            if let manager {
                let t0 = Date()
                let probe = await manager.devProbeResult()
                let took = Date().timeIntervalSince(t0)
                report("probe marks authFailed only after a second refusal", probe == .auth
                       && took >= UploadManager.authConfirmDelay && Account.shared.state == .authFailed(email: fakeEmail),
                       String(format: "%@ after %.1f s", "\(probe)", took))
                Account.shared.cloudAccepted()
                report("accepted password clears authFailed", Account.shared.state == .keychain(email: fakeEmail)
                       && manager.setupIssue == nil, "\(String(describing: manager.setupIssue))")
            }
            let problem = await Account.shared.recheck()
            report("refused password turns authFailed", Account.shared.state == .authFailed(email: fakeEmail), problem ?? "nil")
            report("app delegate reachable", manager != nil)
            report("queue waits for sign-in", manager?.setupIssue == .authFailed(legacy: false) && manager?.rcloneReady == false,
                   "\(String(describing: manager?.setupIssue))")
            let signOut = await Account.shared.disconnect()
            report("sign-out reports success", signOut == nil, signOut ?? "")
            report("sign-out removes item and e-mail", !Keychain.exists(service: service, account: fakeEmail)
                   && UserDefaults.standard.string(forKey: Account.emailKey) == nil)
            report("after sign-out back to rclone.conf or none", Account.shared.state == .legacyRemote || Account.shared.state == .none)
            report("environment back to the app's own", Rclone.environment == nil)
            report("queue follows", manager?.setupIssue == nil || manager?.setupIssue == .notConnected)
            if Account.shared.state == .none, let ob = AppDelegate.shared?.onboarding {
                // Without a remote in rclone.conf (run with RCLONE_CONFIG=/dev/null): the window
                // turns into the onboarding, at the password step since an account was there.
                try? await Task.sleep(nanoseconds: 300_000_000)
                report("sign-out shows the onboarding at «Пароль»", ob.isShown && ob.step == .password,
                       "shown \(ob.isShown) step \(ob.step)")
            }
        } else {
            report("keychain mode end to end", false, "skipped: dev account already set")
        }

        // Links: the guide's «Открыть страницу снова» opens the app passwords page (logged, dry).
        if let ob = AppDelegate.shared?.onboarding {
            Onboarding.devDryLinks = true
            ob.guideHandlers.reopen()
            Onboarding.devDryLinks = false
            report("guide reopens the app passwords page",
                   Onboarding.devLastOpened?.absoluteString == "https://account.mail.ru/user/2-step-auth/passwords/",
                   Onboarding.devLastOpened?.absoluteString ?? "nil")
        }

        // 8. Onboarding: password hints, move check, problem texts, clipboard offer, live check.
        await onboardingChecks(report: report, fakeEmail: fakeEmail)

        // 7. Masking and auth classification.
        report("email mask", Account.masked("ivan@mail.ru") == "i***@mail.ru")
        report("auth vs network", Account.isAuthError("ERROR : : error listing: 401 Unauthorized")
               && !Account.isAuthError("dial tcp: lookup webdav.cloud.mail.ru: no such host")
               && !Account.isAuthError("IMG_4031.MOV: copy failed: i/o timeout"))

        let mode: String
        switch Account.shared.state {
        case .none: mode = "none"
        case .keychain: mode = "keychain"
        case .legacyRemote: mode = "legacyRemote"
        case .authFailed: mode = "authFailed"
        }
        AppLog.write("selftest done: \(failures == 0 ? "all passed" : "\(failures) failed"), account mode \(mode)")
    }

    @MainActor
    private static func onboardingChecks(report: (String, Bool, String) -> Void, fakeEmail: String) async {
        func wait(_ seconds: Double, until done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        let H = PasswordHints.self
        report("app password heuristic",
               H.looksLikeAppPassword("aB3dEfGh1JkLmN0p") && H.looksLikeAppPassword(" aB3d EfGh 1JkL mN0p\n")
               && !H.looksLikeAppPassword("abcdefghijklmnop") && !H.looksLikeAppPassword("1234567890123456")
               && !H.looksLikeAppPassword("Пароль1234567890ab") && !H.looksLikeAppPassword("ab12")
               && !H.looksLikeAppPassword(String(repeating: "a1", count: 17)), "")
        report("soft password warnings",
               H.warning(password: "почта123", email: "") == .looksLikeMailPassword
               && H.warning(password: "short1", email: "") == .looksLikeMailPassword
               && H.warning(password: "my mail pass 2020", email: "") == .looksLikeMailPassword
               && H.warning(password: "Ivan@mail.ru", email: "ivan@mail.ru") == .isEmail
               && H.warning(password: "aB3dEfGh1JkLmN0p", email: "ivan@mail.ru") == nil, "")  // invented, gitleaks:allow
        let home = "/var/home/someone"
        report("move to Applications check",
               !AppMover.needsMove(path: "/Applications/Облачко.app", home: home)
               && !AppMover.needsMove(path: "/var/home/someone/Applications/Облачко.app", home: home)
               && AppMover.needsMove(path: "/var/home/someone/Downloads/Облачко.app", home: home)
               && AppMover.needsMove(path: "/private/var/folders/x/AppTranslocation/ABC/d/Облачко.app", home: home)
               && AppMover.needsMove(path: "/Volumes/Облачко/Облачко.app", home: home)
               && AppMover.needsMove(path: "/Applications Old/Облачко.app", home: home), "")
        report("dev bundle is not offered the move", !AppMover.shouldOffer, "")
        // Problem texts: every plaque has a title and a text, no long dash, no exclamation mark.
        let all = Array(Onboarding.devProblems.values) + [.other("x")]
        report("problem texts", all.allSatisfy { !$0.title.isEmpty && !$0.text.isEmpty
            && !($0.title + $0.text + SignInProblem.againText).contains("\u{2014}")
            && !($0.title + $0.text).contains("!") }, "")
        report("problem mapping",
               SignInProblem(.probe(.wrongPassword), again: false).failedMark == 1
               && SignInProblem(.probe(.accessDenied(403)), again: false) == .accessDenied
               && SignInProblem(.probe(.offline), again: false) == .offline
               && SignInProblem(.probe(.notResponding), again: false) == .notResponding
               && SignInProblem(.probe(.tls), again: false) == .tls
               && SignInProblem(.probe(.serverError(502)), again: false) == .server
               && SignInProblem(.keychain(-25299), again: false) == .keychain(denied: false)
               && SignInProblem(.keychain(errSecUserCanceled), again: false) == .keychain(denied: true)
               && SignInProblem(.noRclone, again: false) == .missingComponent
               && SignInProblem(.obscure, again: false) == .missingComponent, "")
        report("keychain notice: denial statuses", KeychainNotice.isDenial(errSecUserCanceled)
               && KeychainNotice.isDenial(errSecAuthFailed) && KeychainNotice.isDenial(errSecInteractionNotAllowed)
               && !KeychainNotice.isDenial(errSecItemNotFound), "")
        report("keychain notice: dev build is ad-hoc and never waits", KeychainNotice.isAdHocSigned
               && !KeychainNotice.shouldExplainBeforeRead, "")
        if #available(macOS 15.4, *) {
            AppLog.write("selftest: general pasteboard access behavior \(NSPasteboard.general.accessBehavior.rawValue)")
        }

        // Clipboard offer on a private pasteboard (the user's clipboard is never touched).
        let pb = NSPasteboard(name: NSPasteboard.Name("ru.blhn.cloudmail.dev.selftest"))
        pb.clearContents()
        let form = SignInModel(pasteboard: pb)
        form.email = fakeEmail
        form.refreshClipboard()
        report("clipboard: nothing offered before «Открыть Mail.ru»", form.clipboardOffer == .none, "")
        form.armClipboard()
        report("clipboard: armed, unchanged", !form.clipboardChanged, "")
        let copied = randomSecret() + "7a"
        pb.clearContents()
        pb.setString(copied, forType: .string)
        form.refreshClipboard()
        await wait(3) { form.clipboardOffer != .none }
        report("clipboard: a copied app password is offered", form.clipboardOffer == .available, "\(form.clipboardOffer)")
        let taken = form.pasteFromClipboard(connectAfter: false)
        report("clipboard: pasted into the field", taken && form.clipboardOffer == .inserted && form.password == copied, "")
        // Simulated success with the pasted password: the clipboard copy is cleared.
        let fakeQuota = WebDAVProbe.Quota(available: 1 << 30, used: 1 << 29)
        await form.devFinishConnected(fakeQuota)
        report("clipboard: cleared after sign-in with the pasted password",
               form.clipboardCleared && pb.string(forType: .string) == nil && form.password.isEmpty, "")

        // Something copied after the paste stays.
        let formLater = SignInModel(pasteboard: pb)
        formLater.email = fakeEmail
        formLater.armClipboard()
        pb.clearContents()
        pb.setString(randomSecret() + "7a", forType: .string)
        let takenLater = formLater.pasteFromClipboard(connectAfter: false)
        let later = "copied later " + randomSecret()
        pb.clearContents()
        pb.setString(later, forType: .string)
        await formLater.devFinishConnected(fakeQuota)
        report("clipboard: a later copy is kept", takenLater && !formLater.clipboardCleared
               && pb.string(forType: .string) == later, "")

        // Another password typed over the pasted one: the clipboard is left alone.
        let formTyped = SignInModel(pasteboard: pb)
        formTyped.email = fakeEmail
        formTyped.armClipboard()
        let pastedTyped = randomSecret() + "7a"
        pb.clearContents()
        pb.setString(pastedTyped, forType: .string)
        let takenTyped = formTyped.pasteFromClipboard(connectAfter: false)
        formTyped.password = randomSecret()
        await formTyped.devFinishConnected(fakeQuota)
        report("clipboard: kept when another password was used", takenTyped && !formTyped.clipboardCleared
               && pb.string(forType: .string) == pastedTyped, "")

        let formURL = SignInModel(pasteboard: pb)
        formURL.armClipboard()
        pb.clearContents()
        pb.setString("https://example.com/some/page", forType: .string)
        formURL.refreshClipboard()
        await wait(1.5) { formURL.clipboardOffer != .none }
        report("clipboard: a link is not offered", formURL.clipboardOffer == .none, "\(formURL.clipboardOffer)")

        let formText = SignInModel(pasteboard: pb)
        formText.armClipboard()
        pb.clearContents()
        pb.setString("hello there", forType: .string)
        formText.refreshClipboard()
        await wait(3) { formText.clipboardOffer != .none }
        let tookText = formText.pasteFromClipboard(connectAfter: false)
        report("clipboard: other text is refused on paste", !tookText && formText.clipboardOffer == .notPassword
               && formText.password.isEmpty, "\(formText.clipboardOffer)")
        pb.releaseGlobally()

        // Live check of the form with invented credentials: refused at the second mark, the
        // second refusal with another password adds the "closed for outside apps" paragraph.
        let live = SignInModel(pasteboard: pb)
        live.email = fakeEmail
        live.password = randomSecret()
        live.connect()
        await wait(25) { !live.checking }
        report("form: refused at «Пароль»", live.problem == .wrongPassword(again: false)
               && live.marks == [.ok, .failed, .idle], "\(String(describing: live.problem)) \(live.marks)")
        live.password = randomSecret()
        live.connect()
        await wait(25) { !live.checking }
        report("form: second refusal with another password", live.problem == .wrongPassword(again: true), "")
        report("form: nothing stored", !Keychain.exists(service: Account.keychainService, account: fakeEmail), "")
        live.devForcedProblem = .keychain(denied: false)
        live.connect()
        await wait(5) { !live.checking }
        report("form: forced 3.7 fails at the third mark", live.problem == .keychain(denied: false)
               && live.marks == [.ok, .ok, .failed], "")
        live.devForcedProblem = nil
        live.password = randomSecret()
        live.connect()
        try? await Task.sleep(nanoseconds: 50_000_000)
        live.cancel()
        report("form: cancel stops the check", !live.checking && live.marks == [.idle, .idle, .idle] && live.problem == nil, "")
    }

    /// 24 random letters and digits: an invented password nobody has.
    private static func randomSecret() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<24).map { _ in chars.randomElement()! })
    }
}
#endif
