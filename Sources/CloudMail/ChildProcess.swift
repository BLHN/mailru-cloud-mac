import Foundation
import Darwin

/// A child process started with `posix_spawn`, used for rclone instead of Foundation's `Process`.
///
/// `Process` passes arguments and environment values through `fileSystemRepresentation`, which on
/// macOS decomposes them (NFD): "Съёмка" reaches the child as "Съе" + U+0308 + "мка". mail.ru stores
/// names precomposed (NFC), so `rclone check` / `copy` / `lsjson` of a folder path with ё, й or an
/// accented letter found nothing. Here argv is built from the Swift strings' own UTF-8 bytes, so
/// the child receives exactly what the app computed.
final class ChildProcess: @unchecked Sendable {
    enum TerminationReason: Sendable { case exit, uncaughtSignal }

    enum Output {
        /// Discard (`/dev/null`).
        case null
        /// A pipe; read it from `stdoutHandle` / `stderrHandle`.
        case pipe
    }

    enum SpawnError: LocalizedError {
        case failed(Int32)
        var errorDescription: String? {
            switch self {
            case .failed(let code): return String(cString: strerror(code))
            }
        }
    }

    /// What the child reads on stdin.
    enum Input {
        /// `/dev/null`.
        case null
        /// These bytes through a pipe, then EOF (used to hand a secret to `rclone obscure -`
        /// without putting it into argv).
        case data(Data)
    }

    let executable: String
    let arguments: [String]
    /// The child's whole environment; nil inherits the app's (`environ`).
    let environment: [String: String]?
    private let input: Input

    /// Called once on a background thread after the child has exited and been reaped.
    var terminationHandler: (@Sendable (ChildProcess) -> Void)?

    private let outPipe: Pipe?
    private let errPipe: Pipe?
    /// Read ends of the pipes. They exist before `run()`, so a `readabilityHandler` can be set
    /// before the child is able to write or exit.
    var stdoutHandle: FileHandle? { outPipe?.fileHandleForReading }
    var stderrHandle: FileHandle? { errPipe?.fileHandleForReading }

    private let lock = NSCondition()
    private var pid: pid_t = 0
    private var started = false
    private var exited = false
    private var rawStatus: Int32 = 0

    init(executable: String, arguments: [String], environment: [String: String]? = nil,
         stdin: Input = .null, stdout: Output, stderr: Output) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.input = stdin
        outPipe = stdout == .pipe ? Pipe() : nil
        errPipe = stderr == .pipe ? Pipe() : nil
    }

    /// The child's pid once started (0 before).
    var processIdentifier: pid_t {
        lock.lock(); defer { lock.unlock() }
        return pid
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && !exited
    }

    /// Exit code, or the signal number when killed by a signal. Valid after exit.
    var terminationStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        let sig = rawStatus & 0x7f
        return sig == 0 ? (rawStatus >> 8) & 0xff : sig
    }

    var terminationReason: TerminationReason {
        lock.lock(); defer { lock.unlock() }
        return rawStatus & 0x7f == 0 ? .exit : .uncaughtSignal
    }

    /// Starts the child (once). stdin is `/dev/null` or the given bytes; every other descriptor of
    /// the app is closed in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`). The environment is
    /// `environment` when set, else the app's own.
    func run() throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        var inPipe: Pipe?
        switch input {
        case .null:
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        case .data:
            let pipe = Pipe()
            inPipe = pipe
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForReading.fileDescriptor, 0)
        }
        for (pipe, fd) in [(outPipe, Int32(1)), (errPipe, Int32(2))] {
            if let pipe {
                posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, fd)
            } else {
                posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_WRONLY, 0)
            }
        }

        // Default signal handling and an empty mask in the child, whatever the app has set.
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        // argv from the strings' UTF-8 bytes as they are: no Unicode normalization.
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // envp the same way, when an environment is given; otherwise the app's own.
        var envp: [UnsafeMutablePointer<CChar>?] = (environment ?? [:])
            .map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = environment == nil
            ? posix_spawn(&child, executable, &actions, &attr, argv, environ)
            : posix_spawn(&child, executable, &actions, &attr, argv, envp)
        // The child has its own copies of the write ends; closing ours lets the reader see EOF.
        try? outPipe?.fileHandleForWriting.close()
        try? errPipe?.fileHandleForWriting.close()
        try? inPipe?.fileHandleForReading.close()
        guard rc == 0 else {
            try? inPipe?.fileHandleForWriting.close()
            throw SpawnError.failed(rc)
        }
        if case .data(let bytes) = input, let writer = inPipe?.fileHandleForWriting {
            // On a background thread: a payload larger than the pipe buffer would block until the
            // child reads it. A child that exits early closes the pipe; SIGPIPE is ignored by the
            // app (see `ignoreSigpipe`), so the write just fails.
            _ = ChildProcess.ignoreSigpipe
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: bytes)
                try? writer.close()
            }
        }

        lock.lock()
        pid = child
        started = true
        lock.unlock()

        let thread = Thread { [self] in self.waitForExit() }
        thread.name = "rclone wait \(child)"
        thread.stackSize = 64 * 1024
        thread.start()
    }

    /// Writing to a pipe whose reader has exited raises SIGPIPE, which would kill the app.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN); return () }()

    /// Blocks the calling (background) thread until the child has exited.
    func waitUntilExit() {
        lock.lock()
        while started && !exited { lock.wait() }
        lock.unlock()
    }

    /// SIGTERM, only while the child is alive and not yet reaped (its pid cannot be reused yet).
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard started, !exited else { return }
        kill(pid, SIGTERM)
    }

    /// SIGKILL, under the same guard: for a child that did not exit on SIGTERM (stopped or hung).
    /// Returns true when the signal was sent.
    @discardableResult
    func forceKill() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard started, !exited else { return false }
        return kill(pid, SIGKILL) == 0
    }

    private func waitForExit() {
        lock.lock()
        let child = pid
        lock.unlock()
        // Wait without reaping, so `terminate()` can never signal a recycled pid. macOS's waitid
        // also returns for a child stopped by SIGSTOP although only WEXITED is asked, so the reap
        // under the lock never blocks (WNOHANG): a blocking waitpid there would hold the lock for as
        // long as the child stays stopped, and every `isRunning` on the main thread would hang.
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1, errno == EINTR { continue }
            var status: Int32 = 0
            lock.lock()
            var r: pid_t
            repeat { r = waitpid(child, &status, WNOHANG) } while r == -1 && errno == EINTR
            if r == child || r == -1 {
                // r == -1 (ECHILD) should not happen; never report it as a clean exit.
                rawStatus = r == child ? status : SIGKILL
                exited = true
                lock.broadcast()
                lock.unlock()
                break
            }
            lock.unlock()
            // Not exited (stopped): look again shortly.
            usleep(200_000)
        }
        terminationHandler?(self)
    }
}

/// Facts about a process by pid, for the orphan guard: an rclone left over from an earlier run of the
/// app is stopped only when its pid, executable and start time all match what that run saved.
enum ProcessFacts {
    /// Start time in microseconds since 1970, nil when no such process exists.
    static func startMicros(_ pid: pid_t) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
    }

    /// Path of the process's executable, nil when it cannot be read.
    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}
