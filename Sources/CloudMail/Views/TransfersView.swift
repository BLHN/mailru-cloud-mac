import SwiftUI

/// «Передачи»: the options line, then either the calm drop invitation (empty queue) or the queue
/// in three sections: «Сейчас», «Нужно внимание», «Готово».
struct TransfersView: View {
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var motion: TransferMotion
    @EnvironmentObject var nav: AppNavigation
    @State private var showPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            optionsLine
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
            if let issue = manager.setupIssue {
                HStack(spacing: 10) {
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(SetupIssueAction.title(for: issue)) {
                        AppDelegate.shared?.resolveSetupIssue()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if !manager.cloudReachable {
                // Quiet: nothing for the user to do, the queue continues by itself.
                Label("Нет связи с Облаком. Продолжу сам, как только появится", systemImage: "wifi.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .transition(.opacity)
            }
            Divider()
            if manager.jobs.isEmpty {
                emptyState
                    .transition(.opacity)
            } else {
                queue
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.jobs.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: manager.cloudReachable)
        .sheet(isPresented: $showPicker) {
            FolderPickerView(selected: manager.destinationFolder) { path in
                manager.destinationFolder = path
            }
            .environmentObject(manager)
        }
    }

    // MARK: Options line

    private var optionsLine: some View {
        HStack(spacing: 8) {
            Button { showPicker = true } label: {
                Label("в \(manager.destinationFolder.isEmpty ? "корень Облака" : manager.destinationFolder)", systemImage: "folder")
                    .truncationMode(.middle)
            }
            .buttonStyle(ChipButtonStyle())
            .help("Папка в Облаке, куда улетают новые загрузки. Нажми, чтобы выбрать другую.")
            Toggle(isOn: $manager.quietMode) {
                Label("Тихий режим", systemImage: manager.quietMode ? "tortoise.fill" : "tortoise")
            }
            .toggleStyle(ChipToggleStyle())
            .fixedSize()
            .help("Не больше 2 МБ/с, чтобы не мешать интернету. Действует на новые загрузки.")
            Toggle(isOn: $manager.evictAfterUpload) {
                Label("Освобождать место", systemImage: manager.evictAfterUpload ? "internaldrive.fill" : "internaldrive")
            }
            .toggleStyle(ChipToggleStyle())
            .fixedSize()
            .help(evictHelp)
            Spacer(minLength: 8)
            if !manager.jobs.isEmpty {
                Button {
                    manager.add(urls: FileDrop.pickFiles())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Выбрать в Finder…")
                .accessibilityLabel("Выбрать в Finder")
            }
        }
    }

    private var evictHelp: String {
        var s = "Оригинал уйдёт в Корзину, на его месте останется ярлык-облако; двойной клик вернёт файл."
        if manager.freedBytes > 0 { s += " Освобождено на Маке: \(Fmt.size(manager.freedBytes))." }
        return s
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Перетащи сюда файлы или папки")
                .font(.title3.weight(.medium))
            Text(manager.evictAfterUpload
                 ? "Улетят в Облако, в «\(manager.destinationFolder)», а на Маке останутся ярлыки"
                 : "Улетят в Облако, в «\(manager.destinationFolder)»")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Выбрать в Finder…") { manager.add(urls: FileDrop.pickFiles()) }
                .buttonStyle(.link)
                .padding(.top, 2)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Queue

    /// One flat list of headers and rows: a row that changes sections keeps its identity, so it
    /// really moves (with a fade) instead of being removed in one place and inserted in another.
    private enum Item: Identifiable {
        case header(TransferBucket, Int)
        case row(UploadJob, first: Bool, index: Int)
        var id: String {
            switch self {
            case .header(let b, _): return "header-\(b.rawValue)"
            case .row(let j, _, _): return j.id.uuidString
            }
        }
    }

    private var items: [Item] {
        let grouped = Dictionary(grouping: manager.jobs) { motion.bucket(of: $0) }
        var out: [Item] = []
        var index = 0
        for b in TransferBucket.allCases {
            guard let list = grouped[b], !list.isEmpty else { continue }
            out.append(.header(b, list.count))
            for (k, j) in list.enumerated() {
                out.append(.row(j, first: k == 0, index: index))
                index += 1
            }
        }
        return out
    }

    private var queue: some View {
        let list = items
        let order = list.map(\.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { item in
                    switch item {
                    case .header(let b, let count):
                        sectionHeader(b, count: count)
                            .transition(.opacity)
                    case .row(let job, let first, let index):
                        VStack(spacing: 0) {
                            if !first {
                                Divider().padding(.leading, 64).padding(.trailing, 10)
                            }
                            row(job, index: index)
                        }
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(
                                        // Fade in once the rows below have mostly made room, so the
                                        // new row never sits translucent over its neighbour.
                                        insertion: .opacity.combined(with: .offset(y: -10))
                                            .animation(.easeOut(duration: 0.22).delay(0.16)),
                                        removal: .opacity))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Motion.layout, value: order)
    }

    private func row(_ job: UploadJob, index: Int) -> some View {
        TransferRowView(job: job,
                        held: motion.isHeld(job.id),
                        bounce: motion.doneBounce[job.id] ?? 0,
                        shake: motion.failShake[job.id] ?? 0,
                        forcedHover: nav.devHoverRow == index)
    }

    private func sectionHeader(_ bucket: TransferBucket, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(bucket.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(bucket == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text("\(count)")
                .font(.subheadline).foregroundStyle(.tertiary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
            Spacer()
            if bucket == .done {
                Button("Очистить") {
                    // Only this section: failed and blocked rows stay until the user decides.
                    let ids = manager.jobs.filter { TransferBucket.natural($0.state) == .done }.map(\.id)
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Motion.layout) {
                        for id in ids { manager.remove(id) }
                    }
                }
                .buttonStyle(.link).font(.subheadline)
                .help("Убрать готовые и отменённые из списка")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 16).padding(.bottom, 4)
    }
}
