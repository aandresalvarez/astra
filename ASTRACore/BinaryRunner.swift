import Darwin
import Foundation

/// Result of running an external binary: captured stdout/stderr plus a
/// discriminated outcome that distinguishes a clean exit from a signalled
/// exit, a timeout kill, caller cancellation, or a failure to launch
/// (e.g. binary missing).
///
/// `RunResult` is intentionally simple — it's what the runner gives back,
/// not a semantic classification of what the binary "meant." Higher layers
/// (EnvironmentHealthChecker) translate these into product-level health
/// statuses.
public struct RunResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Process exited normally. `code` is the exit status (0 = success).
        case exited(code: Int32)
        /// Process was killed because it exceeded the timeout.
        case timedOut
        /// Process was killed because the caller task was cancelled.
        case cancelled
        /// Process could not be launched — usually means the path does not
        /// resolve to an executable. Distinct from a binary that launches
        /// and then errors out, which is `.exited(code:)` with non-zero.
        case launchFailed(String)
    }

    public let outcome: Outcome
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32?
    public let launchError: String?
    public let timedOut: Bool
    public let cancelled: Bool
    public let elapsedTime: TimeInterval
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public init(
        outcome: Outcome,
        stdout: String,
        stderr: String,
        elapsedTime: TimeInterval = 0,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
        self.elapsedTime = elapsedTime
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        switch outcome {
        case .exited(let code):
            self.exitCode = code
            self.launchError = nil
            self.timedOut = false
            self.cancelled = false
        case .timedOut:
            self.exitCode = nil
            self.launchError = nil
            self.timedOut = true
            self.cancelled = false
        case .cancelled:
            self.exitCode = nil
            self.launchError = nil
            self.timedOut = false
            self.cancelled = true
        case .launchFailed(let reason):
            self.exitCode = nil
            self.launchError = reason
            self.timedOut = false
            self.cancelled = false
        }
    }

    public static func exited(code: Int32, stdout: String, stderr: String, elapsedTime: TimeInterval = 0) -> RunResult {
        RunResult(outcome: .exited(code: code), stdout: stdout, stderr: stderr, elapsedTime: elapsedTime)
    }

    public static func timedOut(stdout: String, stderr: String, elapsedTime: TimeInterval = 0) -> RunResult {
        RunResult(outcome: .timedOut, stdout: stdout, stderr: stderr, elapsedTime: elapsedTime)
    }

    public static func cancelled(stdout: String, stderr: String, elapsedTime: TimeInterval = 0) -> RunResult {
        RunResult(outcome: .cancelled, stdout: stdout, stderr: stderr, elapsedTime: elapsedTime)
    }

    public static func launchFailed(
        _ reason: String,
        stdout: String = "",
        stderr: String = "",
        elapsedTime: TimeInterval = 0
    ) -> RunResult {
        RunResult(outcome: .launchFailed(reason), stdout: stdout, stderr: stderr, elapsedTime: elapsedTime)
    }

    /// Convenience: did the process exit cleanly with status 0?
    public var isSuccess: Bool {
        exitCode == 0
    }
}

/// A seam over process execution so that health checks can be unit-tested
/// with a stub, and the real implementation can enforce a timeout without
/// leaking processes.
///
/// Implementations MUST honor the timeout. A slow or hung binary is a
/// frequent failure mode in preflight checks (e.g. `gcloud` blocking on
/// auth token refresh). The real implementation kills with SIGTERM then
/// SIGKILL after a grace period.
public protocol BinaryRunner: Sendable {
    /// Run `path` with `args` and return captured output + outcome.
    /// - Parameters:
    ///   - path: Absolute path to the executable. No PATH lookup —
    ///     resolvers should supply a resolved path.
    ///   - args: Argument vector (first arg is NOT the program name).
    ///   - timeout: Wall-clock seconds. On expiry, the runner MUST
    ///     terminate the process and return `.timedOut`.
    ///   - environment: Optional environment. `nil` = inherit from parent.
    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult

    /// Run with `stdin` written to the process, after which the write end
    /// is closed so the child observes EOF. Needed for CLIs that only
    /// answer over a stdin/stdout protocol (e.g. stream-json handshakes).
    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        stdin: Data?
    ) async -> RunResult
}

