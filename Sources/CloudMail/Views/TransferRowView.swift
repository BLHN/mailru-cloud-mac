import SwiftUI

/// One queue entry in «Передачи»: real Finder icon with a direction badge, name, route line,
/// capsule progress, trailing stats that cross-fade into the actions on hover. Every state, note,
/// phase and action the queue knows is reachable here (the actions also via the context menu).
struct TransferRowView: View {
    @EnvironmentObject var manager: UploadManager
    let job: UploadJob
    /// Just finished and still shown in «Сейчас»: the bar completes and fades out.
    var held = false
    var bounce = 0
    var shake = 0
    var forcedHover = false

    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHovered: Bool { hover || forcedHover }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(job.source.path)
                routeLine
                if showsBar {
                    CapsuleProgress(value: barValue, indeterminate: job.state == .running && job.verifying,
                                    tint: job.state == .paused ? Color.secondary : Color.appTint)
                        .opacity(job.state == .done ? 0 : 1)
                        .animation(.easeOut(duration: 0.4).delay(0.5), value: job.state == .done)
                        .padding(.vertical, 2)
                        .frame(maxWidth: 520)
                }
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        // Resolve the row's position and size as one unit: without this the layout spring is
        // pushed down to each leaf, and the ticking numbers' own `.animation(value:)` overrides it,
        // so their lines drift over neighbouring rows while rows shift.
        .geometryGroup()
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(isHovered ? 0.45 : 0))
        }
        .contentShape(Rectangle())
        .onHover { h in
            // Instant in, 0.15 s out.
            if h { hover = true } else { withAnimation(Motion.hoverOut) { hover = false } }
        }
        .contextMenu { menuItems }
    }

    // MARK: Icon

    private var icon: some View {
        Image(nsImage: FileIcons.icon(for: job.source, isDirectory: job.isDirectory))
            .resizable()
            .interpolation(.high)
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: job.isDownload ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.appTint)
                    .font(.system(size: 13, weight: .semibold))
                    .background(Circle().fill(.white).padding(1))
                    .offset(x: 4, y: 3)
                    .help(directionHelp)
            }
            .modifier(ShakeOnChange(trigger: shake))
            .accessibilityHidden(true)
    }

    private var directionHelp: String {
        switch job.kind {
        case .copy: return "Загрузить в Облако"
        case .evict: return "Выгрузить и освободить место"
        case .restore: return "Вернуть на Мак"
        case .download: return "Скачать из Облака на Мак"
        }
    }

    // MARK: Route line

    /// «в Облако · Mac/Входящие» / «на Мак · Загрузки»; while running also the file count.
    private var routeLine: some View {
        var parts: [String] = []
        let help: String
        switch job.kind {
        case .copy:
            parts = ["в Облако", cloudFolderName]
            help = "В Облаке: \(job.remotePath)"
        case .evict:
            parts = ["в Облако", cloudFolderName, evictOriginalState.short]
            help = "В Облаке: \(job.remotePath). \(evictOriginalState.help)"
        case .restore, .download:
            let folder = job.source.deletingLastPathComponent()
            parts = ["на Мак", LocalFolderName.display(folder.path)]
            help = (job.restoreRemotePath.map { "Из Облака: \($0)\n" } ?? "") + "На Маке: \(job.source.path)"
        }
        if (job.state == .running || job.state == .paused), job.filesTotal > 1 {
            parts.append("\(job.filesDone) из \(Fmt.files(job.filesTotal))")
        }
        // The bar just stepped back: rclone began an unfinished file again from zero.
        if job.state == .running, job.fileRestartedAt != nil {
            parts.append("начал файл заново")
        }
        return Text(parts.joined(separator: " · "))
            .font(.callout).foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.smooth, value: job.filesDone)
            .lineLimit(1).truncationMode(.middle)
            .help(help)
    }

    private var cloudFolderName: String {
        job.destinationFolder.isEmpty ? "корень" : job.destinationFolder
    }

    /// Where the original of an evict row is now: it goes to the Trash only after a verified
    /// upload (state done); refused, failed and cancelled rows never touched it.
    private var evictOriginalState: (short: String, help: String) {
        if job.state.isActive {
            return ("оригинал потом в Корзину", "После проверки оригинал уйдёт в Корзину, на его месте останется ярлык-облако")
        }
        if job.state == .done {
            return ("оригинал в Корзине", "Оригинал в Корзине, пока её не очистить; на его месте ярлык-облако")
        }
        return ("оригинал на месте", "Оригинал не трогали: он лежит там же, где был")
    }

    // MARK: Progress

    private var showsBar: Bool {
        job.state == .running || job.state == .paused || (held && job.state == .done)
    }

    private var barValue: Double { job.state == .done ? 1 : job.fraction }

    // MARK: Details

    @ViewBuilder private var details: some View {
        if job.state == .running || job.state == .paused {
            if job.state == .running, job.verifying {
                caption("Проверяю, что уже есть в Облаке…")
            } else {
                HStack(spacing: 6) {
                    Text(bytesLine)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth, value: job.bytes)
                    if job.quiet {
                        Label("тихий режим", systemImage: "tortoise")
                            .help("Скорость ограничена 2 МБ/с")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            // A queued row has a phase only while it waits for the cloud to finish a big file.
            if job.state == .running || job.state == .queued, let p = job.phase {
                caption(p)
            }
            if job.state == .running, let f = job.currentFile {
                Text(f).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        switch job.state {
        case .failed(let m):
            Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .blocked(let m), .refused(let m):
            Text(m).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
        // Notes of evict / restore rows stay after "done" (external disk, placeholder left over).
        if let n = job.note, job.state != .done || job.kind != .copy {
            Label(n, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if job.state == .done { doneText }
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }

    private var bytesLine: String {
        var s = "\(Fmt.size(job.bytes)) из \(Fmt.size(job.totalBytes))"
        if job.state == .running, let e = job.eta, e.isFinite, e >= 1 { s += " · осталось \(Fmt.eta(job.eta))" }
        return s
    }

    @ViewBuilder private var doneText: some View {
        switch job.kind {
        case .copy:
            caption("Загружено \(Fmt.size(job.totalBytes))\(durationText)")
        case .evict:
            caption("Загружено \(Fmt.size(job.totalBytes))\(durationText) · сверено с Облаком")
            Label("место освобождено, ярлык оставлен", systemImage: "icloud.fill")
                .font(.caption).foregroundStyle(Color.appTint)
                .help(job.placeholderPath.map { "Ярлык: \($0). Оригинал в Корзине, пока её не очистить." } ?? "")
            if let r = restoreOfThis, r.state == .done {
                caption("Уже возвращено на Мак")
            } else if let r = restoreOfThis, r.state.isActive {
                caption("Возвращается на Мак…")
            }
        case .restore:
            caption("Вернулось на Мак: \(Fmt.size(job.totalBytes))\(durationText) · сверено с Облаком")
        case .download:
            caption(job.isDirectory
                    ? "Скачано: \(Fmt.files(job.expectedFiles ?? job.filesTotal)), \(Fmt.size(job.totalBytes)) · сверено с Облаком"
                    : "Скачано: \(Fmt.size(job.totalBytes)) · сверено с Облаком")
        }
    }

    /// The restore entry started from this evict row's placeholder, if any.
    private var restoreOfThis: UploadJob? {
        guard job.kind == .evict, let ph = job.placeholderPath else { return nil }
        return manager.restoreJob(forPlaceholder: ph)
    }

    /// "Вернуть на Мак" is offered while no restore of this placeholder is running or finished.
    private var canRestore: Bool {
        guard job.kind == .evict, job.state == .done, job.placeholderPath != nil else { return false }
        guard let r = restoreOfThis else { return true }
        return !r.state.isActive && r.state != .done
    }

    private var canReveal: Bool {
        job.state == .done && job.kind != .evict
    }

    /// Total run time over all runs (pause, relaunch and retry gaps excluded). Entries saved
    /// before `activeSeconds` existed fall back to the span of their last run.
    private var durationText: String {
        var t = job.activeSeconds
        if t <= 0, let s = job.startedAt, let f = job.finishedAt { t = f.timeIntervalSince(s) }
        guard t >= 1 else { return "" }
        return " за \(Fmt.eta(t))"
    }

    // MARK: Trailing: stats or actions

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .trailing) {
                status
                    .opacity(isHovered ? 0 : 1)
                actions
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
            // Rows that need the user keep their one resolving action visible at rest.
            primaryButton
        }
        .frame(minWidth: 96, alignment: .trailing)
        .animation(isHovered ? .easeOut(duration: 0.1) : Motion.hoverOut, value: isHovered)
    }

    @ViewBuilder private var primaryButton: some View {
        switch job.state {
        case .failed, .cancelled:
            Button("Повторить") { manager.retry(job.id) }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
        case .blocked:
            Button("Всё равно") { manager.retry(job.id, force: true) }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .help("Загрузить, хотя другая программа (rclone) уже выгружает эту папку")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .running:
            VStack(alignment: .trailing, spacing: 2) {
                if job.verifying {
                    Text("сверка").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(Fmt.percent(job.fraction))
                        .font(.body.weight(.medium)).monospacedDigit()
                        .contentTransition(.numericText(value: job.fraction))
                        .animation(.smooth, value: job.fraction)
                }
                Text(job.speed > 0 ? Fmt.speed(job.speed)
                     : job.restarting ? "перезапускаю" : (job.isDownload ? "скачивается" : "загружается"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: job.speed)
            }
        case .paused:
            VStack(alignment: .trailing, spacing: 2) {
                statusLabel("на паузе", "pause.circle.fill", .orange)
                Text(Fmt.percent(job.fraction)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .queued:
            Text(queuedText).font(.callout).foregroundStyle(.secondary)
        case .done:
            HStack(spacing: 4) {
                DoneMark(bounce: reduceMotion ? 0 : bounce)
                Text("готово").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .failed:
            statusLabel("ошибка", "xmark.octagon.fill", .red)
        case .cancelled:
            Text("отменено").font(.callout).foregroundStyle(.secondary)
        case .blocked:
            statusLabel("отложено", "pause.circle.fill", .orange)
        case .refused:
            statusLabel("не сделано", "hand.raised.fill", .orange)
        }
    }

    /// A queued row behind the closed cloud gate waits for the connection; one restarted after a
    /// stall or a wake says so until bytes flow again.
    private var queuedText: String {
        if manager.waitingForAccount { return "ждёт подключения к Облаку" }
        if job.waitingForNetwork || !manager.cloudReachable { return "ждёт связь" }
        return job.restarting ? "перезапускаю" : "в очереди"
    }

    private func statusLabel(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(color)
        }
        .font(.callout)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .running:
                // Not while the original / placeholder is being moved: that step is not interrupted.
                if !job.committing {
                    iconButton("pause.circle", "Пауза") { manager.pause(job.id) }
                    iconButton("xmark.circle", "Отменить") { manager.cancel(job.id) }
                } else {
                    Text("не прерывается").font(.caption).foregroundStyle(.secondary)
                        .help("Сейчас оригинал или ярлык переносится в Корзину, этот шаг не прерывается")
                }
            case .paused:
                iconButton("play.circle", "Продолжить") { manager.resume(job.id) }
                iconButton("xmark.circle", "Отменить") { manager.cancel(job.id) }
            case .queued:
                iconButton("xmark.circle", "Отменить") { manager.cancel(job.id) }
            case .failed, .cancelled, .blocked:
                // The resolving action («Повторить» / «Всё равно») is always shown below.
                iconButton("minus.circle", "Убрать из списка") { manager.remove(job.id) }
            case .refused:
                iconButton("minus.circle", "Убрать из списка") { manager.remove(job.id) }
            case .done:
                if canRestore {
                    Button("Вернуть на Мак") { manager.restoreEvicted(job.id) }
                        .controlSize(.small).fixedSize()
                        .help("Скачать обратно в ту же папку; ярлык уйдёт в Корзину")
                }
                if canReveal {
                    iconButton("magnifyingglass.circle", "Показать в Finder") { manager.revealInFinder(job.id) }
                }
                iconButton("safari", "Открыть в Облаке") { manager.openInBrowser(job.remotePath) }
                iconButton("minus.circle", "Убрать из списка") { manager.remove(job.id) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var menuItems: some View {
        switch job.state {
        case .running:
            if job.committing {
                Text("Сейчас этот шаг не прерывается")
            } else {
                Button("Пауза") { manager.pause(job.id) }
                Button("Отменить") { manager.cancel(job.id) }
            }
        case .paused:
            Button("Продолжить") { manager.resume(job.id) }
            Button("Отменить") { manager.cancel(job.id) }
        case .queued:
            Button("Отменить") { manager.cancel(job.id) }
        case .failed, .cancelled:
            Button("Повторить") { manager.retry(job.id) }
        case .blocked:
            Button("Всё равно загрузить") { manager.retry(job.id, force: true) }
        case .refused, .done:
            EmptyView()
        }
        if canRestore {
            Button("Вернуть на Мак") { manager.restoreEvicted(job.id) }
        }
        if canReveal {
            Button("Показать в Finder") { manager.revealInFinder(job.id) }
        }
        if job.state == .done {
            Button("Открыть в Облаке") { manager.openInBrowser(job.remotePath) }
        }
        if case .failed(let m) = job.state {
            Button("Скопировать текст ошибки") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m, forType: .string)
            }
        }
        if !job.state.isActive {
            Divider()
            Button("Убрать из списка") { manager.remove(job.id) }
        }
    }
}

/// Signature 3: the green checkmark bounces once when its job has just finished. The mark appears
/// together with the "done" state, so the bounce is triggered right after it is on screen (an
/// effect value that is already set when a view appears never plays).
private struct DoneMark: View {
    let bounce: Int
    @State private var played = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: played)
            .onAppear {
                guard bounce > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { played = bounce }
            }
            .onChange(of: bounce) { _, b in played = b }
    }
}
