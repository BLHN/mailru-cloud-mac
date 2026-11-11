import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// «Облако»: a Finder-like list of the shown cloud folder. Header line with back, breadcrumb,
/// filter, refresh and the actions; columns «Имя», «Размер», «Изменён» (folders first);
/// a bottom bar describes the selection, with folder sizes counted lazily. The app never
/// deletes, renames or moves anything in the cloud, so no such actions are offered.
struct CloudBrowserView: View {
    @EnvironmentObject var model: CloudBrowserModel
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sortOrder = [KeyPathComparator(\CloudRow.name)]
    @State private var newFolderShown = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
            Divider()
            ZStack {
                content
                    .id(model.path)
                    .transition(slideTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { model.listFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in model.listFrame = f }
                }
            }
            if !model.selection.isEmpty {
                SelectionBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.small, value: model.selection.isEmpty)
        .background(shortcuts)
        .toolbar { actions }
        .onAppear { model.start(at: AppDelegate.devArgs.cloudPath) }
        .onChange(of: model.selection) { _, _ in model.selectionChanged() }
        .alert("Новая папка", isPresented: $newFolderShown) {
            TextField("Имя папки", text: $newFolderName)
            Button("Создать") { createFolder() }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("Появится в «\(model.crumbs.last?.title ?? "Облако")»")
        }
        .alert("Папку создать не вышло", isPresented: Binding(get: { newFolderError != nil },
                                                               set: { if !$0 { newFolderError = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(newFolderError ?? "")
        }
    }

    private var slideTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let forward = model.direction == .forward
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    /// Cmd+Up, Cmd+[ and Cmd+R, active while the section is shown.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.up() }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("") { model.back() }.keyboardShortcut("[", modifiers: .command)
            Button("") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!model.canGoBack)
            .help("Назад (⌘[)")
            .accessibilityLabel("Назад")

            Breadcrumb()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            SearchField(text: $model.filter, prompt: "Фильтр по имени")
                .frame(width: 168)

            Button { model.refresh() } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .opacity(model.refreshing ? 0 : 1)
                    if model.refreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    }
                }
                .frame(width: 24, height: 22)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Обновить (⌘R)")
            .accessibilityLabel("Обновить")
        }
    }

    /// The actions sit in the window's toolbar, on the right of the section title (like Finder's):
    /// the header line below keeps the room for the breadcrumb.
    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { uploadPicked(into: model.path) } label: {
                Label("Загрузить сюда", systemImage: "icloud.and.arrow.up")
            }
            .help("Загрузить сюда…")
            Button { askNewFolder() } label: {
                Label("Новая папка", systemImage: "folder.badge.plus")
            }
            .help("Новая папка…")
            Button { manager.openInBrowser(model.path) } label: {
                Label("Открыть в браузере", systemImage: "safari")
            }
            .help("Открыть в браузере")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { downloadSelection() } label: {
                Label("Скачать на Мак", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selection.isEmpty)
            .help("Скачать выбранное на Мак")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.load {
        case .loading:
            VStack(spacing: 0) {
                ShimmerRows()
                WaitCaption(wait: model.wait) { model.reload(background: false) }
                Spacer(minLength: 0)
            }
        case .failed(let message):
            CloudMessage(symbol: "exclamationmark.icloud", tint: .orange,
                         title: "Папку открыть не вышло", text: message,
                         action: ("Повторить", { model.reload(background: false) }), prominent: true)
        case .loaded:
            if model.entries.isEmpty {
                CloudMessage(symbol: "folder", tint: .secondary, title: "Папка пустая",
                             text: "Сюда можно перетащить файлы из Finder",
                             action: ("Загрузить сюда", { uploadPicked(into: model.path) }), prominent: false)
            } else if model.visibleEntries.isEmpty {
                CloudMessage(symbol: "magnifyingglass", tint: .secondary, title: "Ничего не нашлось",
                             text: "В этой папке нет имён с «\(model.filter)»",
                             action: ("Сбросить фильтр", { model.filter = "" }), prominent: false)
            } else {
                table
            }
        }
    }

    private var rows: [CloudRow] {
        let all = model.visibleEntries.map(CloudRow.init)
        let folders = all.filter(\.isDir).sorted(using: sortOrder)
        let files = all.filter { !$0.isDir }.sorted(using: sortOrder)
        return folders + files
    }

    private var table: some View {
        Table(of: CloudRow.self, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Имя", value: \.name) { r in
                NameCell(row: r, selected: model.selection.contains(r.id))
            }
            .width(min: 180, ideal: 360)
            TableColumn("Размер", value: \.sizeKey) { r in
                Text(r.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 130)
            .alignment(.numeric)
            TableColumn("Изменён", value: \.dateKey) { r in
                Text(r.dateText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170, max: 240)
        } rows: {
            ForEach(rows) { r in
                TableRow(r)
                    .dropDestination(for: URL.self) { urls in
                        // On a folder row: into that folder; on a file row: into the shown folder.
                        uploadDropped(urls, into: r.isDir ? model.fullPath(r.entry) : model.path)
                    }
            }
        }
        .tableStyle(.inset)
        // Plain area under the last row (striping down the empty space read as skeleton rows).
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            primary(ids)
        }
    }

    // MARK: Menus and actions

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        let picked = model.entries.filter { ids.contains($0.id) }
        if picked.count == 1, let e = picked.first, e.IsDir {
            Button("Открыть") { model.openEntry(e) }
            Divider()
        }
        if !picked.isEmpty {
            Button("Скачать на Мак…") { download(picked) }
        }
        let target = (picked.count == 1 && picked[0].IsDir) ? model.fullPath(picked[0]) : model.path
        let targetName = target.isEmpty ? "корень Облака" : (target as NSString).lastPathComponent
        Button(picked.count == 1 && picked[0].IsDir ? "Загрузить в «\(targetName)»…" : "Загрузить сюда…") {
            uploadPicked(into: target)
        }
        Button("Новая папка…") { askNewFolder() }
        Divider()
        Toggle("Загружать сюда по умолчанию", isOn: Binding(
            get: { manager.destinationFolder == target },
            set: { if $0 { manager.destinationFolder = target } }))
        Button("Открыть в браузере") { manager.openInBrowser(target) }
        if picked.count == 1, let e = picked.first {
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.fullPath(e), forType: .string)
            }
        }
        if picked.isEmpty {
            Divider()
            Button("Обновить") { model.refresh() }
        }
    }

    /// Double click or Return: a folder opens; files are offered for download.
    private func primary(_ ids: Set<String>) {
        let picked = model.entries.filter { ids.contains($0.id) }
        if picked.count == 1, let e = picked.first, e.IsDir {
            model.openEntry(e)
        } else if !picked.isEmpty, picked.allSatisfy({ !$0.IsDir }) {
            download(picked)
        }
    }

    private func downloadSelection() {
        download(model.visibleEntries.filter { model.selection.contains($0.id) })
    }

    private func download(_ items: [RcloneEntry]) {
        guard !items.isEmpty,
              let folder = model.askDownloadFolder(count: items.count, firstName: items[0].Name,
                                                   defaultFolder: manager.downloadFolder) else { return }
        CloudDownload.queue(items, from: model, to: folder, manager: manager, nav: nav, reduceMotion: reduceMotion)
    }

    private func uploadPicked(into folder: String) {
        let urls = FileDrop.pickFiles()
        guard !urls.isEmpty else { return }
        upload(urls, into: folder, from: CGPoint(x: model.listFrame.midX, y: model.listFrame.midY))
    }

    private func uploadDropped(_ urls: [URL], into folder: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        upload(files, into: folder, from: CGPoint(x: model.listFrame.midX, y: model.listFrame.midY))
    }

    /// Into `folder` without changing the saved default folder. `from` is a global point.
    private func upload(_ urls: [URL], into folder: String, from: CGPoint) {
        manager.add(urls: urls, folder: folder)
        let local = CGPoint(x: from.x - nav.flightLayerOrigin.x, y: from.y - nav.flightLayerOrigin.y)
        nav.flyToTransfers(symbol: "icloud.and.arrow.up", from: local, size: 40,
                           toast: "Загружается в «\(folder.isEmpty ? "корень Облака" : folder)»",
                           reduceMotion: reduceMotion)
    }

    private func askNewFolder() {
        newFolderName = "Новая папка"
        newFolderShown = true
    }

    private func createFolder() {
        let name = newFolderName
        Task { @MainActor in
            if let problem = await model.createFolder(name) { newFolderError = problem }
        }
    }
}