public extension BinaryRunner {
    /// Convenience: run with inherited environment.
    func run(path: String, args: [String], timeout: TimeInterval = 3) async -> RunResult {
        await run(path: path, args: args, timeout: timeout, environment: nil)
    }

    /// Default for runners that don't support stdin: the input is dropped.
    /// `ProcessBinaryRunner` overrides this with a real pipe.
    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        stdin _: Data?
    ) async -> RunResult {
        await run(path: path, args: args, timeout: timeout, environment: environment)
    }
}

/// Production implementation. Uses `Process` with an async waiter that
/// race-cancels against a timeout. On timeout we send SIGTERM, wait up
/// to 500ms, then SIGKILL — matching the well-behaved-then-forceful
/// pattern from ClaudeCodeWorker.
///
/// A timed-out result is classified and timed at the deadline, but it is
/// returned only once the child is reaped. That way it carries everything
/// the child wrote up to its death, including anything it prints on its
/// way out after SIGTERM. At that point the runner collects only output that
/// is already buffered: an orphan that inherited the pipes can hold them
/// open indefinitely, and the timeout exists so that nothing waits on it. A
/// child that not even SIGKILL can reap (an uninterruptible wait) gets one
/// more grace period, and then the run finishes without it.
///
/// The deadline also bounds a run whose child exited in time but left
/// something holding its pipes: the drain to EOF stops there, and the run is
/// a timeout. In process-group mode the group is torn down first, which
/// usually ends that drain on its own.
public struct ProcessBinaryRunner: BinaryRunner {
    public init() {}

