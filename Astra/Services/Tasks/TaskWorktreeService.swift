import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskWorktreeCreationError: LocalizedError {
    case repositoryUnavailable
    case noCommit(String)
    case baseUnavailable(String)
    case persistenceFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            "The selected Git repository is no longer available in this workspace. Choose another repository."
        case .noCommit(let path):
            "Could not read HEAD in \(path). Create an initial commit before starting a task in a worktree."
        case .baseUnavailable(let path):
            "Could not find the default branch (main or master) of \(path). Choose Start from › Current branch instead."
        case .persistenceFailed(let path, let reason):
            "The worktree was created at \(path), but ASTRA could not save the task. The worktree has been kept; no agent was launched. \(reason)"
        }
    }
}

/// The composer's request for a new task worktree of `repositoryPath`.
/// `checkoutPath` is the checkout selected for that repository (its root or
/// one of its worktrees); `.currentBranch` starts from that checkout's HEAD.
struct TaskWorktreeRequest: Equatable, Sendable {
    var repositoryPath: String
    var checkoutPath: String?
    var base: TaskWorktreeBaseChoice = .defaultBranch
}

/// The commit a new task worktree starts from.
struct TaskWorktreeBase: Equatable, Sendable {
    /// What the commit was resolved from: `origin/main`, `main`, the current
    /// branch, or a short SHA for a detached checkout.
    let ref: String
    let commit: String
    let source: TaskWorktreeBaseChoice
    /// True when the remote branch was fetched right before resolving it.
    let fetched: Bool
}

/// Value snapshot of a draft's worktree, taken before the draft is deleted so
/// cleanup can run once the model object is gone.
struct TaskWorktreeDiscard: Equatable, Sendable {
    let taskID: UUID
    let repositoryPath: String
    let worktreePath: String
    let branch: String
    let baseCommit: String
}

/// Prepares the checkout before submission freezes the task's launch path and
/// resource claims. The task's existing executionRootPath owns the durable pin;
/// the latest `task.worktree.prepared` event whose worktree is still that pin
/// is the task's worktree binding.
@MainActor
enum TaskWorktreeService {
    static let slugLimit = 32
    static let maxNameAttempts = 20

