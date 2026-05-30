import Foundation

struct GitRepositoryInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
}

struct GitStatusFile: Identifiable, Hashable {
    let id = UUID()
    let relativePath: String
    let status: String // "M", "A", "D", "?", "R"
    let isStaged: Bool
}

/// Thread-safe lifecycle/outcome tracker for a single `git` subprocess.
///
/// Encapsulates the concurrency-sensitive state shared between the stdout/stderr
/// readability handlers, the termination handler, and the timeout watchdog so
/// `GitService.runGit` resumes its continuation exactly once, regardless of the
/// order in which those events fire.
private final class GitProcessState: @unchecked Sendable {
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
    fileprivate func consumeOutcome() -> ResolvedOutcome? {
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
            AppLogger.error("git command failed: \(command) — \(message)", category: "Git")
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

class GitService {
    static let shared = GitService()

    private init() {}

    private let indexLock = NSLock()
    private var _indexBusy = false

    /// Acquires a logical lock so only one index-writing batch runs at a time.
    /// Returns false if another batch is already running.
    func acquireIndexGuard() -> Bool {
        indexLock.lock()
        defer { indexLock.unlock() }
        if _indexBusy { return false }
        _indexBusy = true
        return true
    }

    func releaseIndexGuard() {
        indexLock.lock()
        defer { indexLock.unlock() }
        _indexBusy = false
    }

    /// Scans a workspace's primary path and additional paths for folders containing a `.git` subdirectory.
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
        var repos: [GitRepositoryInfo] = []
        let allPaths = [primaryPath] + additionalPaths
        
        for path in allPaths where !path.isEmpty {
            let expandedPath = NSString(string: path).expandingTildeInPath
            var isDir: ObjCBool = false
            let fm = FileManager.default
            
            if fm.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue {
                let gitPath = URL(fileURLWithPath: expandedPath).appendingPathComponent(".git")
                if fm.fileExists(atPath: gitPath.path, isDirectory: &isDir), isDir.boolValue {
                    let name = URL(fileURLWithPath: expandedPath).lastPathComponent
                    repos.append(GitRepositoryInfo(name: name, path: expandedPath))
                }
            }
        }
        return repos
    }
    
    /// Default wall-clock budget for local index/read git operations.
    private static let defaultGitTimeout: TimeInterval = 30
    /// Extended budget for network operations (fetch/pull/push) that legitimately run longer.
    private static let networkGitTimeout: TimeInterval = 300

    /// Spawns a git subprocess and returns standard output or throws standard error.
    ///
    /// Robustness guarantees (a single git invocation must never be able to
    /// deadlock the Repository panel):
    /// - `stdin` is detached to `/dev/null` and interactive prompts are disabled
    ///   so git can never block waiting for credentials, a username, or a pager
    ///   inside a GUI process that has no controlling terminal.
    /// - stdout/stderr are drained with non-blocking readability handlers, so a
    ///   stream larger than the OS pipe buffer (~64KB) can never wedge the child.
    /// - Completion fires when the process exits and both streams reach EOF, or
    ///   when the hard `timeout` elapses — whichever comes first. A lingering
    ///   grandchild that keeps a pipe open therefore cannot stall us forever.
    /// - The continuation is resumed exactly once, guarded by a lock.
    private func runGit(
        at repoPath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let command = (["git"] + arguments).joined(separator: " ")
        AppLogger.debug("git \(arguments.joined(separator: " "))", category: "Git")

        let budget = timeout ?? Self.defaultGitTimeout
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoPath] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Detach stdin: a GUI process has no tty, so any git command that tries
        // to read input (credential/username prompts) would otherwise block
        // forever. An empty, closed stdin makes such reads return EOF instantly.
        process.standardInput = FileHandle.nullDevice
        // Force fully non-interactive, non-paged behavior regardless of the
        // user's global git config.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let state = GitProcessState()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let finalize: () -> Void = { [outPipe, errPipe] in
                guard let outcome = state.consumeOutcome() else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                switch outcome {
                case let .success(output):
                    continuation.resume(returning: output)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    state.markStreamClosed(.standardOutput)
                } else {
                    state.append(chunk, to: .standardOutput)
                }
                if state.isComplete { finalize() }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    state.markStreamClosed(.standardError)
                } else {
                    state.append(chunk, to: .standardError)
                }
                if state.isComplete { finalize() }
            }

            process.terminationHandler = { proc in
                state.markExited(status: proc.terminationStatus, command: command)
                if state.isComplete { finalize() }
            }

            // Hard safety net: terminate a stuck git process so a single hung
            // subprocess can never deadlock the whole Repository panel.
            DispatchQueue.global().asyncAfter(deadline: .now() + budget) {
                guard !state.hasFinished else { return }
                AppLogger.error("git command timed out after \(Int(budget))s: \(command)", category: "Git")
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                state.markTimedOut(after: budget)
                finalize()
            }

            do {
                try process.run()
            } catch {
                state.markLaunchFailure(error)
                finalize()
            }
        }
    }
    
    func getCurrentBranch(at repoPath: String) async -> String {
        do {
            let output = try await runGit(at: repoPath, arguments: ["branch", "--show-current"])
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "unknown"
        }
    }
    
    func getLocalBranches(at repoPath: String) async -> [String] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["branch", "--format=%(refname:short)"])
            return output.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }
    
    func checkoutBranch(_ branch: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["checkout", branch])
    }
    
    func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws {
        var args = ["checkout", "-b", branch]
        if let base = base {
            args.append(base)
        }
        _ = try await runGit(at: repoPath, arguments: args)
    }
    
    func getStatusFiles(at repoPath: String) async -> [GitStatusFile] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "status", "--porcelain"])
            return GitService.parseStatusPorcelain(output)
        } catch {
            return []
        }
    }

    static func parseStatusPorcelain(_ output: String) -> [GitStatusFile] {
        var files: [GitStatusFile] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            guard line.count >= 3 else { continue }
            let xIndex = line.index(line.startIndex, offsetBy: 0)
            let yIndex = line.index(line.startIndex, offsetBy: 1)
            let x = String(line[xIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let y = String(line[yIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

            let fileStartIndex = line.index(line.startIndex, offsetBy: 3)
            let relativePath = String(line[fileStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if x == "?" && y == "?" {
                files.append(GitStatusFile(relativePath: relativePath, status: "?", isStaged: false))
            } else {
                if !x.isEmpty {
                    files.append(GitStatusFile(relativePath: relativePath, status: x, isStaged: true))
                }
                if !y.isEmpty {
                    files.append(GitStatusFile(relativePath: relativePath, status: y, isStaged: false))
                }
            }
        }
        return files
    }
    
    func stageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", relativePath])
    }
    
    func stageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", "."])
    }
    
    func unstageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD", relativePath])
    }
    
    func unstageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD"])
    }
    
    func commit(message: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["commit", "-m", message])
    }
    
    func pull(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["pull"], timeout: Self.networkGitTimeout)
    }
    
    func push(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["push"], timeout: Self.networkGitTimeout)
    }

    func pullRebase(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["pull", "--rebase"], timeout: Self.networkGitTimeout)
    }

    /// Returns ahead/behind counts vs. the upstream tracking branch. Returns nil when no upstream is configured.
    func getAheadBehind(at repoPath: String) async -> (ahead: Int, behind: Int)? {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-list", "--left-right", "--count", "@{u}...HEAD"]
            )
            let parts = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2,
                  let behind = Int(parts[0]),
                  let ahead = Int(parts[1]) else { return nil }
            return (ahead, behind)
        } catch {
            return nil
        }
    }

    func hasUpstream(at repoPath: String) async -> Bool {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
            )
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Returns the staged diff (for commit message generation). Truncated to `limit` bytes.
    func getStagedDiff(at repoPath: String, limit: Int = 8 * 1024) async -> String {
        do {
            let output = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "diff", "--cached"])
            if output.utf8.count <= limit { return output }
            let prefix = String(output.prefix(limit))
            return prefix + "\n…[truncated]"
        } catch {
            return ""
        }
    }

    /// Returns the most recent N commit subjects from HEAD for tone matching.
    func getRecentCommitSubjects(at repoPath: String, count: Int = 5) async -> [String] {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["log", "-n", "\(count)", "--pretty=%s"]
            )
            return output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    /// Returns the merge-base ref between two refs (typically `origin/main` and HEAD).
    func getMergeBase(at repoPath: String, refA: String, refB: String) async -> String? {
        do {
            let output = try await runGit(at: repoPath, arguments: ["merge-base", refA, refB])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Returns the default upstream base branch, e.g. "origin/main", as detected from refs/remotes/origin/HEAD.
    func getDefaultBaseBranch(at repoPath: String) async -> String {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["symbolic-ref", "refs/remotes/origin/HEAD"]
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("refs/remotes/") {
                return String(trimmed.dropFirst("refs/remotes/".count))
            }
        } catch {
            // ignore
        }
        return "origin/main"
    }

    /// Returns the formatted log between `base..branch` for PR body generation.
    func getBranchLog(at repoPath: String, base: String, branch: String, limit: Int = 30) async -> String {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: [
                    "log",
                    "\(base)..\(branch)",
                    "-n", "\(limit)",
                    "--pretty=- %s%n%w(0,2,2)%b"
                ]
            )
            return output
        } catch {
            return ""
        }
    }

    /// Returns the diffstat of `base...branch` for PR body generation.
    func getBranchDiffStat(at repoPath: String, base: String, branch: String) async -> String {
        do {
            return try await runGit(
                at: repoPath,
                arguments: ["diff", "--stat", "\(base)...\(branch)"]
            )
        } catch {
            return ""
        }
    }
    
    func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        
        do {
            let unstagedOutput = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "diff", "--numstat"])
            let stagedOutput = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "diff", "--cached", "--numstat"])
            
            let allLines = unstagedOutput.split(separator: "\n") + stagedOutput.split(separator: "\n")
            for line in allLines {
                // Split by spaces or tabs
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }
                
                guard parts.count >= 2 else { continue }
                if let add = Int(parts[0]) {
                    additions += add
                }
                if let del = Int(parts[1]) {
                    deletions += del
                }
            }
        } catch {
            // Graceful fallback
        }
        return (additions, deletions)
    }
    
    func getRemoteOriginURL(at repoPath: String) async -> String? {
        do {
            let output = try await runGit(at: repoPath, arguments: ["config", "--get", "remote.origin.url"])
            let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { return nil }
            
            var webURL = url
            if webURL.hasPrefix("git@github.com:") {
                webURL = webURL.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            }
            if webURL.hasSuffix(".git") {
                webURL = String(webURL.dropLast(4))
            }
            return webURL
        } catch {
            return nil
        }
    }
}