    public func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        await run(
            path: path,
            args: args,
            timeout: timeout,
            environment: environment,
            currentDirectory: nil
        )
    }

    public func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        stdin: Data?
    ) async -> RunResult {
        await run(
            path: path,
            args: args,
            timeout: timeout,
            environment: environment,
            currentDirectory: nil,
            stdin: stdin
        )
    }

    public func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        currentDirectory: String?,
        stdin: Data? = nil,
        maximumOutputBytes: Int? = nil,
        terminateProcessGroup: Bool = false,
        stopOnOutputLimit: Bool = false
    ) async -> RunResult {
        if terminateProcessGroup {
            return await runSpawnedProcessGroup(
                path: path,
                args: args,
                timeout: timeout,
                environment: environment,
                currentDirectory: currentDirectory,
                stdin: stdin,
                maximumOutputBytes: maximumOutputBytes,
                stopOnOutputLimit: stopOnOutputLimit
            )
        }

        let state = ProcessRunState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if state.setContinuation(continuation) {
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                if let currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
                }
                if let env = environment {
                    process.environment = env
                }
                state.setProcess(process)
                if state.isFinished {
                    return
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                let stdinPipe: Pipe?
                if stdin != nil {
                    let pipe = Pipe()
                    process.standardInput = pipe
                    stdinPipe = pipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                    stdinPipe = nil
                }

                let stdoutCollector = PipeCollector(maximumBytes: maximumOutputBytes)
                let stderrCollector = PipeCollector(maximumBytes: maximumOutputBytes)
                let startedAt = Date()
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    stdoutCollector.drainAvailable(from: handle)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrCollector.drainAvailable(from: handle)
                }

                let cleanupPipes = {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                }

                // Finishes a timed-out run from the reap, or from the teardown
                // backstop for a child that cannot be reaped, whichever comes
                // first. `elapsed` is the moment the deadline passed.
                let finishTimedOut = { (elapsed: TimeInterval) in
                    cleanupPipes()
                    stdoutCollector.drainAvailable(from: stdoutPipe.fileHandleForReading)
                    stderrCollector.drainAvailable(from: stderrPipe.fileHandleForReading)
                    state.finish(
                        outcome: .timedOut,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: elapsed,
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                }

                process.terminationHandler = { proc in
                    // Stamp elapsed time from the moment the process actually
                    // exited, before draining what's left. A drain the
                    // scheduler is slow to run must not read as the child
                    // itself running past the timeout. Only a drain the
                    // deadline has to cut short makes the run a timeout.
                    let elapsed = Date().timeIntervalSince(startedAt)
                    if let timedOutAfter = state.claimReap(elapsed: elapsed, deadline: timeout) {
                        finishTimedOut(timedOutAfter)
                        return
                    }
                    cleanupPipes()
                    // An orphan that inherited the pipes can put EOF off
                    // forever, and nothing in this mode signals it. So the
                    // drain waits outside the collectors' locks and stops once
                    // the run is over, which leaves the deadline free to end
                    // the run without it (`markTimedOut` → `.stopDraining`).
                    Self.drainToEOF(
                        [(stdoutCollector, stdoutPipe.fileHandleForReading),
                         (stderrCollector, stderrPipe.fileHandleForReading)],
                        until: { state.isFinished }
                    )
                    let timedOutAfter = state.claimDrainedResult()
                    state.finish(
                        outcome: timedOutAfter == nil ? .exited(code: proc.terminationStatus) : .timedOut,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: timedOutAfter ?? elapsed,
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                }

                do {
                    try process.run()
                } catch {
                    cleanupPipes()
                    state.finish(
                        outcome: .launchFailed(error.localizedDescription),
                        stdout: "",
                        stderr: "",
                        elapsedTime: Date().timeIntervalSince(startedAt)
                    )
                    return
                }
                if let stdinPipe, let stdin {
                    // Small payloads only (well under the 64KB pipe buffer),
                    // so a synchronous write cannot block. Closing signals EOF.
                    let writer = stdinPipe.fileHandleForWriting
                    try? writer.write(contentsOf: stdin)
                    try? writer.close()
                }
                if state.stopIfFinished(process) {
                    return
                }

                // Timeout enforcement. DispatchSourceTimer would work but we're
                // already inside a structured continuation — a Task is simple
                // and cancellable once the process finishes first.
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    switch state.markTimedOut(elapsed: elapsed) {
                    case .terminateChild:
                        // Stamp timeout before terminating so a fast SIGTERM
                        // exit cannot be misclassified as a normal status-15
                        // exit. The reap then finishes the run (see
                        // terminationHandler), so what the child writes on its
                        // way out is not lost.
                        state.terminateTimedOutProcess(process) { finishTimedOut(elapsed) }
                    case .stopDraining:
                        finishTimedOut(elapsed)
                    case nil:
                        return
                    }
                }
                state.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.cancel()
        }
    }

    private func runSpawnedProcessGroup(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        currentDirectory: String?,
        stdin: Data?,
        maximumOutputBytes: Int?,
        stopOnOutputLimit: Bool
    ) async -> RunResult {
        let state = SpawnedProcessGroupRunState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if state.setContinuation(continuation) {
                    return
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = stdin == nil ? nil : Pipe()
                let stdoutCollector = PipeCollector(maximumBytes: maximumOutputBytes)
                let stderrCollector = PipeCollector(maximumBytes: maximumOutputBytes)
                let startedAt = Date()
                let stopIfOutputExceeded = {
                    guard stopOnOutputLimit, stdoutCollector.wasTruncated || stderrCollector.wasTruncated else { return }
                    state.finish(outcome: .exited(code: 1), stdout: stdoutCollector.string,
                        stderr: stderrCollector.string, elapsedTime: Date().timeIntervalSince(startedAt),
                        stdoutTruncated: stdoutCollector.wasTruncated, stderrTruncated: stderrCollector.wasTruncated)
                    state.terminateRemainingProcessGroup()
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    stdoutCollector.drainAvailable(from: handle)
                    stopIfOutputExceeded()
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrCollector.drainAvailable(from: handle)
                    stopIfOutputExceeded()
                }
                let cleanupPipes = {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                }
                // Same contract as the Process path's `finishTimedOut`.
                let finishTimedOut = { (elapsed: TimeInterval) in
                    cleanupPipes()
                    stdoutCollector.drainAvailable(from: stdoutPipe.fileHandleForReading)
                    stderrCollector.drainAvailable(from: stderrPipe.fileHandleForReading)
                    state.finish(
                        outcome: .timedOut,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: elapsed,
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                }
                let closeParentPipeEnds = {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    try? stdinPipe?.fileHandleForReading.close()
                }

                var fileActions: posix_spawn_file_actions_t? = nil
                var spawnAttributes: posix_spawnattr_t? = nil
                guard posix_spawn_file_actions_init(&fileActions) == 0 else {
                    cleanupPipes()
                    state.finish(
                        outcome: .launchFailed("Could not initialize spawn file actions."),
                        stdout: "",
                        stderr: "",
                        elapsedTime: Date().timeIntervalSince(startedAt)
                    )
                    return
                }
                defer { posix_spawn_file_actions_destroy(&fileActions) }
                guard posix_spawnattr_init(&spawnAttributes) == 0 else {
                    cleanupPipes()
                    state.finish(
                        outcome: .launchFailed("Could not initialize spawn attributes."),
                        stdout: "",
                        stderr: "",
                        elapsedTime: Date().timeIntervalSince(startedAt)
                    )
                    return
                }
                defer { posix_spawnattr_destroy(&spawnAttributes) }

                let configureResult = configureSpawnFileActions(
                    &fileActions,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe,
                    stdinPipe: stdinPipe,
                    currentDirectory: currentDirectory
                )
                guard configureResult == 0 else {
                    cleanupPipes()
                    state.finish(
                        outcome: .launchFailed(Self.posixErrorDescription(configureResult)),
                        stdout: "",
                        stderr: "",
                        elapsedTime: Date().timeIntervalSince(startedAt)
                    )
                    return
                }
                guard ProcessGroupSpawn.configureNewProcessGroup(&spawnAttributes) else {
                    cleanupPipes()
                    state.finish(
                        outcome: .launchFailed("Could not configure spawn process group."),
                        stdout: "",
                        stderr: "",
                        elapsedTime: Date().timeIntervalSince(startedAt)
                    )
                    return
                }

                var pid = pid_t()
                let argv = CStringArray([path] + args)
                let envp = CStringArray(Self.environmentVector(environment))
                let spawnResult = argv.withUnsafeMutableBufferPointer { argvPointer in
                    envp.withUnsafeMutableBufferPointer { envPointer in
                        path.withCString { pathPointer in
                            posix_spawn(
                                &pid,
                                pathPointer,
                                &fileActions,
                                &spawnAttributes,
                                argvPointer.baseAddress,
                                envPointer.baseAddress
                            )
                        }
                    }
                }
                guard spawnResult == 0 else {
                    cleanupPipes()
                    closeParentPipeEnds()
                    state.finish(
                        outcome: .launchFailed(Self.posixErrorDescription(spawnResult)),
                        stdout: "",
                        stderr: "",
                        elapsedTime: Date().timeIntervalSince(startedAt)
                    )
                    return
                }

                closeParentPipeEnds()
                state.setProcessGroupID(pid)
                if let stdinPipe, let stdin {
                    let writer = stdinPipe.fileHandleForWriting
                    try? writer.write(contentsOf: stdin)
                    try? writer.close()
                }
                if state.stopIfFinished() {
                    return
                }

                // waitpid and the post-exit pipe drain block their thread.
                // Keep them off Swift's cooperative pool so cancellation and
                // timeout tasks can still run when all providers are waiting.
                DispatchQueue.global(qos: .utility).async {
                    var status = Int32(0)
                    while waitpid(pid, &status, 0) == -1 {
                        guard errno == EINTR else {
                            cleanupPipes()
                            state.finish(
                                outcome: .exited(code: 1),
                                stdout: stdoutCollector.string,
                                stderr: stderrCollector.string,
                                elapsedTime: Date().timeIntervalSince(startedAt),
                                stdoutTruncated: stdoutCollector.wasTruncated,
                                stderrTruncated: stderrCollector.wasTruncated
                            )
                            return
                        }
                    }
                    let reapedAfter = Date().timeIntervalSince(startedAt)
                    if let timedOut = state.claimReap(elapsed: reapedAfter, deadline: timeout) {
                        if timedOut.needsTeardown {
                            state.terminateRemainingProcessGroup()
                        }
                        finishTimedOut(timedOut.elapsed)
                        return
                    }
                    cleanupPipes()
                    // The leader's descendants can keep the pipes open, even
                    // ones that left its group or outlive SIGKILL. So this
                    // drain waits outside the collectors' locks and stops
                    // once the run is over, which leaves the deadline's
                    // backstop free to finish the run without it.
                    Self.drainToEOF(
                        [(stdoutCollector, stdoutPipe.fileHandleForReading),
                         (stderrCollector, stderrPipe.fileHandleForReading)],
                        until: { state.isFinished }
                    )
                    // The leader exited in time, but if the deadline passed
                    // while this drain waited on what it left behind, the
                    // timeout task tore the group down to end the wait, and the
                    // run is a timeout.
                    let timedOutAfter = state.claimDrainedResult()
                    state.finish(
                        outcome: timedOutAfter == nil ? .exited(code: Self.exitCode(fromWaitStatus: status)) : .timedOut,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: timedOutAfter ?? Date().timeIntervalSince(startedAt),
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                }

                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    guard state.markTimedOut(elapsed: elapsed) else { return }
                    // Whether the leader is still running or its reap is still
                    // draining what it left behind, tearing the group down is
                    // what ends the run. If even that does not, the backstop
                    // does.
                    state.terminateTimedOutProcessGroup { finishTimedOut(elapsed) }
                }
                state.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.cancel()
        }
    }

    private func configureSpawnFileActions(
        _ fileActions: inout posix_spawn_file_actions_t?,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdinPipe: Pipe?,
        currentDirectory: String?
    ) -> Int32 {
        var result = posix_spawn_file_actions_adddup2(
            &fileActions,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        )
        guard result == 0 else { return result }
        result = posix_spawn_file_actions_adddup2(
            &fileActions,
            stderrPipe.fileHandleForWriting.fileDescriptor,
            STDERR_FILENO
        )
        guard result == 0 else { return result }
        if let stdinPipe {
            result = posix_spawn_file_actions_adddup2(
                &fileActions,
                stdinPipe.fileHandleForReading.fileDescriptor,
                STDIN_FILENO
            )
            guard result == 0 else { return result }
        } else {
            result = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            guard result == 0 else { return result }
        }
        result = posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.fileHandleForReading.fileDescriptor)
        guard result == 0 else { return result }
        result = posix_spawn_file_actions_addclose(&fileActions, stderrPipe.fileHandleForReading.fileDescriptor)
        guard result == 0 else { return result }
        result = posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.fileHandleForWriting.fileDescriptor)
        guard result == 0 else { return result }
        result = posix_spawn_file_actions_addclose(&fileActions, stderrPipe.fileHandleForWriting.fileDescriptor)
        guard result == 0 else { return result }
        if let stdinPipe {
            result = posix_spawn_file_actions_addclose(&fileActions, stdinPipe.fileHandleForReading.fileDescriptor)
            guard result == 0 else { return result }
            result = posix_spawn_file_actions_addclose(&fileActions, stdinPipe.fileHandleForWriting.fileDescriptor)
            guard result == 0 else { return result }
        }
        if let currentDirectory {
            result = currentDirectory.withCString { directory in
                posix_spawn_file_actions_addchdir_np(&fileActions, directory)
            }
            guard result == 0 else { return result }
        }
        return 0
    }

    /// Drains each pipe until it reaches EOF, or until `isOver` says the run
    /// no longer needs it. It waits in `poll` with no collector lock held, and
    /// only `drainAvailable`'s reads take it. Anyone else who needs a collector,
    /// such as the deadline's backstop, never waits on a writer that will not
    /// close. The wait is bounded so `isOver` is checked even if nothing ever
    /// arrives.
    private static func drainToEOF(
        _ pipes: [(collector: PipeCollector, handle: FileHandle)],
        until isOver: () -> Bool
    ) {
        var open = pipes
        while !open.isEmpty, !isOver() {
            var descriptors = open.map { pollfd(fd: $0.handle.fileDescriptor, events: Int16(POLLIN), revents: 0) }
            if poll(&descriptors, nfds_t(descriptors.count), 100) < 0, errno != EINTR { return }
            open.removeAll { $0.collector.drainAvailable(from: $0.handle) }
        }
    }

    private static func environmentVector(_ environment: [String: String]?) -> [String] {
        (environment ?? ProcessInfo.processInfo.environment)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }

    private static func posixErrorDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let waitStatus = status & 0o177
        if waitStatus == 0 {
            return (status >> 8) & 0x000000ff
        }
        if waitStatus != 0o177 {
            return waitStatus
        }
        return status
    }
}

