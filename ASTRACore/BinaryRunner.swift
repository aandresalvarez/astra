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
        terminateProcessGroup: Bool = false
    ) async -> RunResult {
        if terminateProcessGroup {
            return await runSpawnedProcessGroup(
                path: path,
                args: args,
                timeout: timeout,
                environment: environment,
                currentDirectory: currentDirectory,
                stdin: stdin,
                maximumOutputBytes: maximumOutputBytes
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
                    let data = handle.availableData
                    if data.isEmpty { return }
                    stdoutCollector.append(data)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { return }
                    stderrCollector.append(data)
                }

                let cleanupPipes = {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                }

                process.terminationHandler = { proc in
                    cleanupPipes()
                    // Drain whatever's left after the process exits.
                    let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !tailOut.isEmpty { stdoutCollector.append(tailOut) }
                    let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !tailErr.isEmpty { stderrCollector.append(tailErr) }

                    let elapsed = Date().timeIntervalSince(startedAt)
                    let outcome: RunResult.Outcome = timeout > 0 && elapsed >= timeout
                        ? .timedOut
                        : .exited(code: proc.terminationStatus)
                    state.finish(
                        outcome: outcome,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: elapsed,
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
                    guard process.isRunning else { return }
                    // Stamp timeout before terminating so a fast SIGTERM exit
                    // cannot be misclassified as a normal status-15 exit.
                    state.finish(
                        outcome: .timedOut,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: Date().timeIntervalSince(startedAt),
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                    state.terminateRunningProcess(process)
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
        maximumOutputBytes: Int?
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
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { return }
                    stdoutCollector.append(data)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { return }
                    stderrCollector.append(data)
                }
                let cleanupPipes = {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
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
                let attrFlags = Int16(POSIX_SPAWN_SETPGROUP)
                guard posix_spawnattr_setflags(&spawnAttributes, attrFlags) == 0,
                      posix_spawnattr_setpgroup(&spawnAttributes, 0) == 0 else {
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

                Task.detached {
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
                    cleanupPipes()
                    let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !tailOut.isEmpty { stdoutCollector.append(tailOut) }
                    let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !tailErr.isEmpty { stderrCollector.append(tailErr) }
                    state.finish(
                        outcome: .exited(code: Self.exitCode(fromWaitStatus: status)),
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: Date().timeIntervalSince(startedAt),
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                }

                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    state.finish(
                        outcome: .timedOut,
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string,
                        elapsedTime: Date().timeIntervalSince(startedAt),
                        stdoutTruncated: stdoutCollector.wasTruncated,
                        stderrTruncated: stderrCollector.wasTruncated
                    )
                    state.terminateProcessGroup()
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
/// background queue, so appends need synchronization.
private final class PipeCollector: @unchecked Sendable {
    private var buffer = Data()
    private var truncated = false
    private let lock = NSLock()
    private let maximumBytes: Int?

    init(maximumBytes: Int? = nil) {
        if let maximumBytes, maximumBytes >= 0 {
            self.maximumBytes = maximumBytes
        } else {
            self.maximumBytes = nil
        }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
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
        lock.unlock()
    }

    var string: String {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }

    var wasTruncated: Bool {
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

    func setContinuation(_ continuation: CheckedContinuation<RunResult, Never>) -> Bool {
        lock.lock()
        self.continuation = continuation
        let alreadyFinished = didFinish
        lock.unlock()
        if alreadyFinished {
            finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        }
        return alreadyFinished
    }

    func setProcess(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = didFinish
        lock.unlock()
        if shouldTerminate {
            terminate(process)
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
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

    func terminateRunningProcess(_ process: Process) {
        terminate(process)
    }

    func stopIfFinished(_ process: Process) -> Bool {
        lock.lock()
        let shouldTerminate = didFinish
        lock.unlock()
        if shouldTerminate {
            terminate(process)
        }
        return shouldTerminate
    }

    var isFinished: Bool {
        lock.lock()
        let value = didFinish
        lock.unlock()
        return value
    }

    func cancel() {
        let processToTerminate: Process?
        lock.lock()
        processToTerminate = process
        lock.unlock()
        finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        if let processToTerminate {
            terminate(processToTerminate)
        }
    }

    func finish(
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

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                kill(pid, SIGKILL)
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

    func setContinuation(_ continuation: CheckedContinuation<RunResult, Never>) -> Bool {
        lock.lock()
        self.continuation = continuation
        let alreadyFinished = didFinish
        lock.unlock()
        if alreadyFinished {
            finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        }
        return alreadyFinished
    }

    func setProcessGroupID(_ processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldTerminate = didFinish
        lock.unlock()
        if shouldTerminate {
            terminate(processGroupID: processGroupID)
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
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

    func stopIfFinished() -> Bool {
        lock.lock()
        let shouldTerminate = didFinish
        let processGroupID = self.processGroupID
        lock.unlock()
        if shouldTerminate, let processGroupID {
            terminate(processGroupID: processGroupID)
        }
        return shouldTerminate
    }

    func cancel() {
        let processGroupID: pid_t?
        lock.lock()
        processGroupID = self.processGroupID
        lock.unlock()
        finish(outcome: .cancelled, stdout: "", stderr: "", elapsedTime: 0)
        if let processGroupID {
            terminate(processGroupID: processGroupID)
        }
    }

    func terminateProcessGroup() {
        let processGroupID: pid_t?
        lock.lock()
        processGroupID = self.processGroupID
        lock.unlock()
        if let processGroupID {
            terminate(processGroupID: processGroupID)
        }
    }

    func finish(
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

    private func terminate(processGroupID: pid_t) {
        kill(-processGroupID, SIGTERM)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            kill(-processGroupID, SIGKILL)
        }
    }
}

private final class CStringArray {
    private var storage: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
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

    func withUnsafeMutableBufferPointer<Result>(
        _ body: (inout UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeMutableBufferPointer(body)
    }
}
