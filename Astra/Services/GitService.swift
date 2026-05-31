import Foundation

struct GitRepositoryInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let subtitle: String
    let roleLabel: String

    init(name: String, path: String, subtitle: String = "", roleLabel: String = "") {
        self.name = name
        self.path = WorkspacePathPresentation.standardizedPath(path)
        self.subtitle = subtitle
        self.roleLabel = roleLabel
    }
}

struct GitStatusFile: Identifiable, Hashable {
    let id = UUID()
    let relativePath: String
    let status: String // "M", "A", "D", "?", "R"
    let isStaged: Bool
}

/// A single git worktree as reported by `git worktree list --porcelain`.
///
/// The main worktree (the original clone) is flagged via `isPrimary` so the UI
/// can present it as the repository "Root" rather than as a removable worktree.
struct GitWorktreeInfo: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let branch: String?      // short branch name, nil when detached/bare
    let head: String?        // commit SHA
    let isPrimary: Bool      // the repository's main working tree
    let isDetached: Bool
    let isLocked: Bool
    let isPrunable: Bool

    /// Folder name, used as a stable display label when no branch is attached.
    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Human-facing label: branch when available, else the folder name.
    var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return folderName
    }
}

/// Failure modes specific to git worktree management, surfaced so the UI can
/// give actionable guidance instead of a raw git error string.
enum GitWorktreeError: LocalizedError {
    case branchAlreadyCheckedOut(String)
    case invalidBranchName(String)
    case cannotRemovePrimary
    case worktreeDirty(String)

    var errorDescription: String? {
        switch self {
        case let .branchAlreadyCheckedOut(branch):
            return "Branch \"\(branch)\" is already checked out in another worktree."
        case let .invalidBranchName(name):
            return "\"\(name)\" is not a valid branch name."
        case .cannotRemovePrimary:
            return "The repository root cannot be removed as a worktree."
        case let .worktreeDirty(path):
            return "Worktree at \(path) has uncommitted changes. Discard or commit them first."
        }
    }
}

/// Lightweight reference to an existing GitHub pull request, used to link to a
/// branch's open PR instead of offering to create a duplicate.
struct GitHubPullRequestRef: Equatable, Sendable, Codable {
    let number: Int
    let url: String
    var title: String = ""
    var isDraft: Bool = false
    var state: String = "OPEN"

    /// Builds a minimal reference from a freshly created PR URL (`…/pull/<n>`),
    /// so the panel can flip to the link state immediately after creation while
    /// a full lookup fills in the remaining metadata.
    static func fromCreatedURL(_ url: String) -> GitHubPullRequestRef? {
        guard let range = url.range(of: "/pull/") else { return nil }
        let digits = url[range.upperBound...].prefix { $0.isNumber }
        guard let number = Int(digits) else { return nil }
        return GitHubPullRequestRef(number: number, url: url)
    }
}

struct GitHubPullRequestComment: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let body: String
    let path: String?
    let line: Int?
    let url: String
    let createdAt: String
    let isReviewThread: Bool

    var locationLabel: String {
        guard let path, !path.isEmpty else { return "Conversation" }
        if let line, line > 0 {
            return "\(path):\(line)"
        }
        return path
    }

    var preview: String {
        Self.compactBody(body, maxLength: 180)
    }

    private static func compactBody(_ raw: String, maxLength: Int) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

struct GitHubPullRequestCommentSummary: Equatable, Sendable {
    let pullRequest: GitHubPullRequestRef
    let comments: [GitHubPullRequestComment]
    let unresolvedThreadCount: Int
    let issueCommentCount: Int
    let fetchedAt: Date

    var totalCommentCount: Int { comments.count }
    var hasComments: Bool { totalCommentCount > 0 }
}

/// Outcome of the passive "does this branch already have a PR?" enrichment.
/// `unavailable` is deliberately distinct from `none` so callers can log and
/// present a degraded state without treating an auth/network/tooling failure as
/// proof that no PR exists.
enum GitHubPullRequestLookupResult: Equatable, Sendable {
    case found(GitHubPullRequestRef)
    case none
    case unavailable(String)

    var pullRequest: GitHubPullRequestRef? {
        if case let .found(ref) = self { return ref }
        return nil
    }
}