// MARK: - Private helpers

/// Thread-safe byte collector. Pipe readability handlers fire on a
/// background queue, and the reap drains the same pipes, so every read goes
/// through `drainAvailable`, which reads and appends under one lock.
///
/// The read itself, not just the append, has to be inside the lock. `Process`
/// delivers "stdout is readable" (via `readabilityHandler`, on a GCD-managed
/// queue) and "the child exited" (via `terminationHandler`, which does its own
/// final drain) as two independent, unordered signals. Locking only around the
/// append (as this used to) still lets a reader that already consumed bytes
/// via its own `read()` call lose the CPU before reaching the lock; a
/// concurrently running drain then finds the fd AND the buffer both empty and
/// finalizes the result before the first reader's bytes were ever folded in —
/// silently dropping output that was read but not yet processed. With the
/// read inside the lock, whichever side reaches the lock first fully reads
/// and appends before the other side can even perform its own read.
///
/// `drainAvailable` never waits for more data, either. An orphan may hold
/// these pipes open, and once a drain has emptied one, a readability event
/// already queued for it would block in a waiting read while holding this
/// lock, so the run's result would wait on the orphan. Waiting happens only in
/// `drainToEOF`, outside the lock.
private final class PipeCollector: @unchecked Sendable {
    private var buffer = Data()
    private var truncated = false
    private let lock = NSLock()
    private let maximumBytes: Int?