/// Queues downloads and plays signature 2 toward «Передачи»: the flight from the first selected
/// row, the badge bounce and the toast «Скачивается в Загрузки · Показать». In demo mode fake
/// queue entries are added instead (no rclone).
@MainActor
enum CloudDownload {
    static func queue(_ items: [RcloneEntry], from model: CloudBrowserModel, to folder: URL,
                      manager: UploadManager, nav: AppNavigation, reduceMotion: Bool) {
        let origin = model.flightOrigin(for: items.map(\.id))
        for e in items {
            let remote = model.fullPath(e)
            if manager.isDemo {
                var j = UploadJob(kind: .download, source: folder.appendingPathComponent(e.Name, isDirectory: e.IsDir),
                                  isDirectory: e.IsDir, destinationFolder: model.path)
                j.restoreRemotePath = remote
                j.totalBytes = e.IsDir ? (DevPromo.on ? DemoCloud.size(remote).bytes : 82_400_000_000) : max(0, e.Size ?? 0)
                withAnimation(Motion.layout) { manager.jobs.insert(j, at: 0) }
            } else {
                manager.download(remotePath: remote, isDirectory: e.IsDir, to: folder)
            }
        }
        AppLog.write("cloud: queued \(items.count) download(s) to \(folder.path)")
        let local = CGPoint(x: origin.x - nav.flightLayerOrigin.x, y: origin.y - nav.flightLayerOrigin.y)
        nav.flyToTransfers(symbol: "arrow.down.circle", from: local, size: 32,
                           toast: "Скачивается в \(LocalFolderName.display(folder.path))", reduceMotion: reduceMotion)
    }

