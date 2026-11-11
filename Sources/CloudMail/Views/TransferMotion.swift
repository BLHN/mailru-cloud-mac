import SwiftUI
import AppKit
import Combine

/// The three sections of «Передачи».
enum TransferBucket: Int, CaseIterable {
    case now, attention, done

    var title: String {
        switch self {
        case .now: return "Сейчас"
        case .attention: return "Нужно внимание"
        case .done: return "Готово"
        }
    }

    static func natural(_ state: JobState) -> TransferBucket {
        switch state {
        case .queued, .running, .paused: return .now
        case .failed, .blocked, .refused: return .attention
        case .done, .cancelled: return .done
        }
    }
}

/// Watches job state changes for the signature touches: a job that just finished stays in
/// «Сейчас» for a moment (its bar completes and fades, the checkmark bounces) before it moves to
/// «Готово»; a job that just failed shakes its icon before it moves to «Нужно внимание».
/// Transitions are detected here, not in the rows, because a row that changes sections is a new
/// view and would never see the change itself.
@MainActor
final class TransferMotion: ObservableObject {
    /// Jobs held in a section other than their natural one, until the moment has played.
    @Published private(set) var held: [UUID: TransferBucket] = [:]
    @Published private(set) var doneBounce: [UUID: Int] = [:]
    @Published private(set) var failShake: [UUID: Int] = [:]

    private var last: [UUID: JobState] = [:]
    private var primed = false
    private var subscription: AnyCancellable?

    /// Subscribes to the queue. `@Published` emits in `willSet`, so `held` changes in the same
    /// update as the job state and a finished row never flashes in «Готово» for one frame.
    init(manager: UploadManager) {
        subscription = manager.$jobs.sink { [weak self] jobs in
            MainActor.assumeIsolated {
                self?.ingest(jobs, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
    }

    func bucket(of job: UploadJob) -> TransferBucket {
        held[job.id] ?? TransferBucket.natural(job.state)
    }

    func isHeld(_ id: UUID) -> Bool { held[id] != nil }

    func ingest(_ jobs: [UploadJob], reduceMotion: Bool) {
        var seen = Set<UUID>()
        for j in jobs {
            seen.insert(j.id)
            let prev = last[j.id]
            if prev != j.state { last[j.id] = j.state }
            guard primed, let prev, prev != j.state else { continue }
            if j.state == .done, prev == .running {
                doneBounce[j.id, default: 0] += 1
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                hold(j.id, in: TransferBucket.natural(prev), for: reduceMotion ? 0.5 : 1.3, reduceMotion: reduceMotion)
            } else if TransferBucket.natural(j.state) == .attention, prev.isActive {
                failShake[j.id, default: 0] += 1
                hold(j.id, in: TransferBucket.natural(prev), for: reduceMotion ? 0.4 : 0.9, reduceMotion: reduceMotion)
            }
        }
        if last.count != seen.count {
            for id in last.keys where !seen.contains(id) {
                last[id] = nil; held[id] = nil; doneBounce[id] = nil; failShake[id] = nil
            }
        }
        primed = true
    }

    private func hold(_ id: UUID, in bucket: TransferBucket, for seconds: Double, reduceMotion: Bool) {
        held[id] = bucket
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : Motion.layout) {
                _ = self?.held.removeValue(forKey: id)
            }
        }
    }
}
