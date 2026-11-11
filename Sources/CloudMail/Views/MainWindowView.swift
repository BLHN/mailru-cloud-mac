import SwiftUI
import UniformTypeIdentifiers

/// Root of the main window: sidebar + section, and the window-wide layers on top of it: the drop
/// overlay (signature 2), the flight toward «Передачи» and the inline toast.
struct MainWindowView: View {
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var cloud: CloudBrowserModel
    @EnvironmentObject var onboarding: Onboarding
    @ObservedObject private var account = Account.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drops land in the saved default folder, except in «Облако»: there into the shown folder
    /// (the saved default stays as it is).
    private var dropFolder: String {
        nav.section == .cloud ? cloud.path : manager.destinationFolder
    }

    var body: some View {
        Group {
            if onboarding.isShown {
                // First run: no sidebar until the cloud is connected.
                OnboardingView()
                    .transition(.opacity)
            } else {
                mainLayout
                    .transition(.opacity)
            }
        }
        .tint(.appTint)
        .sheet(isPresented: $nav.signInPresented) { SignInSheet() }
        .background {
            Color.clear.sheet(item: keychainNotice) { notice in
                KeychainNoticeSheet(notice: notice).environmentObject(nav)
            }
        }
    }

    /// The Keychain explanation (A8) while the account asks for it.
    private var keychainNotice: Binding<KeychainNotice?> {
        Binding(get: { account.keychainNotice },
                set: { if $0 == nil, account.keychainNotice != nil { account.dismissKeychainNotice() } })
    }

    private var mainLayout: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(nav.section.title)
                .overlay(alignment: .bottom) { ToastView() }
        }
        .overlay { DropOverlay(active: nav.dropTargeted, folder: dropFolder.isEmpty ? "корень Облака" : dropFolder) }
        .overlay { FlightLayer() }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { nav.windowSize = g.size }
                    .onChange(of: g.size) { _, s in nav.windowSize = s }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: dropTargeted) { providers in
            let folder = nav.section == .cloud ? cloud.path : nil
            land(dropCount: providers.count)
            Task { @MainActor in
                manager.add(urls: await FileDrop.urls(from: providers), folder: folder)
            }
            return true
        }
    }

    /// The drop overlay follows the drag; with the dev `--dev-play drop` it is driven directly.
    private var dropTargeted: Binding<Bool> {
        Binding(get: { nav.dropTargeted }, set: { v in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.small) { nav.dropTargeted = v }
        })
    }

    /// On drop: the overlay collapses toward the «Передачи» row and its badge bounces.
    private func land(dropCount: Int) {
        let folder = dropFolder.isEmpty ? "корень Облака" : dropFolder
        // Where the overlay's cloud symbol sits (centered stack, symbol on top).
        let center = CGPoint(x: nav.windowSize.width / 2, y: nav.windowSize.height / 2 - 38)
        withAnimation(.easeOut(duration: 0.22)) { nav.dropTargeted = false }
        nav.flyToTransfers(symbol: "icloud.and.arrow.up", from: center, size: 64,
                           toast: "Загружается в «\(folder)»", reduceMotion: reduceMotion)
    }

    @ViewBuilder private var detail: some View {
        switch nav.section {
        case .transfers: TransfersView()
        case .cloud: CloudBrowserView()
        case .backup: BackupView()
        case .settings: SettingsView()
        }
    }
}

/// Signature 2: dragging files over the window turns the whole window into the target.
struct DropOverlay: View {
    let active: Bool
    let folder: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 64, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.appTint)
                    Text("Отпускай")
                        .font(.title2.weight(.semibold))
                    Text("Улетят в Облако, в «\(folder)»")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The flying symbol of a landing (drop or queued download).
private struct FlightLayer: View {
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { nav.flightLayerOrigin = g.frame(in: .global).origin }
                .onChange(of: g.frame(in: .global).origin) { _, o in nav.flightLayerOrigin = o }
            if let f = nav.flight {
                let origin = g.frame(in: .global).origin
                let target = CGPoint(x: nav.transfersRowCenter.x - origin.x, y: nav.transfersRowCenter.y - origin.y)
                Image(systemName: f.symbol)
                    .font(.system(size: f.size))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appTint)
                    .scaleEffect(f.arrived ? 0.22 : 1)
                    .opacity(f.arrived ? 0.35 : 1)
                    .position(f.arrived ? target : f.from)
                    .id(f.id)
            }
        }
        .allowsHitTesting(false)
    }
}

/// «Загружается в «Mac/Входящие» · Показать»: offers the jump to «Передачи» while the user stays
/// where they are.
private struct ToastView: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var cloud: CloudBrowserModel

    var body: some View {
        if let t = nav.toast {
            HStack(spacing: 10) {
                Text(t.text).lineLimit(1)
                Button("Показать") {
                    nav.section = .transfers
                    withAnimation(.easeOut(duration: 0.2)) { nav.toast = nil }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            // Above the selection bar of «Облако» while it is shown.
            .padding(.bottom, nav.section == .cloud && !cloud.selection.isEmpty ? 48 : 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}
