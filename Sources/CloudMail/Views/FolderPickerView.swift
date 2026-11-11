import SwiftUI

/// Lazy folder tree of the cloud: children are listed with `rclone lsjson --dirs-only` on expand.
struct FolderPickerView: View {
    @EnvironmentObject var manager: UploadManager
    @Environment(\.dismiss) private var dismiss
    @State var selected: String
    let onPick: (String) -> Void

    @State private var newFolderName = ""
    @State private var message: String?
    @State private var reloadToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Куда загружать").font(.title2.weight(.semibold))
            Text("Выбрана: \(selected)").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    FolderNodeView(path: "", name: "Облако (корень)", selected: $selected, reloadToken: reloadToken, startExpanded: true)
                }
                .padding(6)
            }
            .frame(minHeight: 260)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                TextField("Новая папка внутри выбранной", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createFolder)
                Button("Создать", action: createFolder).disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let m = message { Text(m).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Открыть в браузере") { manager.openInBrowser(selected) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Выбрать") { onPick(selected); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { message = "Имя без слэшей, пожалуйста"; return }
        let path = selected.isEmpty ? name : "\(selected)/\(name)"
        Task {
            do {
                try await Rclone.mkdir(path)
                selected = path
                newFolderName = ""
                message = nil
                reloadToken += 1
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct FolderNodeView: View {
    let path: String
    let name: String
    @Binding var selected: String
    var reloadToken: Int
    var startExpanded = false

    @State private var expanded = false
    @State private var children: [RcloneEntry]?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "folder.fill" : "folder").foregroundStyle(.blue)
                    Text(name).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(selected == path ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { selected = path }
                .onTapGesture(count: 2) { expanded = true }
            }
            if expanded {
                Group {
                    if loading {
                        ProgressView().controlSize(.small).padding(.leading, 24)
                    } else if let e = error {
                        Text(e).font(.caption).foregroundStyle(.orange).padding(.leading, 24)
                    } else if let c = children {
                        if c.isEmpty {
                            Text("нет подпапок").font(.caption).foregroundStyle(.tertiary).padding(.leading, 24)
                        }
                        ForEach(c) { entry in
                            FolderNodeView(path: entry.Path.isEmpty ? entry.Name : fullPath(entry.Name),
                                           name: entry.Name, selected: $selected, reloadToken: reloadToken)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
        .onAppear { if startExpanded { expanded = true } }
        .onChange(of: expanded) { _, on in if on && children == nil { load() } }
        .onChange(of: reloadToken) { _, _ in if expanded { load() } }
        .task(id: expanded) { if expanded && children == nil && !loading { load() } }
    }

    private func fullPath(_ child: String) -> String { path.isEmpty ? child : "\(path)/\(child)" }

    private func load() {
        loading = true; error = nil
        Task {
            do {
                children = try await Rclone.listFolders(path)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
