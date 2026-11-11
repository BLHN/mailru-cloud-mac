import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The app tint (Mail.ru blue), the only accent of the window.
extension Color {
    static let appTint = Color(red: 0, green: 0.47, blue: 1)
}

/// Shared springs and durations (DESIGN.md "Micro-interactions and motion").
enum Motion {
    static let layout = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let small = Animation.spring(response: 0.25, dampingFraction: 0.82)
    static let press = Animation.easeOut(duration: 0.12)
    static let hoverOut = Animation.easeOut(duration: 0.15)
}

// MARK: - Press feedback

/// Borderless icon or text button that scales to 0.97 while pressed.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Small capsule chip (the options line): quiet fill, accent tint when `isOn`.
struct ChipButtonStyle: ButtonStyle {
    var isOn = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.appTint) : AnyShapeStyle(.primary))
            .background {
                Capsule().fill(isOn ? AnyShapeStyle(Color.appTint.opacity(0.14))
                                    : AnyShapeStyle(.quaternary.opacity(hover ? 0.9 : 0.55)))
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .onHover { h in withAnimation(h ? nil : Motion.hoverOut) { hover = h } }
    }
}

/// A toggle drawn as a chip.
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(ChipButtonStyle(isOn: configuration.isOn))
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Progress

/// 4 pt capsule progress bar. Animates between values; `indeterminate` shows a slow sweep
/// (while rclone is still listing). With reduce motion the sweep becomes a still, dimmed track.
struct CapsuleProgress: View {
    var value: Double
    var indeterminate = false
    var tint: Color = .appTint
    var height: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if indeterminate {
                    if reduceMotion {
                        Capsule().fill(tint.opacity(0.35))
                    } else {
                        Sweep(width: g.size.width, tint: tint)
                    }
                } else {
                    Capsule().fill(tint)
                        .frame(width: max(height, g.size.width * min(1, max(0, value))))
                        .opacity(value > 0 ? 1 : 0)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.45), value: value)
        .accessibilityElement()
        .accessibilityValue(indeterminate ? "проверяю" : Fmt.percent(value))
    }

    private struct Sweep: View {
        let width: CGFloat
        let tint: Color
        @State private var phase: CGFloat = 0
        var body: some View {
            let w = max(24, width * 0.3)
            Capsule().fill(tint.opacity(0.75))
                .frame(width: w)
                .offset(x: -w + phase * (width + w))
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

// MARK: - Shake

/// One small horizontal shake whenever `trigger` changes (a failed job's icon).
struct ShakeOnChange: ViewModifier {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-5, duration: 0.06)
                    LinearKeyframe(5, duration: 0.08)
                    LinearKeyframe(-3, duration: 0.08)
                    LinearKeyframe(2, duration: 0.07)
                    SpringKeyframe(0, duration: 0.2, spring: .snappy)
                }
            }
        }
    }
}

/// A short scale bounce whenever `trigger` changes (the sidebar badge).
struct BounceOnChange: ViewModifier {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, s in
                view.scaleEffect(s)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.35, duration: 0.14, spring: .snappy)
                    SpringKeyframe(0.92, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1, duration: 0.25, spring: .bouncy)
                }
            }
        }
    }
}

// MARK: - File icons

/// Real Finder icons for queue rows. Existing items get their own icon; items that do not exist
/// (yet) get the icon of their file type or the generic folder icon. Cached per path.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL, isDirectory: Bool) -> NSImage {
        let key = url.path + (isDirectory ? "/" : "")
        if let i = cache[key] { return i }
        let image: NSImage
        if FileManager.default.fileExists(atPath: url.path) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if let t = UTType(filenameExtension: url.pathExtension), !url.pathExtension.isEmpty {
            image = NSWorkspace.shared.icon(for: t)
        } else {
            image = NSWorkspace.shared.icon(for: .data)
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// Forget an item's icon (its file appeared or changed, e.g. a finished download).
    static func forget(_ url: URL) {
        cache[url.path] = nil
        cache[url.path + "/"] = nil
    }
}

// MARK: - Files from drops and the open panel

enum FileDrop {
    /// File URLs of dropped item providers.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers {
            if let u = await loadURL(p) { urls.append(u) }
        }
        return urls
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: u)
                } else if let u = item as? URL {
                    cont.resume(returning: u)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// «Выбрать в Finder…»: files and folders to upload.
    @MainActor
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Загрузить"
        panel.message = "Что отправить в Облако?"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