    private static let slugStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "could", "for", "from",
        "i", "in", "into", "is", "it", "me", "my", "of", "on", "or", "our", "please",
        "so", "that", "the", "this", "to", "we", "with", "you"
    ]

    // MARK: - Naming

    /// `astra/<slug>-<first 8 of the task id>`, matching the task folder name
    /// under `.astra/tasks/`. Later attempts append `-2`, `-3`, … on collision.
    static func branchName(for task: AgentTask, attempt: Int = 1) -> String {
        branchName(title: task.title, taskID: task.id, attempt: attempt)
    }

    static func branchName(title: String, taskID: UUID, attempt: Int = 1) -> String {
        let shortID = String(taskID.uuidString.lowercased().prefix(8))
        let suffix = attempt > 1 ? "-\(attempt)" : ""
        return "astra/\(slug(for: title))-\(shortID)\(suffix)"
    }

    /// Whole words of the title, transliterated to ASCII, without filler
    /// words, up to `slugLimit` characters.
    static func slug(for title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false) ?? title
        let folded = latin
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        let words = folded
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
        let meaningful = words.filter { $0.count > 1 && !slugStopWords.contains($0) }
        var slug = ""
        for word in meaningful.isEmpty ? words : meaningful {
            let candidate = slug.isEmpty ? word : "\(slug)-\(word)"
            guard candidate.count <= slugLimit else {
                if slug.isEmpty { slug = String(word.prefix(slugLimit)) }
                break
            }
            slug = candidate
        }
        return slug.isEmpty ? "task" : slug
    }

    private static func availableName(
        for task: AgentTask,
        repositoryPath: String,
        worktreesRoot: String,
        git: any GitRepositoryOperating
    ) async -> (branch: String, destination: String) {
        var attempt = 1
        while true {
            let branch = branchName(for: task, attempt: attempt)
            let destination = GitService.worktreeLocation(
                repoPath: repositoryPath, branch: branch, worktreesRoot: worktreesRoot
            )
            var taken = FileManager.default.fileExists(atPath: destination)
            if !taken { taken = await git.localBranchExists(branch, at: repositoryPath) }
            if !taken || attempt >= maxNameAttempts {
                return (branch, destination)
            }
            attempt += 1
        }
    }

    // MARK: - Base

    /// Resolves the commit a new worktree starts from. The default branch is
    /// fetched first so the task starts from the remote's current tip; when
    /// the remote can't be reached the last fetched ref is used.
    static func resolveBase(
        for request: TaskWorktreeRequest,
        git: any GitRepositoryOperating
    ) async throws -> TaskWorktreeBase {
        let repository = WorkspacePathPresentation.standardizedPath(request.repositoryPath)
        guard await git.getCommitSHA("HEAD", at: repository) != nil else {
            throw TaskWorktreeCreationError.noCommit(repository)
        }
        switch request.base {
        case .currentBranch:
            let checkout = existingCheckout(for: request) ?? repository
            guard let commit = await git.getCommitSHA("HEAD", at: checkout) else {
                throw TaskWorktreeCreationError.noCommit(checkout)
            }
            let branch = await git.getCurrentBranch(at: checkout)
            return TaskWorktreeBase(
                ref: isNamedBranch(branch) ? branch : String(commit.prefix(8)),
                commit: commit,
                source: .currentBranch,
                fetched: false
            )
        case .defaultBranch:
            var localCandidates = ["main", "master"]
            if let remote = await git.getDefaultRemote(at: repository),
               let branch = await remoteDefaultBranch(remote: remote, repository: repository, git: git) {
                let fetched = await git.fetchRemoteBranch(remote: remote, branch: branch, at: repository)
                if let commit = await git.getCommitSHA("refs/remotes/\(remote)/\(branch)", at: repository) {
                    return TaskWorktreeBase(
                        ref: "\(remote)/\(branch)", commit: commit, source: .defaultBranch, fetched: fetched
                    )
                }
                localCandidates.insert(branch, at: 0)
            }
            var seen = Set<String>()
            for branch in localCandidates where seen.insert(branch).inserted {
                if let commit = await git.getCommitSHA("refs/heads/\(branch)", at: repository) {
                    return TaskWorktreeBase(ref: branch, commit: commit, source: .defaultBranch, fetched: false)
                }
            }
            throw TaskWorktreeCreationError.baseUnavailable(repository)
        }
    }

    /// The branch name a request would start from, for display. Never fetches.
    static func baseLabel(
        for request: TaskWorktreeRequest,
        git: any GitRepositoryOperating
    ) async -> String? {
        let repository = WorkspacePathPresentation.standardizedPath(request.repositoryPath)
        switch request.base {
        case .currentBranch:
            let checkout = existingCheckout(for: request) ?? repository
            let branch = await git.getCurrentBranch(at: checkout)
            if isNamedBranch(branch) { return branch }
            return await git.getCommitSHA("HEAD", at: checkout).map { String($0.prefix(8)) }
        case .defaultBranch:
            var localCandidates = ["main", "master"]
            if let remote = await git.getDefaultRemote(at: repository),
               let branch = await remoteDefaultBranch(remote: remote, repository: repository, git: git) {
                if await git.getCommitSHA("refs/remotes/\(remote)/\(branch)", at: repository) != nil {
                    return branch
                }
                localCandidates.insert(branch, at: 0)
            }
            for branch in localCandidates {
                if await git.getCommitSHA("refs/heads/\(branch)", at: repository) != nil {
                    return branch
                }
            }
            return nil
        }
    }

    private static func remoteDefaultBranch(
        remote: String,
        repository: String,
        git: any GitRepositoryOperating
    ) async -> String? {
        guard GitService.isSafeRefComponent(remote) else { return nil }
        let branch = git.normalizeBaseBranch(
            await git.getDefaultBaseBranch(at: repository, remote: remote),
            remote: remote
        )
        return GitService.isSafeRefComponent(branch) ? branch : nil
    }

    private static func existingCheckout(for request: TaskWorktreeRequest) -> String? {
        guard let checkout = request.checkoutPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !checkout.isEmpty,
              FileManager.default.fileExists(atPath: checkout) else { return nil }
        return WorkspacePathPresentation.standardizedPath(checkout)
    }

    private static func isNamedBranch(_ branch: String) -> Bool {
        !branch.isEmpty && branch != "unknown" && branch != "HEAD"
    }

    // MARK: - Binding

    /// The worktree the task runs in: the latest prepared payload whose
    /// worktree is still the task's pin. A draft retargeted elsewhere has none.
    static func activeWorktreeBinding(for task: AgentTask) -> TaskWorktreePayload? {
        activeWorktreeEvent(for: task).flatMap {
            try? $0.decodePayload(as: TaskWorktreePayload.self).get()
        }
    }

    private static func activeWorktreeEvent(for task: AgentTask) -> TaskEvent? {
        guard let pinned = task.executionRootPath, !pinned.isEmpty,
              let event = task.events
                .filter({ $0.hasType(TaskEventTypes.Task.worktreePrepared) })
                .max(by: { $0.timestamp < $1.timestamp }),
              case .success(let payload) = event.decodePayload(as: TaskWorktreePayload.self),
              WorkspacePathPresentation.standardizedPath(payload.worktreePath)
                == WorkspacePathPresentation.standardizedPath(pinned)
        else { return nil }
        return event
    }

    // MARK: - Intent

    static func latestRequest(for task: AgentTask) -> TaskWorktreeRequestPayload? {
        task.events
            .filter { $0.hasType(TaskEventTypes.Task.worktreeRequested) }
            .max { $0.timestamp < $1.timestamp }
            .flatMap { try? $0.decodePayload(as: TaskWorktreeRequestPayload.self).get() }
    }

    /// Records the composer's worktree choice on a draft so reopening the draft
    /// restores it. Nothing is written until the choice is first enabled, nor
    /// when it is unchanged.
    @discardableResult
    static func recordRequestIfChanged(
        _ request: TaskWorktreeRequestPayload,
        on task: AgentTask,
        modelContext: ModelContext
    ) -> Bool {
        let latest = latestRequest(for: task)
        guard latest != request, latest != nil || request.enabled,
              case .success(let payload) = TaskEvent.encodePayload(request) else { return false }
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.worktreeRequested,
            payload: payload
        ))
        return true
    }

    // MARK: - Prepare

    /// Gives `task` its checkout before submission:
    /// 1. a draft's worktree carries over to the task created from it;
    /// 2. a task that already has a worktree keeps it;
    /// 3. a request creates a new worktree from the requested base;
    /// 4. otherwise the task inherits the draft's pin, if any.
    static func prepare(
        task: AgentTask,
        request: TaskWorktreeRequest?,
        inheritingFrom draft: AgentTask? = nil,
        modelContext: ModelContext,
        git: any GitRepositoryOperating = GitService.shared,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot
    ) async throws {
        try Task.checkCancellation()
        let source = draft === task ? nil : draft
        if let source, let prepared = activeWorktreeEvent(for: source) {
            task.executionRootPath = source.executionRootPath
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Task.worktreePrepared,
                payload: prepared.payload
            ))
            return
        }
        if activeWorktreeEvent(for: task) != nil { return }
        if let request {
            try await createWorktree(
                for: task, request: request, modelContext: modelContext, git: git, worktreesRoot: worktreesRoot
            )
        } else if let source {
            task.executionRootPath = source.executionRootPath
        }
    }

    private static func createWorktree(
        for task: AgentTask,
        request: TaskWorktreeRequest,
        modelContext: ModelContext,
        git: any GitRepositoryOperating,
        worktreesRoot: String
    ) async throws {
        guard let workspace = task.workspace else {
            throw TaskWorktreeCreationError.repositoryUnavailable
        }
        let repositories = await git.scanForGitRepositories(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        let path = WorkspacePathPresentation.standardizedPath(request.repositoryPath)
        guard repositories.contains(where: { $0.path == path }) else {
            throw TaskWorktreeCreationError.repositoryUnavailable
        }
        try Task.checkCancellation()
        var resolvedRequest = request
        resolvedRequest.repositoryPath = path
        let base = try await resolveBase(for: resolvedRequest, git: git)
        try Task.checkCancellation()
        let (branch, destination) = await availableName(
            for: task, repositoryPath: path, worktreesRoot: worktreesRoot, git: git
        )
        let payload = try TaskEvent.encodePayload(TaskWorktreePayload(
            repositoryPath: path,
            worktreePath: destination,
            branch: branch,
            baseRef: base.ref,
            baseCommit: base.commit,
            baseSource: base.source,
            baseFetched: base.fetched
        )).get()
        try Task.checkCancellation()

        let createdPath = try await git.addWorktree(
            repoPath: path,
            branch: branch,
            createBranch: true,
            base: base.commit,
            worktreesRoot: worktreesRoot
        )
        task.executionRootPath = createdPath
        modelContext.insert(task)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.worktreePrepared,
            payload: payload
        ))
        // Keep a recoverable draft even if the composer is dismissed after Git
        // finishes. Cancellation may prevent launch, but must not orphan the pin.
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "task_worktree_prepared"]
            )
        } catch {
            throw TaskWorktreeCreationError.persistenceFailed(
                path: createdPath, reason: error.localizedDescription
            )
        }
        AppLogger.breadcrumb(action: "task_worktree_prepared", category: "Git", taskID: task.id, fields: [
            "repository": path,
            "worktree": createdPath,
            "branch": branch,
            "base": base.ref,
            "base_commit": String(base.commit.prefix(12)),
            "base_fetched": base.fetched ? "true" : "false"
        ])
    }

    // MARK: - Failure recovery

    /// Undoes a task whose submission failed. A task that owns a worktree
    /// becomes (or hands its worktree to) the draft the user returns to, so
    /// the worktree is never left without a task.
    static func recoverFailedSubmission(
        task: AgentTask,
        existingDraft: AgentTask?,
        modelContext: ModelContext
    ) -> AgentTask? {
        if existingDraft === task { return task }
        let prepared = activeWorktreeEvent(for: task)
        if existingDraft == nil, prepared != nil {
            if task.status == .queued {
                TaskStateMachine.restoreDraftForEditing(task, modelContext: modelContext)
            }
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "worktree_submission_failed"]
            )
            return task
        }
        if let draft = existingDraft, let prepared, activeWorktreeEvent(for: draft) == nil {
            draft.executionRootPath = task.executionRootPath
            modelContext.insert(TaskEvent(
                task: draft,
                eventType: TaskEventTypes.Task.worktreePrepared,
                payload: prepared.payload
            ))
        }
        modelContext.delete(task)
        return existingDraft
    }

    // MARK: - Cleanup

    /// Snapshot of a draft's worktree for `discardUnusedWorktree`. Worktrees
    /// prepared before the base commit was recorded are never discarded.
    static func discardSnapshot(for task: AgentTask) -> TaskWorktreeDiscard? {
        guard let binding = activeWorktreeBinding(for: task),
              let baseCommit = binding.baseCommit, !baseCommit.isEmpty else { return nil }
        return TaskWorktreeDiscard(
            taskID: task.id,
            repositoryPath: binding.repositoryPath,
            worktreePath: binding.worktreePath,
            branch: binding.branch,
            baseCommit: baseCommit
        )
    }

    /// Removes a discarded draft's worktree and branch only while nothing
    /// happened in them: the checkout is clean, still on its branch, the branch
    /// is still at its base commit, and no other task or workspace default
    /// points at it. Anything else is kept for the user.
    @discardableResult
    static func discardUnusedWorktree(
        _ discard: TaskWorktreeDiscard,
        modelContext: ModelContext,
        git: any GitRepositoryOperating = GitService.shared
    ) async -> Bool {
        let path = WorkspacePathPresentation.standardizedPath(discard.worktreePath)
        func kept(_ reason: String) -> Bool {
            AppLogger.breadcrumb(action: "task_worktree_kept", category: "Git", taskID: discard.taskID, fields: [
                "worktree": path,
                "branch": discard.branch,
                "reason": reason
            ])
            return false
        }
        guard !isReferenced(path, excluding: discard.taskID, modelContext: modelContext) else {
            return kept("referenced")
        }
        guard FileManager.default.fileExists(atPath: path) else { return kept("missing") }
        guard await git.getStatusFiles(at: path).isEmpty else { return kept("uncommitted_changes") }
        guard await git.getCurrentBranch(at: path) == discard.branch else { return kept("branch_switched") }
        guard await git.getCommitSHA("refs/heads/\(discard.branch)", at: discard.repositoryPath)
                == discard.baseCommit else { return kept("has_commits") }
        guard !isReferenced(path, excluding: discard.taskID, modelContext: modelContext) else {
            return kept("referenced")
        }
        do {
            try await git.removeWorktree(repoPath: discard.repositoryPath, worktreePath: path, force: false)
        } catch {
            return kept("remove_failed")
        }
        let branchInUse = await git.listWorktrees(at: discard.repositoryPath)
            .contains { $0.branch == discard.branch }
        var branchDeleted = false
        if !branchInUse {
            do {
                try await git.deleteLocalBranch(discard.branch, ifAt: discard.baseCommit, at: discard.repositoryPath)
                branchDeleted = true
            } catch {
                branchDeleted = false
            }
        }
        AppLogger.breadcrumb(action: "task_worktree_discarded", category: "Git", taskID: discard.taskID, fields: [
            "worktree": path,
            "branch": discard.branch,
            "branch_deleted": branchDeleted ? "true" : "false"
        ])
        return true
    }

    private static func isReferenced(_ path: String, excluding taskID: UUID, modelContext: ModelContext) -> Bool {
        let pinned = (try? modelContext.fetch(FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.id != taskID && $0.executionRootPath != nil }
        ))) ?? []
        if pinned.contains(where: { standardized($0.executionRootPath) == path }) { return true }
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        return workspaces.contains { standardized($0.activeWorkingPath) == path }
    }

    private static func standardized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return WorkspacePathPresentation.standardizedPath(path)
    }
}
