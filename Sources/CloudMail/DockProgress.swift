import AppKit
import Combine

/// A progress bar on the Dock icon while transfers run (overall fraction of the active jobs),
/// removed when idle. Redraws only when the shown value changes by at least half a percent.
@MainActor
final class DockProgress {
    private var subscription: AnyCancellable?
    private var shown: Double?
    private let view = DockProgressView()

    init(manager: UploadManager) {
        subscription = manager.$jobs.sink { [weak self] jobs in
            MainActor.assumeIsolated { self?.update(jobs) }
        }
    }

    private func update(_ jobs: [UploadJob]) {
        let tile = NSApplication.shared.dockTile
        guard jobs.contains(where: { $0.state == .running }) else {
            if shown != nil {
                shown = nil
                tile.contentView = nil
                tile.display()
            }
            return
        }
        let active = jobs.filter { $0.state.isActive }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = active.reduce(Int64(0)) { $0 + min($1.bytes, $1.totalBytes) }
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        if let s = shown, abs(s - fraction) < 0.005 { return }
        shown = fraction
        view.fraction = fraction
        if tile.contentView !== view {
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        }
        tile.display()
    }
}

/// The app icon with a capsule bar near its bottom edge.
private final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApplication.shared.applicationIconImage?.draw(in: bounds)
        let inset = bounds.width * 0.14
        let height = max(6, bounds.height * 0.07)
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        let radius = height / 2
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5).fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var bar = track
        bar.size.width = max(height, track.width * CGFloat(min(1, max(0, fraction))))
        NSColor(red: 0, green: 0.47, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
    }
}
