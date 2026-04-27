import Foundation

/// Result of running an external binary: captured stdout/stderr plus a
/// discriminated outcome that distinguishes a clean exit from a signalled
/// exit, a timeout kill, or a failure to launch (e.g. binary missing).
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
        /// Process could not be launched — usually means the path does not
        /// resolve to an executable. Distinct from a binary that launches
        /// and then errors out, which is `.exited(code:)` with non-zero.
        case launchFailed(String)
    }

    public let outcome: Outcome
    public let stdout: String
    public let stderr: String

    public init(outcome: Outcome, stdout: String, stderr: String) {
        self.outcome = outcome
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Convenience: did the process exit cleanly with status 0?
    public var isSuccess: Bool {
        if case .exited(code: 0) = outcome { return true }
        return false
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
        await withCheckedContinuation { continuation in
            // Guard against a continuation being resumed twice if both the
            // process-termination callback and the timeout fire close
            // together. We keep the first result and drop the rest.
            let state = ContinuationState(continuation: continuation)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            if let env = environment {
                process.environment = env
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

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
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
                state.finish(
                    outcome: .launchFailed(error.localizedDescription),
                    stdout: "",
                    stderr: ""
                )
                return
            }

            // Timeout enforcement. DispatchSourceTimer would work but we're
            // already inside a structured continuation — a detached Task is
            // simpler and cancellable.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard process.isRunning else { return }
                // Polite first, then forceful. terminate() sends SIGTERM;
                // if the process hasn't exited after 500ms we SIGKILL.
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                // Stamp the outcome as a timeout even though the termination
                // handler will still fire. First one wins (see state.finish).
                state.finish(
                    outcome: .timedOut,
                    stdout: stdoutCollector.string,
                    stderr: stderrCollector.string
                )
            }
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

/// Wraps a CheckedContinuation so only the first `finish(...)` wins.
/// Prevents "resumed twice" crashes when termination and timeout race.
private final class ContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunResult, Never>?

    init(continuation: CheckedContinuation<RunResult, Never>) {
        self.continuation = continuation
    }

    func finish(outcome: RunResult.Outcome, stdout: String, stderr: String) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: RunResult(outcome: outcome, stdout: stdout, stderr: stderr))
    }
}