    public init(maximumBytes: Int? = nil) {
        if let maximumBytes, maximumBytes >= 0 {
            self.maximumBytes = maximumBytes
        } else {
            self.maximumBytes = nil
        }
    }

    public func append(_ data: Data) {
        lock.lock()
        appendLocked(data)
        lock.unlock()
    }

    public func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Folds in whatever `handle` holds right now, then returns without
    /// waiting for more.
    ///
    /// A writer that never stops, such as an orphan streaming into an
    /// inherited pipe, must not keep a drain going either, so each call reads
    /// at most 16 chunks. That is 1 MiB, against the 64 KiB a macOS pipe can
    /// buffer, so a single call still takes everything that was already
    /// there. A readability handler is simply called again for the rest.
    ///
    /// Returns true once the pipe has nothing more to give: EOF, or a
    /// descriptor that can no longer be read.
    @discardableResult
    public func drainAvailable(from handle: FileHandle) -> Bool {
        let fileDescriptor = handle.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 65_536)
        return synchronized {
            for _ in 0..<16 {
                // A zero-timeout poll before every read: with the lock held no
                // other reader can take the bytes it reports, so the read
                // cannot block. An empty pipe someone still holds open ends
                // the drain instead.
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 0)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return false }
                let count = read(fileDescriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                // 0 is EOF. A negative count includes a descriptor that is
                // already closed, which poll reports as ready (POLLNVAL).
                guard count > 0 else { return true }
                appendLocked(Data(chunk[..<count]))
            }
            return false
        }
    }

    public func appendLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        if let maximumBytes {
            let remaining = max(0, maximumBytes - buffer.count)
            if remaining > 0 {
                buffer.append(data.prefix(remaining))
            }
            if data.count > remaining {
                truncated = true
            }
        } else {
            buffer.append(data)
        }
    }

    public var string: String {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        // The byte-prefix truncation above can land mid-multi-byte character,
        // leaving an invalid trailing sequence that a strict UTF-8 decode
        // rejects wholesale (empty string, losing the entire valid prefix
        // too). Decode lossily instead: every valid byte before the cut is
        // preserved, with only the truncated character itself becoming U+FFFD.
        return String(decoding: snapshot, as: UTF8.self)
    }

    public var wasTruncated: Bool {
        lock.lock()
        let value = truncated
        lock.unlock()
        return value
    }
}

