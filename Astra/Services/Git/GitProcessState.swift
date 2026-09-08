import Foundation

/// Thread-safe lifecycle/outcome tracker for a single `git` subprocess.
///
/// Encapsulates the concurrency-sensitive state shared between the stdout/stderr
/// readability handlers, the termination handler, and the timeout watchdog so
/// `GitService.runGit` resumes its continuation exactly once, regardless of the
/// order in which those events fire.
///
/// It lives here rather than in `GitService.swift` because that file is the
/// module's largest and this is the one self-contained piece of it: the process
/// transport's private bookkeeping, with a single construction site. Module
/// visibility is the price of the move — nothing outside `GitService.runProcess`
/// should build one.
final class GitProcessState: @unchecked Sendable {
    enum Stream { case standardOutput, standardError }

    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var outClosed = false
    private var errClosed = false
    private var exitStatus: Int32?
    private var command = ""
    private var terminalError: Error?
    private var outcomeConsumed = false
    /// Severity for a non-zero exit, chosen by the caller. See
    /// `GitService.runGit(at:arguments:timeout:failureLogLevel:)`.
    private let failureLogLevel: LogLevel

    init(failureLogLevel: LogLevel) {
        self.failureLogLevel = failureLogLevel
    }

    func append(_ chunk: Data, to stream: Stream) {
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .standardOutput: outData.append(chunk)
        case .standardError: errData.append(chunk)
        }
    }

    func markStreamClosed(_ stream: Stream) {
        lock.lock(); defer { lock.unlock() }
        switch stream {
        case .standardOutput: outClosed = true
        case .standardError: errClosed = true
        }
    }

    func markExited(status: Int32, command: String) {
        lock.lock(); defer { lock.unlock() }
        exitStatus = status
        self.command = command
    }

    func markTimedOut(after seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if terminalError == nil {
            terminalError = NSError(
                domain: "GitError",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "git timed out after \(Int(seconds))s"]
            )
        }
    }

    func markLaunchFailure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if terminalError == nil { terminalError = error }
    }

    /// True once a terminal outcome is known: either a fatal error (timeout /
    /// launch failure) occurred, or the process exited and both streams drained.
    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        if terminalError != nil { return true }
        return exitStatus != nil && outClosed && errClosed
    }

    var hasFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return outcomeConsumed
    }

    /// Returns the resolved outcome exactly once; subsequent calls return nil.
    func consumeOutcome() -> ResolvedOutcome? {
        lock.lock(); defer { lock.unlock() }
        guard !outcomeConsumed else { return nil }
        if let terminalError {
            outcomeConsumed = true
            return .failure(terminalError)
        }
        guard let exitStatus, outClosed, errClosed else { return nil }
        outcomeConsumed = true
        if exitStatus != 0 {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppLogger.log(
                failureLogLevel,
                "git command failed: \(command) — \(message)",
                category: "Git"
            )
            return .failure(NSError(
                domain: "GitError",
                code: Int(exitStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
        return .success(String(data: outData, encoding: .utf8) ?? "")
    }

    enum ResolvedOutcome {
        case success(String)
        case failure(Error)
    }
}
