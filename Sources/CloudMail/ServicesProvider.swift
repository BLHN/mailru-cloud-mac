import AppKit

/// Finder → Службы → «Отправить в Облако Mail.ru» and «Выгрузить в Облако Mail.ru и освободить место».
/// Declared in Packaging/Info.plist (NSServices, NSMessage = uploadFiles / evictFiles) and
/// registered with `NSApp.servicesProvider`. `.mailcloud` placeholders sent here are restored.
@MainActor
final class ServicesProvider: NSObject {
    private let manager: UploadManager

    init(manager: UploadManager) {
        self.manager = manager
    }

    @objc func uploadFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pboard, evict: nil, error: error)
    }

    @objc func evictFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(pboard, evict: true, error: error)
    }

    /// `evict: nil` follows the "Освобождать место после загрузки" setting.
    private func receive(_ pboard: NSPasteboard, evict: Bool?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Нет файлов для загрузки" as NSString
            return
        }
        AppLog.write("service\(evict == true ? " (evict)" : ""): \(urls.count) item(s) from Finder")
        manager.add(urls: urls, evict: evict)
        AppDelegate.shared?.showWindow(activate: false)
    }
}