    /// Dev `--dev-play download` in «Облако»: selects the first item, then queues it into the
    /// default download folder without a panel (demo: without rclone).
    static func devPlay(model: CloudBrowserModel, manager: UploadManager, nav: AppNavigation) {
        guard let first = model.visibleEntries.first else {
            AppLog.write("dev: --dev-play download: the cloud folder is empty")
            return
        }
        model.selection = [first.id]
        Task { @MainActor in
            // The promo holds the selection longer so «Скачать на Мак» reads before the flight.
            try? await Task.sleep(nanoseconds: DevPromo.on ? 1_600_000_000 : 600_000_000)
            queue([first], from: model, to: URL(fileURLWithPath: manager.downloadFolder, isDirectory: true),
                  manager: manager, nav: nav, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }
}

// MARK: - Rows

/// One table row: the entry plus comparable keys for the column sort.
struct CloudRow: Identifiable {
    let entry: RcloneEntry
    var id: String { entry.id }
    var isDir: Bool { entry.IsDir }
    var name: String { entry.Name }
    var sizeKey: Int64 { entry.IsDir ? -1 : (entry.Size ?? 0) }
    var dateKey: Date { modified ?? .distantPast }

    init(_ e: RcloneEntry) {
        entry = e
        // mail.ru gives folders no date (rclone reports 2000-01-01): leave the cell empty.
        let d = e.modDate
        modified = (d.map { $0.timeIntervalSince1970 > 946_771_200 } ?? false) ? d : nil
    }

    let modified: Date?

    var sizeText: String { entry.IsDir ? "" : Fmt.size(max(0, entry.Size ?? 0)) }
    var dateText: String { modified.map(CloudDates.string) ?? "" }
}

enum CloudDates {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// «Сегодня, 14:02», «Вчера, 17:54», «9 нояб. 2026 г., 17:54».
    static func string(_ d: Date) -> String { formatter.string(from: d) }
}

private struct NameCell: View {
    @EnvironmentObject var model: CloudBrowserModel
    let row: CloudRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: FileIcons.icon(for: URL(fileURLWithPath: "/.cloudmail-icons/" + row.name), isDirectory: row.isDir))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text(row.name)
                .lineLimit(1).truncationMode(.middle)
        }
        .help(model.fullPath(row.entry))
        .background {
            if selected {
                GeometryReader { g in
                    Color.clear
                        .onAppear { model.rowFrames[row.id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in model.rowFrames[row.id] = f }
                        .onDisappear { model.rowFrames[row.id] = nil }
                }
            }
        }
    }
}

