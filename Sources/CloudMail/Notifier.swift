import AppKit
import UserNotifications

/// macOS notifications for finished / failed jobs. Authorization is requested lazily, on the first job.
/// Works only from the .app bundle; the bare binary has no bundle id and
/// UNUserNotificationCenter would crash there, so it is skipped.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var requested = false

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorizationIfNeeded() {
        // The dev build never asks: it only logs what it would have shown.
        guard !AppPaths.isDev, !requested, let c = center else { return }
        requested = true
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { granted, error in
            let note = error.map { " (\($0.localizedDescription))" } ?? ""
            Task { @MainActor in AppLog.write("notifications authorization: \(granted ? "granted" : "denied")\(note)") }
        }
    }

    /// The current permission; nil in the dev build and the bare binary (they never ask).
    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard !AppPaths.isDev, let c = center else { return nil }
        return await c.notificationSettings().authorizationStatus
    }

    /// «Разрешить» on the onboarding's last screen: the system question, asked only on that click.
    /// The dev build only logs it.
    func requestAuthorizationNow() async -> UNAuthorizationStatus? {
        guard !AppPaths.isDev, let c = center else {
            AppLog.write("dev: notifications permission would be asked now")
            return nil
        }
        requested = true
        c.delegate = self
        let granted = (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
        AppLog.write("notifications authorization: \(granted ? "granted" : "denied")")
        return await c.notificationSettings().authorizationStatus
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "ru.blhn.cloudmail"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func jobDone(_ job: UploadJob) {
        switch job.kind {
        case .copy:
            post(title: AppInfo.name, body: "Загружено: \(job.name), \(Fmt.size(job.totalBytes))")
        case .evict:
            post(title: AppInfo.name, body: "В Облаке, место освобождено: \(job.name), \(Fmt.size(job.freedBytes ?? job.totalBytes))")
        case .restore:
            post(title: AppInfo.name, body: "Вернулось на Мак: \(job.name), \(Fmt.size(job.totalBytes))")
        case .download:
            post(title: AppInfo.name, body: "Скачано на Мак: \(job.name), \(Fmt.size(job.totalBytes))")
        }
    }

    func jobFailed(_ job: UploadJob, message: String) {
        let title: String
        switch job.kind {
        case .copy, .evict: title = "Не загрузилось: \(job.name)"
        case .restore: title = "Не вернулось: \(job.name)"
        case .download: title = "Не скачалось: \(job.name)"
        }
        post(title: title, body: message)
    }

    /// A notice of the app itself: «Копия Мака» news (BackupMonitor decides when) or the account.
    func notice(_ body: String) {
        post(title: AppInfo.name, body: body)
    }

    private func post(title: String, body: String) {
        if AppPaths.isDev {
            AppLog.write("notify: \(title) | \(body)")
            return
        }
        guard let c = center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        c.add(request) { error in
            if let error {
                let text = error.localizedDescription
                Task { @MainActor in AppLog.write("notification failed: \(text)") }
            }
        }
    }

    /// Show banners even while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
