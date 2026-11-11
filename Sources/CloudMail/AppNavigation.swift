import SwiftUI

/// Sections of the main window's sidebar.
enum AppSection: String, CaseIterable, Hashable {
    case transfers, cloud, backup, settings

    var title: String {
        switch self {
        case .transfers: return "Передачи"
        case .cloud: return "Облако"
        case .backup: return "Копия Мака"
        case .settings: return "Настройки"
        }
    }

    var symbol: String {
        switch self {
        case .transfers: return "arrow.up.arrow.down"
        case .cloud: return "cloud"
        case .backup: return "checkmark.shield"
        case .settings: return "gearshape"
        }
    }
}

/// Window-wide UI state shared by the sidebar, the sections, the drop overlay and the app
/// delegate (Cmd+, and the dev flags): the selected section, the drop overlay, flights toward
/// «Передачи», the badge bounce and the inline toast.
@MainActor
final class AppNavigation: ObservableObject {
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var text: String
    }

    /// One symbol flying from a point of the window to the «Передачи» sidebar row.
    struct Flight: Equatable, Identifiable {
        let id = UUID()
        var symbol: String
        /// Start point and size in the window's coordinate space (top-left origin).
        var from: CGPoint
        var size: CGFloat
        var arrived = false
    }

    @Published var section: AppSection = .transfers
    /// Files are dragged over the window: the whole window shows the drop overlay.
    @Published var dropTargeted = false
    @Published var flight: Flight?
    /// Bumped when something lands in «Передачи»: the sidebar badge bounces.
    @Published private(set) var badgeBounce = 0
    @Published var toast: Toast?
    /// The sign-in sheet («Вход в Облако») is shown over the window.
    @Published var signInPresented = false
    /// Dev `--dev-hover <n>`: this row of «Передачи» is drawn as hovered.
    @Published var devHoverRow: Int?

    /// Frame of the «Передачи» sidebar row in window coordinates (written by the sidebar).
    var transfersRowFrame: CGRect = .zero
    /// Global origin of the flight layer: flights that start at a global point (a row in
    /// «Облако») subtract it (written by the flight layer).
    var flightLayerOrigin: CGPoint = .zero
    /// Size of the window's content (written by the root view).
    var windowSize: CGSize = .zero

    private var toastTask: Task<Void, Never>?

    /// The landing of a drop or of a queued download: the symbol flies from `from` to the
    /// «Передачи» row, the badge bounces, and when the user is elsewhere a toast offers the jump.
    /// With reduce motion there is no flight, only the badge update and the toast.
    func flyToTransfers(symbol: String, from: CGPoint, size: CGFloat, toast text: String?, reduceMotion: Bool) {
        let showToast = { [weak self] in
            guard let self, let text, self.section != .transfers else { return }
            self.show(toast: text)
        }
        guard !reduceMotion, transfersRowFrame != .zero else {
            badgeBounce += 1
            showToast()
            return
        }
        if AppPaths.isDev { AppLog.write("dev: flight from \(from) to row \(transfersRowFrame) window \(windowSize)") }
        let f = Flight(symbol: symbol, from: from, size: size)
        flight = f
        // Next runloop turn: the flight view exists at its start point before it moves.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.flight?.id == f.id else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                self.flight?.arrived = true
            } completion: { [weak self] in
                guard let self, self.flight?.id == f.id else { return }
                self.flight = nil
                self.badgeBounce += 1
                showToast()
            }
        }
    }

    var transfersRowCenter: CGPoint {
        CGPoint(x: transfersRowFrame.minX + 24, y: transfersRowFrame.midY)
    }

    func show(toast text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { toast = Toast(text: text) }
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }
}
