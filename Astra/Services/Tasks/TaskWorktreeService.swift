import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskWorktreeCreationError: LocalizedError, Equatable {
    case repositoryUnavailable
    case repositoryBusy(String)
    case resourceQueueUnavailable
    case noCommit(String)
    case checkoutUnavailable(String)
    case baseUnavailable(String)
    case nameUnavailable(String)
    case journalFailed(String)
    case submodulesUnavailable(path: String, reason: String)
    case destinationInsideRepository(repository: String, worktreesRoot: String)
    case persistenceFailed(path: String, reason: String)
    case recoveryPersistenceFailed(String)
    case choicePersistenceFailed(String)
    case noDraft

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            "The selected Git repository is no longer available in this workspace. Choose another repository."
        case .repositoryBusy(let path):
            "Another task or worktree operation is using \(path). Wait for it to finish, then try again. No new worktree was created."
        case .resourceQueueUnavailable:
            "ASTRA could not access the task queue to reserve this repository. No worktree operation was started."
        case .noCommit(let path):
            "Could not read HEAD in \(path). Create an initial commit before starting a task in a worktree."
        case .checkoutUnavailable(let path):
            "The selected checkout \(path) is no longer available. Choose the repository again before starting the task."
        case .baseUnavailable(let path):
            "Could not find the default branch of \(path): its remote didn't name one, and there is no main or master. Choose Start from › Current branch instead."
        case .nameUnavailable(let path):
            "Every branch and folder name ASTRA tried for a new worktree of \(path) is taken. Remove this task's unused astra/ worktrees or branches, then try again."
        case .journalFailed(let reason):
            "ASTRA could not record the new worktree before creating it, so nothing was created and no agent was launched. \(reason)"
        case .submodulesUnavailable(let path, let reason):
            "ASTRA could not set up the Git submodules of \(path) in a new worktree, so no agent was launched. Check that you can fetch the submodules, or start the task without a worktree. \(reason)"
        case .destinationInsideRepository(let repository, let worktreesRoot):
            "ASTRA keeps task worktrees in \(WorkspacePathPresentation.abbreviatePath(worktreesRoot)), which is inside \(WorkspacePathPresentation.abbreviatePath(repository)). A worktree there would show up as untracked files in that checkout, so none was created. Start the task without a worktree, or move the repository outside that folder."
        case .persistenceFailed(let path, let reason):
            "The worktree was created at \(path), but ASTRA could not save the task, so no agent was launched. If the task is still unsaved when ASTRA next starts, the unused worktree is removed. \(reason)"
        case .recoveryPersistenceFailed(let reason):
            "ASTRA could not save the recovered draft. Its checkout has been kept; no agent was launched. \(reason)"
        case .choicePersistenceFailed(let reason):
            "ASTRA could not save the worktree choice. The previous choice has been kept. \(reason)"
        case .noDraft:
            "ASTRA needs a saved draft to hold the new worktree. Describe the task in a message, then try again."
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

/// Whether draft deletion reached the store, and the cleanup that starts
/// only after that save. `cleanup` is nil when there is no worktree or the
/// deletion was not persisted; it yields true when every worktree was removed.
struct TaskWorktreeDeletionResult: Sendable {
    var persisted: Bool
    var cleanup: Task<Bool, Never>?
}

/// Value snapshot of a draft's worktree, taken before the draft is deleted so
/// cleanup can run once the model object is gone.
struct TaskWorktreeDiscard: Codable, Equatable, Sendable {
    let taskID: UUID
    let repositoryPath: String
    let worktreePath: String
    let branch: String
    let baseCommit: String
    /// The Git directory the worktree shares, so cleanup can still reach the
    /// repository after a linked-worktree source checkout is removed. Absent
    /// on records written before it was kept.
    var commonDirectory: String? = nil
    /// The worktree's identity token, so cleanup never removes a worktree
    /// recreated at the same path. Absent on older records.
    var identity: String? = nil
    /// The shared Git directory's file identity at creation; absent on older
    /// records.
    var commonDirectoryID: String? = nil
}

/// Populates a new worktree's submodules once Git has checked it out.
typealias TaskWorktreeSubmoduleSetup = @MainActor (any GitRepositoryOperating, String) async throws -> Void

/// Prepares the checkout before submission freezes the task's launch path and
/// resource claims. The task's existing executionRootPath owns the durable pin;
/// the latest `task.worktree.prepared` event whose worktree is still that pin
/// is the task's worktree binding.
@MainActor
enum TaskWorktreeService {
    static let slugLimit = 32
    static let maxNameAttempts = 20

    /// Repositories a creation is currently fetching into or adding a
    /// worktree to. Creations share the repository's Git directory with
    /// running worktree tasks but not with each other, so a second composer
    /// on the same repository fails visibly instead of racing the fetch.
    private static var activeCreationRepositories: Set<String> = []

    private static let slugStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "could", "for", "from",
        "i", "in", "into", "is", "it", "me", "my", "of", "on", "or", "our", "please",
        "so", "that", "the", "this", "to", "we", "with", "you"
    ]

    // MARK: - Naming

    /// `astra/<slug>-<first 8 of the task id>`, matching the task folder name
    /// under `.astra/tasks/`. Later attempts append `-2`, `-3`, … on collision.
    static func branchName(for task: AgentTask, title: String? = nil, attempt: Int = 1) -> String {
        branchName(title: title ?? task.title, taskID: task.id, attempt: attempt)
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
        title: String?,
        repositoryPath: String,
        worktreesRoot: String,
        journal: TaskWorktreeCleanupStore,
        git: any GitRepositoryOperating
    ) async -> (branch: String, destination: String)? {
        for attempt in 1...maxNameAttempts {
            let branch = branchName(for: task, title: title, attempt: attempt)
            let destination = GitService.worktreeLocation(
                repoPath: repositoryPath, branch: branch, worktreesRoot: worktreesRoot
            )
            // A journaled name may belong to an interrupted creation that
            // hasn't been settled yet. Neither check follows links: a
            // dangling symlink at the destination makes `git worktree add -b`
            // create the branch and then fail, orphaning that branch. Only a
            // path confirmed missing is free; one that can't be checked is
            // skipped like a taken one.
            let journaled = journal.recordURL(taskID: task.id, worktreePath: destination)
            guard confirmedMissing(destination), confirmedMissing(journaled.path),
                  !(await git.localBranchExists(branch, at: repositoryPath)) else { continue }
            return (branch, destination)
        }
        return nil
    }

    private static func confirmedMissing(_ path: String) -> Bool {
        do {
            return try GitService.attributesConfirmingAbsence(atPath: path) == nil
        } catch {
            return false
        }
    }

    // MARK: - Base

    /// Resolves the commit a new worktree starts from. The default branch is
    /// the one the remote's HEAD names, fetched first so the task starts from
    /// the remote's current tip; when the remote can't be reached the last
    /// fetched ref, then local `main` or `master`, is used.
    static func resolveBase(
        for request: TaskWorktreeRequest,
        git: any GitRepositoryOperating
    ) async throws -> TaskWorktreeBase {
        let repository = WorkspacePathPresentation.standardizedPath(request.repositoryPath)
        // The repository checkout's HEAD is not the base. An unborn orphan
        // branch there must not reject a default-branch ref, or Current branch
        // pointed at a linked worktree that already has a commit.
        switch request.base {
        case .currentBranch:
            let checkout: String
            switch resolveCurrentCheckout(request) {
            case .missing(let path):
                throw TaskWorktreeCreationError.checkoutUnavailable(path)
            case .ready(let path):
                checkout = path
            }
            guard await isRegisteredCheckout(checkout, of: repository, git: git) else {
                throw TaskWorktreeCreationError.checkoutUnavailable(checkout)
            }
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
            if let remote = await git.getDefaultRemote(at: repository), GitService.isSafeRefComponent(remote) {
                // The remote's own HEAD first: the local `<remote>/HEAD` is
                // missing after `git remote add` and stale after a rename.
                let head = await git.lookupRemoteHead(remote: remote, at: repository)
                var branch: String?
                if case .branch(let advertised) = head {
                    branch = advertised
                } else {
                    branch = await remoteDefaultBranch(remote: remote, repository: repository, git: git)
                }
                if let branch {
                    // A remote that just failed to answer is not asked again.
                    let fetched = head == .unavailable
                        ? false
                        : await git.fetchRemoteBranch(remote: remote, branch: branch, at: repository)
                    if let commit = await git.getCommitSHA("refs/remotes/\(remote)/\(branch)", at: repository) {
                        return TaskWorktreeBase(
                            ref: "\(remote)/\(branch)", commit: commit, source: .defaultBranch, fetched: fetched
                        )
                    }
                    localCandidates.insert(branch, at: 0)
                }
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

    /// The branch name a request would start from, for display. Reads local
    /// refs only, so it can differ from the branch the remote names when the
    /// task starts; the task's binding records the base actually used.
    static func baseLabel(
        for request: TaskWorktreeRequest,
        git: any GitRepositoryOperating
    ) async -> String? {
        let repository = WorkspacePathPresentation.standardizedPath(request.repositoryPath)
        switch request.base {
        case .currentBranch:
            guard case .ready(let checkout) = resolveCurrentCheckout(request),
                  await isRegisteredCheckout(checkout, of: repository, git: git) else { return nil }
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

    /// Current branch uses the recorded checkout. A nonempty checkout that has
    /// disappeared is missing; it must not fall back to the repository folder,
    /// which can be a different branch. An empty checkout is the repository.
    private enum CurrentCheckout {
        case ready(String)
        case missing(String)
    }

    private static func resolveCurrentCheckout(_ request: TaskWorktreeRequest) -> CurrentCheckout {
        let repository = WorkspacePathPresentation.standardizedPath(request.repositoryPath)
        let checkout = request.checkoutPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if checkout.isEmpty { return .ready(repository) }
        guard FileManager.default.fileExists(atPath: checkout) else {
            return .missing(WorkspacePathPresentation.standardizedPath(checkout))
        }
        return .ready(WorkspacePathPresentation.standardizedPath(checkout))
    }

    /// A folder that merely exists at a recorded checkout path is not the
    /// recorded checkout: it must still be the repository's root, or a
    /// checkout of the repository whose own `.git` reaches it. A replacement
    /// clone at a path Git still lists would otherwise have Current branch
    /// start from whatever it checked out.
    private static func isRegisteredCheckout(
        _ checkout: String, of repository: String, git: any GitRepositoryOperating
    ) async -> Bool {
        let resolved = WorkspacePathPresentation.resolvedPath(checkout)
        if resolved == WorkspacePathPresentation.resolvedPath(repository) { return true }
        guard TaskWorktreeBinding.verifiedCommonDirectory(checkout: checkout, repository: repository) != nil else {
            return false
        }
        return await git.listWorktrees(at: repository).contains {
            WorkspacePathPresentation.resolvedPath($0.path) == resolved
        }
    }

    private static func isNamedBranch(_ branch: String) -> Bool {
        !branch.isEmpty && branch != "unknown" && branch != "HEAD"
    }

    // MARK: - Binding

    /// The worktree the task runs in: the latest prepared payload whose
    /// worktree is still the task's pin. A draft retargeted elsewhere has none.
    static func activeWorktreeBinding(for task: AgentTask) -> TaskWorktreePayload? {
        TaskWorkspaceAccess(task: task).worktreeBinding
    }

    static func activeWorktreeEvent(for task: AgentTask) -> TaskEvent? {
        TaskWorkspaceAccess(task: task).worktreeBindingEvent
    }

    // MARK: - Intent

    /// The newest request by its recorded sequence, then by timestamp, so
    /// two choices made within a second stay ordered after a store is rebuilt
    /// from a mirror that keeps whole seconds.
    ///
    /// A request that can't be read and is at least as new as the newest
    /// readable one may have turned creation off or changed it, so the
    /// choice reads as off, keeping that base, rather than falling back to
    /// an older one. A choice made after it is newer and wins again.
    static func latestRequest(for task: AgentTask) -> TaskWorktreeRequestPayload? {
        let latest = orderedRequests(for: task).last
        let newestUnreadable = task.events
            .filter {
                !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreeRequested)
                    && (try? $0.decodePayload(as: TaskWorktreeRequestPayload.self).get()) == nil
            }
            .map(\.timestamp).max()
        guard let newestUnreadable, latest.map({ newestUnreadable >= $0.event.timestamp }) ?? true else {
            return latest?.payload
        }
        var off = TaskWorktreeRequestPayload(enabled: false, base: latest?.payload.base ?? .defaultBranch)
        off.sequence = latest?.payload.sequence
        return off
    }

    /// The draft's readable requests, oldest first, by sequence and then time.
    private static func orderedRequests(for task: AgentTask) -> [(event: TaskEvent, payload: TaskWorktreeRequestPayload)] {
        task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreeRequested) }
            .compactMap { event in
                (try? event.decodePayload(as: TaskWorktreeRequestPayload.self).get()).map { (event, $0) }
            }
            .sorted { lhs, rhs in
                let left = lhs.payload.sequence ?? -1, right = rhs.payload.sequence ?? -1
                return left != right ? left < right : lhs.event.timestamp < rhs.event.timestamp
            }
    }

    /// Numbers the draft's requests 0, 1, … in their current order, for when
    /// an imported sequence reached the maximum: a later choice then still
    /// gets a higher one rather than tying at the maximum, where timestamps
    /// stored to the second can't order it.
    private static func renumberRequests(on task: AgentTask) {
        for (index, request) in orderedRequests(for: task).enumerated() {
            var payload = request.payload
            payload.sequence = index
            if case .success(let encoded) = TaskEvent.encodePayload(payload) { request.event.payload = encoded }
        }
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
        var latest = latestRequest(for: task)
        var request = request
        guard latest != request, latest != nil || request.enabled else { return false }
        // An imported sequence can be any value, even Int.max.
        if latest?.sequence == .max {
            renumberRequests(on: task)
            latest = latestRequest(for: task)
        }
        let previous = max(latest?.sequence ?? -1, -1)
        guard previous < .max else { return false }
        request.sequence = previous + 1
        guard case .success(let payload) = TaskEvent.encodePayload(request) else { return false }
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
    /// A draft from another workspace lends neither its worktree nor its pin.
    /// `branchTitle` names a new worktree's branch instead of the task title.
    static func prepare(
        task: AgentTask,
        request: TaskWorktreeRequest?,
        inheritingFrom draft: AgentTask? = nil,
        branchTitle: String? = nil,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        git: any GitRepositoryOperating = GitService.shared,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot,
        ownership: TaskWorktreeOwnershipStore = TaskWorktreeCleanupStore().ownership,
        setUpSubmodules: TaskWorktreeSubmoduleSetup = { git, path in try await git.initializeSubmodules(at: path) }
    ) async throws {
        try Task.checkCancellation()
        let source = draft === task || draft?.workspace?.id != task.workspace?.id ? nil : draft
        if let source, request == nil || activeWorktreeEvent(for: source) != nil,
           TaskWorktreeBinding.eventForInheritance(from: source) != nil,
           let binding = TaskWorktreeBinding.inheritPin(from: source, into: task) {
            modelContext.insert(binding)
            return
        }
        if activeWorktreeEvent(for: task) != nil {
            task.isolationStrategy = .sameDirectory
            return
        }
        if let request {
            try await createWorktree(
                for: task, request: request, branchTitle: branchTitle, modelContext: modelContext, git: git,
                resourceQueue: resourceQueue, worktreesRoot: worktreesRoot,
                journal: ownership.creationJournal, setUpSubmodules: setUpSubmodules
            )
        } else if let source {
            guard TaskWorktreeCheckoutReservation.commit(source.executionRootPath, to: task) else {
                throw TaskWorktreeCreationError.checkoutUnavailable(source.executionRootPath ?? "the selected checkout")
            }
        }
    }

    /// Creation is journaled before Git runs and settled only once the task's
    /// binding is saved; recovery removes what an interrupted creation left.
    private static func createWorktree(
        for task: AgentTask,
        request: TaskWorktreeRequest,
        branchTitle: String?,
        modelContext: ModelContext,
        git: any GitRepositoryOperating,
        resourceQueue: TaskQueue?,
        worktreesRoot: String,
        journal: TaskWorktreeCleanupStore,
        setUpSubmodules: TaskWorktreeSubmoduleSetup
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
        // A worktree inside its own source checkout would appear there as
        // untracked files, polluting the checkout the option leaves alone.
        // That holds for every checkout of the repository, not just the
        // selected one: a sibling checkout would see the same pollution.
        let resolvedRoot = WorkspacePathPresentation.resolvedPath(worktreesRoot)
        let checkouts = [GitCheckoutLayout.worktreeRoot(containing: path) ?? path]
            + (await git.listWorktrees(at: path)).map(\.path)
        var containing = checkouts.first(where: {
            let checkout = WorkspacePathPresentation.resolvedPath($0)
            return resolvedRoot == checkout || resolvedRoot.hasPrefix(checkout + "/")
        })
        // An unrelated repository around the worktrees folder, such as a
        // home folder kept in Git, would list the worktrees too, unless it
        // ignores that folder or hides untracked files.
        if containing == nil, let outer = GitCheckoutLayout.worktreeRoot(containing: worktreesRoot) {
            try? FileManager.default.createDirectory(atPath: worktreesRoot, withIntermediateDirectories: true)
            if !(await git.pathIsHiddenFromStatus(worktreesRoot, in: outer)) { containing = outer }
        }
        if let containing {
            throw TaskWorktreeCreationError.destinationInsideRepository(repository: containing, worktreesRoot: worktreesRoot)
        }
        // One creation per repository: linked checkouts of one repository
        // share its Git directory, so they share this key too.
        let repositoryKey = WorkspacePathPresentation.resolvedPath(GitCheckoutLayout.commonDirectory(for: path) ?? path)
        guard activeCreationRepositories.insert(repositoryKey).inserted else {
            throw TaskWorktreeCreationError.repositoryBusy(path)
        }
        defer { activeCreationRepositories.remove(repositoryKey) }
        let resourceLease = try TaskWorktreeResourceLease.acquire(repositoryPath: path, taskID: task.id, queue: resourceQueue)
        defer { resourceLease.release() }
        try Task.checkCancellation()
        var resolvedRequest = request
        resolvedRequest.repositoryPath = path
        let base = try await resolveBase(for: resolvedRequest, git: git)
        try Task.checkCancellation()
        guard let (branch, destination) = await availableName(
            for: task, title: branchTitle, repositoryPath: path, worktreesRoot: worktreesRoot, journal: journal, git: git
        ) else {
            throw TaskWorktreeCreationError.nameUnavailable(path)
        }
        // The destination is claimed too, so a running task whose root
        // contains the worktrees folder can't touch it while Git fills it.
        let destinationLease = try TaskWorktreeResourceLease.acquireCheckout(
            destination, taskID: task.id, queue: resourceQueue
        )
        defer { destinationLease.release() }
        let commonDirectory = GitCheckoutLayout.commonDirectory(for: path)
        let binding = TaskWorktreePayload(
            repositoryPath: path,
            worktreePath: destination,
            branch: branch,
            baseRef: base.ref,
            baseCommit: base.commit,
            baseSource: base.source,
            baseFetched: base.fetched,
            commonDirectory: commonDirectory,
            identity: UUID().uuidString.lowercased(),
            commonDirectoryID: commonDirectory.flatMap(GitCheckoutLayout.fileIdentity(of:))
        )
        let payload = try TaskEvent.encodePayload(binding).get()
        let intent = TaskWorktreeDiscard(
            taskID: task.id, repositoryPath: path, worktreePath: destination, branch: branch, baseCommit: base.commit,
            commonDirectory: commonDirectory, identity: binding.identity, commonDirectoryID: binding.commonDirectoryID
        )
        try Task.checkCancellation()
        do {
            try TaskWorktreeCleanupService.beginCreation(intent, journal: journal)
        } catch {
            throw TaskWorktreeCreationError.journalFailed(error.localizedDescription)
        }

        let createdPath: String
        do {
            // Git writes the lock reason in the same command that creates the
            // worktree, so recovery can tell this creation's worktree from a
            // competing one even if ASTRA stops before recording ownership.
            createdPath = try await git.addLockedTaskWorktree(
                repoPath: path, branch: branch, base: base.commit, worktreesRoot: worktreesRoot,
                lockReason: TaskWorktreeBinding.lockReason(forIdentity: binding.identity ?? "")
            )
            try TaskWorktreeBinding.recordIdentity(of: binding)
            try TaskWorktreeCleanupService.recordCreated(intent, journal: journal)
            try await git.unlockWorktree(repoPath: path, worktreePath: createdPath)
            if FileManager.default.fileExists(atPath: (createdPath as NSString).appendingPathComponent(".gitmodules")) {
                do {
                    try await setUpSubmodules(git, createdPath)
                } catch {
                    // Taken on failure too: what setup populated came from the
                    // clone, and abandoning the creation must still remove it.
                    try? await git.recordSubmoduleTagSnapshot(at: createdPath)
                    throw TaskWorktreeCreationError.submodulesUnavailable(path: path, reason: error.localizedDescription)
                }
                // Without it cleanup can't tell a tag made later from a
                // fetched one, so it keeps the worktree; never fatal here.
                try? await git.recordSubmoduleTagSnapshot(at: createdPath)
            }
            // The workspace can drop the repository while Git runs; a binding
            // to a source it no longer configures would be invalid at once.
            guard TaskWorktreeBinding.repositoryIsConfigured(path, for: task) else {
                throw TaskWorktreeCreationError.repositoryUnavailable
            }
            guard TaskWorktreeCheckoutReservation.commit(createdPath, to: task) else {
                throw TaskWorktreeCreationError.checkoutUnavailable(createdPath)
            }
        } catch {
            // Cleanup takes the same claims, so they are released first.
            resourceLease.release()
            destinationLease.release()
            await TaskWorktreeCleanupService.abandonCreation(
                intent, journal: journal, modelContext: modelContext, resourceQueue: resourceQueue, git: git
            )
            throw error
        }
        task.isolationStrategy = .sameDirectory
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
            // The intent stays journaled: next launch keeps the worktree if a
            // later save bound it, and otherwise removes it while unchanged.
            throw TaskWorktreeCreationError.persistenceFailed(
                path: createdPath, reason: error.localizedDescription
            )
        }
        TaskWorktreeCleanupService.finishCreation(intent, journal: journal)
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
    /// the worktree is never left without a task. When a draft's adoption
    /// cannot be saved, it is undone in memory and in the context: the draft
    /// gets its previous pin and isolation back, the copied binding is
    /// removed, and the temporary task's deletion is rolled back, so no later
    /// unrelated save can commit half of a failed recovery. Restore the pin
    /// after rollback, which can otherwise overwrite it with a saved checkout
    /// that cleanup has since reserved.
    static func recoverFailedSubmission(
        task: AgentTask,
        existingDraft: AgentTask?,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext, UUID) throws -> Void = { workspace, context, taskID in
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace, modelContext: context, taskID: taskID,
                auditFields: ["operation": "worktree_submission_failed"]
            )
        }
    ) throws -> AgentTask? {
        let workspace = task.workspace
        let taskID = task.id
        let prepared = TaskWorktreeBinding.eventForInheritance(from: task)
        // Only a draft of the task's own workspace may take over its worktree.
        let adoptingDraft = existingDraft?.workspace?.id == workspace?.id ? existingDraft : nil
        let recovered: AgentTask?
        var undoAdoption: (() -> Void)?
        // A draft that already has its own worktree can't take this task's
        // other one, so the task stays, as a draft, to keep owning it.
        let draftHoldsAnotherWorktree = adoptingDraft.map { draft in
            prepared != nil && activeWorktreeEvent(for: draft) != nil
                && draft.executionRootPath.map(WorkspacePathPresentation.standardizedPath)
                    != task.executionRootPath.map(WorkspacePathPresentation.standardizedPath)
        } ?? false
        if existingDraft === task || (adoptingDraft == nil && prepared != nil) || draftHoldsAnotherWorktree {
            if task.status == .queued {
                TaskStateMachine.restoreDraftForEditing(task, modelContext: modelContext)
            }
            recovered = task
        } else {
            let previousPin = adoptingDraft?.executionRootPath
            let previousIsolation = adoptingDraft?.isolationStrategy
            var copiedBinding: TaskEvent?
            if let draft = adoptingDraft, let prepared, activeWorktreeEvent(for: draft) == nil {
                guard TaskWorktreeCheckoutReservation.commit(task.executionRootPath, to: draft) else {
                    throw TaskWorktreeCreationError.checkoutUnavailable(task.executionRootPath ?? "the selected checkout")
                }
                TaskWorktreeBinding.applyIsolation(to: draft, for: prepared)
                let copy = TaskWorktreeBinding.copy(prepared, to: draft)
                modelContext.insert(copy)
                copiedBinding = copy
            }
            SwiftDataDeletionPreparation.prepare(task)
            modelContext.delete(task)
            recovered = adoptingDraft
            undoAdoption = {
                if let draft = adoptingDraft, let copiedBinding {
                    draft.events.removeAll { $0 === copiedBinding }
                    modelContext.delete(copiedBinding)
                }
                modelContext.rollback()
                if let draft = adoptingDraft {
                    // Restoring nil, the usual case, always succeeds; a prior
                    // pin that cleanup has since reserved is not readopted,
                    // and the adopted one, whose binding goes below, is
                    // cleared rather than left unbound.
                    if draft.executionRootPath != previousPin || TaskWorktreeCheckoutReservation.isReserved(previousPin) {
                        if !TaskWorktreeCheckoutReservation.commit(previousPin, to: draft) {
                            TaskWorktreeCheckoutReservation.commit(nil, to: draft)
                        }
                    }
                    if let previousIsolation, draft.isolationStrategy != previousIsolation {
                        draft.isolationStrategy = previousIsolation
                    }
                }
            }
        }
        do {
            try persist(workspace, modelContext, recovered?.id ?? taskID)
        } catch {
            undoAdoption?()
            AppLogger.audit(.taskFailed, category: "Persistence", taskID: recovered?.id ?? taskID, fields: [
                "reason": "worktree_submission_recovery_save_failed",
                "error": error.localizedDescription
            ], level: .error)
            throw TaskWorktreeCreationError.recoveryPersistenceFailed(error.localizedDescription)
        }
        return recovered
    }

    // MARK: - Cleanup

    /// Snapshots of every worktree prepared for `task`, newest first, for
    /// `discardUnusedWorktree`. They don't follow the task's current pin: a
    /// draft retargeted to another checkout, or one that then prepared a new
    /// worktree, still gives back the worktrees it no longer uses. Status and
    /// reference checks keep any that changed or were adopted elsewhere. Only
    /// a worktree this install created, per its local ownership record, is
    /// ever discarded: an imported or crafted binding, or one prepared before
    /// the base commit was recorded, keeps its checkout.
    static func discardSnapshots(
        for task: AgentTask,
        ownership: TaskWorktreeOwnershipStore = TaskWorktreeCleanupStore().ownership
    ) -> [TaskWorktreeDiscard] {
        var seen = Set<String>()
        return task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .sorted { $0.timestamp > $1.timestamp }
            .compactMap { event -> TaskWorktreeDiscard? in
                // A path is taken once, by its newest incarnation this install
                // owns: one that isn't owned, as an older or replaced event
                // with the same timestamp, doesn't hide the one that is. One
                // whose ownership can't be read yet doesn't take it either,
                // so every incarnation is queued until cleanup can tell.
                guard case .success(let binding) = event.decodePayload(as: TaskWorktreePayload.self),
                      let baseCommit = binding.baseCommit, !baseCommit.isEmpty,
                      !seen.contains(WorkspacePathPresentation.standardizedPath(binding.worktreePath)) else {
                    return nil
                }
                let discard = TaskWorktreeDiscard(
                    taskID: task.id,
                    repositoryPath: binding.repositoryPath,
                    worktreePath: binding.worktreePath,
                    branch: binding.branch,
                    baseCommit: baseCommit,
                    commonDirectory: binding.commonDirectory ?? GitCheckoutLayout.commonDirectory(for: binding.repositoryPath),
                    identity: binding.identity,
                    commonDirectoryID: binding.commonDirectoryID
                )
                // One whose ownership can't be read for now is still queued:
                // cleanup checks again, and keeps its record while it can't
                // tell, rather than this deletion leaving no intent at all.
                let state = ownership.ownershipState(discard)
                guard state != .notOwned else {
                    AppLogger.breadcrumb(action: "task_worktree_kept", category: "Git", taskID: task.id, fields: [
                        "worktree": binding.worktreePath,
                        "branch": binding.branch,
                        "reason": "not_created_locally"
                    ])
                    return nil
                }
                if state == .owned { seen.insert(WorkspacePathPresentation.standardizedPath(binding.worktreePath)) }
                return discard
            }
    }

    /// Removes a discarded draft's worktree and branch only while nothing
    /// happened in them: the checkout is clean with no ignored files, its
    /// populated submodules hold no local work, it is still on its branch,
    /// the branch is still at its base commit, and no other task or
    /// workspace default points at it. Anything else, including a store that
    /// can't be read, keeps the worktree for the user.
    @discardableResult
    static func discardUnusedWorktree(
        _ discard: TaskWorktreeDiscard,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        git: any GitRepositoryOperating = GitService.shared,
        checkoutPins: @MainActor (ModelContext) throws -> Set<String> = { try durableCheckoutPins(modelContext: $0) }
    ) async -> Bool {
        await discardOutcome(
            discard, modelContext: modelContext, resourceQueue: resourceQueue, git: git, checkoutPins: checkoutPins
        ) == .removed
    }

    /// The checkout cleanup runs Git from: the recorded source while it
    /// exists, otherwise the main checkout of the recorded shared Git
    /// directory, so removing a linked-worktree source doesn't strand the
    /// cleanup. A shared Git directory not named `.git`, such as a
    /// submodule's `.git/modules/<name>` after the submodule was
    /// deinitialized, is used directly. A moved main checkout takes its Git
    /// directory with it, and Git itself loses the worktree, so that case
    /// keeps retrying.
    static func cleanupRepository(for discard: TaskWorktreeDiscard) -> String {
        let fileManager = FileManager.default
        guard let common = discard.commonDirectory else { return discard.repositoryPath }
        // The recorded source is used while it still shares the recorded Git
        // directory; a folder or another repository now at that path isn't
        // trusted just because it exists.
        if let current = GitCheckoutLayout.commonDirectory(for: discard.repositoryPath),
           WorkspacePathPresentation.resolvedPath(current) == WorkspacePathPresentation.resolvedPath(common) {
            return discard.repositoryPath
        }
        guard fileManager.fileExists(atPath: common) else { return discard.repositoryPath }
        if URL(fileURLWithPath: common).lastPathComponent == ".git" {
            let main = URL(fileURLWithPath: common).deletingLastPathComponent().path
            if fileManager.fileExists(atPath: main) { return main }
        }
        // Only a directory that is still that same Git directory.
        guard let own = GitCheckoutLayout.commonDirectory(ofGitDirectory: common),
              WorkspacePathPresentation.resolvedPath(own) == WorkspacePathPresentation.resolvedPath(common)
        else { return discard.repositoryPath }
        return common
    }

    static func discardOutcome(
        _ discard: TaskWorktreeDiscard,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        git: any GitRepositoryOperating = GitService.shared,
        ownership: TaskWorktreeOwnershipStore? = nil,
        checkoutPins: @MainActor (ModelContext) throws -> Set<String> = { try durableCheckoutPins(modelContext: $0) },
        duringReservation: @MainActor () async -> Void = {}
    ) async -> TaskWorktreeCleanupOutcome {
        let path = WorkspacePathPresentation.standardizedPath(discard.worktreePath)
        let repository = cleanupRepository(for: discard)
        func kept(_ reason: String, retry: Bool = false) -> TaskWorktreeCleanupOutcome {
            AppLogger.breadcrumb(action: "task_worktree_kept", category: "Git", taskID: discard.taskID, fields: [
                "worktree": path,
                "branch": discard.branch,
                "reason": reason
            ])
            return retry ? .retry(reason) : .kept(reason)
        }
        func referenceProblem() -> String? {
            do {
                // A pin at, inside, or above the checkout still reaches it.
                return try checkoutPins(modelContext).contains { TaskWorktreeCheckoutReservation.overlaps($0, path) }
                    ? "referenced" : nil
            } catch {
                return "reference_check_failed"
            }
        }
        if Task.isCancelled { return kept("cancelled", retry: true) }
        if let problem = referenceProblem() { return kept(problem, retry: problem == "reference_check_failed") }
        guard let reservation = TaskWorktreeCheckoutReservation.acquire(path) else {
            return kept("cleanup_in_progress", retry: true)
        }
        defer { TaskWorktreeCheckoutReservation.release(reservation) }
        let resourceLease: TaskWorktreeResourceLease
        do {
            // Exclusive across the whole check-then-delete sequence, so no
            // sibling worktree task can check out the branch in between.
            resourceLease = try TaskWorktreeResourceLease.acquire(
                repositoryPath: repository, worktreePath: path, gitAccess: .exclusive,
                taskID: discard.taskID, queue: resourceQueue
            )
        } catch TaskWorktreeCreationError.repositoryBusy {
            return kept("repository_busy", retry: true)
        } catch {
            return kept(error.localizedDescription, retry: true)
        }
        defer { resourceLease.release() }
        // An unborn primary checkout is still a repository. Availability is the
        // worktree registry, not whether that checkout's HEAD is a commit.
        guard !(await git.listWorktrees(at: repository)).isEmpty else {
            return kept("repository_unavailable", retry: true)
        }
        // A status that can't be read is never taken as clean: the forced
        // removal below deletes tracked and untracked edits.
        func uncleanOutcome() async -> TaskWorktreeCleanupOutcome? {
            switch await git.worktreeIsClean(at: path) {
            case true?:
                // Status trusts the index for assume-unchanged and
                // skip-worktree files, so their contents are compared too.
                return await git.indexHiddenEntriesChanged(at: path) ? kept("index_hidden_changes") : nil
            case false?:
                return kept("uncommitted_changes")
            case nil:
                return kept("status_unavailable", retry: true)
            }
        }
        // A worktree that recorded an identity is removed only while the
        // registered checkout is still that incarnation, never one recreated
        // at the same path on the same branch. A lock this creation took is
        // released first, or Git refuses the removal.
        if let identity = discard.identity {
            if let markers = TaskWorktreeBinding.registeredMarkers(repositoryPath: repository, worktreePath: path) {
                let reason = TaskWorktreeBinding.lockReason(forIdentity: identity)
                guard markers.identity == identity || markers.lockReason == reason else { return kept("replaced") }
                if markers.lockReason == reason {
                    do {
                        try await git.unlockWorktree(repoPath: repository, worktreePath: path)
                    } catch {
                        return kept("unlock_failed", retry: true)
                    }
                }
            } else if ownership?.removalState(discard) == .unreadable {
                return kept("removal_mark_unreadable", retry: true)
            } else if ownership?.isRemoving(discard) != true {
                // Gone without this cleanup having removed it: nothing ties
                // the branch to this worktree any more, so it is kept.
                return kept("identity_unverifiable")
            } else {
                // Resuming the branch phase of a removal this cleanup made.
                // With the worktree gone, only the Git directory's identity
                // shows this is still the repository it created the branch
                // in, not a new clone at the same path.
                guard let recorded = discard.commonDirectoryID,
                      let current = GitCheckoutLayout.commonDirectory(for: repository),
                      GitCheckoutLayout.fileIdentity(of: current) == recorded
                else { return kept("repository_unverifiable") }
            }
        }
        // From the checks of what the checkout holds and which branch it is
        // on, through its removal and the branch deletion, the Repository
        // card can't check out a branch here; it waits for any branch
        // operation it started.
        guard let deletionHold = TaskBranchDeletionGate.beginDeletion(at: repository) else {
            return kept("repository_busy", retry: true)
        }
        defer { TaskBranchDeletionGate.endDeletion(deletionHold) }
        // A checkout that can't be checked is retried, never taken as gone:
        // that would skip every check of what it holds.
        let exists: Bool
        do {
            exists = try GitService.attributesConfirmingAbsence(atPath: path) != nil
        } catch {
            return kept("worktree_unavailable", retry: true)
        }
        if exists {
            if let unclean = await uncleanOutcome() { return unclean }
            guard !(await git.hasIgnoredFiles(at: path)) else { return kept("ignored_files") }
            guard !(await git.unpopulatedGitlinksHoldFiles(at: path)) else { return kept("submodule_files") }
            let branch = await git.getCurrentBranch(at: path)
            guard branch != "unknown" else { return kept("branch_unavailable", retry: true) }
            guard branch == discard.branch else { return kept("branch_switched") }
        }
        // Per-worktree Git configuration lives in the entry a removal deletes.
        if TaskWorktreeBinding.registeredWorktreeHasLocalConfig(repositoryPath: repository, worktreePath: path) == true {
            return kept("worktree_config")
        }
        // ASTRA creates the branch from a commit, with no upstream, so any
        // `branch.<name>.*` setting, such as one `--set-upstream-to` or a
        // description wrote, is the user's, and deleting the ref strands it.
        if await git.branchHasConfiguration(discard.branch, at: repository) {
            return kept("branch_config")
        }
        if TaskWorktreeBinding.registeredWorktreeHasOwnRefs(repositoryPath: repository, worktreePath: path) == true {
            return kept("worktree_refs")
        }
        // A tip that can't be read is retried, never taken as a missing branch.
        let commit: String?
        switch await git.localBranchTip(discard.branch, at: repository) {
        case .commit(let tip): commit = tip
        case .absent: commit = nil
        case .unavailable: return kept("branch_unavailable", retry: true)
        }
        if let commit {
            guard commit == discard.baseCommit else { return kept("has_commits") }
        } else if exists {
            return kept("branch_unavailable", retry: true)
        }
        if commit != nil, await git.hasWorktreeReflogChanges(
            branch: discard.branch, baseCommit: discard.baseCommit,
            worktreePath: exists ? path : nil, repoPath: repository
        ) {
            return kept("reflog_changes")
        }
        // With the folder gone, Git still keeps the worktree's HEAD reflog in
        // its registry entry until the removal below deletes it; a detached
        // commit there is work too.
        if !exists {
            switch TaskWorktreeBinding.registeredHeadReflog(repositoryPath: repository, worktreePath: path) {
            case .notRegistered:
                break
            case .unreadable:
                return kept("reflog_changes")
            case .commits(let commits):
                if commits.isEmpty || commits.contains(where: { $0 != discard.baseCommit }) { return kept("reflog_changes") }
            }
        }
        // Last of the work checks, so a more specific reason above wins.
        if TaskWorktreeBinding.registeredWorktreeHasOwnState(
            repositoryPath: repository, worktreePath: path, baseCommit: discard.baseCommit
        ) == true {
            return kept("worktree_state")
        }
        let registered = await git.listWorktrees(at: repository)
        guard !registered.isEmpty else { return kept("registry_unavailable", retry: true) }
        if Task.isCancelled { return kept("cancelled", retry: true) }
        if let problem = referenceProblem() { return kept(problem, retry: problem == "reference_check_failed") }
        // Resolved through the deepest existing folder: Foundation can't
        // resolve a vanished path, so `/var` would never match Git's
        // `/private/var` and a gone worktree would never be removed.
        let isRegistered = registered.contains {
            WorkspacePathPresentation.resolvedPath($0.path) == WorkspacePathPresentation.resolvedPath(path)
        }
        await duringReservation()
        if let problem = referenceProblem() { return kept(problem, retry: problem == "reference_check_failed") }
        /// Nil once Git removed the worktree; otherwise why it was kept.
        func removeWorktree() async -> TaskWorktreeCleanupOutcome? {
            do {
                try await git.removeWorktree(repoPath: repository, worktreePath: path, force: false)
                return nil
            } catch {
                // Git removes a worktree that stores submodule repositories
                // only when forced, which deletes them too.
                switch exists ? await git.submoduleCheckoutState(at: path) : .notPopulated {
                case .changed:
                    return kept("submodule_changes")
                case .notPopulated, .unknown:
                    return kept("remove_failed", retry: true)
                case .unchanged:
                    if let unclean = await uncleanOutcome() { return unclean }
                    guard !(await git.hasIgnoredFiles(at: path)) else { return kept("ignored_files") }
                    if let problem = referenceProblem() { return kept(problem, retry: problem == "reference_check_failed") }
                    do {
                        try await git.removeWorktree(repoPath: repository, worktreePath: path, force: true)
                        return nil
                    } catch {
                        return kept("remove_failed", retry: true)
                    }
                }
            }
        }
        // A registered checkout whose folder is gone may have been moved, not
        // deleted: Git would prune it without `--force`, breaking the moved
        // checkout's `.git` and losing its index. The removal mark doesn't
        // tell either, as it is written before `git worktree remove` runs and
        // so records intent, not a removal. Only Git's entry being gone shows
        // one happened, which the resumed branch phase above checks.
        if !exists, isRegistered { return kept("worktree_missing") }
        if exists || isRegistered {
            do {
                try ownership?.markRemoving(discard)
            } catch {
                return kept("removal_mark_failed", retry: true)
            }
            // The mark vouches only for a removal this cleanup made, so it is
            // taken back whenever Git didn't remove the worktree.
            if let notRemoved = await removeWorktree() {
                do {
                    try ownership?.clearRemoving(discard)
                } catch {
                    return kept("removal_mark_clear_failed", retry: true)
                }
                return notRemoved
            }
            if let problem = referenceProblem() { return kept(problem, retry: true) }
        }
        let remaining = await git.listWorktrees(at: repository)
        guard !remaining.isEmpty else { return kept("registry_unavailable", retry: true) }
        guard !remaining.contains(where: { $0.branch == discard.branch }) else { return kept("branch_in_use") }
        if commit != nil {
            do {
                try await git.deleteLocalBranch(discard.branch, ifAt: discard.baseCommit, at: repository)
            } catch {
                return kept("branch_delete_failed", retry: true)
            }
        }
        AppLogger.breadcrumb(action: "task_worktree_discarded", category: "Git", taskID: discard.taskID, fields: [
            "worktree": path,
            "branch": discard.branch,
            "branch_deleted": "true"
        ])
        return .removed
    }

    /// Every checkout that a surviving task or workspace points at: task pins,
    /// explicit workspace defaults, and each workspace's configured primary and
    /// additional paths, which it uses implicitly while no default is set.
    /// Cleanup follows saved deletion; never exclude task UUIDs, which
    /// Duplicate imports preserve. Unreadable stores keep the worktree.
    ///
    /// A configured folder at or above `worktreesRoot`, such as `~/Documents`
    /// above the app-managed `Worktrees` folder, is not a checkout a task
    /// writes through; counting it would keep every discarded worktree of
    /// every repository forever. Pins and workspace defaults always count.
    ///
    /// `ignoring` drops one task's pin, for a pin that provably names
    /// another checkout than the one being cleaned up.
    static func durableCheckoutPins(
        modelContext: ModelContext,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot,
        ignoring: (AgentTask) -> Bool = { _ in false }
    ) throws -> Set<String> {
        let tasks = try modelContext.fetch(FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.executionRootPath != nil }
        ))
        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        let root = WorkspacePathPresentation.resolvedPath(worktreesRoot)
        func containsWorktreesRoot(_ path: String) -> Bool {
            guard !root.isEmpty else { return false }
            let resolved = WorkspacePathPresentation.resolvedPath(path)
            return !resolved.isEmpty && (root == resolved || root.hasPrefix(resolved.hasSuffix("/") ? resolved : resolved + "/"))
        }
        return Set(tasks.filter { !ignoring($0) }.compactMap { standardized($0.executionRootPath) }
            + workspaces.flatMap { workspace -> [String] in
                [standardized(workspace.activeWorkingPath)].compactMap { $0 }
                    + ([workspace.primaryPath] + workspace.additionalPaths)
                        .filter { !containsWorktreesRoot($0) }
                        .compactMap { standardized($0) }
            })
    }

    /// Records cleanup of each worktree before deleting the draft, then saves
    /// the deletion. Removal starts only after both are durable and resumes on
    /// next launch if interrupted. A failed intent write never runs `delete`.
    /// A failed save rolls the deletion back so the draft stays in the context;
    /// unrelated unsaved work is saved first so that rollback reverts only the
    /// deletion, and `delete` must not save on its own.
    @discardableResult
    static func saveDeletionThenDiscard(
        _ discards: [TaskWorktreeDiscard],
        workspace: Workspace?,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        cleanupStore: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore(),
        delete: @MainActor () -> Void = {},
        persist: @MainActor (Workspace?, ModelContext) -> Bool = { workspace, modelContext in
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        }
    ) -> TaskWorktreeDeletionResult {
        if modelContext.hasChanges {
            do {
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                    workspace: workspace, modelContext: modelContext,
                    auditFields: ["operation": "deletion_checkpoint"]
                )
            } catch {
                AppLogger.audit(.taskFailed, category: "Persistence", taskID: discards.first?.taskID, fields: [
                    "reason": "deletion_checkpoint_save_failed",
                    "error": error.localizedDescription
                ], level: .error)
                return TaskWorktreeDeletionResult(persisted: false, cleanup: nil)
            }
        }
        // Records this attempt adds, which a failure below, writing a later
        // one or saving the deletion, takes back: the deletion never
        // happened, so they must not outlive it. Ones an
        // earlier deletion left stay, as `record` never rewrites them.
        var added: [TaskWorktreeDiscard] = []
        for discard in discards {
            do {
                if try cleanupStore.record(discard) { added.append(discard) }
                AppLogger.breadcrumb(action: "task_worktree_cleanup_requested", category: "Git", taskID: discard.taskID, fields: [
                    "worktree": discard.worktreePath,
                    "branch": discard.branch
                ])
            } catch {
                AppLogger.audit(.taskFailed, category: "Persistence", taskID: discard.taskID, fields: [
                    "reason": "worktree_cleanup_intent_save_failed",
                    "error": error.localizedDescription
                ], level: .error)
                for record in added { try? cleanupStore.remove(record) }
                return TaskWorktreeDeletionResult(persisted: false, cleanup: nil)
            }
        }
        delete()
        let saved = persist(workspace, modelContext)
        guard saved else {
            modelContext.rollback()
            for record in added { try? cleanupStore.remove(record) }
            for discard in discards {
                AppLogger.breadcrumb(action: "task_worktree_kept", category: "Git", taskID: discard.taskID, fields: [
                    "worktree": discard.worktreePath,
                    "branch": discard.branch,
                    "reason": "deletion_not_saved"
                ])
            }
            return TaskWorktreeDeletionResult(persisted: false, cleanup: nil)
        }
        guard !discards.isEmpty else { return TaskWorktreeDeletionResult(persisted: true, cleanup: nil) }
        let cleanup = Task { @MainActor in
            var removedAll = true
            for discard in discards {
                let removed = await TaskWorktreeCleanupService.process(
                    discard, store: cleanupStore, modelContext: modelContext, resourceQueue: resourceQueue
                )
                removedAll = removedAll && removed
            }
            return removedAll
        }
        return TaskWorktreeDeletionResult(persisted: true, cleanup: cleanup)
    }

    private static func standardized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return WorkspacePathPresentation.standardizedPath(path)
    }
}
