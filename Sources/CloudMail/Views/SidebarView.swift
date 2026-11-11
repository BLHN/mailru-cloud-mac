import SwiftUI

/// The window's sidebar: «Передачи» (badge), «Облако», «Копия Мака» (status dot, only where the
/// background supervisor is set up); pinned to the bottom the cloud gauge and the «Настройки» row.
struct SidebarView: View {
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var status: CloudStatus
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listSelection: Binding<AppSection?> {
        Binding(get: { nav.section == .settings ? nil : nav.section },
                set: { if let s = $0 { nav.section = s } })
    }

    var body: some View {
        List(selection: listSelection) {
            transfersRow.tag(AppSection.transfers)
            Label(AppSection.cloud.title, systemImage: AppSection.cloud.symbol)
                .tag(AppSection.cloud)
            if status.hasSupervisor {
                backupRow.tag(AppSection.backup)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // No account yet: nothing to measure.
                if manager.setupIssue == nil {
                    CloudGaugeView()
                        .padding(.horizontal, 8)
                }
                SettingsRow(selected: nav.section == .settings) { nav.section = .settings }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private var isTransferring: Bool { manager.runningJob != nil }

    private var transfersRow: some View {
        HStack(spacing: 0) {
            Label {
                Text(AppSection.transfers.title)
            } icon: {
                Image(systemName: AppSection.transfers.symbol)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isTransferring && !reduceMotion)
            }
            Spacer(minLength: 4)
            let active = manager.activeCount
            if active > 0 {
                Text("\(active)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(active)))
                    .animation(.smooth, value: active)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .modifier(BounceOnChange(trigger: nav.badgeBounce))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("активных: \(active)")
            }
        }
        .animation(Motion.small, value: manager.activeCount > 0)
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { nav.transfersRowFrame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in nav.transfersRowFrame = f }
            }
        }
    }

    private var backupRow: some View {
        HStack {
            Label(AppSection.backup.title, systemImage: AppSection.backup.symbol)
            Spacer(minLength: 4)
            BackupDot(state: status.backup)
        }
    }
}

/// Trailing status dot of «Копия Мака»: green = all in the cloud, accent = syncing (breathes),
/// orange = needs attention, gray = supervisor silent.
struct BackupDot: View {
    let state: BackupState
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.5 : 1)
            .help(help)
            .accessibilityLabel(help)
            .onAppear(perform: updateBreathing)
            .onChange(of: state) { _, _ in updateBreathing() }
    }

    private func updateBreathing() {
        if state == .syncing && !reduceMotion {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dim = false }
        }
    }

    private var color: Color {
        switch state {
        case .ok: return .green
        case .syncing: return .appTint
        case .attention: return .orange
        case .silent, .unknown: return .gray
        }
    }

    private var help: String {
        switch state {
        case .ok: return "Всё в Облаке"
        case .syncing: return "Выгружается"
        case .attention: return "Нужно внимание"
        case .silent: return "Супервизор молчит"
        case .unknown: return "Проверяю"
        }
    }
}

/// The «Настройки» row pinned under the gauge, drawn like a sidebar row.
private struct SettingsRow: View {
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            Label(AppSection.settings.title, systemImage: AppSection.settings.symbol)
                // Sidebar rows dim in an inactive window; this row does the same.
                .foregroundStyle(activeState == .inactive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(hover ? 0.5 : 0)))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { h in if h { hover = true } else { withAnimation(Motion.hoverOut) { hover = false } } }
        .help("Настройки (⌘,)")
    }
}

/// Signature 1: the cloud is the gauge. A `cloud` outline filled from the bottom up to the used
/// share of the cloud storage; the level rises from zero on appear and settles to new values with
/// a soft spring. Hover switches the text to the used amount.
struct CloudGaugeView: View {
    @EnvironmentObject var status: CloudStatus
    @State private var level: Double = 0
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { status.storage?.usedFraction ?? 0 }

    var body: some View {
        HStack(spacing: 10) {
            gauge
            VStack(alignment: .leading, spacing: 1) {
                ZStack(alignment: .leading) {
                    Text(primary).opacity(hover ? 0 : 1)
                    Text(hoverText).opacity(hover ? 1 : 0)
                }
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                Text(secondary)
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .animation(.easeInOut(duration: 0.18), value: hover)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 && status.storage != nil }
        .onAppear {
            // Promo takes start calm: the level is already there (`--dev-play gauge` replays the rise).
            if DevPromo.on { level = fraction } else { settle(delay: 0.25) }
        }
        .onChange(of: fraction) { _, _ in settle(delay: 0) }
        .accessibilityElement(children: .combine)
        .help("Место в Облаке")
    }

    private func settle(delay: Double) {
        let target = fraction
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.25)) { level = target }
        } else {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.82).delay(delay)) { level = target }
        }
    }

    /// The outline's body spans roughly 15 to 90 % of the symbol's height; the level maps there so
    /// 0 is empty and 1 is full.
    private var gauge: some View {
        let shown = level <= 0 ? 0 : 0.15 + 0.75 * level
        return ZStack {
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
        .font(.system(size: 30, weight: .regular))
        .frame(width: 44)
        .accessibilityHidden(true)
    }

    private var primary: String {
        guard let s = status.storage else { return "Облако" }
        return "Свободно \(Fmt.size(s.free))"
    }

    private var secondary: String {
        guard let s = status.storage else { return "узнаю, сколько места" }
        return "из \(Fmt.size(s.total))"
    }

    private var hoverText: String {
        guard let s = status.storage else { return primary }
        return "Занято \(Fmt.size(s.used)) · \(Int((s.usedFraction * 100).rounded())) %"
    }
}