/// Wraps process lifecycle state so only the first terminal result wins.
/// Prevents "resumed twice" crashes when termination, timeout, and caller
/// cancellation race.
private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunResult, Never>?
    private var process: Process?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false
    private var didReap = false
    private var didDrain = false
    private var timedOutElapsed: TimeInterval?

    public func setContinuation(_ continuation: CheckedContinuation<RunResult, Never>) -> Bool {
        lock.lock()
        self.continuation = continuation
        let alreadyFinished = didFinish
        lock.unlock()
        if alreadyFinished {
            finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        }
        return alreadyFinished
    }

    public func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = didFinish
        lock.unlock()
        if shouldTerminate {
            terminate(process)
        }
    }

    public func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = didFinish
        if shouldCancel {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    /// What the timeout task has to do once the deadline passes.
    enum TimeoutAction {
        /// The child is still running: terminate it, and its reap finishes
        /// the run.
        case terminateChild
        /// The child exited in time, but its reap is still draining pipes an
        /// orphan holds open. Nothing in this mode signals that orphan, so
        /// the deadline ends the run itself.
        case stopDraining
    }

    /// Records that the deadline passed and says what is left to do. Nil when
    /// the run is over, its drain already reached EOF, or the reap itself
    /// already decided the timeout.
    public func markTimedOut(elapsed: TimeInterval) -> TimeoutAction? {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish, !didDrain, timedOutElapsed == nil else { return nil }
        timedOutElapsed = elapsed
        return didReap ? .stopDraining : .terminateChild
    }

    /// Claims the result of a reap whose drain reached EOF. It returns the
    /// timeout stamp when the deadline got there first. Otherwise
    /// `markTimedOut` refuses from here on, so a deadline that lands now
    /// cannot act on a run this result reports as a clean exit.
    public func claimDrainedResult() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        didDrain = true
        return timedOutElapsed
    }

    /// Claims the reap for the termination handler. It returns the timeout
    /// stamp when the run timed out: either the timeout task stamped it, or
    /// the child was reaped past its deadline before that task got to run.
    /// Either way the run finishes as a timeout, without waiting on the pipes.
    /// Otherwise the handler's drain to EOF waits on any orphan holding them,
    /// and nothing is left to stop it.
    public func claimReap(elapsed: TimeInterval, deadline: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        didReap = true
        if timedOutElapsed == nil, deadline > 0, elapsed >= deadline {
            timedOutElapsed = elapsed
        }
        return timedOutElapsed
    }

    /// Timeout teardown: the reap normally finishes the run, and `backstop`
    /// finishes it one grace period after SIGKILL if it has not.
    public func terminateTimedOutProcess(_ process: Process, backstop: @escaping @Sendable () -> Void) {
        terminate(process, backstop: backstop)
    }

    public func stopIfFinished(_ process: Process) -> Bool {
        lock.lock()
        let shouldTerminate = didFinish
        lock.unlock()
        if shouldTerminate {
            terminate(process)
        }
        return shouldTerminate
    }

    public var isFinished: Bool {
        lock.lock()
        let value = didFinish
        lock.unlock()
        return value
    }

    public func cancel() {
        let processToTerminate: Process?
        lock.lock()
        processToTerminate = process
        lock.unlock()
        finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        if let processToTerminate {
            terminate(processToTerminate)
        }
    }

    public func finish(
        outcome: RunResult.Outcome,
        stdout: String,
        stderr: String,
        elapsedTime: TimeInterval,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        lock.lock()
        let cont = continuation
        continuation = nil
        didFinish = true
        process = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: RunResult(
            outcome: outcome,
            stdout: stdout,
            stderr: stderr,
            elapsedTime: elapsedTime,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated
        ))
    }

    private func terminate(_ process: Process, backstop: (@Sendable () -> Void)? = nil) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: terminationGraceNanoseconds)
            if process.isRunning {
                kill(pid, SIGKILL)
            }
            guard let backstop else { return }
            try? await Task.sleep(nanoseconds: terminationGraceNanoseconds)
            if !self.isFinished {
                backstop()
            }
        }
    }
}

