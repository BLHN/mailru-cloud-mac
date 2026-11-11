import AppKit
import SwiftUI

/// Screen 2A: a small floating panel at the right edge of the screen, next to the browser with the
/// Mail.ru passwords page. It never takes focus from the browser (non-activating panel) and only
/// watches the clipboard's change count and types; the content is read once, when the user clicks
/// «Вставить и подключить». It closes when the app becomes active again.
@MainActor
final class PasswordGuidePanel {
    static let shared = PasswordGuidePanel()

    struct Handlers {
        /// «Я создал пароль»: back to the window, screen 3.
        var created: () -> Void
        /// «Вставить и подключить».
        var pasteAndConnect: () -> Void
        /// «Mail.ru просит телефон?»: screen 2B.
        var phone: () -> Void
        /// «Открыть ещё раз».
        var reopen: () -> Void
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private weak var form: SignInModel?

    var isShown: Bool { panel?.isVisible == true }

    func show(form: SignInModel, handlers: Handlers) {
        close()
        self.form = form
        // 280 x 360 with the (empty) title bar.
        let size = NSSize(width: 280, height: 336)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.title = "Создайте пароль на Mail.ru"
        let host = NSHostingView(rootView: GuidePanelView(form: form, handlers: handlers).tint(.appTint))
        host.sizingOptions = []
        p.contentView = host
        p.setContentSize(size)
        // At the right edge of the screen the user works on, 20 pt in.
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20, y: f.midY - size.height / 2))
        }
        if AppPaths.isDev {
            // The dev build never draws above the developer's apps: an ordinary window at the back.
            p.level = .normal
            p.orderBack(nil)
        } else {
            p.level = .floating
            p.orderFrontRegardless()
        }
        panel = p
        // The change count has no notification: a cheap look twice a second while the panel is up.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.form?.refreshClipboard() }
        }
        AppLog.write("guide panel: shown")
    }

    func close() {
        timer?.invalidate()
        timer = nil
        guard let p = panel else { return }
        p.orderOut(nil)
        panel = nil
        AppLog.write("guide panel: closed")
    }
}

private struct GuidePanelView: View {
    @ObservedObject var form: SignInModel
    let handlers: PasswordGuidePanel.Handlers
    @State private var showHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copied: Bool { form.clipboardOffer == .available }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Создайте пароль на Mail.ru")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                GuideStep(number: 1) { Text("«Создать»") }
                GuideStep(number: 2) { Text("Название: Мой Мак → «Продолжить»") }
                GuideStep(number: 3) { Text("«Полный доступ к Облаку» → «Продолжить»") }
                GuideStep(number: 4) { Text("«Скопировать»") }
            }
            .font(.callout)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                if copied {
                    Label("Что-то скопировано", systemImage: "doc.on.clipboard")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                    Button(action: handlers.pasteAndConnect) {
                        Text("Вставить и подключить").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Жду, когда вы скопируете пароль…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                    Button(action: handlers.created) {
                        Text("Я создал пароль").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: copied)
            VStack(alignment: .leading, spacing: 4) {
                Button("Mail.ru просит телефон?", action: handlers.phone)
                Button("Не вижу «Пароли для внешних приложений»") { showHelp = true }
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Откройте почту, внизу слева «Настройки» → «Все настройки» → «Безопасность» → «Пароли для внешних приложений».")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Открыть ещё раз", action: handlers.reopen)
                        }
                        .font(.callout)
                        .padding(14)
                        .frame(width: 260)
                    }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(width: 280, height: 336, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

/// A numbered step: the number in a small accent circle.
struct GuideStep<Content: View>: View {
    let number: Int
    var size: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: size * 0.6, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.appTint))
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            content
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