enum GitHubPullRequestCommentLookupResult: Equatable, Sendable {
    case found(GitHubPullRequestCommentSummary)
    case unavailable(String)

    var summary: GitHubPullRequestCommentSummary? {
        if case let .found(summary) = self { return summary }
        return nil
    }
}

/// Failure modes for GitHub operations performed through the `gh` CLI.
enum GitHubCLIError: LocalizedError {
    case notInstalled
    case notAuthenticated(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "GitHub CLI (gh) is not installed."
        case let .notAuthenticated(detail):
            return "GitHub CLI is not authenticated. Run `gh auth login`. (\(detail))"
        case let .commandFailed(detail):
            return detail.isEmpty ? "gh pr create failed." : detail
        }
    }
}

private struct GitHubPullRequestCommentsGraphQLResponse: Decodable {
    struct GraphQLError: Decodable {
        let message: String
    }

    struct Actor: Decodable {
        let login: String?
    }

    struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case nodes
        }
    }

    struct IssueComment: Decodable {
        let author: Actor?
        let body: String
        let createdAt: String
        let url: String
    }

    struct ReviewComment: Decodable {
        let author: Actor?
        let body: String
        let createdAt: String
        let url: String
    }

    struct ReviewThread: Decodable {
        let isResolved: Bool
        let path: String?
        let line: Int?
        let comments: Connection<ReviewComment>
    }

    struct PullRequest: Decodable {
        let comments: Connection<IssueComment>
        let reviewThreads: Connection<ReviewThread>
    }

    struct Repository: Decodable {
        let pullRequest: PullRequest?
    }

    struct DataNode: Decodable {
        let repository: Repository?
    }

    let data: DataNode?
    let errors: [GraphQLError]?
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

    /// Scans configured workspace roots for folders that are themselves git repositories.
    /// Non-git additional folders remain browsable in the Files shelf but are not
    /// returned as Repository-panel candidates.
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
        let descriptors = WorkspacePathPresentation.descriptors(
            primaryPath: primaryPath,
            additionalPaths: additionalPaths
        )
        let repos = descriptors.compactMap { descriptor -> GitRepositoryInfo? in
            guard WorkspacePathPresentation.isGitRepository(at: descriptor.path) else { return nil }
            return GitRepositoryInfo(
                name: descriptor.title,
                path: descriptor.path,
                subtitle: descriptor.subtitle,
                roleLabel: descriptor.roleLabel
            )
        }
        AppLogger.audit(.gitRepositoryScan, category: "Git", fields: [
            "configured_paths": "\(descriptors.count)",
            "repositories": "\(repos.count)",
            "non_git_paths": "\(max(0, descriptors.count - repos.count))"
        ], level: .debug)
        return repos
    }
    
    /// Default wall-clock budget for local index/read git operations.
    private static let defaultGitTimeout: TimeInterval = 30
    /// Extended budget for network operations (fetch/pull/push) that legitimately run longer.
    private static let networkGitTimeout: TimeInterval = 300
    private static let pullRequestCommentsGraphQLQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          comments(first: 20) {
            nodes {
              author { login }
              body
              createdAt
              url
            }
          }
          reviewThreads(first: 50) {
            nodes {
              isResolved
              path
              line
              comments(first: 10) {
                nodes {
                  author { login }
                  body
                  createdAt
                  url
                }
              }
            }
          }
        }
      }
    }
    """

    /// Builds the non-interactive environment used for every git invocation.
    ///
    /// Disables terminal prompts, pagers, and optional index locks so git can
    /// never block waiting for a controlling terminal that a GUI process lacks.
    private static func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    /// Spawns a git subprocess and returns standard output or throws standard error.
    private func runGit(
        at repoPath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> String {
        AppLogger.debug("git \(arguments.joined(separator: " "))", category: "Git")
        return try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "-C", repoPath] + arguments,
            environment: Self.gitEnvironment(),
            timeout: timeout ?? Self.defaultGitTimeout,
            label: (["git"] + arguments).joined(separator: " ")
        )
    }

    /// Runs an external process and returns standard output, or throws on a
    /// non-zero exit, a launch failure, or a timeout.
    ///
    /// Robustness guarantees (a single invocation must never be able to deadlock
    /// the caller):
    /// - `stdin` is detached to `/dev/null` so the child can never block waiting
    ///   for interactive input inside a process that has no controlling terminal.
    /// - stdout/stderr are drained with non-blocking readability handlers, so a
    ///   stream larger than the OS pipe buffer (~64KB) can never wedge the child.
    /// - Completion fires when the process exits and both streams reach EOF, or
    ///   when the hard `timeout` elapses — whichever comes first. A lingering
    ///   grandchild that keeps a pipe open therefore cannot stall us forever.
    /// - The continuation is resumed exactly once, guarded by a lock.
    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        label: String,
        currentDirectory: String? = nil
    ) async throws -> String {
        let command = label
        let budget = timeout
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
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

    #if DEBUG
    /// Test seam: exercises the exact `runProcess` machinery (drain, timeout,
    /// exactly-once completion) against an arbitrary executable so regression
    /// tests can prove a hung subprocess is killed within its budget rather than
    /// deadlocking forever.
    func runProcessForTesting(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        try await runProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout,
            label: ([executableURL.lastPathComponent] + arguments).joined(separator: " ")
        )
    }
    #endif

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
            let output = try await runGit(at: repoPath, arguments: ["--no-optional-locks", "status", "--porcelain=v1", "-z"])
            return GitService.parseStatusPorcelainZ(output)
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
            let rawPath = String(line[fileStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let relativePath = displayPathForPorcelainPath(rawPath, stagedStatus: x, unstagedStatus: y)

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

    /// Parses `git status --porcelain=v1 -z`. The NUL-delimited form avoids
    /// quoting ambiguity and reports rename/copy entries as `XY newPath\0oldPath`.
    static func parseStatusPorcelainZ(_ output: String) -> [GitStatusFile] {
        var files: [GitStatusFile] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let x = String(record[record.startIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let yIndex = record.index(after: record.startIndex)
            let y = String(record[yIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pathStart = record.index(record.startIndex, offsetBy: 3)
            let relativePath = String(record[pathStart...])

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

            if x == "R" || x == "C" || y == "R" || y == "C" {
                index += 1 // skip original path payload
            }
            index += 1
        }
        return files
    }

    private static func displayPathForPorcelainPath(
        _ rawPath: String,
        stagedStatus: String,
        unstagedStatus: String
    ) -> String {
        guard stagedStatus == "R" || stagedStatus == "C" || unstagedStatus == "R" || unstagedStatus == "C",
              let range = rawPath.range(of: " -> ", options: .backwards) else {
            return rawPath
        }
        return String(rawPath[range.upperBound...])
    }
    
    func stageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", "--", relativePath])
    }
    
    func stageAll(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["add", "."])
    }
    
    func unstageFile(_ relativePath: String, at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["reset", "HEAD", "--", relativePath])
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

    /// Pushes the current branch and sets `origin/<branch>` as its upstream.
    /// Used to publish a branch that has never been pushed before.
    func pushSetUpstream(branch: String, remote: String = "origin", at repoPath: String) async throws {
        _ = try await runGit(
            at: repoPath,
            arguments: ["push", "--set-upstream", remote, branch],
            timeout: Self.networkGitTimeout
        )
    }

    /// Returns true when the repository has at least one configured remote.
    func hasRemote(at repoPath: String) async -> Bool {
        do {
            let output = try await runGit(at: repoPath, arguments: ["remote"])
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    /// Creates a GitHub pull request via the `gh` CLI and returns the new PR URL.
    ///
    /// Reuses the user's existing `gh` authentication rather than storing a
    /// GitHub token. Throws `GitHubCLIError` when `gh` is missing, unauthenticated,
    /// or the command fails, so callers can fall back to the web compare flow.
    func createPullRequest(
        repoPath: String,
        base: String,
        head: String,
        title: String,
        body: String,
        ghPathOverride: String? = nil
    ) async throws -> String {
        let ghPath = ghPathOverride ?? RuntimePathResolver.detectExecutablePath(named: "gh")
        guard !ghPath.isEmpty, FileManager.default.isExecutableFile(atPath: ghPath) else {
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "base": base,
                "head": head,
                "result": "gh_not_installed"
            ], level: .warning)
            throw GitHubCLIError.notInstalled
        }

        let normalizedBase = GitService.normalizeBaseBranch(base)
        let arguments = [
            "pr", "create",
            "--base", normalizedBase,
            "--head", head,
            "--title", title,
            "--body", body
        ]
        do {
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "base": normalizedBase,
                "head": head,
                "title_bytes": "\(title.utf8.count)",
                "body_bytes": "\(body.utf8.count)",
                "method": "gh"
            ], level: .info)
            let output = try await runProcess(
                executableURL: URL(fileURLWithPath: ghPath),
                arguments: arguments,
                environment: RuntimeProcessEnvironment.enriched(),
                timeout: Self.networkGitTimeout,
                label: "gh pr create",
                currentDirectory: repoPath
            )
            guard let url = GitService.firstURL(in: output) else {
                throw GitHubCLIError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "base": normalizedBase,
                "head": head,
                "result": "created",
                "url": url
            ], level: .info, fieldMaxLength: 240)
            return url
        } catch let error as GitHubCLIError {
            throw error
        } catch let error as NSError {
            let message = error.localizedDescription
            // `gh` reports an existing PR with its URL — treat that as success.
            if let existing = GitService.firstURL(in: message) {
                AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                    "base": normalizedBase,
                    "head": head,
                    "result": "existing",
                    "url": existing
                ], level: .info, fieldMaxLength: 240)
                return existing
            }
            if message.localizedCaseInsensitiveContains("auth")
                || message.localizedCaseInsensitiveContains("logged") {
                AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                    "base": normalizedBase,
                    "head": head,
                    "result": "auth_failed",
                    "detail": message
                ], level: .warning, fieldMaxLength: 240)
                throw GitHubCLIError.notAuthenticated(message)
            }
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "base": normalizedBase,
                "head": head,
                "result": "failed",
                "detail": message
            ], level: .error, fieldMaxLength: 240)
            throw GitHubCLIError.commandFailed(message)
        }
    }

    /// Finds the open pull request whose head is `head`, or nil when there is
    /// none. Kept as an optional convenience wrapper for call sites/tests that
    /// only need the PR reference; use `lookupOpenPullRequest` when a diagnostic
    /// distinction between "none" and "lookup failed" matters.
    func findOpenPullRequest(
        repoPath: String,
        head: String,
        ghPathOverride: String? = nil
    ) async -> GitHubPullRequestRef? {
        await lookupOpenPullRequest(
            repoPath: repoPath,
            head: head,
            ghPathOverride: ghPathOverride
        ).pullRequest
    }

    /// Looks up the current branch's open pull request through `gh`, logging the
    /// degraded cases so a missing/auth-broken/network-broken GitHub CLI cannot
    /// masquerade as "no PR exists" during diagnostics.
    func lookupOpenPullRequest(
        repoPath: String,
        head: String,
        ghPathOverride: String? = nil
    ) async -> GitHubPullRequestLookupResult {
        let ghPath = ghPathOverride ?? RuntimePathResolver.detectExecutablePath(named: "gh")
        guard !ghPath.isEmpty, FileManager.default.isExecutableFile(atPath: ghPath) else {
            AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                "head": head,
                "result": "unavailable",
                "reason": "gh_not_installed"
            ], level: .debug)
            return .unavailable("GitHub CLI (gh) is not installed.")
        }
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHead.isEmpty else {
            AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                "result": "unavailable",
                "reason": "empty_head"
            ], level: .debug)
            return .unavailable("Current branch is empty.")
        }

        let arguments = [
            "pr", "list",
            "--head", trimmedHead,
            "--state", "open",
            "--json", "number,url,title,isDraft,state",
            "--limit", "1"
        ]
        do {
            let output = try await runProcess(
                executableURL: URL(fileURLWithPath: ghPath),
                arguments: arguments,
                environment: RuntimeProcessEnvironment.enriched(),
                timeout: Self.networkGitTimeout,
                label: "gh pr list",
                currentDirectory: repoPath
            )
            guard let decoded = GitService.decodeOpenPullRequests(from: output) else {
                AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                    "head": trimmedHead,
                    "result": "unavailable",
                    "reason": "invalid_json",
                    "stdout_sample": String(output.prefix(240))
                ], level: .warning, fieldMaxLength: 240)
                return .unavailable("GitHub CLI returned PR data ASTRA could not read.")
            }
            if let pr = decoded.first(where: { $0.state.uppercased() == "OPEN" }) ?? decoded.first {
                AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                    "head": trimmedHead,
                    "result": "found",
                    "number": "\(pr.number)"
                ], level: .debug)
                return .found(pr)
            }
            AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                "head": trimmedHead,
                "result": "none"
            ], level: .debug)
            return .none
        } catch {
            AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: [
                "head": trimmedHead,
                "result": "unavailable",
                "reason": error.localizedDescription
            ], level: .warning, fieldMaxLength: 240)
            return .unavailable(error.localizedDescription)
        }
    }

    /// Fetches recent PR conversation comments and unresolved review-thread
    /// comments for the Repository panel. This is intentionally read-only and
    /// uses `gh api graphql` so inline review threads are available even when
    /// `gh pr view --comments` omits enough structure to drive an actionable UI.
    func lookupPullRequestComments(
        repoPath: String,
        pullRequest: GitHubPullRequestRef,
        ghPathOverride: String? = nil
    ) async -> GitHubPullRequestCommentLookupResult {
        let ghPath = ghPathOverride ?? RuntimePathResolver.detectExecutablePath(named: "gh")
        guard !ghPath.isEmpty, FileManager.default.isExecutableFile(atPath: ghPath) else {
            AppLogger.audit(.gitPullRequestComments, category: "Git", fields: [
                "number": "\(pullRequest.number)",
                "result": "unavailable",
                "reason": "gh_not_installed"
            ], level: .debug)
            return .unavailable("GitHub CLI (gh) is not installed.")
        }
        guard let locator = GitService.pullRequestLocator(from: pullRequest.url) else {
            AppLogger.audit(.gitPullRequestComments, category: "Git", fields: [
                "number": "\(pullRequest.number)",
                "result": "unavailable",
                "reason": "unsupported_url"
            ], level: .warning)
            return .unavailable("ASTRA could not identify the GitHub repository for this pull request.")
        }

        let arguments = [
            "api", "graphql",
            "-f", "query=\(Self.pullRequestCommentsGraphQLQuery)",
            "-F", "owner=\(locator.owner)",
            "-F", "name=\(locator.name)",
            "-F", "number=\(pullRequest.number)"
        ]
        do {
            let output = try await runProcess(
                executableURL: URL(fileURLWithPath: ghPath),
                arguments: arguments,
                environment: RuntimeProcessEnvironment.enriched(),
                timeout: Self.networkGitTimeout,
                label: "gh api graphql pull request comments",
                currentDirectory: repoPath
            )
            guard let summary = GitService.decodePullRequestComments(
                from: output,
                pullRequest: pullRequest
            ) else {
                AppLogger.audit(.gitPullRequestComments, category: "Git", fields: [
                    "number": "\(pullRequest.number)",
                    "result": "unavailable",
                    "reason": "invalid_json",
                    "stdout_sample": String(output.prefix(240))
                ], level: .warning, fieldMaxLength: 240)
                return .unavailable("GitHub CLI returned PR comments ASTRA could not read.")
            }
            AppLogger.audit(.gitPullRequestComments, category: "Git", fields: [
                "number": "\(pullRequest.number)",
                "result": "found",
                "comments": "\(summary.totalCommentCount)",
                "unresolved_threads": "\(summary.unresolvedThreadCount)"
            ], level: .debug)
            return .found(summary)
        } catch {
            AppLogger.audit(.gitPullRequestComments, category: "Git", fields: [
                "number": "\(pullRequest.number)",
                "result": "unavailable",
                "reason": error.localizedDescription
            ], level: .warning, fieldMaxLength: 240)
            return .unavailable(error.localizedDescription)
        }
    }

    /// Decodes the first open PR from `gh pr list --json …` array output.
    static func parseOpenPullRequest(from json: String) -> GitHubPullRequestRef? {
        guard let list = decodeOpenPullRequests(from: json) else { return nil }
        return list.first { $0.state.uppercased() == "OPEN" } ?? list.first
    }

    static func decodeOpenPullRequests(from json: String) -> [GitHubPullRequestRef]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([GitHubPullRequestRef].self, from: data)
    }

    static func decodePullRequestComments(
        from json: String,
        pullRequest: GitHubPullRequestRef,
        fetchedAt: Date = Date()
    ) -> GitHubPullRequestCommentSummary? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let response = try? JSONDecoder().decode(GitHubPullRequestCommentsGraphQLResponse.self, from: data) else {
            return nil
        }
        if let errors = response.errors, !errors.isEmpty { return nil }
        guard let pr = response.data?.repository?.pullRequest else { return nil }

        var comments: [GitHubPullRequestComment] = []
        let unresolvedThreads = pr.reviewThreads.nodes.filter { !$0.isResolved }
        for thread in unresolvedThreads {
            for node in thread.comments.nodes {
                comments.append(GitHubPullRequestComment(
                    id: node.url.isEmpty ? "\(thread.path ?? "review"):\(thread.line ?? 0):\(comments.count)" : node.url,
                    author: node.author?.login ?? "unknown",
                    body: node.body,
                    path: thread.path,
                    line: thread.line,
                    url: node.url,
                    createdAt: node.createdAt,
                    isReviewThread: true
                ))
            }
        }

        let issueComments = pr.comments.nodes.map { node in
            GitHubPullRequestComment(
                id: node.url.isEmpty ? "conversation:\(node.createdAt):\(node.body.count)" : node.url,
                author: node.author?.login ?? "unknown",
                body: node.body,
                path: nil,
                line: nil,
                url: node.url,
                createdAt: node.createdAt,
                isReviewThread: false
            )
        }
        comments.append(contentsOf: issueComments)

        return GitHubPullRequestCommentSummary(
            pullRequest: pullRequest,
            comments: comments,
            unresolvedThreadCount: unresolvedThreads.count,
            issueCommentCount: issueComments.count,
            fetchedAt: fetchedAt
        )
    }

    static func pullRequestLocator(from url: String) -> (owner: String, name: String)? {
        guard let parsed = URL(string: url) else { return nil }
        let components = parsed.pathComponents.filter { $0 != "/" }
        guard components.count >= 4,
              components[2] == "pull",
              Int(components[3]) != nil else {
            return nil
        }
        return (components[0], components[1])
    }

    /// Strips a leading `<remote>/` (e.g. `origin/`) from a base ref so it is a
    /// plain branch name suitable for `gh pr create --base`.
    static func normalizeBaseBranch(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("origin/") {
            return String(trimmed.dropFirst("origin/".count))
        }
        return trimmed
    }

    /// Returns the first http(s) URL found in arbitrary CLI output.
    static func firstURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "()<>\"'"))
            if candidate.hasPrefix("https://") || candidate.hasPrefix("http://") {
                return candidate
            }
        }
        return nil
    }

    /// Returns the number of commits reachable from HEAD that are not present on
    /// any remote-tracking branch. This is upstream-independent: it reports
    /// unpushed work even for a branch that has never been published, and is 0
    /// once every local commit exists on a remote.
    func getUnpushedCommitCount(at repoPath: String) async -> Int {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-list", "--count", "HEAD", "--not", "--remotes"]
            )
            return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } catch {
            return 0
        }
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

    func getUpstreamBranchRef(at repoPath: String) async -> String? {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    func getRemotes(at repoPath: String) async -> [String] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["remote"])
            return output
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    func getDefaultRemote(at repoPath: String) async -> String? {
        if let upstream = await getUpstreamBranchRef(at: repoPath),
           let slash = upstream.firstIndex(of: "/") {
            let remote = String(upstream[..<slash])
            if !remote.isEmpty { return remote }
        }
        let remotes = await getRemotes(at: repoPath)
        if remotes.contains("origin") { return "origin" }
        return remotes.first
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

    /// Returns the default upstream base branch, e.g. `origin/main`, preferring
    /// the selected/default remote instead of assuming every repository uses
    /// `origin`.
    func getDefaultBaseBranch(at repoPath: String, remote: String? = nil) async -> String {
        let selectedRemote: String
        if let remote, !remote.isEmpty {
            selectedRemote = remote
        } else {
            selectedRemote = await getDefaultRemote(at: repoPath) ?? "origin"
        }
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["symbolic-ref", "refs/remotes/\(selectedRemote)/HEAD"]
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("refs/remotes/") {
                return String(trimmed.dropFirst("refs/remotes/".count))
            }
        } catch {
            // ignore
        }

        for candidate in ["main", "master"] {
            do {
                _ = try await runGit(
                    at: repoPath,
                    arguments: ["rev-parse", "--verify", "--quiet", "refs/remotes/\(selectedRemote)/\(candidate)"]
                )
                return "\(selectedRemote)/\(candidate)"
            } catch {
                continue
            }
        }
        return "\(selectedRemote)/main"
    }

    /// Returns the formatted log between `base..branch` for PR body generation.
    func getBranchLog(
        at repoPath: String,
        base: String,
        branch: String,
        limit: Int = 30,
        maxBytes: Int = 12 * 1024
    ) async -> String {
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
            return GitService.limitedContext(output, maxBytes: maxBytes)
        } catch {
            return ""
        }
    }

    /// Returns the diffstat of `base...branch` for PR body generation.
    func getBranchDiffStat(
        at repoPath: String,
        base: String,
        branch: String,
        maxBytes: Int = 12 * 1024
    ) async -> String {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["diff", "--stat", "\(base)...\(branch)"]
            )
            return GitService.limitedContext(output, maxBytes: maxBytes)
        } catch {
            return ""
        }
    }

    static func limitedContext(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0, text.utf8.count > maxBytes else { return text }
        var output = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            if used + width > maxBytes { break }
            output.unicodeScalars.append(scalar)
            used += width
        }
        return output + "\n...[truncated]"
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
    
    // MARK: - Worktrees

    /// Lists every worktree attached to the repository. The first entry is the
    /// primary working tree (the original checkout). Returns an empty array on
    /// failure so callers can treat "no worktrees" and "git failed" uniformly.
    func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo] {
        do {
            let output = try await runGit(at: repoPath, arguments: ["worktree", "list", "--porcelain"])
            return GitService.parseWorktreePorcelain(output)
        } catch {
            return []
        }
    }

    /// Parses `git worktree list --porcelain`. Records are separated by blank
    /// lines; the first record is always the primary working tree.
    static func parseWorktreePorcelain(_ output: String) -> [GitWorktreeInfo] {
        var result: [GitWorktreeInfo] = []
        let blocks = output.components(separatedBy: "\n\n")
        for (index, block) in blocks.enumerated() {
            var path: String?
            var branch: String?
            var head: String?
            var isDetached = false
            var isLocked = false
            var isPrunable = false

            for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine)
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                } else if line == "detached" {
                    isDetached = true
                } else if line == "locked" || line.hasPrefix("locked ") {
                    isLocked = true
                } else if line == "prunable" || line.hasPrefix("prunable ") {
                    isPrunable = true
                }
            }

            guard let path, !path.isEmpty else { continue }
            result.append(GitWorktreeInfo(
                path: path,
                branch: branch,
                head: head,
                isPrimary: index == 0,
                isDetached: isDetached,
                isLocked: isLocked,
                isPrunable: isPrunable
            ))
        }
        return result
    }

    /// Returns true when a local branch with the given name already exists.
    func localBranchExists(_ branch: String, at repoPath: String) async -> Bool {
        do {
            _ = try await runGit(
                at: repoPath,
                arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]
            )
            return true
        } catch {
            return false
        }
    }

    /// Computes the app-managed on-disk location for a new worktree, namespaced
    /// by repository so multiple repos never collide:
    /// `<worktreesRoot>/<repoName>/<sanitized-branch>`.
    static func worktreeLocation(
        repoPath: String,
        branch: String,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot
    ) -> String {
        let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
        let safeBranch = sanitizeForFolder(branch)
        return URL(fileURLWithPath: worktreesRoot, isDirectory: true)
            .appendingPathComponent(repoName, isDirectory: true)
            .appendingPathComponent(safeBranch, isDirectory: true)
            .path
    }

    /// Converts a branch name into a filesystem-safe folder component while
    /// keeping it recognizable (slashes become dashes, unsafe characters drop).
    static func sanitizeForFolder(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.replacingOccurrences(of: "/", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(replaced.unicodeScalars.filter { allowed.contains($0) })
        return filtered.isEmpty ? "worktree" : filtered
    }

    /// Creates a worktree at an app-managed location.
    ///
    /// When `createBranch` is true a new branch `branch` is created from `base`
    /// (defaults to the current HEAD); otherwise an existing branch is checked
    /// out into the new worktree. Returns the absolute worktree path on success.
    @discardableResult
    func addWorktree(
        repoPath: String,
        branch: String,
        createBranch: Bool,
        base: String? = nil,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot
    ) async throws -> String {
        let cleanBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBranch.isEmpty else { throw GitWorktreeError.invalidBranchName(branch) }

        let destination = GitService.worktreeLocation(
            repoPath: repoPath,
            branch: cleanBranch,
            worktreesRoot: worktreesRoot
        )

        // Ensure the parent directory exists; git creates the leaf itself.
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var arguments = ["worktree", "add"]
        if createBranch {
            arguments += ["-b", cleanBranch, destination]
            if let base, !base.isEmpty { arguments.append(base) }
        } else {
            arguments += [destination, cleanBranch]
        }

        do {
            _ = try await runGit(at: repoPath, arguments: arguments, timeout: Self.networkGitTimeout)
        } catch let error as NSError {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("already checked out")
                || message.localizedCaseInsensitiveContains("already used by worktree") {
                throw GitWorktreeError.branchAlreadyCheckedOut(cleanBranch)
            }
            if message.localizedCaseInsensitiveContains("not a valid")
                || message.localizedCaseInsensitiveContains("invalid ref") {
                throw GitWorktreeError.invalidBranchName(cleanBranch)
            }
            throw error
        }
        return destination
    }

    /// Removes a worktree. Refuses to remove the primary working tree. Without
    /// `force`, git itself refuses to remove a worktree with local changes,
    /// which we translate into a typed error so the UI can prompt the user.
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool = false) async throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(worktreePath)
        do {
            _ = try await runGit(at: repoPath, arguments: arguments)
        } catch let error as NSError {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("is a main working tree") {
                throw GitWorktreeError.cannotRemovePrimary
            }
            if message.localizedCaseInsensitiveContains("contains modified or untracked")
                || message.localizedCaseInsensitiveContains("use --force") {
                throw GitWorktreeError.worktreeDirty(worktreePath)
            }
            throw error
        }
    }

    /// Prunes administrative entries for worktrees whose directories were
    /// removed out from under git, keeping `git worktree list` accurate.
    func pruneWorktrees(at repoPath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["worktree", "prune"])
    }

    func getRemoteURL(at repoPath: String, remote: String? = nil) async -> String? {
        let selectedRemote: String
        if let remote, !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedRemote = remote
        } else if let detected = await getDefaultRemote(at: repoPath) {
            selectedRemote = detected
        } else {
            return nil
        }
        do {
            let output = try await runGit(at: repoPath, arguments: ["config", "--get", "remote.\(selectedRemote).url"])
            let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitService.webURLFromRemoteURL(url)
        } catch {
            return nil
        }
    }

    func getRemoteOriginURL(at repoPath: String) async -> String? {
        await getRemoteURL(at: repoPath, remote: "origin")
    }

    static func webURLFromRemoteURL(_ rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func dropGitSuffix(_ value: String) -> String {
            value.hasSuffix(".git") ? String(value.dropLast(4)) : value
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return dropGitSuffix(trimmed)
        }

        if trimmed.hasPrefix("git@"), let colon = trimmed.firstIndex(of: ":") {
            let hostStart = trimmed.index(trimmed.startIndex, offsetBy: "git@".count)
            let host = trimmed[hostStart..<colon]
            let path = trimmed[trimmed.index(after: colon)...]
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "https://\(host)/\(dropGitSuffix(String(path)))"
        }

        if let components = URLComponents(string: trimmed),
           components.scheme == "ssh",
           let host = components.host {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { return nil }
            return "https://\(host)/\(dropGitSuffix(path))"
        }

        return nil
    }
}
