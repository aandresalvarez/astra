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

    public init(outcome: Outcome, stdout: String, stderr: String) {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
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

    public static func exited(code: Int32, stdout: String, stderr: String) -> RunResult {
        RunResult(outcome: .exited(code: code), stdout: stdout, stderr: stderr)
    }

    public static func timedOut(stdout: String, stderr: String) -> RunResult {
        RunResult(outcome: .timedOut, stdout: stdout, stderr: stderr)
    }

    public static func cancelled(stdout: String, stderr: String) -> RunResult {
        RunResult(outcome: .cancelled, stdout: stdout, stderr: stderr)
    }

    public static func launchFailed(_ reason: String, stdout: String = "", stderr: String = "") -> RunResult {
        RunResult(outcome: .launchFailed(reason), stdout: stdout, stderr: stderr)
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
}

public extension BinaryRunner {
    /// Convenience: run with inherited environment.
    func run(path: String, args: [String], timeout: TimeInterval = 3) async -> RunResult {
        await run(path: path, args: args, timeout: timeout, environment: nil)
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
        let state = ProcessRunState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if state.setContinuation(continuation) {
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
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

                let stdoutCollector = PipeCollector()
                let stderrCollector = PipeCollector()
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

                    state.finish(
                        outcome: .exited(code: proc.terminationStatus),
                        stdout: stdoutCollector.string,
                        stderr: stderrCollector.string
                    )
                }

                do {
                    try process.run()
                } catch {
                    cleanupPipes()
                    state.finish(
                        outcome: .launchFailed(error.localizedDescription),
                        stdout: "",
                        stderr: ""
                    )
                    return
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
                        stderr: stderrCollector.string
                    )
                    // Polite first, then forceful. terminate() sends SIGTERM;
                    // if the process hasn't exited after 500ms we SIGKILL.
                    process.terminate()
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
                state.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

// MARK: - Private helpers

/// Thread-safe byte collector. Pipe readability handlers fire on a
/// background queue, so appends need synchronization.
private final class PipeCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
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
            finish(outcome: .cancelled, stdout: "", stderr: "")
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
        finish(outcome: .cancelled, stdout: "", stderr: "")
        if let processToTerminate {
            terminate(processToTerminate)
        }
    }

    func finish(outcome: RunResult.Outcome, stdout: String, stderr: String) {
        lock.lock()
        let cont = continuation
        continuation = nil
        didFinish = true
        process = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: RunResult(outcome: outcome, stdout: stdout, stderr: stderr))
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
