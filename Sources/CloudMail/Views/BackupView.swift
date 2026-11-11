import SwiftUI
import AppKit

/// «Копия Мака»: read-only view of the background supervisor (cloudsup_status.json). A summary
/// sentence on top, the alerts, one row per protected folder with the files being sent under it.
/// No pause, add-folder or edit controls in this version.
struct BackupView: View {
    @EnvironmentObject var monitor: BackupMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let snap = monitor.snapshot {
                summary(snap)
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
                Divider()
                list(snap)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: Summary

    private enum Mood { case ok, syncing, attention, silent, waiting }

    private func mood(_ snap: BackupMonitor.Snapshot) -> Mood {
        guard let st = snap.status, !snap.isStale else { return .silent }
        if st.state == "standby" || st.state == "paused" || st.state == "network_down" { return .waiting }
        switch st.backupState {
        case .syncing: return .syncing
        case .attention: return .attention
        default: return .ok
        }
    }

    private func headline(_ snap: BackupMonitor.Snapshot) -> String {
        guard let st = snap.status, !snap.isStale else {
            guard snap.exists, let m = snap.modified else { return "Супервизор молчит" }
            return "Супервизор молчит с \(BackupDates.time(m))"
        }
        switch mood(snap) {
        case .waiting:
            switch st.state {
            case "network_down": return "Ждёт сеть"
            case "paused": return "Копия на паузе"
            default: return "Супервизор в режиме ожидания"
            }
        case .syncing:
            let left = st.filesLeft
            return left > 0 ? "Выгружается: \(Plural.filesLeft(left))" : "Выгружается: сверяю список"
        case .attention: return "Нужно внимание"
        default: return "Всё в Облаке"
        }
    }

    private func symbol(_ m: Mood) -> (String, Color) {
        switch m {
        case .ok: return ("checkmark.shield.fill", .green)
        case .syncing: return ("checkmark.shield", .appTint)
        case .attention: return ("exclamationmark.shield.fill", .orange)
        case .silent: return ("shield.slash", .secondary)
        case .waiting: return ("shield", .secondary)
        }
    }

    private func caption(_ snap: BackupMonitor.Snapshot) -> String {
        var parts: [String] = []
        guard let st = snap.status else {
            return snap.exists ? "Файл состояния не читается" : "Файла состояния нет: фоновая выгрузка не запущена"
        }
        if let d = st.lastComplete { parts.append("последняя сверка \(BackupDates.relative(d))") }
        if !snap.isStale, st.isBusy, let v = st.link_mibps, v > 0 { parts.append(Fmt.speed(v * 1_048_576)) }
        if let e = st.last_event, !e.isEmpty { parts.append("последнее событие: \(SupervisorEventText.russian(e))") }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func summary(_ snap: BackupMonitor.Snapshot) -> some View {
        let m = mood(snap)
        let (name, tint) = symbol(m)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: name)
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: m == .syncing && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(snap))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(caption(snap))
                    .font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .animation(.smooth, value: headline(snap))
            Spacer(minLength: 0)
        }
    }

    // MARK: List

    private func list(_ snap: BackupMonitor.Snapshot) -> some View {
        let st = snap.status
        let jobs = st?.jobs ?? []
        let alerts = (st?.alerts ?? []).filter { !$0.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !alerts.isEmpty {
                    AlertsBlock(alerts: alerts)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
                if !jobs.isEmpty {
                    sectionHeader("Папки", count: jobs.count)
                    ForEach(Array(jobs.enumerated()), id: \.element.name) { i, job in
                        VStack(spacing: 0) {
                            if i > 0 { Divider().padding(.leading, 64).padding(.trailing, 10) }
                            BackupJobRow(job: job,
                                         workers: (st?.workers ?? []).filter { $0.job == job.name },
                                         unmounted: snap.unmounted.contains(job.name ?? job.src ?? ""),
                                         stale: snap.isStale)
                        }
                    }
                } else if st != nil {
                    Text("Супервизор не следит ни за одной папкой")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Motion.layout, value: alerts)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 16).padding(.bottom, 4)
    }
}

/// The supervisor's alerts in an orange «Нужно внимание» block.
private struct AlertsBlock: View {
    let alerts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Нужно внимание", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(alerts, id: \.self) { a in
                Text(a)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
    }
}

