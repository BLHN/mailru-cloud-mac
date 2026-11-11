import SwiftUI

/// The button next to a setup problem (banner in «Передачи», menu bar popover).
enum SetupIssueAction {
    static func title(for issue: UploadManager.SetupIssue) -> String {
        switch issue {
        case .noRclone: return "Открыть страницу загрузки"
        case .notConnected: return "Подключить…"
        case .keychainLocked: return "Попробовать снова"
        case .authFailed(let legacy): return legacy ? "Открыть настройки" : "Войти заново…"
        }
    }
}

/// «Настройки» → «Аккаунт»: how the app reaches the cloud, check, change password, sign out.
struct AccountSection: View {
    @EnvironmentObject var nav: AppNavigation
    @ObservedObject private var account = Account.shared
    @State private var checking = false
    @State private var checkResult: String?
    @State private var confirmSignOut = false
    @State private var signOutError: String?

    var body: some View {
        Section("Аккаунт") {
            switch account.state {
            case .keychain(let email):
                keychainRows(email: email, failed: false)
            case .authFailed(.some(let email)):
                keychainRows(email: email, failed: true)
            case .legacyRemote, .authFailed(.none):
                legacyRows(failed: account.state != .legacyRemote)
            case .none:
                LabeledContent {
                    Button("Подключить…") { nav.signInPresented = true }
                } label: {
                    Text("Облако не подключено")
                    Text("Нужны почта Mail.ru и пароль для внешнего приложения.")
                }
            }
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut) {
            Button("Выйти", role: .destructive) {
                Task { signOutError = await account.disconnect() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Пароль удалится из связки ключей этого Мака. Файлы на Маке и в Облаке останутся на месте, загрузки подождут нового входа.")
        }
        .alert("Выйти не получилось", isPresented: Binding(get: { signOutError != nil },
                                                           set: { if !$0 { signOutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signOutError ?? "")
        }
    }

    @ViewBuilder private func keychainRows(email: String, failed: Bool) -> some View {
        LabeledContent("Почта") {
            Text(email).foregroundStyle(.secondary).textSelection(.enabled)
        }
        LabeledContent {
            HStack(spacing: 8) {
                if checking { ProgressView().controlSize(.small) }
                Button("Проверить", action: check).disabled(checking)
            }
        } label: {
            statusLabel(failed: failed)
            Text(account.keychainReadFailed
                 ? "Пароль не удалось прочитать из связки ключей"
                 : "Пароль: в связке ключей этого Мака")
        }
        HStack {
            Button("Сменить пароль…") { nav.signInPresented = true }
            Spacer()
            Button("Выйти из аккаунта…") { confirmSignOut = true }
        }
    }

    @ViewBuilder private func legacyRows(failed: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if checking { ProgressView().controlSize(.small) }
                Button("Проверить", action: check).disabled(checking)
            }
        } label: {
            statusLabel(failed: failed)
            Text("Через rclone, remote «mailru» из вашего rclone.conf. Приложение этот файл не читает и не меняет.")
        }
        LabeledContent {
            Button("Перейти на вход в приложении…") { nav.signInPresented = true }
        } label: {
            Text("Вход в приложении")
            Text("Пароль будет храниться в связке ключей, rclone.conf останется как есть.")
        }
    }

    private func statusLabel(failed: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(failed ? Color.orange : Color.green).frame(width: 7, height: 7)
            if let checkResult {
                Text(checkResult)
            } else {
                Text(failed ? "Облако не принимает пароль" : "Подключено")
            }
        }
    }

    private func check() {
        checking = true
        checkResult = nil
        Task {
            let problem = await account.recheck()
            checking = false
            checkResult = problem ?? "Подключено, Облако отвечает"
        }
    }
}

/// «Вход в Облако» as a sheet: screen 3 of the onboarding in compact form, for «Сменить пароль…»,
/// «Перейти на вход в приложении…» and a password the cloud no longer accepts. Same live check,
/// clipboard offer and problem texts; nothing is stored before Mail.ru has accepted the pair.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = Account.shared
    @StateObject private var form = SignInModel()

    static let passwordsPage = Onboarding.passwordsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Вход в Облако").font(.title2.weight(.semibold))
            Text("Нужны почта Mail.ru и пароль для внешнего приложения с доступом к Облаку. Обычный пароль от почты не подойдёт.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SignInFields(form: form, openPasswordsPage: openMailRu)
            HStack(spacing: 10) {
                Button("Где взять пароль", action: openMailRu)
                    .buttonStyle(.link)
                    .disabled(form.checking)
                Spacer()
                SignInButtons(form: form, backTitle: "Отмена") {
                    PasswordGuidePanel.shared.close()
                    dismiss()
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            if form.email.isEmpty {
                form.email = account.state.email ?? UserDefaults.standard.string(forKey: Account.emailKey) ?? ""
            }
            form.onConnected = { _ in
                PasswordGuidePanel.shared.close()
                dismiss()
            }
        }
        .onDisappear { form.cancel() }
    }

    /// Opens the passwords page and the floating guide; its buttons fill this sheet.
    private func openMailRu() {
        form.commitEmail()
        form.armClipboard()
        Onboarding.openPage(Self.passwordsPage)
        let back = { PasswordGuidePanel.shared.close(); AppDelegate.shared?.showWindow() }
        PasswordGuidePanel.shared.show(form: form, handlers: .init(
            created: back,
            pasteAndConnect: { back(); form.pasteFromClipboard() },
            phone: { Onboarding.openPage(Onboarding.contactsPage) },
            reopen: { Onboarding.openPage(Self.passwordsPage) }))
    }
}