private final class SpawnedProcessGroupRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunResult, Never>?
    private var processGroupID: pid_t?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false
    private var didReap = false
    private var didDrain = false
    private var timedOutElapsed: TimeInterval?

    public func setContinuation(_ continuation: CheckedContinuation<RunResult, Never>) -> Bool {
        lock.lock()
        self.continuation = continuation
        let alreadyFinished = didFinish
        lock.unlock()
        if alreadyFinished {
            finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        }
        return alreadyFinished
    }

    public func setProcessGroupID(_ processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldTerminate = didFinish
        lock.unlock()
        if shouldTerminate {
            terminate(processGroupID: processGroupID)
        }
    }

    public func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = didFinish
        if shouldCancel {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    public func stopIfFinished() -> Bool {
        lock.lock()
        let shouldTerminate = didFinish
        let processGroupID = self.processGroupID
        lock.unlock()
        if shouldTerminate, let processGroupID {
            terminate(processGroupID: processGroupID)
        }
        return shouldTerminate
    }

    public func cancel() {
        let processGroupID: pid_t?
        lock.lock()
        processGroupID = self.processGroupID
        lock.unlock()
        finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        if let processGroupID {
            terminate(processGroupID: processGroupID)
        }
    }

    public var isFinished: Bool {
        lock.lock()
        let value = didFinish
        lock.unlock()
        return value
    }

    /// See `ProcessRunState.markTimedOut`. Unlike the `Process` path, a reap
    /// does not close the window: the run is not over until the reap's drain
    /// is, so the deadline still applies to that drain. False once the run is
    /// over, its drain already reached EOF, or the reap itself already decided
    /// the timeout and tore the group down.
    public func markTimedOut(elapsed: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish, !didDrain, timedOutElapsed == nil else { return false }
        timedOutElapsed = elapsed
        return true
    }

    /// See `ProcessRunState.claimDrainedResult`.
    public func claimDrainedResult() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        didDrain = true
        return timedOutElapsed
    }

    /// See `ProcessRunState.claimReap`; here the reaper is the `waitpid` task.
    /// `needsTeardown` is true when this reap is what decided the timeout. The
    /// timeout task then never signals the group, so whatever the leader left
    /// running in it still has to be stopped.
    public func claimReap(
        elapsed: TimeInterval,
        deadline: TimeInterval
    ) -> (elapsed: TimeInterval, needsTeardown: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        didReap = true
        if let timedOutElapsed {
            return (timedOutElapsed, false)
        }
        guard deadline > 0, elapsed >= deadline else { return nil }
        timedOutElapsed = elapsed
        return (elapsed, true)
    }

    /// SIGTERM, then SIGKILL after the grace period, to what is left of the
    /// group after its leader was reaped past the deadline. No backstop: that
    /// reap finishes the run without waiting on the pipes.
    public func terminateRemainingProcessGroup() {
        let processGroupID: pid_t?
        lock.lock()
        processGroupID = self.processGroupID
        lock.unlock()
        if let processGroupID {
            terminate(processGroupID: processGroupID)
        }
    }

    /// See `ProcessRunState.terminateTimedOutProcess`. Reaping the leader
    /// finishes the run, while the rest of the group still gets its SIGKILL.
    public func terminateTimedOutProcessGroup(backstop: @escaping @Sendable () -> Void) {
        let processGroupID: pid_t?
        lock.lock()
        processGroupID = self.processGroupID
        lock.unlock()
        if let processGroupID {
            terminate(processGroupID: processGroupID, backstop: backstop)
        }
    }

    public func finish(
        outcome: RunResult.Outcome,
        stdout: String,
        stderr: String,
        elapsedTime: TimeInterval,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        lock.lock()
        let cont = continuation
        continuation = nil
        didFinish = true
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: RunResult(
            outcome: outcome,
            stdout: stdout,
            stderr: stderr,
            elapsedTime: elapsedTime,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated
        ))
    }

    private func terminate(processGroupID: pid_t, backstop: (@Sendable () -> Void)? = nil) {
        ProcessGroupSpawn.signalProcessGroup(processGroupID, signal: SIGTERM)
        Task {
            try? await Task.sleep(nanoseconds: terminationGraceNanoseconds)
            ProcessGroupSpawn.signalProcessGroup(processGroupID, signal: SIGKILL)
            guard let backstop else { return }
            try? await Task.sleep(nanoseconds: terminationGraceNanoseconds)
            if !self.isFinished {
                backstop()
            }
        }
    }
}

/// How long a terminated child gets between SIGTERM and SIGKILL. A timed-out
/// run waits one more grace period after SIGKILL before giving up on the reap.
private let terminationGraceNanoseconds: UInt64 = 500_000_000

private final class CStringArray {
    private var storage: [UnsafeMutablePointer<CChar>?]

    public init(_ strings: [String]) {
        storage = strings.map { strdup($0) }
        storage.append(nil)
    }

    deinit {
        for pointer in storage {
            if let pointer {
                free(pointer)
            }
        }
    }

    public func withUnsafeMutableBufferPointer<Result>(
        _ body: (inout UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeMutableBufferPointer(body)
    }
}