// MARK: - Header pieces

/// «Облако › Mac › Movies»: every part opens its folder; the last one is the shown folder.
/// Long paths keep the root and the last two parts, the rest is in a «…» menu.
private struct Breadcrumb: View {
    typealias Crumb = (title: String, path: String)
    @EnvironmentObject var model: CloudBrowserModel

    var body: some View {
        let crumbs = model.crumbs
        let all: [Crumb?] = crumbs.map { Optional($0) }
        ViewThatFits(in: .horizontal) {
            line(all)
            if crumbs.count > 3 {
                line([all[0], nil] + Array(all.suffix(2)), hidden: Array(crumbs.dropFirst().dropLast(2)))
            }
            if crumbs.count > 1 {
                line([nil, all[all.count - 1]], hidden: Array(crumbs.dropLast()))
            }
        }
        .id(model.path)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: model.path)
    }

    private func line(_ parts: [(title: String, path: String)?], hidden: [(title: String, path: String)] = []) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if let part, i == parts.count - 1 {
                    HStack(spacing: 4) {
                        if part.path.isEmpty { Image(systemName: "cloud").font(.system(size: 12, weight: .medium)) }
                        Text(part.title).lineLimit(1)
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .help(part.path.isEmpty ? "Корень Облака" : part.path)
                } else if let part {
                    crumb(part)
                } else {
                    Menu {
                        ForEach(hidden, id: \.path) { h in
                            Button(h.title) { model.open(h.path, direction: .back) }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
    }

    private func crumb(_ part: (title: String, path: String)) -> some View {
        Button { model.open(part.path, direction: .back) } label: {
            HStack(spacing: 4) {
                if part.path.isEmpty {
                    Image(systemName: "cloud").font(.system(size: 12, weight: .medium))
                }
                Text(part.title).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3).padding(.vertical, 2)
        }
        .buttonStyle(PressableButtonStyle())
        .help(part.path.isEmpty ? "Корень Облака" : part.path)
    }
}

/// The native search field (clear button, magnifier) for the filter.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.sendsSearchStringImmediately = true
        f.controlSize = .regular
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

// MARK: - States

/// Loading: placeholder rows with a soft shimmer (a staggered opacity wave; still with reduce
/// motion), not a lone spinner.
private struct ShimmerRows: View {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let widths: [CGFloat] = [180, 120, 220, 150, 260, 140, 200, 110, 240, 170, 130, 210]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Имя"); Spacer(); Text("Размер").frame(width: 90, alignment: .trailing)
                Text("Изменён").frame(width: 170, alignment: .leading).padding(.leading, 16)
            }
            .font(.subheadline).foregroundStyle(.tertiary)
            .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 6)
            ForEach(Array(widths.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 3).frame(width: w, height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).frame(width: 52, height: 10)
                        .frame(width: 90, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 3).frame(width: 118, height: 10)
                        .frame(width: 170, alignment: .leading).padding(.leading, 16)
                }
                .foregroundStyle(.quaternary)
                .frame(height: 24)
                .padding(.horizontal, 22)
                // The looping animation is scoped to the opacity only: applied to the whole row it
                // also caught the rows' first layout and kept their positions swinging forever.
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(i) * 0.07)) {
                    $0.opacity(reduceMotion ? 0.8 : (phase ? 1 : 0.45))
                }
            }
        }
        .onAppear { phase = true }
        .accessibilityElement()
        .accessibilityLabel("Загружаю список")
    }
}

/// Under the placeholder rows while a listing takes long: a quiet caption after 3 s, after 12 s a
/// second wording with «Повторить». The space is always reserved, so nothing jumps when it fades in.
private struct WaitCaption: View {
    let wait: CloudBrowserModel.Wait
    let retry: () -> Void

