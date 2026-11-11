import Foundation
import ServiceManagement

/// "Запускать при входе" via SMAppService.mainApp. macOS accepts it reliably only for the
/// copy in /Applications, so a short hint is shown when registration fails or needs approval.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var hint: String?

    init() { reload() }

    func reload() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        hint = status == .requiresApproval
            ? "Разреши в Системных настройках → Основные → Объекты входа."
            : nil
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppLog.write("launch at login: \(on ? "on" : "off")")
            reload()
        } catch {
            AppLog.write("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            reload()
            if on && !enabled {
                hint = Bundle.main.bundlePath.hasPrefix("/Applications/")
                    ? "Не получилось. Разреши в Системных настройках → Основные → Объекты входа."
                    : "Работает, только если приложение лежит в папке «Программы»."
            }
        }
    }
}
