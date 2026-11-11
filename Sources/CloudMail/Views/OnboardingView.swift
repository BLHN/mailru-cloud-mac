import SwiftUI
import UserNotifications

/// The first run in the main window, instead of the sidebar layout, while no account is set up.
/// Content column 520 pt; steps slide in from the trailing edge (back: from the leading edge) in
/// 0.25 s, cross-fade with reduce motion.
struct OnboardingView: View {
    @EnvironmentObject var onboarding: Onboarding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // The dots keep their row on every screen, so the content does not jump.
            ZStack(alignment: .leading) {
                if let dot = onboarding.step.dot {
                    StepDots(current: dot)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(.leading, 22)
            .padding(.top, 4)
            ZStack {
                page
                    .id(onboarding.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.25), value: onboarding.step)
        .navigationTitle(AppInfo.name)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let fwd = onboarding.forward
        return .asymmetric(insertion: .move(edge: fwd ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: fwd ? .leading : .trailing).combined(with: .opacity))
    }

    @ViewBuilder private var page: some View {
        switch onboarding.step {
        case .move: MoveStep()
        case .welcome: WelcomeStep()
        case .password: PasswordStep(form: onboarding.form)
        case .phone: PhoneStep()
        case .signIn: SignInStep(form: onboarding.form)
        case .done: DoneStep(form: onboarding.form)
        }
    }
}

// MARK: - Layout pieces

/// «Пароль · Вход · Готово», the current one filled with the accent.
private struct StepDots: View {
    let current: Int
    private let names = ["Пароль", "Вход", "Готово"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(names.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    Circle()
                        .fill(i == current ? AnyShapeStyle(Color.appTint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                    Text(names[i])
                        .font(.caption)
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шаг \(current + 1) из 3: \(names[current])")
    }
}

/// One onboarding screen: symbol, title, text and the screen's own content in a 520 pt column,
/// centered vertically (scrolls when the window is short); the buttons at the bottom right.
struct OnboardingPage<Symbol: View, Content: View, Leading: View, Buttons: View>: View {
    var title: String
    var text: String?
    /// Bumped when something new appears at the end of the content (a problem plaque): the column
    /// scrolls down to it when the window is short.
    var scrollTrigger = 0
    @ViewBuilder var symbol: Symbol
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        symbol
                            .padding(.bottom, 12)
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let text {
                            Text(text)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                        }
                        content
                            .padding(.top, 16)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(width: 520, alignment: .leading)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: g.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: scrollTrigger) { _, _ in
                    // After the plaque's fade-in has laid it out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .onAppear {
                    if scrollTrigger > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                }
            }
            HStack(spacing: 10) {
                leading
                Spacer(minLength: 12)
                buttons
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }
}

/// The large SF Symbol on top of a screen (56 pt, hierarchical, accent).
private struct PageSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 56, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.appTint)
            .frame(height: 64, alignment: .leading)
            .accessibilityHidden(true)
    }
}

// MARK: - Screen 0: move to Applications

private struct MoveStep: View {
    @EnvironmentObject var onboarding: Onboarding

    private var fromDownloads: Bool {
        let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads") + "/"
        return AppMover.originalURL.path.hasPrefix(downloads)
    }