    var body: some View {
        ZStack {
            switch wait {
            case .none:
                EmptyView()
            case .slow:
                Text("Облако отвечает медленно, жду ответ")
                    .font(.callout).foregroundStyle(.secondary)
                    .transition(.opacity)
            case .verySlow:
                HStack(spacing: 10) {
                    Text("Всё ещё жду Облако")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Повторить", action: retry)
                        .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .animation(.easeInOut(duration: 0.35), value: wait)
    }
}

/// Empty folder, nothing filtered, listing error.
private struct CloudMessage: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    let action: (String, () -> Void)
    let prominent: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .padding(.bottom, 2)
            Text(title).font(.title3.weight(.medium))
            Text(text)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            if prominent {
                Button(action.0, action: action.1).padding(.top, 4)
            } else {
                Button(action.0, action: action.1).buttonStyle(.link).padding(.top, 2)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Selection bar

/// «<name>» or «Выбрано: N», the kind, and the size (folders: counted by `rclone size`, with a
/// small spinner meanwhile).
private struct SelectionBar: View {
    @EnvironmentObject var model: CloudBrowserModel

    var body: some View {
        let picked = model.selectedEntries
        HStack(spacing: 10) {
            if picked.count == 1, let e = picked.first {
                Image(nsImage: FileIcons.icon(for: URL(fileURLWithPath: "/.cloudmail-icons/" + e.Name), isDirectory: e.IsDir))
                    .resizable().interpolation(.high)
                    .frame(width: 16, height: 16)
                Text("«\(e.Name)»").lineLimit(1).truncationMode(.middle)
                    .font(.callout.weight(.medium))
            } else {
                Text("Выбрано: \(picked.count)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(picked.count)))
            }
            Text(kind(picked)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            sizeView(picked)
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.smooth, value: picked.count)
    }

    private func kind(_ picked: [RcloneEntry]) -> String {
        let folders = picked.filter(\.IsDir).count
        let files = picked.count - folders
        if picked.count == 1, let e = picked.first {
            if e.IsDir { return "папка" }
            let ext = (e.Name as NSString).pathExtension
            if !ext.isEmpty, let t = UTType(filenameExtension: ext), let d = t.localizedDescription { return d }
            return "файл"
        }
        var parts: [String] = []
        if folders > 0 { parts.append(Plural.folders(folders)) }
        if files > 0 { parts.append(Fmt.files(files)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private func sizeView(_ picked: [RcloneEntry]) -> some View {
        let folders = picked.filter(\.IsDir).map(model.fullPath)
        let states = folders.map { model.sizes[$0] }
        let fileBytes = picked.filter { !$0.IsDir }.reduce(Int64(0)) { $0 + max(0, $1.Size ?? 0) }
        let fileCount = Int64(picked.filter { !$0.IsDir }.count)
        if states.contains(where: { $0 == nil || $0 == .counting }) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("считаю размер").font(.callout).foregroundStyle(.secondary)
            }
            .transition(.opacity)
        } else if let failure = states.compactMap({ s -> String? in if case .failed(let m) = s { return m }; return nil }).first {
            Text("размер не узнать").font(.callout).foregroundStyle(.secondary)
                .help(failure)
        } else {
            let counted = states.reduce((count: fileCount, bytes: fileBytes)) { acc, s in
                if case .done(let c, let b) = s { return (acc.count + c, acc.bytes + b) }
                return acc
            }
            Group {
                if folders.isEmpty {
                    Text(Fmt.size(counted.bytes))
                } else {
                    Text("\(Plural.filesGrouped(counted.count)) · \(Fmt.size(counted.bytes))")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .transition(.opacity)
        }
    }
}

enum Plural {
    private static func form(_ n: Int64, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    static func grouped(_ n: Int64) -> String { grouping.string(from: NSNumber(value: n)) ?? "\(n)" }

    /// «40 779 файлов».
    static func filesGrouped(_ n: Int64) -> String { "\(grouped(n)) \(form(n, "файл", "файла", "файлов"))" }

    static func folders(_ n: Int) -> String { "\(n) \(form(Int64(n), "папка", "папки", "папок"))" }

    /// «остался 1 файл», «осталось 214 файлов».
    static func filesLeft(_ n: Int) -> String {
        "\(form(Int64(n), "остался", "осталось", "осталось")) \(grouped(Int64(n))) \(form(Int64(n), "файл", "файла", "файлов"))"
    }
}
