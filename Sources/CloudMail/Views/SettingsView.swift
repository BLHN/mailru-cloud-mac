import SwiftUI
import UserNotifications

/// «Настройки»: a grouped form with the account, the upload options, default folders, launch at
/// login, the notifications state, the log and what the app is.
struct SettingsView: View {
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var loginItem: LoginItem
    @State private var showPicker = false
    @State private var notifications: UNAuthorizationStatus?

    var body: some View {
        Form {
            AccountSection()
            Section("Загрузка в Облако") {
                Toggle(isOn: $manager.quietMode) {
                    Text("Тихий режим")
                    Text("Не больше 2 МБ/с, чтобы не мешать интернету. Действует на новые загрузки.")
                }
                Toggle(isOn: $manager.evictAfterUpload) {
                    Text("Освобождать место после загрузки")
                    Text("Оригинал уйдёт в Корзину, на его месте останется ярлык-облако; двойной клик вернёт файл.")
                }
                if manager.freedBytes > 0 {
                    LabeledContent("Освобождено на Маке") {
                        Text(Fmt.size(manager.freedBytes)).monospacedDigit()
                    }
                    .help("Столько ушло в Корзину после загрузки в Облако. Место на диске вернётся, когда Корзину очистят.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(manager.destinationFolder.isEmpty ? "корень Облака" : manager.destinationFolder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Изменить…") { showPicker = true }
                    }
                } label: {
                    Text("Папка в Облаке для загрузок")
                }
            }
            Section("Скачивание на Мак") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(LocalFolderName.display(manager.downloadFolder))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(manager.downloadFolder)
                        Button("Изменить…", action: pickDownloadFolder)
                    }
                } label: {
                    Text("Папка на Маке для скачанного")
                }
            }
            Section("Система") {
                launchAtLogin
                notificationsRow
            }
            Section {
                LabeledContent {
                    Button("Показать журнал") { manager.revealLog() }
                } label: {
                    Text("Журнал")
                    Text(AppLog.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
            }
            Section {
                LabeledContent {
                    Text(AppInfo.version).foregroundStyle(.secondary).monospacedDigit()
                } label: {
                    Text(AppInfo.name)
                    Text("\(AppInfo.tagline) · \(AppInfo.disclaimer)")
                }
                if let notices = AppInfo.thirdPartyNotices {
                    LabeledContent {
                        Button("Лицензии") { NSWorkspace.shared.open(notices) }
                    } label: {
                        Text(AppInfo.includesNotice)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await loadNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadNotifications() }
            loginItem.reload()
        }
        .sheet(isPresented: $showPicker) {
            FolderPickerView(selected: manager.destinationFolder) { path in
                manager.destinationFolder = path
            }
            .environmentObject(manager)
        }
    }

    // MARK: Launch at login

    @ViewBuilder private var launchAtLogin: some View {
        if AppPaths.isDev {
            Toggle(isOn: .constant(false)) {
                Text("Запускать при входе")
                Text("в тестовой сборке выключено")
            }
            .disabled(true)
        } else {
            Toggle(isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) })) {
                Text("Запускать при входе")
                if let hint = loginItem.hint {
                    Text(hint).foregroundStyle(.orange)
                } else {
                    Text("Работает, только если приложение лежит в папке «Программы».")
                }
            }
            .onAppear { loginItem.reload() }
        }
    }

    // MARK: Notifications

    @ViewBuilder private var notificationsRow: some View {
        if AppPaths.isDev {
            LabeledContent {
                Text("в тестовой сборке не проверяются").foregroundStyle(.secondary)
            } label: {
                Text("Уведомления")
            }
        } else {
            switch notifications {
            case .authorized, .provisional:
                LabeledContent {
                    Label("разрешены", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } label: {
                    Text("Уведомления разрешены")
                    Text("Сообщу, когда загрузка закончится или не получится.")
                }
            case .denied:
                LabeledContent {
                    Button("Открыть настройки уведомлений", action: openNotificationSettings)
                } label: {
                    Text("Уведомления выключены в macOS")
                    Text("Без них не узнать, что загрузка закончилась, пока окно закрыто.")
                }
            case .notDetermined:
                LabeledContent {
                    Button("Открыть настройки уведомлений", action: openNotificationSettings)
                } label: {
                    Text("Уведомления")
                    Text("macOS спросит разрешение при первой загрузке.")
                }
            default:
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    Text("Уведомления")
                }
            }
        }
    }

    private func loadNotifications() async {
        guard !AppPaths.isDev, Bundle.main.bundleIdentifier != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = settings.authorizationStatus
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "ru.blhn.cloudmail"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Download folder

    private func pickDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: manager.downloadFolder, isDirectory: true)
        panel.prompt = "Выбрать"
        panel.message = "Куда скачивать из Облака?"
        if panel.runModal() == .OK, let url = panel.url {
            manager.downloadFolder = url.path
        }
    }
}
