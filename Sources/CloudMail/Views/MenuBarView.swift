import SwiftUI

/// Menu bar popover: active transfers (name, thin bar, percent), one line about the Mac copy,
/// a small drop target, «Тихий режим» and «Открыть окно».
struct MenuBarView: View {
    @EnvironmentObject var manager: UploadManager
    @EnvironmentObject var status: CloudStatus
    @State private var targeted = false

    private var active: [UploadJob] {
        // Running first, then paused, then the next queued ones (the queue runs from the end).
        let running = manager.jobs.filter { $0.state == .running }
        let paused = manager.jobs.filter { $0.state == .paused }
        let queued = manager.jobs.filter { $0.state == .queued }.reversed()
        return Array((running + paused + queued).prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Передачи").font(.headline)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if active.isEmpty {
                Text(manager.jobs.isEmpty ? "Ничего не передаётся" : "Сейчас ничего не передаётся")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(active) { job in MenuBarJobRow(job: job) }
                }
            }
            if manager.activeCount > active.count {
                Text("и ещё \(manager.activeCount - active.count) в очереди")
                    .font(.caption).foregroundStyle(.secondary)
            }
            dropTarget
            Divider()
            if let issue = manager.setupIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                    Text(issue == .notConnected ? "Облако не подключено" : issue.message)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(issue == .noRclone ? "Скачать…" : "Подключить…") {
                        AppDelegate.shared?.resolveSetupIssue()
                    }
                    .controlSize(.small)
                }
            }
            if status.hasSupervisor {
                HStack(spacing: 8) {
                    BackupDot(state: status.backup)
                    Text(backupLine)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $manager.quietMode) {
                Label("Тихий режим", systemImage: manager.quietMode ? "tortoise.fill" : "tortoise")
            }
            .toggleStyle(.switch).controlSize(.small)
            .help("Не больше 2 МБ/с, для новых загрузок")
            Divider()
            HStack {
                Button("Открыть окно") {
                    AppDelegate.shared?.showWindow()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button {
                    manager.openInBrowser()
                } label: { Image(systemName: "safari") }
                .buttonStyle(PressableButtonStyle())
                .help("Открыть Облако в браузере")
                Button("Выйти") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
        .tint(.appTint)
    }

    private var dropTarget: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.up")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(targeted ? Color.appTint : .secondary)
            Text(targeted ? "Отпускай" : "Перетащи сюда, улетит в «\(manager.destinationFolder)»")
                .font(.caption).foregroundStyle(targeted ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(targeted ? AnyShapeStyle(Color.appTint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)))
        }
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(Motion.small, value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in manager.add(urls: await FileDrop.urls(from: providers)) }
            return true
        }
    }

    private var summary: String {
        let done = manager.jobs.filter { $0.state == .done }.count
        let failed = manager.jobs.filter { TransferBucket.natural($0.state) == .attention }.count
        var parts: [String] = []
        if manager.activeCount > 0 { parts.append("активных \(manager.activeCount)") }
        if failed > 0 { parts.append("внимание \(failed)") }
        if done > 0 { parts.append("готово \(done)") }
        return parts.joined(separator: " · ")
    }

    private var backupLine: String {
        switch status.backup {
        case .silent: return "Копия Мака: супервизор молчит"
        case .unknown: return "Копия Мака: проверяю"
        case .ok: return "Копия Мака: всё в Облаке"
        case .attention: return "Копия Мака: нужно внимание. " + (status.background ?? "")
        case .syncing: return status.background ?? "Копия Мака: выгружается"
        }
    }
}

private struct MenuBarJobRow: View {
    @EnvironmentObject var manager: UploadManager
    let job: UploadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: job.isDownload ? "arrow.down" : "arrow.up")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.appTint)
                Text(job.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(trailing)
                    .font(.caption).foregroundStyle(job.state == .paused ? .orange : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: job.fraction))
                    .animation(.smooth, value: job.fraction)
                if job.state == .running, !job.committing {
                    Button { manager.pause(job.id) } label: { Image(systemName: "pause.circle") }
                        .buttonStyle(PressableButtonStyle()).foregroundStyle(.secondary).help("Пауза")
                } else if job.state == .paused {
                    Button { manager.resume(job.id) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(PressableButtonStyle()).foregroundStyle(.secondary).help("Продолжить")
                }
            }
            if job.state != .queued {
                CapsuleProgress(value: job.fraction, indeterminate: job.state == .running && job.verifying,
                                tint: job.state == .paused ? .secondary : .appTint, height: 3)
            }
        }
    }

    private var trailing: String {
        switch job.state {
        case .queued:
            if manager.waitingForAccount { return "ждёт подключения к Облаку" }
            return job.waitingForNetwork || !manager.cloudReachable ? "ждёт связь" : "в очереди"
        case .paused: return "пауза, \(Fmt.percent(job.fraction))"
        default:
            if job.verifying { return "сверка" }
            return job.speed > 0 ? "\(Fmt.percent(job.fraction)) · \(Fmt.speed(job.speed))" : Fmt.percent(job.fraction)
        }
    }
}