/// One protected folder: icon, name, local path, state; while it uploads a progress bar with the
/// files left, and indented under it the files being sent with their speeds.
private struct BackupJobRow: View {
    let job: SupervisorStatus.Job
    let workers: [SupervisorStatus.Worker]
    let unmounted: Bool
    let stale: Bool

    private var running: Bool { !stale && job.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(displayPath)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(job.src ?? "")
                    if running, (job.big_total ?? 0) > 0 || job.phase == "listing" {
                        CapsuleProgress(value: fraction, indeterminate: job.phase == "listing")
                            .padding(.vertical, 2)
                            .frame(maxWidth: 520)
                    }
                    if let d = detail {
                        Text(d)
                            .font(.callout).foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                stateView
            }
            if running {
                ForEach(Array(workers.enumerated()), id: \.offset) { _, w in
                    WorkerLine(worker: w)
                }
                if let sm = job.small, sm.state == "running" {
                    smallLine(sm)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .opacity(unmounted ? 0.5 : 1)
        .animation(.smooth, value: job.big_done)
    }

    private var icon: some View {
        Image(nsImage: folderIcon)
            .resizable().interpolation(.high)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }

    private var folderIcon: NSImage {
        guard let src = job.src else { return NSWorkspace.shared.icon(for: .folder) }
        if FileManager.default.fileExists(atPath: src) { return FileIcons.icon(for: URL(fileURLWithPath: src), isDirectory: true) }
        if SupervisorStatus.volumeRoot(of: src) != nil {
            return NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSWorkspace.shared.icon(for: .folder)
        }
        return NSWorkspace.shared.icon(for: .folder)
    }

    /// Standard home folders get their localized Finder name («Фильмы», «Документы»); a job
    /// with its own name or any other folder keeps the supervisor's name.
    private var title: String {
        let name = job.name ?? "Без имени"
        guard let src = job.src else { return name }
        let url = URL(fileURLWithPath: src).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard url.deletingLastPathComponent().path == home.path,
              job.name == nil || job.name == url.lastPathComponent else { return name }
        let shown = FileManager.default.displayName(atPath: url.path)
        return shown.isEmpty ? name : shown
    }

    private var displayPath: String {
        guard let src = job.src else { return "" }
        return (src as NSString).abbreviatingWithTildeInPath
    }

    private var fraction: Double {
        guard let t = job.big_total, t > 0 else { return 0 }
        return Double(job.big_done ?? 0) / Double(t)
    }

    /// Second line while uploading: files left and bytes.
    private var detail: String? {
        guard running else { return nil }
        if job.phase == "listing" { return "Сверяю, что уже есть в Облаке…" }
        var parts: [String] = []
        if let left = job.files_left, left > 0 { parts.append(Plural.filesLeft(left)) }
        if let t = job.big_total, t > 0 { parts.append("\(Fmt.size(job.big_done ?? 0)) из \(Fmt.size(t))") }
        if let p = job.probing, p > 0 { parts.append("ждёт ответа сервера: \(p)") }
        if let parked = job.parked, !parked.isEmpty { parts.append("отложено: \(parked.count)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var stateView: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch state.kind {
            case .ok:
                Label(state.text, systemImage: "checkmark.circle.fill")
                    .labelStyle(TrailingIconLabel(tint: .green))
            case .busy:
                Text(state.text).foregroundStyle(Color.appTint)
                if let v = speed { Text(v).font(.callout).foregroundStyle(.secondary).monospacedDigit().contentTransition(.numericText()) }
            case .waiting:
                Text(state.text).foregroundStyle(.secondary)
            case .error:
                Label(state.text, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(TrailingIconLabel(tint: .orange))
            }
        }
        .font(.callout)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 260, alignment: .trailing)
        .help(job.note ?? "")
    }

    private var speed: String? {
        let total = workers.reduce(0.0) { $0 + ($1.mibps ?? 0) } + (job.small?.state == "running" ? (job.small?.mibps ?? 0) : 0)
        return total > 0 ? Fmt.speed(total * 1_048_576) : nil
    }

    private enum Kind { case ok, busy, waiting, error }

    private var state: (kind: Kind, text: String) {
        if unmounted { return (.waiting, "диск не подключён") }
        switch job.phase ?? "" {
        case "running": return stale ? (.waiting, "выгружалась") : (.busy, "выгружается")
        case "listing": return stale ? (.waiting, "сверялась") : (.busy, "сверяется")
        case "waiting_mount": return (.waiting, "ждёт диск")
        case "blocked": return (.waiting, "ждёт: туда же пишет другой rclone")
        case "error", "failed":
            let note = (job.note ?? "").trimmingCharacters(in: .whitespaces)
            return (.error, note.isEmpty ? "ошибка" : "ошибка: \(note)")
        default:
            if job.small?.state == "running" && !stale { return (.busy, "выгружается") }
            if let d = SupervisorStatus.date(job.last_complete) {
                return (.ok, "в Облаке, сверено \(BackupDates.relative(d))")
            }
            return (.waiting, "ещё не сверялась")
        }
    }

    private func smallLine(_ sm: SupervisorStatus.Small) -> some View {
        var parts: [String] = []
        if let x = sm.xfr, !x.isEmpty {
            let nums = x.split(separator: "/").compactMap { Int64($0) }
            parts.append(nums.count == 2 ? "\(Plural.grouped(nums[0])) из \(Plural.filesGrouped(nums[1]))" : x)
        }
        return HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 16)
            Text("Мелкие файлы" + (parts.isEmpty ? "" : ": " + parts.joined(separator: " · ")))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let v = sm.mibps, v > 0 {
                Text(Fmt.speed(v * 1_048_576)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .font(.callout)
        .padding(.leading, 44)
    }
}

/// One file the supervisor is sending: name, how much of it, speed.
private struct WorkerLine: View {
    let worker: SupervisorStatus.Worker

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcons.icon(for: URL(fileURLWithPath: "/.cloudmail-icons/" + ((worker.file ?? "") as NSString).lastPathComponent),
                                          isDirectory: false))
                .resizable().interpolation(.high)
                .frame(width: 16, height: 16)
            Text(worker.file ?? "?")
                .lineLimit(1).truncationMode(.middle)
                .help(worker.file ?? "")
            Spacer(minLength: 8)
            Text(progress)
                .foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
            Text(worker.phase == "final" ? "дописывается" : Fmt.speed((worker.mibps ?? 0) * 1_048_576))
                .foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 76, alignment: .trailing)
        }
        .font(.callout)
        .padding(.leading, 44)
    }

    private var progress: String {
        guard let size = worker.size, size > 0 else { return "" }
        var s = "\(Fmt.size(worker.bytes ?? 0)) из \(Fmt.size(size))"
        if let a = worker.attempt, a > 1 { s += " · попытка \(a)" }
        return s
    }
}