    var body: some View {
        OnboardingPage(title: "Перенесём приложение в Программы",
                       text: (fromDownloads ? "Сейчас \(AppInfo.name) запущено из Загрузок." : "Сейчас \(AppInfo.name) запущено не из папки «Программы».")
                           + " Так macOS не даст ему запускаться при входе и показывать пункт в меню Finder. Нажмите кнопку, и приложение само переедет в Программы и откроется заново.") {
            PageSymbol(name: "folder.badge.plus")
        } content: {
            if let e = onboarding.moveError {
                ProblemPlaque(symbol: "exclamationmark.triangle.fill", quiet: false, title: nil,
                              text: Self.text(for: e), trigger: 1) {
                    if e != .devRefused {
                        Button("Показать в Finder") { AppMover.revealOriginal() }
                    }
                }
            }
        } leading: {
            EmptyView()
        } buttons: {
            Button("Не сейчас") { onboarding.skipMove() }
                .disabled(onboarding.moving)
            Button {
                onboarding.moveToApplications()
            } label: {
                HStack(spacing: 6) {
                    if onboarding.moving { ProgressView().controlSize(.small) }
                    Text("Перенести и открыть")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(onboarding.moving)
        }
    }

    static func text(for e: AppMover.MoveError) -> String {
        switch e {
        case .noAccess:
            return "Перенести не вышло: нет доступа к папке Программы. Перетащите \(AppInfo.name) в Программы вручную в Finder и откройте его оттуда."
        case .destinationRunning:
            return "Перенести не вышло: из Программ уже запущена другая копия \(AppInfo.name). Закройте её и нажмите кнопку ещё раз."
        case .launchFailed:
            return "Копия в Программах не открылась. Откройте её вручную в Finder."
        case .devRefused:
            return "Это сборка для разработки, в Программы она не переносится."
        }
    }
}

// MARK: - Screen 1: welcome

private struct WelcomeStep: View {
    @EnvironmentObject var onboarding: Onboarding

    var body: some View {
        OnboardingPage(title: "Облако Mail.ru на вашем Маке",
                       text: "Перетаскивайте файлы в окно, и они улетят в Облако. Скачивайте папки обратно, освобождайте место на диске. Подключение займёт пару минут.") {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                feature("icloud.and.arrow.up", "Загрузка перетаскиванием, даже если файлы большие")
                feature("arrow.down.circle", "Просмотр Облака и скачивание на Мак")
                feature("lock", "Пароль хранится только в связке ключей этого Мака")
            }
            HStack(spacing: 4) {
                Text("Неофициальное приложение. Не связано с VK и Mail.ru.")
                    .foregroundStyle(.tertiary)
                Link("Подробнее", destination: AppInfo.readmePage)
            }
            .font(.footnote)
            .padding(.top, 28)
        } leading: {
            EmptyView()
        } buttons: {
            Button("Подключить Облако") { onboarding.go(.password) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.appTint).frame(width: 22)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Screen 2: app password

private struct PasswordStep: View {
    @EnvironmentObject var onboarding: Onboarding
    @ObservedObject var form: SignInModel
    @FocusState private var emailFocused: Bool

    var body: some View {
        OnboardingPage(title: "Нужен пароль для приложения",
                       text: "Mail.ru не пускает сторонние программы по обычному паролю от почты. Для них есть отдельные пароли, которые создаются за минуту в настройках почты. Обычный пароль останется в секрете.") {
            PageSymbol(name: "key.horizontal")
        } content: {
            EmailField(form: form, focused: $emailFocused, label: "Ваша почта Mail.ru") {
                if form.emailValid { onboarding.openMailRu() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Что сделать на Mail.ru")
                    .font(.headline)
                    .padding(.bottom, 2)
                GuideStep(number: 1) { Text("Нажмите «Создать».") }
                GuideStep(number: 2) { Text("Введите любое название, например «Мой Мак», и нажмите «Продолжить».") }
                GuideStep(number: 3) { Text("Выберите «Полный доступ к Облаку» и нажмите «Продолжить».") }
                GuideStep(number: 4) { Text("Нажмите «Скопировать». Пароль покажут один раз, поэтому скопируйте его сразу.") }
                GuideStep(number: 5) { Text("Вернитесь сюда, остальное приложение сделает само.") }
                Text("Подойдёт и «Полный доступ к Почте, Облаку, Календарю», но приложению нужен только доступ к Облаку.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(.top, 18)
        } leading: {
            HStack(spacing: 16) {
                Button("У меня уже есть пароль") {
                    form.commitEmail()
                    onboarding.go(.signIn)
                }
                Button("Mail.ru просит телефон?") { onboarding.go(.phone) }
            }
            .buttonStyle(.link)
            .controlSize(.regular)
        } buttons: {
            Button("Назад") { onboarding.back() }
            Button("Открыть Mail.ru") { onboarding.openMailRu() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.emailValid)
        }
        .onAppear { if form.email.isEmpty { emailFocused = true } }
    }
}

// MARK: - Screen 2B: phone

private struct PhoneStep: View {
    @EnvironmentObject var onboarding: Onboarding

    var body: some View {
        OnboardingPage(title: "Сначала привяжите телефон",
                       text: "Mail.ru даёт создавать пароли для приложений только ящикам с привязанным номером телефона. Двухфакторную защиту включать не обязательно, достаточно номера.") {
            PageSymbol(name: "iphone")
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Иногда Mail.ru предлагает подписку Mail Space вместо создания пароля. Это правило самого Mail.ru для части ящиков, и обойти его приложение не может.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Link("Почему так", destination: AppInfo.readmePage)
                .font(.footnote)
                .padding(.top, 4)
        } leading: {
            EmptyView()
        } buttons: {
            Button("Готово, назад к паролю") { onboarding.go(.password) }
            Button("Открыть «Контакты и адреса»") { Onboarding.openPage(Onboarding.contactsPage) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Screen 3: sign-in with the live check

private struct SignInStep: View {
    @EnvironmentObject var onboarding: Onboarding
    @ObservedObject var form: SignInModel

    var body: some View {
        OnboardingPage(title: "Вход в Облако", text: nil, scrollTrigger: form.problemCount) {
            PageSymbol(name: "person.badge.key")
        } content: {
            SignInFields(form: form, openPasswordsPage: { onboarding.openMailRu() })
        } leading: {
            Button("Где взять пароль") { onboarding.go(.password) }
                .buttonStyle(.link)
                .controlSize(.regular)
                .disabled(form.checking)
        } buttons: {
            SignInButtons(form: form, backTitle: "Назад") { onboarding.back() }
        }
    }
}

/// «Назад» / «Отменить» and «Подключить» / «Проверяю…».
struct SignInButtons: View {
    @ObservedObject var form: SignInModel
    var backTitle: String
    var back: () -> Void

    var body: some View {
        if form.checking {
            Button("Отменить") { form.cancel() }
                .keyboardShortcut(.cancelAction)
        } else {
            Button(backTitle, action: back)
                .keyboardShortcut(.cancelAction)
        }
        Button(form.checking ? "Проверяю…" : "Подключить") { form.connect() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canConnect || form.succeeded)
    }
}

/// E-mail with the domain chips and the soft validation.
struct EmailField: View {
    @ObservedObject var form: SignInModel
    var focused: FocusState<Bool>.Binding
    var label: String
    var submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.medium))
            TextField("", text: $form.email, prompt: Text("name@mail.ru"))
                .textContentType(.username)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: 420)
                .focused(focused)
                .onSubmit(submit)
                .onChange(of: focused.wrappedValue) { _, isFocused in if !isFocused { form.commitEmail() } }
                .onChange(of: form.email) { _, _ in if form.emailNeedsDomain && form.email.contains("@") { form.emailNeedsDomain = false } }
                .disabled(form.checking)
            let chips = form.domainSuggestions
            if !chips.isEmpty, !form.checking {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { d in
                        Button(d) { form.applyDomain(d) }
                            .buttonStyle(ChipButtonStyle())
                    }
                }
                .transition(.opacity)
            }
            if form.emailNeedsDomain {
                Text("Нужен полный адрес, например ivan@mail.ru")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: form.domainSuggestions)
    }
}

/// Screen 3's body, shared with the compact sign-in sheet: the two fields, the clipboard offer,
/// soft warnings, the three marks of the live check and the problem plaque.
struct SignInFields: View {
    @ObservedObject var form: SignInModel
    /// «Создать новый пароль»: opens the passwords page (and the floating guide).
    var openPasswordsPage: () -> Void
    @FocusState private var emailFocused: Bool
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmailField(form: form, focused: $emailFocused, label: "Почта") { passwordFocused = true }
            VStack(alignment: .leading, spacing: 6) {
                Text("Пароль для приложения").font(.callout.weight(.medium))
                if form.clipboardOffer != .none {
                    ClipboardOfferRow(form: form)
                        .transition(.opacity)
                }
                SecureField("", text: $form.password, prompt: Text("Вставьте пароль из Mail.ru"))
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 420)
                    .focused($passwordFocused)
                    .onSubmit { form.connect() }
                    .disabled(form.checking)
                if let w = form.passwordWarning {
                    Text(w == .isEmail
                         ? "В поле пароля оказался адрес почты."
                         : "Похоже на обычный пароль от почты. Нужен пароль из раздела «Пароли для внешних приложений».")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if form.marks != [.idle, .idle, .idle] {
                CheckMarks(marks: form.marks, succeeded: form.succeeded)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
            if form.succeeded, form.clipboardCleared {
                ClipboardClearedLine()
                    .transition(.opacity)
            }
            if let p = form.problem {
                plaque(for: p)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: form.problem)
        .animation(.easeInOut(duration: 0.2), value: form.clipboardOffer)
        .animation(.easeInOut(duration: 0.2), value: form.clipboardCleared)
        .onAppear {
            if !form.emailValid { emailFocused = true } else if form.password.isEmpty { passwordFocused = true }
        }
    }

    @ViewBuilder private func plaque(for p: SignInProblem) -> some View {
        ProblemPlaque(symbol: p.symbol, quiet: p.isQuiet, title: p.title, text: p.text, trigger: form.problemCount) {
            switch p {
            case .wrongPassword:
                Button("Создать новый пароль", action: openPasswordsPage)
                Button("Ещё раз") { form.connect() }.disabled(!form.canConnect)
            case .accessDenied:
                Button("Создать пароль с доступом к Облаку", action: openPasswordsPage)
                Button("Ещё раз") { form.connect() }.disabled(!form.canConnect)
            case .missingComponent:
                Button("Открыть страницу загрузки") { Onboarding.openPage(AppInfo.downloadPage) }
            default:
                Button("Ещё раз") { form.connect() }.disabled(!form.canConnect)
            }
        } details: {
            if case .wrongPassword(let again) = p {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("•  Почта: \(form.normalizedEmail)")
                        Button("Исправить") { emailFocused = true }
                            .buttonStyle(.link)
                    }
                    Text("•  Пароль из раздела «Пароли для внешних приложений»")
                    Text("•  Доступ: «Полный доступ к Облаку»")
                }
                .foregroundStyle(.secondary)
                if again {
                    Text(SignInProblem.againText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    Link("Подробнее", destination: AppInfo.readmePage)
                }
            }
        }
    }
}

/// After a sign-in with a pasted password: the clipboard no longer holds it.
struct ClipboardClearedLine: View {
    var body: some View {
        Label("Пароль убрали из буфера обмена", systemImage: "doc.on.clipboard")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

/// «Вы что-то скопировали. Вставить как пароль?» and its outcomes.
private struct ClipboardOfferRow: View {
    @ObservedObject var form: SignInModel

    var body: some View {
        HStack(spacing: 10) {
            switch form.clipboardOffer {
            case .available:
                Image(systemName: "doc.on.clipboard").foregroundStyle(Color.appTint)
                Text("Вы что-то скопировали. Вставить как пароль?")
                Spacer(minLength: 8)
                Button("Вставить") { form.pasteFromClipboard() }
                    .controlSize(.small)
                    .disabled(form.checking)
            case .inserted:
                Image(systemName: "checkmark").foregroundStyle(.green)
                Text("Пароль вставлен")
                Spacer(minLength: 0)
            case .notPassword:
                Image(systemName: "doc.on.clipboard").foregroundStyle(.orange)
                Text("В буфере что-то другое. Скопируйте пароль на странице Mail.ru ещё раз.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            case .none:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.appTint.opacity(0.08)))
    }
}

/// «Связь с Облаком · Пароль · Место в Облаке»: spinner, then a green mark with one bounce.
private struct CheckMarks: View {
    let marks: [SignInModel.Mark]
    let succeeded: Bool
    private let names = ["Связь с Облаком", "Пароль", "Место в Облаке"]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(names.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    MarkIcon(mark: marks[i], bounce: succeeded)
                    Text(names[i])
                        .foregroundStyle(marks[i] == .idle ? .tertiary : .primary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private struct MarkIcon: View {
        let mark: SignInModel.Mark
        let bounce: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            ZStack {
                switch mark {
                case .idle:
                    Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                case .running:
                    ProgressView().controlSize(.mini)
                case .ok:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: reduceMotion ? false : bounce)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                        .transition(.opacity)
                }
            }
            .frame(width: 16, height: 16)
        }
    }
}

/// A problem: symbol (shakes once), bold first line, text, optional details, action buttons.
struct ProblemPlaque<Actions: View, Details: View>: View {
    let symbol: String
    let quiet: Bool
    let title: String?
    let text: String
    let trigger: Int
    @ViewBuilder var actions: Actions
    @ViewBuilder var details: Details

    init(symbol: String, quiet: Bool, title: String?, text: String, trigger: Int,
         @ViewBuilder actions: () -> Actions, @ViewBuilder details: () -> Details = { EmptyView() }) {
        self.symbol = symbol
        self.quiet = quiet
        self.title = title
        self.text = text
        self.trigger = trigger
        self.actions = actions()
        self.details = details()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .frame(width: 28)
                .modifier(ShakeOnChange(trigger: trigger))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(title).font(.headline) }
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                details
                HStack(spacing: 8) { actions }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

// MARK: - Screen 4: done

private struct DoneStep: View {
    @EnvironmentObject var onboarding: Onboarding
    @ObservedObject var form: SignInModel
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var loginItem: LoginItem
    @State private var notifications: UNAuthorizationStatus?
    @State private var asking = false

    private var waitingJobs: Bool { manager.jobs.contains { $0.state.isActive } }

    private var text: String {
        var parts: [String] = []
        if let q = form.quota, let a = q.available, let total = q.total, total > 0 {
            parts.append("Свободно \(Fmt.size(a)) из \(Fmt.size(total)).")
        }
        let folder = manager.destinationFolder.isEmpty ? "корень Облака" : manager.destinationFolder
        parts.append("Перетаскивайте файлы в окно, и они улетят в «\(folder)».")
        return parts.joined(separator: " ")
    }

    var body: some View {
        OnboardingPage(title: "Облако подключено", text: text) {
            CloudLevelIcon(fraction: usedFraction, size: 72)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Запускать при входе в Mac")
                        if !AppMover.isInApplications {
                            Text("Сначала перенесите в Программы").font(.caption).foregroundStyle(.secondary)
                        } else if let hint = loginItem.hint {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("Запускать при входе в Mac", isOn: Binding(get: { loginItem.enabled },
                                                                    set: { loginItem.set($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!AppMover.isInApplications)
                }
                HStack(spacing: 10) {
                    Text("Уведомлять о готовых загрузках")
                    Spacer(minLength: 8)
                    notificationControl
                }
            }
            .frame(maxWidth: 400)
            if form.clipboardCleared {
                ClipboardClearedLine()
                    .padding(.top, 16)
            }
            Label {
                Text("Пароль сохранён в связке ключей этого Мака. Приложение передаёт его только на webdav.cloud.mail.ru.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock")
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.top, 24)
        } leading: {
            EmptyView()
        } buttons: {
            Button(waitingJobs ? "Начать загрузку" : "Открыть Облако") {
                onboarding.finish(nav: nav, startTransfers: waitingJobs)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .task { notifications = await Notifier.shared.authorizationStatus() }
    }

    private var usedFraction: Double {
        guard let q = form.quota, let u = q.used, let t = q.total, t > 0 else { return 0 }
        return min(1, max(0, Double(u) / Double(t)))
    }

    @ViewBuilder private var notificationControl: some View {
        switch notifications {
        case .authorized, .provisional:
            Label("Разрешено", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
        case .denied:
            Button("Открыть настройки") { Notifier.openSystemSettings() }
        default:
            Button("Разрешить") {
                asking = true
                Task {
                    notifications = await Notifier.shared.requestAuthorizationNow()
                    asking = false
                }
            }
            .disabled(asking)
        }
    }
}

/// The cloud as a gauge (signature 1) at a larger size: filled from the bottom to `fraction` with a
/// soft spring on appear.
struct CloudLevelIcon: View {
    let fraction: Double
    var size: CGFloat
    @State private var level: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The outline's body spans roughly 15 to 90 % of the symbol's height.
        let shown = level <= 0 ? 0 : 0.15 + 0.75 * level
        ZStack {
            Image(systemName: "cloud.fill")
                .foregroundStyle(Color.appTint.opacity(0.45))
                .mask {
                    GeometryReader { g in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().frame(height: g.size.height * shown)
                        }
                    }
                }
            Image(systemName: "cloud")
                .foregroundStyle(Color.appTint)
        }
        .font(.system(size: size, weight: .regular))
        .frame(height: size * 0.9, alignment: .leading)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                level = fraction
            } else {
                withAnimation(.spring(response: 1.1, dampingFraction: 0.82).delay(0.2)) { level = fraction }
            }
        }
        .onChange(of: fraction) { _, f in withAnimation(Motion.layout) { level = f } }
    }
}

// MARK: - Keychain notice (plan A8)

/// «macOS спросит пароль от Мака»: before the first Keychain read of a new ad-hoc signed build,
/// and after a denied read.
struct KeychainNoticeSheet: View {
    let notice: KeychainNotice
    @EnvironmentObject var nav: AppNavigation
    @ObservedObject private var account = Account.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.appTint)
                .accessibilityHidden(true)
            switch notice {
            case .beforeRead:
                Text("macOS спросит пароль от Мака").font(.title3.weight(.semibold))
                Text("После обновления macOS проверяет, можно ли \(AppInfo.name) снова брать пароль Облака из связки ключей. Введите пароль от Мака и нажмите «Всегда разрешать». Это нужно один раз на версию.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Понятно") { account.dismissKeychainNotice() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            case .denied:
                Text("Нет доступа к паролю Облака").font(.title3.weight(.semibold))
                Text("Без доступа к связке ключей приложение не видит пароль. Разрешите доступ или войдите заново.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Войти заново") {
                        account.dismissKeychainNotice()
                        nav.signInPresented = true
                    }
                    Button("Попробовать снова") {
                        Task {
                            await account.retryKeychain()
                            await AppDelegate.shared?.manager.checkSetup()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}