/// Text first, symbol after it (trailing column of a row).
private struct TrailingIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.foregroundStyle(tint)
        }
    }
}

enum BackupDates {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
        return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    /// «сегодня в 02:10», «вчера в 17:54», «7 ноября в 18:04».
    static func relative(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let t = time(d)
        if cal.isDate(d, inSameDayAs: now) { return "сегодня в \(t)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "вчера в \(t)" }
        return "\(dayFormatter.string(from: d)) в \(t)"
    }
}

/// The supervisor writes its events in English ("20:11:12 network back after 60 s"). The known
/// shapes are shown in Russian; anything unrecognised is shown as written.
enum SupervisorEventText {
    private typealias Rule = (pattern: String, render: ([String]) -> String)

    private static func gb(_ s: String) -> String { s.replacingOccurrences(of: ".", with: ",") + " ГБ" }

    private static let rules: [Rule] = [
        (#"^network back after (\d+) s$"#, { "сеть вернулась через \($0[1]) с" }),
        (#"^network down \(cannot reach (.+)\)$"#, { "нет сети, \($0[1]) не отвечает" }),
        (#"^(.+?): foreign rclone pid \d+ writes to the same destination, waiting$"#,
         { "\($0[1]): туда же пишет другой rclone, жду" }),
        (#"^(.+?): cycle start \((full|incremental)\)$"#,
         { "\($0[1]): начат \($0[2] == "full" ? "полный" : "быстрый") проход" }),
        (#"^(.+?): prep failed: (.+)$"#, { "\($0[1]): подготовка не удалась: \($0[2])" }),
        (#"^(.+?): worklist (\d+) big files, ([\d.]+) GiB$"#,
         { "\($0[1]): в списке \(Fmt.files(Int($0[2]) ?? 0)), \(gb($0[3]))" }),
        (#"^(.+?): small lane started pid \d+$"#, { "\($0[1]): пошли мелкие файлы" }),
        (#"^(.+?): start (.+) \(([\d.]+) GiB\) attempt (\d+)$"#,
         { "\($0[1]): отправляю «\($0[2])», \(gb($0[3])), попытка \($0[4])" }),
        (#"^(.+?): PARKED (.+?): (.+)$"#, { "\($0[1]): «\($0[2])» отложен: \($0[3])" }),
        (#"^(.+?): killed (.+?): (.+)$"#, { "\($0[1]): «\($0[2])» остановлен: \($0[3])" }),
        (#"^(.+?): (.+) not mounted, (.+) waits$"#, { "\($0[1]): диск \($0[2]) не подключён, «\($0[3])» ждёт" }),
        (#"^(.+?): (.+) vanished locally, dropped until next cycle$"#,
         { "\($0[1]): «\($0[2])» пропал с Мака, до следующего прохода" }),
        (#"^(.+?): (.+) changed size locally \(.*\), next cycle$"#,
         { "\($0[1]): «\($0[2])» изменился на Маке, в следующий проход" }),
        (#"^(.+?): late failure (.+?) \(.*$"#, { "\($0[1]): «\($0[2])» проверяется в Облаке без повторной отправки" }),
        (#"^(.+?): (.+) network error, no attempt counted$"#,
         { "\($0[1]): «\($0[2])» сбой сети, попытка не засчитана" }),
        (#"^(.+?): throttled \(429\), global pause (\d+) s$"#,
         { "\($0[1]): Облако просит притормозить, пауза \($0[2]) с" }),
        (#"^(.+?): (.+) failed rc=(\S+): .*$"#, { "\($0[1]): «\($0[2])» не отправился (код \($0[3]))" }),
        (#"^(.+?): (.+) verified \(.*\)$"#, { "\($0[1]): «\($0[2])» сверен с Облаком" }),
        (#"^(.+?): (.+) RECOVERED after (\d+) s probe.*$"#,
         { "\($0[1]): «\($0[2])» нашёлся в Облаке, повторно не отправляется" }),
        (#"^(.+?): (.+) remote size \d+ != \d+ after rc 0$"#,
         { "\($0[1]): «\($0[2])» в Облаке другого размера, отправится снова" }),
        (#"^(.+?): (.+) did not land within the probe window, will re-send$"#,
         { "\($0[1]): «\($0[2])» не появился в Облаке, отправится снова" }),
        (#"^(.+?): small lane done$"#, { "\($0[1]): мелкие файлы выгружены" }),
        (#"^(.+?): small lane ended \(.*\), retry in (\d+) s$"#,
         { "\($0[1]): мелкие файлы прервались, повтор через \($0[2]) с" }),
        (#"^(.+?): cycle complete \((\d+) big files, ([\d.]+) GiB; (full|incremental)\)$"#,
         { "\($0[1]): проход завершён, \(Fmt.files(Int($0[2]) ?? 0)), \(gb($0[3]))" }),
        (#"^(.+?): retrying parked (.+)$"#, { "\($0[1]): снова пробую «\($0[2])»" }),
        (#"^time gap (\d+) s.*$"#, { "перерыв \($0[1]) с (Мак спал), счётчики скорости сброшены" }),
        (#"^memory low \((\d+) %\).*$"#, { "мало памяти (\($0[1]) %), новые выгрузки не запускаются" }),
        (#"^memory recovered \((\d+) %\)$"#, { "память в норме (\($0[1]) %)" }),
        (#"^DRAIN requested.*$"#, { _ in "супервизор дописывает начатое перед обновлением" }),
        (#"^DRAIN complete.*$"#, { _ in "супервизор перезапускается после обновления" }),
        (#"^ALL-SLOW.*$"#, { _ in "медленно идут все потоки, дело в сети или сервере" }),
    ]

    private static let compiled: [(NSRegularExpression, ([String]) -> String)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern)).map { ($0, r.render) }
    }

    static func russian(_ event: String) -> String {
        // An optional leading "HH:MM:SS " stamp is shown as «в HH:MM: …» (no seconds).
        var time = ""
        var text = event
        if let m = event.range(of: #"^\d{1,2}:\d{2}(:\d{2})? "#, options: .regularExpression) {
            let hm = event[m].trimmingCharacters(in: .whitespaces).split(separator: ":").prefix(2)
            time = "в " + hm.joined(separator: ":") + ": "
            text = String(event[m.upperBound...])
        }
        let ns = text as NSString
        for (re, render) in compiled {
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            return time + render(groups)
        }
        return time + text
    }
}
