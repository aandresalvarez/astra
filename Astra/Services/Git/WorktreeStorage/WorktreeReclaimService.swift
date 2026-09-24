import Foundation
import ASTRACore
import ASTRAModels

/// Runs synchronous file-system work on one serial utility queue, so
/// measuring and deleting multi-gigabyte trees never contend with each other
/// and never occupy Swift concurrency's cooperative threads.
enum WorktreeStorageWork {
    private static let queue = DispatchQueue(label: "com.coral.astra.worktree-storage", qos: .utility)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

/// A finished reclaim pass, as the panel reports it.
struct WorktreeReclaimSummary: Equatable, Sendable {
    struct Kept: Equatable, Sendable {
        let worktreeName: String
        let reason: String
    }

    let mode: WorktreeReclaimMode
    let finishedAt: Date
    /// The worktrees the pass covered.
    let worktreePaths: [String]
    let outcome: WorktreeReclaimOutcome
    /// Worktrees with artifacts the pass left alone, and why.
    let kept: [Kept]
    let reclaimedWorktreeCount: Int

    var freedBytes: Int64 { outcome.freedBytes }
    var skippedCount: Int { kept.count + outcome.skipped.count + outcome.failures.count }
    var skipReasons: [String] {
        kept.map { "\($0.worktreeName): \($0.reason)" }
            + outcome.skipped.map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
            + outcome.failures.map { "\(($0.path as NSString).lastPathComponent): \($0.message)" }
    }
}

/// What the panel shows for one worktree.
struct WorktreeStorageStatus: Equatable, Sendable {
    /// The worktree as git reported it when this was computed. When HEAD,
    /// branch, lock or prune state moves, the decision no longer applies.
    let worktree: GitWorktreeInfo
    /// Whether it counted as a workspace's root or selected worktree. When
    /// that changes, the decision no longer applies either.
    let isWorkspaceRoot: Bool
    let report: WorktreeStorageReport
    /// What "Reclaim" would do right now (manual mode), including the removal
    /// suggestion.
    let decision: WorktreeReclaimDecision
    let idle: TimeInterval?
    /// Why a task held the worktree when this was decided, if one did. When
    /// tasks start or stop using it, the decision no longer applies.
    var taskClaim: String?
    /// The last activity the decision saw. A newer durable record (a task
    /// that started and finished in between) makes it stale.
    var lastActivity: Date?

    var reclaimableBytes: Int64 { decision.reclaimArtifacts ? report.artifactBytes : 0 }
}

/// A workspace's configured paths, captured on the main actor at launch.
struct WorktreeStorageWorkspacePaths: Equatable, Sendable {
    let primaryPath: String
    let additionalPaths: [String]
}

/// Owns the storage lifecycle of every worktree git reports for a workspace
/// repository: measures, reclaims idle build artifacts, and suggests removing
/// merged, stale worktrees. It never removes a worktree itself.
///
/// Evaluation is event-driven: app launch, a task reaching a terminal state,
/// the panel, and the user's Reclaim button. When time alone will change an
/// automatic decision (a worktree becoming idle enough), the pass schedules a
/// one-shot recheck for that moment instead of polling.
@MainActor
final class WorktreeReclaimService: ObservableObject {
    static let shared = WorktreeReclaimService()

    /// Derived cache of measurements and decisions, keyed by worktree path
    /// (`GitWorktreeInfo.id`). Source: the file system via
    /// `WorktreeStorageInspector`, plus git and task state. Refreshed when the
    /// worktree sheet opens (entries older than `measurementTTL`), on the
    /// panel's refresh button, after a reclaim and by every automatic pass;
    /// the panel's 30 s refresh only reconciles the path set. Never evicted on
    /// an empty worktree list, which is what a failed `git worktree list`
    /// returns.
    @Published private(set) var statuses: [String: WorktreeStorageStatus] = [:]
    @Published private(set) var measuringPaths: Set<String> = []
    @Published private(set) var isReclaiming = false
    /// Recent pass results, newest last. Each records the worktrees it
    /// covered, so a repository's sheet only shows its own.
    @Published private(set) var recentReclaims: [WorktreeReclaimSummary] = []
    /// When each scheduled automatic recheck fires, by worktree path.
    private(set) var pendingRecheckDates: [String: Date] = [:]

    nonisolated static let measurementTTL: TimeInterval = 10 * 60
    nonisolated static let launchDelay: TimeInterval = 120
    /// Debounces repeated setting changes before a pass runs.
    private static let settingsChangeDelay: TimeInterval = 5
    /// Rechecks fire a little after the threshold so rounding never re-keeps.
    private static let recheckSlack: TimeInterval = 60

    private let git: WorktreeStorageGitReading
    private let defaults: UserDefaults
    private let inspector: WorktreeStorageInspector
    private let reclaimer: WorktreeReclaimer
    private let resolver: WorktreeMergeStateResolver
    private let clock: () -> Date
    /// Throws when task state can't be read; a pass then keeps everything.
    private var taskHolds: @MainActor () throws -> [WorktreeTaskHold] = { [] }
    /// Throws when workspace state can't be read; automatic mode then keeps
    /// everything, and no removal is suggested.
    private var workspaceRoots: @MainActor () throws -> [String] = { [] }
    /// The app's workspaces, read when a launch or settings-change pass fires.
    private var workspaces: @MainActor () throws -> [WorktreeStorageWorkspacePaths] = { [] }
    private var hasRunLaunchPass = false
    /// Consecutive launch passes that couldn't read the workspace list.
    private(set) var failedLaunchReads = 0
    static let maxLaunchReadAttempts = 3
    /// The workspaces the waiting launch pass retries; nil for a full pass.
    private(set) var launchRetryWorkspaces: [WorktreeStorageWorkspacePaths]?
    /// Repositories an automatic pass has covered (or is about to), by
    /// canonical path.
    private var automaticallyEvaluatedRepositories: Set<String> = []
    private var repositoryPasses: [String: Task<Void, Never>] = [:]
    private var suggestionCheckedAt: [String: Date] = [:]
    /// Consecutive keeps per worktree that a failed read caused. Only a
    /// pass that reads cleanly resets it.
    private var readFailureRetries: [String: Int] = [:]
    /// Tries a recheck makes at listing the worktree before giving up.
    static let maxRecheckListingAttempts = 3
    private var revalidatingSuggestions: Set<String> = []
    private static let suggestionRecheckInterval: TimeInterval = 60
    /// Worktrees measured so far; lets tests prove work isn't repeated.
    private(set) var measuredWorktreeCount = 0
    private var repoWorktreePaths: [String: Set<String>] = [:]
    private var passChain: Task<Void, Never>?
    private var rechecks: [String: Task<Void, Never>] = [:]
    private var launchPass: Task<Void, Never>?
    private var terminalObserver: NSObjectProtocol?
    private var requestObserver: NSObjectProtocol?

    init(
        git: WorktreeStorageGitReading = GitService.shared,
        defaults: UserDefaults = .standard,
        probe: WorktreeActivityProbe = WorktreeActivityProbe(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.git = git
        self.defaults = defaults
        self.inspector = WorktreeStorageInspector()
        self.reclaimer = WorktreeReclaimer(probe: probe)
        self.resolver = WorktreeMergeStateResolver(git: git)
        self.clock = clock
    }

    /// Connects the service to the app's tasks and workspaces. The app calls
    /// this once at launch with providers backed by its main model context.
    /// Each is read when a pass needs it, so later workspace edits count.
    func attach(
        taskHolds: @escaping @MainActor () throws -> [WorktreeTaskHold],
        workspaceRoots: @escaping @MainActor () throws -> [String],
        workspaces: @escaping @MainActor () throws -> [WorktreeStorageWorkspacePaths] = { [] }
    ) {
        self.taskHolds = taskHolds
        self.workspaceRoots = workspaceRoots
        self.workspaces = workspaces
    }

    /// Cancels the pending launch pass, repository passes and rechecks.
    func cancelScheduledWork() {
        launchPass?.cancel()
        launchPass = nil
        launchRetryWorkspaces = nil
        repositoryPasses.values.forEach { $0.cancel() }
        repositoryPasses.removeAll()
        rechecks.values.forEach { $0.cancel() }
        rechecks.removeAll()
        pendingRecheckDates.removeAll()
    }

    // MARK: - Triggers

    /// Launch trigger: after `delay`, finish interrupted reclaims and evaluate
    /// every workspace repository once. The workspace list is read when the
    /// pass fires, so workspaces added in the meantime are included.
    /// `retrying` limits the pass to workspaces an earlier pass couldn't get
    /// answers for; `attempt` counts those passes.
    func scheduleLaunchPass(
        delay: TimeInterval = launchDelay,
        retrying missed: [WorktreeStorageWorkspacePaths]? = nil,
        attempt: Int = 1
    ) {
        launchPass?.cancel()
        launchRetryWorkspaces = missed
        launchPass = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            do {
                var current = try self.workspaces()
                if let missed { current = current.filter { missed.contains($0) } }
                self.failedLaunchReads = 0
                let unanswered = await self.runLaunchPass(workspaces: current, skippingCovered: missed != nil)
                // A settings change may have replaced this task meanwhile.
                guard !Task.isCancelled else { return }
                self.launchPass = nil
                // Nothing polls, so git failing for a workspace now would
                // otherwise leave it uncovered until its panel opens.
                if !unanswered.isEmpty, attempt < Self.maxLaunchReadAttempts {
                    self.scheduleLaunchPass(delay: Self.launchDelay, retrying: unanswered, attempt: attempt + 1)
                }
            } catch {
                if !Task.isCancelled { self.launchPass = nil }
                self.failedLaunchReads += 1
                AppLogger.error("Worktree launch pass deferred: workspace state unreadable (attempt \(self.failedLaunchReads)): \(error.localizedDescription)", category: "Git")
                if self.failedLaunchReads < Self.maxLaunchReadAttempts {
                    self.scheduleLaunchPass(delay: Self.launchDelay, retrying: missed, attempt: attempt)
                } else {
                    // Stop retrying; let the panel cover repositories one by one.
                    self.hasRunLaunchPass = true
                }
            }
        }
    }

    /// True while a launch or settings-change pass is waiting to run.
    var hasScheduledLaunchPass: Bool { launchPass != nil }

    /// True while a first automatic pass for a newly seen repository waits.
    func hasScheduledRepositoryPass(_ repoPath: String) -> Bool {
        repositoryPasses[WorktreePath.canonical(repoPath)] != nil
    }

    /// The settings card calls this after either setting changes. Turning
    /// automatic reclaim off cancels scheduled work, and a pass already
    /// running re-reads the setting before it deletes anything. Turning it
    /// on, or changing the threshold, schedules a fresh pass over every
    /// workspace, so the new rule applies without waiting for a relaunch.
    func automaticReclaimSettingsChanged() {
        cancelScheduledWork()
        guard WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults) else { return }
        scheduleLaunchPass(delay: Self.settingsChangeDelay)
    }

    /// Evaluates every repository of these workspaces once. Returns the
    /// workspaces git couldn't fully answer for: a configured path with a
    /// `.git` that discovery didn't return, or a failed worktree listing.
    /// `skippingCovered` leaves out repositories a pass already covered.
    @discardableResult
    func runLaunchPass(
        workspaces: [WorktreeStorageWorkspacePaths],
        skippingCovered: Bool = false
    ) async -> [WorktreeStorageWorkspacePaths] {
        hasRunLaunchPass = true
        var repositories: [(path: String, workspace: Int)] = []
        var unanswered = Set<Int>()
        for (index, workspace) in workspaces.enumerated() {
            let scanned = await git.scanForGitRepositories(
                primaryPath: workspace.primaryPath,
                additionalPaths: workspace.additionalPaths
            )
            // Discovery answers "no repository" and "git failed" alike.
            let configured = WorkspacePathPresentation.descriptors(
                primaryPath: workspace.primaryPath,
                additionalPaths: workspace.additionalPaths
            ).map(\.path)
            if configured.contains(where: { path in
                WorkspacePathPresentation.isGitRepository(at: path) && !scanned.contains { WorktreePath.same($0.path, path) }
            }) {
                unanswered.insert(index)
            }
            for repository in scanned.map(\.path) where !repositories.contains(where: { WorktreePath.same($0.path, repository) }) {
                repositories.append((repository, index))
            }
        }
        var seen = Set<String>()
        for repository in repositories {
            let key = WorktreePath.canonical(repository.path)
            if skippingCovered, automaticallyEvaluatedRepositories.contains(key) { continue }
            // Two configured paths can be checkouts of one repository; each
            // worktree is evaluated once.
            let listed = await git.listWorktrees(at: repository.path)
            // An empty list means git failed: leave the repository uncovered
            // and its workspace up for another try.
            guard !listed.isEmpty else {
                unanswered.insert(repository.workspace)
                continue
            }
            automaticallyEvaluatedRepositories.insert(key)
            let worktrees = listed.filter { seen.insert(WorktreePath.canonical($0.path)).inserted }
            guard !worktrees.isEmpty else { continue }
            _ = await evaluate(repoPath: repository.path, worktrees: worktrees, mode: .automatic)
        }
        return unanswered.sorted().map { workspaces[$0] }
    }

    /// New-repository trigger: a repository the panel shows that no automatic
    /// pass has covered (a workspace added or imported after launch) gets one,
    /// after the launch delay. Until the launch pass has run, it covers every
    /// workspace itself.
    private func scheduleFirstAutomaticPassIfNeeded(repoPath: String) {
        guard hasRunLaunchPass, WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults) else { return }
        let key = WorktreePath.canonical(repoPath)
        guard automaticallyEvaluatedRepositories.insert(key).inserted else { return }
        repositoryPasses[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            guard !Task.isCancelled, let self else { return }
            self.repositoryPasses[key] = nil
            let worktrees = await self.git.listWorktrees(at: repoPath)
            guard !worktrees.isEmpty else {
                // Git failed; let a later look try again.
                self.automaticallyEvaluatedRepositories.remove(key)
                return
            }
            _ = await self.evaluate(repoPath: repoPath, worktrees: worktrees, mode: .automatic)
        }
    }

    /// Task trigger: the worktree a finished task used was active just now,
    /// so look again once it can have been idle long enough.
    func startObservingTaskCompletion() {
        guard terminalObserver == nil else { return }
        terminalObserver = NotificationCenter.default.addObserver(
            forName: .taskDidReachTerminalState,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let change = notification.object as? TaskTerminalStateChange else { return }
            Task { @MainActor [weak self] in
                self?.handleTaskReachedTerminalState(change)
            }
        }
        requestObserver = NotificationCenter.default.addObserver(
            forName: .taskTurnRequestDidReachTerminalState,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let change = notification.object as? TaskTurnRequestTerminalChange else { return }
            Task { @MainActor [weak self] in
                self?.handleTurnRequestReachedTerminalState(change)
            }
        }
    }

    func stopObservingTaskCompletion() {
        if let terminalObserver { NotificationCenter.default.removeObserver(terminalObserver) }
        if let requestObserver { NotificationCenter.default.removeObserver(requestObserver) }
        terminalObserver = nil
        requestObserver = nil
    }

    func handleTaskReachedTerminalState(_ change: TaskTerminalStateChange) {
        let enabled = WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults)
        let reclaimAfter = WorktreeStorageSettings.thresholds(in: defaults).reclaimAfter
        // A task can run in a subfolder and write elsewhere; each recheck needs
        // the checkout git lists. `git worktree list` works from any checkout.
        var roots: [String] = []
        if let path = change.workingPath {
            roots.append(WorktreePath.containingCheckoutRoot(of: path) ?? path)
        }
        for path in change.writablePaths {
            if let root = WorktreePath.containingCheckoutRoot(of: path), !roots.contains(root) {
                roots.append(root)
            }
        }
        let finishedAt = clock()
        for root in roots {
            // Recorded durably, whatever the setting: once finished, the task
            // no longer claims the checkout, and turning automatic reclaim on
            // later must still see it was just in use.
            _ = preservedActivity(root, observed: finishedAt)
            guard enabled else { continue }
            scheduleRecheck(repoPath: root, worktreePath: root, at: finishedAt.addingTimeInterval(reclaimAfter))
        }
    }

    /// A turn request stopped holding what it captured. A pass that kept a
    /// worktree only for that hold scheduled nothing, and a follow-up
    /// retracted from a finished task changes no task status, so this is the
    /// only cue to look again.
    func handleTurnRequestReachedTerminalState(_ change: TaskTurnRequestTerminalChange) {
        let enabled = WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults)
        let reclaimAfter = WorktreeStorageSettings.thresholds(in: defaults).reclaimAfter
        var roots: [String] = []
        for path in change.capturedPaths {
            let root = WorktreePath.containingCheckoutRoot(of: path) ?? path
            if !roots.contains(root) { roots.append(root) }
        }
        let endedAt = clock()
        for root in roots {
            // A turn that ran worked there just now; one retracted while
            // queued never touched it, and the pass reads real activity.
            if change.ran { _ = preservedActivity(root, observed: endedAt) }
            guard enabled else { continue }
            let at = endedAt.addingTimeInterval(change.ran ? reclaimAfter : WorktreeActivityProbe.recentWriteWindow)
            // An earlier recheck re-derives any later one, so keep it.
            if let pending = pendingRecheckDates[root], pending <= at { continue }
            scheduleRecheck(repoPath: root, worktreePath: root, at: at)
        }
    }

    // MARK: - Panel

    /// Called on every panel refresh: measures worktrees the cache hasn't
    /// seen, re-evaluates any whose HEAD, branch, lock, prune state, task
    /// claims or recorded activity moved, and forgets removed ones. Cheap
    /// when nothing changed.
    func reconcile(repoPath: String, worktrees: [GitWorktreeInfo]) {
        guard !worktrees.isEmpty else { return }
        let paths = Set(worktrees.map(\.path))
        for removed in (repoWorktreePaths[repoPath] ?? []).subtracting(paths) {
            statuses[removed] = nil
        }
        repoWorktreePaths[repoPath] = paths
        scheduleFirstAutomaticPassIfNeeded(repoPath: repoPath)
        let roots = currentWorkspaceRoots()
        let holds = worktrees.contains { statuses[$0.path] != nil } ? currentTaskHolds() : []
        var stale: [GitWorktreeInfo] = []
        for worktree in worktrees where !measuringPaths.contains(worktree.path) {
            guard let status = statuses[worktree.path] else {
                stale.append(worktree)
                continue
            }
            let isWorkspaceRoot = Self.isProtected(worktree.path, roots: roots, otherWorktreePaths: Array(paths))
            let taskClaim = inUseReason(worktree.path, holds: holds, otherWorktreePaths: Array(paths))
            let usedSince = recordedActivity(worktree.path).map { $0 > (status.lastActivity ?? .distantPast) } ?? false
            guard status.worktree != worktree || status.isWorkspaceRoot != isWorkspaceRoot
                || status.taskClaim != taskClaim || usedSince else { continue }
            if status.isWorkspaceRoot, !isWorkspaceRoot, pendingRecheckDates[worktree.path] == nil,
               WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults) {
                // No longer a workspace's checkout: the pass that kept it for
                // that reason scheduled nothing, so look again now. A pending
                // recheck (a finished task's grace period) is left in place.
                scheduleRecheck(repoPath: repoPath, worktreePath: worktree.path, at: clock())
            }
            // Withdraw a "Merged · Remove" suggestion at once: it described a
            // HEAD, or a selection, that has changed. The refresh decides afresh.
            var decision = status.decision
            decision.suggestRemoval = false
            // A task now using it: stop offering its artifacts at once too.
            if let taskClaim {
                decision.reclaimArtifacts = false
                decision.reason = taskClaim
            }
            statuses[worktree.path] = WorktreeStorageStatus(
                worktree: worktree,
                isWorkspaceRoot: isWorkspaceRoot,
                report: status.report,
                decision: decision,
                idle: status.idle,
                taskClaim: taskClaim,
                lastActivity: status.lastActivity
            )
            stale.append(worktree)
        }
        revalidateSuggestions(repoPath: repoPath, worktrees: worktrees.filter { !stale.contains($0) })
        guard !stale.isEmpty else { return }
        Task { await self.refresh(repoPath: repoPath, worktrees: stale, maxAge: nil, context: worktrees) }
    }

    /// A "Merged · Remove" suggestion depends on the base branch too, which can
    /// move (a force-push, a retarget) without the worktree changing. At most
    /// once a minute per worktree, re-check cleanliness and merge state and
    /// withdraw the suggestion if either no longer holds. Ancestry is a local
    /// git call; a merge GitHub confirmed stays cached.
    private func revalidateSuggestions(repoPath: String, worktrees: [GitWorktreeInfo]) {
        let now = clock()
        let due = worktrees.filter { worktree in
            guard statuses[worktree.path]?.decision.suggestRemoval == true,
                  !revalidatingSuggestions.contains(worktree.path) else { return false }
            return now.timeIntervalSince(suggestionCheckedAt[worktree.path] ?? .distantPast) >= Self.suggestionRecheckInterval
        }
        guard !due.isEmpty else { return }
        revalidatingSuggestions.formUnion(due.map(\.path))
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.revalidatingSuggestions.subtract(due.map(\.path)) }
            let defaultBranch = await self.git.getDefaultBaseBranch(at: repoPath, remote: nil)
            for worktree in due {
                self.suggestionCheckedAt[worktree.path] = self.clock()
                let clean = await self.git.hasUncommittedChanges(at: worktree.path) == false
                let merged = clean
                    ? await self.resolver.resolve(worktree: worktree, repoPath: repoPath, defaultBranch: defaultBranch) == .merged
                    : false
                guard !(clean && merged), let status = self.statuses[worktree.path], status.worktree == worktree else { continue }
                var decision = status.decision
                decision.suggestRemoval = false
                self.statuses[worktree.path] = WorktreeStorageStatus(
                    worktree: status.worktree,
                    isWorkspaceRoot: status.isWorkspaceRoot,
                    report: status.report,
                    decision: decision,
                    idle: status.idle,
                    taskClaim: status.taskClaim,
                    lastActivity: status.lastActivity
                )
            }
        }
    }

    /// Re-measures worktrees whose entry is older than `maxAge`, or all of
    /// them when `maxAge` is nil. Changes nothing on disk. `context` is every
    /// worktree of the repository, so nested ones scope task claims.
    func refresh(
        repoPath: String,
        worktrees: [GitWorktreeInfo],
        maxAge: TimeInterval?,
        context: [GitWorktreeInfo]? = nil
    ) async {
        let requestedAt = clock()
        _ = await enqueue {
            // Decided when the pass runs, not when it's queued: a pass queued
            // ahead of this one may already have measured these worktrees.
            let now = self.clock()
            let stale = worktrees.filter { worktree in
                guard let status = self.statuses[worktree.path] else { return true }
                if status.report.measuredAt >= requestedAt { return false }
                guard let maxAge else { return true }
                return now.timeIntervalSince(status.report.measuredAt) >= maxAge
            }
            guard !stale.isEmpty else {
                return WorktreeReclaimSummary(
                    mode: .manual,
                    finishedAt: now,
                    worktreePaths: [],
                    outcome: WorktreeReclaimOutcome(),
                    kept: [],
                    reclaimedWorktreeCount: 0
                )
            }
            return await self.runPass(repoPath: repoPath, worktrees: stale, context: context ?? worktrees, mode: .manual, act: false)
        }
    }

    /// The Reclaim button: manual mode on every worktree of the repository.
    @discardableResult
    func reclaimNow(repoPath: String, worktrees: [GitWorktreeInfo]) async -> WorktreeReclaimSummary {
        isReclaiming = true
        defer { isReclaiming = false }
        let summary = await evaluate(repoPath: repoPath, worktrees: worktrees, mode: .manual)
        record(summary)
        return summary
    }

    /// The newest pass of `mode` that covered any of these worktrees.
    func lastReclaim(_ mode: WorktreeReclaimMode, among worktrees: [GitWorktreeInfo]) -> WorktreeReclaimSummary? {
        let paths = Set(worktrees.map(\.path))
        return recentReclaims.last { $0.mode == mode && !paths.isDisjoint(with: $0.worktreePaths) }
    }

    private func record(_ summary: WorktreeReclaimSummary) {
        recentReclaims.append(summary)
        if recentReclaims.count > 20 { recentReclaims.removeFirst(recentReclaims.count - 20) }
    }

    /// Bytes the Reclaim button would free across the given worktrees.
    func reclaimableBytes(in worktrees: [GitWorktreeInfo]) -> Int64 {
        worktrees.reduce(0) { $0 + (statuses[$1.path]?.reclaimableBytes ?? 0) }
    }

    // MARK: - Evaluation

    /// One serialized pass that may act: manual mode always reclaims what the
    /// policy allows; automatic mode only when the setting is on.
    func evaluate(
        repoPath: String,
        worktrees: [GitWorktreeInfo],
        mode: WorktreeReclaimMode,
        context: [GitWorktreeInfo]? = nil
    ) async -> WorktreeReclaimSummary {
        let act = mode == .manual || WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults)
        let summary = await enqueue {
            await self.runPass(repoPath: repoPath, worktrees: worktrees, context: context ?? worktrees, mode: mode, act: act)
        }
        if mode == .automatic, summary.freedBytes > 0 {
            record(summary)
        }
        return summary
    }

    private func scheduleRecheck(repoPath: String, worktreePath: String, at date: Date, attempt: Int = 1) {
        rechecks[worktreePath]?.cancel()
        pendingRecheckDates[worktreePath] = date
        let delay = min(max(0, date.timeIntervalSince(clock())) + Self.recheckSlack, 8 * 24 * 60 * 60)
        rechecks[worktreePath] = Task { @MainActor [weak self] in
            // The default continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.rechecks[worktreePath] = nil
            self.pendingRecheckDates[worktreePath] = nil
            await self.performRecheck(repoPath: repoPath, worktreePath: worktreePath, attempt: attempt)
        }
    }

    /// Evaluates one worktree when its recheck fires. Rechecks are one-shot and
    /// nothing polls, so a failed `git worktree list` (an empty list) is
    /// retried a few times rather than dropping the worktree for the session.
    /// A worktree git no longer lists is simply gone.
    func performRecheck(repoPath: String, worktreePath: String, attempt: Int = 1) async {
        let all = await git.listWorktrees(at: repoPath)
        guard !all.isEmpty else {
            if attempt < Self.maxRecheckListingAttempts, pendingRecheckDates[worktreePath] == nil {
                scheduleRecheck(
                    repoPath: repoPath,
                    worktreePath: worktreePath,
                    at: clock().addingTimeInterval(WorktreeActivityProbe.recentWriteWindow),
                    attempt: attempt + 1
                )
            }
            return
        }
        let worktrees = all.filter { WorktreePath.same($0.path, worktreePath) }
        guard !worktrees.isEmpty else { return }
        _ = await evaluate(repoPath: repoPath, worktrees: worktrees, mode: .automatic, context: all)
    }

    /// Chains passes so two never touch the same tree at once.
    private func enqueue(_ body: @escaping @MainActor () async -> WorktreeReclaimSummary) async -> WorktreeReclaimSummary {
        let previous = passChain
        let pass = Task { @MainActor in
            await previous?.value
            return await body()
        }
        passChain = Task { _ = await pass.value }
        return await pass.value
    }

    private struct FileFacts: Sendable {
        var report: WorktreeStorageReport
        let buildSignal: WorktreeBuildSignal?
        let newestArtifactWrite: Date?
        let indexModified: Date?
    }

    private struct ReclaimJob: Sendable {
        let worktree: String
        let name: String
        var artifacts: [WorktreeArtifactMeasurement]
    }

    private func runPass(
        repoPath: String,
        worktrees: [GitWorktreeInfo],
        context: [GitWorktreeInfo],
        mode: WorktreeReclaimMode,
        act: Bool
    ) async -> WorktreeReclaimSummary {
        let now = clock()
        let paths = worktrees.map(\.path)
        let allPaths = Array(Set(context.map(\.path) + paths))
        measuringPaths.formUnion(paths)
        defer { measuringPaths.subtract(paths) }
        measuredWorktreeCount += paths.count

        let inspector = self.inspector
        let probe = reclaimer.probe
        var facts = await WorktreeStorageWork.run {
            paths.map { Self.fileFacts(worktreePath: $0, inspector: inspector, probe: probe, now: now) }
        }

        // A folder's name and manifest make it look like build output; a file
        // git tracks inside it is source all the same. Those artifacts are
        // never reclaimable, and a worktree git can't answer for is kept.
        var trackedArtifacts: [String: Set<String>] = [:]
        var trackingUnknown: Set<String> = []
        for index in facts.indices where !facts[index].report.artifacts.isEmpty {
            let report = facts[index].report
            guard let tracked = await git.trackedDirectories(
                among: report.artifacts.map(\.relativePath),
                at: report.worktreePath
            ) else {
                trackingUnknown.insert(report.worktreePath)
                continue
            }
            trackedArtifacts[report.worktreePath] = tracked
            facts[index].report = report.excludingArtifacts(at: tracked)
        }

        // Fail closed: if task state can't be read, every worktree counts as
        // in use for this pass.
        let holds = currentTaskHolds()
        let roots = currentWorkspaceRoots()
        let thresholds = WorktreeStorageSettings.thresholds(in: defaults)
        let defaultBranch = await git.getDefaultBaseBranch(at: repoPath, remote: nil)
        resolver.beginPass()

        var inputs: [String: WorktreeReclaimInput] = [:]
        var candidates: [ReclaimJob] = []
        var leftovers: [(worktree: String, paths: [String])] = []
        var kept: [WorktreeReclaimSummary.Kept] = []
        for (worktree, fact) in zip(worktrees, facts) {
            var input = WorktreeReclaimInput(
                worktree: worktree,
                isWorkspaceRoot: Self.isProtected(worktree.path, roots: roots, otherWorktreePaths: allPaths),
                artifactBytes: fact.report.artifactBytes,
                lastActivity: preservedActivity(
                    worktree.path,
                    observed: await lastActivity(of: worktree, facts: fact, holds: holds ?? [], otherWorktreePaths: allPaths)
                ),
                buildSignal: fact.buildSignal,
                inUse: inUseReason(worktree.path, holds: holds, otherWorktreePaths: allPaths)
                    ?? (trackingUnknown.contains(worktree.path) ? Self.unreadableTrackingReason : nil)
                    ?? (roots == nil && mode == .automatic ? Self.unreadableWorkspaceStateReason : nil),
                mode: mode,
                thresholds: thresholds,
                now: now
            )
            if WorktreeReclaimPolicy.isRemovalCandidate(input) {
                input.isDirty = await git.hasUncommittedChanges(at: worktree.path)
                if input.isDirty == false {
                    input.mergeState = await resolver.resolve(worktree: worktree, repoPath: repoPath, defaultBranch: defaultBranch, now: now)
                }
            }
            inputs[worktree.path] = input
            publishStatus(worktree, report: fact.report, input: input)

            let decision = WorktreeReclaimPolicy.decide(input)
            if !fact.report.interruptedReclaims.isEmpty {
                leftovers.append((worktree.path, fact.report.interruptedReclaims))
            }
            if act, decision.reclaimArtifacts {
                candidates.append(ReclaimJob(
                    worktree: worktree.path,
                    name: worktree.displayName,
                    artifacts: fact.report.artifacts
                ))
            } else if fact.report.artifactBytes > 0 {
                kept.append(.init(worktreeName: worktree.displayName, reason: decision.reason))
            }
            if mode == .automatic, act, let recheckAt = decision.recheckAt {
                scheduleRecheck(repoPath: repoPath, worktreePath: worktree.path, at: recheckAt)
            }
            // Candidates get their final answer at the gate below.
            if mode == .automatic, act, !decision.reclaimArtifacts {
                retryAfterReadFailure(repoPath: repoPath, worktreePath: worktree.path, decision: decision)
            }
        }

        // Last look before anything is renamed: the pass awaited git and
        // possibly GitHub. Meanwhile a task may have started, the user may
        // have selected one of these worktrees, changed the idle threshold, or
        // turned automatic reclaim off. The check and the renames happen in
        // this one main-actor turn, and every task status change happens on the
        // main actor too, so no task can start in between. Only the slow
        // deletes run on the file-system queue afterwards.
        var jobs: [ReclaimJob] = []
        var prepared: [WorktreeReclaimer.Prepared] = []
        var outcome = WorktreeReclaimOutcome()
        if !candidates.isEmpty {
            // The full build-activity scan walks thousands of entries, so it
            // runs on the file-system queue first. The turn below re-validates,
            // takes SwiftPM's lock, re-checks activity at a cheap depth (for
            // Cargo and npm, which have no lock) and renames.
            let scanAt = clock()
            let scanned = candidates
            let busy = await WorktreeStorageWork.run { () -> [String: WorktreeBuildSignal] in
                var busy: [String: WorktreeBuildSignal] = [:]
                for job in scanned {
                    busy[job.worktree] = job.artifacts.lazy
                        .compactMap { probe.buildSignal(forArtifactAt: $0.path, rule: $0.rule, now: scanAt) }
                        .first
                }
                return busy
            }
            // Git may have started tracking a file under an artifact while
            // the pass awaited GitHub (`git add -N` changes nothing on disk).
            // Ask again, noting the index's timestamp first: the turn below
            // keeps any worktree whose index changed since.
            var gateTracking: [String: (index: Date?, tracked: Set<String>?)] = [:]
            for job in candidates {
                let index = probe.gitIndexModificationDate(worktreePath: job.worktree)
                let tracked = await git.trackedDirectories(among: job.artifacts.map(\.relativePath), at: job.worktree)
                gateTracking[job.worktree] = (index, tracked)
            }
            let checkedAt = clock()
            let current = currentTaskHolds()
            let currentRoots = mode == .automatic ? currentWorkspaceRoots() : []
            let currentThresholds = WorktreeStorageSettings.thresholds(in: defaults)
            let stillEnabled = mode == .manual || WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults)
            for var job in candidates {
                guard var input = inputs[job.worktree] else { continue }
                guard stillEnabled else {
                    kept.append(.init(worktreeName: job.name, reason: "Automatic reclaim turned off"))
                    continue
                }
                if let reason = inUseReason(job.worktree, holds: current, otherWorktreePaths: allPaths) {
                    input.inUse = reason
                }
                // A task can start and finish while the pass awaited git or
                // GitHub, leaving no hold behind. Its finish moved its
                // `updatedAt` and the durable record forward; honor both.
                let taskActivity = current.flatMap {
                    WorktreeTaskUsage.latestActivity(forWorktreePath: job.worktree, holds: $0, otherWorktreePaths: allPaths)
                }
                input.lastActivity = preservedActivity(
                    job.worktree,
                    observed: [input.lastActivity, taskActivity].compactMap { $0 }.max()
                )
                if let signal = busy[job.worktree] {
                    input.buildSignal = signal
                }
                if mode == .automatic {
                    input.thresholds = currentThresholds
                    if Self.isProtected(job.worktree, roots: currentRoots, otherWorktreePaths: allPaths) {
                        input.isWorkspaceRoot = true
                        if currentRoots == nil, input.inUse == nil { input.inUse = Self.unreadableWorkspaceStateReason }
                    }
                }
                let gate = gateTracking[job.worktree]
                let dotGit = (job.worktree as NSString).appendingPathComponent(".git")
                let hasGitEntry = FileManager.default.fileExists(atPath: dotGit) || WorktreeFileSystem.isSymbolicLink(dotGit)
                if let tracked = gate?.tracked {
                    if hasGitEntry, gate?.index == nil {
                        // Without the index's timestamp nothing below could
                        // see a file become tracked.
                        input.inUse = input.inUse ?? Self.unreadableIndexReason
                    } else if probe.gitIndexModificationDate(worktreePath: job.worktree) != gate?.index {
                        input.inUse = input.inUse ?? Self.indexChangedReason
                    } else if !tracked.isEmpty {
                        job.artifacts.removeAll { tracked.contains($0.relativePath) }
                        trackedArtifacts[job.worktree, default: []].formUnion(tracked)
                        input.artifactBytes = job.artifacts.reduce(Int64(0)) { $0 + $1.bytes }
                    }
                } else {
                    input.inUse = input.inUse ?? Self.unreadableTrackingReason
                }
                input.now = checkedAt
                inputs[job.worktree] = input
                let decision = WorktreeReclaimPolicy.decide(input)
                guard decision.reclaimArtifacts else {
                    kept.append(.init(worktreeName: job.name, reason: decision.reason))
                    if let status = statuses[job.worktree] {
                        publishStatus(status.worktree, report: status.report, input: input)
                    }
                    if mode == .automatic, let recheckAt = decision.recheckAt {
                        scheduleRecheck(repoPath: repoPath, worktreePath: job.worktree, at: recheckAt)
                    }
                    if mode == .automatic {
                        retryAfterReadFailure(repoPath: repoPath, worktreePath: job.worktree, decision: decision)
                    }
                    continue
                }
                readFailureRetries[job.worktree] = nil
                jobs.append(job)
                let worktreePath = job.worktree
                let indexAtGate = gate?.index
                let step = reclaimer.prepare(
                    artifactPaths: job.artifacts.map(\.path),
                    inWorktree: worktreePath,
                    now: checkedAt,
                    quickActivityCheck: true,
                    indexUnchanged: { probe.gitIndexModificationDate(worktreePath: worktreePath) == indexAtGate }
                )
                prepared += step.prepared
                outcome.merge(step.outcome)
            }
        }

        let reclaimer = self.reclaimer
        let renamedAside = prepared
        let sweeps = mode == .automatic || act ? leftovers : []
        outcome.merge(await WorktreeStorageWork.run { () -> WorktreeReclaimOutcome in
            var deleted = WorktreeReclaimOutcome()
            for sweep in sweeps {
                deleted.merge(reclaimer.sweepLeftovers(sweep.paths, inWorktree: sweep.worktree))
            }
            deleted.merge(reclaimer.finish(renamedAside))
            return deleted
        })

        // Decide again from fresh facts for what changed, so a skipped or
        // failed artifact stays reclaimable and automatic mode retries it.
        let changed = Array(Set(jobs.map(\.worktree) + sweeps.map(\.worktree)))
        if !changed.isEmpty {
            let later = clock()
            let fresh = await WorktreeStorageWork.run {
                changed.map { Self.fileFacts(worktreePath: $0, inspector: inspector, probe: probe, now: later) }
            }
            for var fact in fresh {
                let path = fact.report.worktreePath
                fact.report = fact.report.excludingArtifacts(at: trackedArtifacts[path] ?? [])
                guard var input = inputs[path], let status = statuses[path] else { continue }
                input.artifactBytes = fact.report.artifactBytes
                input.buildSignal = fact.buildSignal
                input.lastActivity = preservedActivity(
                    path,
                    observed: [input.lastActivity, fact.newestArtifactWrite, fact.indexModified].compactMap { $0 }.max()
                )
                input.now = later
                publishStatus(status.worktree, report: fact.report, input: input)
                let hasLeftovers = !fact.report.interruptedReclaims.isEmpty
                guard mode == .automatic, act, fact.report.artifactBytes > 0 || hasLeftovers else { continue }
                // A delete that failed after its rename leaves a leftover the
                // next pass sweeps; still-eligible artifacts get another try.
                let retry = WorktreeReclaimPolicy.decide(input)
                let retryLater = later.addingTimeInterval(WorktreeActivityProbe.recentWriteWindow)
                if let recheckAt = retry.recheckAt ?? (retry.reclaimArtifacts || hasLeftovers ? retryLater : nil) {
                    scheduleRecheck(repoPath: repoPath, worktreePath: path, at: recheckAt)
                }
            }
        }

        let touchedRoots = jobs.map(\.worktree) + sweeps.map(\.worktree)
        let reclaimedWorktrees = Set(outcome.reclaimed.compactMap { reclaimed in
            touchedRoots.first { WorktreePath.isStrictlyInside(reclaimed.path, root: $0) }
        })
        // One line per pass, so automatic work is observable in the log.
        AppLogger.audit(.gitWorktreeReclaim, category: "Git", fields: [
            "result": "pass",
            "mode": mode.rawValue,
            "acted": String(act),
            "worktrees": "\(worktrees.count)",
            "artifact_bytes": "\(facts.reduce(Int64(0)) { $0 + $1.report.artifactBytes })",
            "freed_bytes": "\(outcome.freedBytes)",
            "reclaimed_worktrees": "\(reclaimedWorktrees.count)",
            "kept": "\(kept.count)",
            "skipped": "\(outcome.skipped.count)",
            "failed": "\(outcome.failures.count)"
        ], level: act ? .info : .debug)
        return WorktreeReclaimSummary(
            mode: mode,
            finishedAt: clock(),
            worktreePaths: paths,
            outcome: outcome,
            kept: kept,
            reclaimedWorktreeCount: reclaimedWorktrees.count
        )
    }

    /// The newer of `observed` and the newest activity ever recorded for the
    /// worktree, recording `observed` when it is newer. Reclaiming deletes
    /// artifacts whose timestamps were activity signals; without this, a
    /// worktree could look idle for longer right after its cleanup. Entries
    /// for worktrees that no longer exist are dropped on each write.
    private func preservedActivity(_ path: String, observed: Date?) -> Date? {
        // Canonical keys: a task's path and git's can spell one checkout
        // differently.
        let key = WorktreePath.canonical(path)
        var recorded = defaults.dictionary(forKey: AppStorageKeys.worktreeObservedActivity) as? [String: Double] ?? [:]
        let previous = recorded[key].map { Date(timeIntervalSince1970: $0) }
        guard let observed, observed > (previous ?? .distantPast) else { return previous ?? observed }
        recorded[key] = observed.timeIntervalSince1970
        // By age, not reachability: a checkout on an unmounted volume keeps
        // its record. Past the retention, every threshold is long exceeded.
        let cutoff = clock().addingTimeInterval(-Self.activityRetention).timeIntervalSince1970
        recorded = recorded.filter { $0.value >= cutoff }
        defaults.set(recorded, forKey: AppStorageKeys.worktreeObservedActivity)
        return observed
    }

    /// The durable record alone, without updating it.
    private func recordedActivity(_ path: String) -> Date? {
        let recorded = defaults.dictionary(forKey: AppStorageKeys.worktreeObservedActivity) as? [String: Double]
        return recorded?[WorktreePath.canonical(path)].map { Date(timeIntervalSince1970: $0) }
    }

    /// How long a recorded activity is kept: well past the longest idle and
    /// removal thresholds, after which it can't change a decision.
    nonisolated static let activityRetention: TimeInterval = 30 * 24 * 60 * 60

    nonisolated static let unreadableWorkspaceStateReason = "Workspace state couldn't be read"
    nonisolated static let unreadableTrackingReason = "Tracked files couldn't be checked"
    nonisolated static let indexChangedReason = "Git index changed during the check"
    nonisolated static let unreadableIndexReason = "Git index couldn't be read"
    nonisolated static let nonTaskKeepReasons: Set<String> = [
        unreadableWorkspaceStateReason,
        unreadableTrackingReason,
        indexChangedReason,
        unreadableIndexReason
    ]

    /// Keeps caused by state that couldn't be read (or moved mid-check), not
    /// by a worktree being busy. Nothing else would bring the pass back.
    nonisolated static let readFailureReasons: Set<String> = [
        WorktreeTaskUsage.unreadableTaskStateReason,
        unreadableWorkspaceStateReason,
        unreadableTrackingReason,
        indexChangedReason,
        unreadableIndexReason
    ]
    static let maxReadFailureRetries = 3

    /// Automatic mode: after a keep a failed read caused, look again after
    /// the recent-write window, up to `maxReadFailureRetries` times in a row.
    /// Still fail closed: the retry decides from fresh reads. Any other
    /// answer resets the count.
    private func retryAfterReadFailure(repoPath: String, worktreePath: String, decision: WorktreeReclaimDecision) {
        guard Self.readFailureReasons.contains(decision.reason) else {
            readFailureRetries[worktreePath] = nil
            return
        }
        let failures = (readFailureRetries[worktreePath] ?? 0) + 1
        readFailureRetries[worktreePath] = failures
        let at = clock().addingTimeInterval(WorktreeActivityProbe.recentWriteWindow)
        guard failures <= Self.maxReadFailureRetries else { return }
        if let pending = pendingRecheckDates[worktreePath], pending <= at { return }
        scheduleRecheck(repoPath: repoPath, worktreePath: worktreePath, at: at)
    }

    /// Canonical protected paths, or nil when workspace state can't be read.
    private func currentWorkspaceRoots() -> Set<String>? {
        do {
            return Set(try workspaceRoots().map(WorktreePath.canonical))
        } catch {
            AppLogger.error("Worktree reclaim kept everything: workspace state unreadable: \(error.localizedDescription)", category: "Git")
            return nil
        }
    }

    /// A worktree is protected when a workspace's configured or selected path
    /// is anywhere inside it (not inside a worktree nested in it).
    /// Unreadable workspace state protects every worktree.
    private static func isProtected(_ path: String, roots: Set<String>?, otherWorktreePaths: [String]) -> Bool {
        guard let roots else { return true }
        let scope = WorktreeScope(path: path, otherWorktreePaths: otherWorktreePaths)
        return roots.contains { scope.contains(canonicalPath: $0) }
    }

    /// Task claims, or nil when the store can't be read.
    private func currentTaskHolds() -> [WorktreeTaskHold]? {
        do {
            return try taskHolds()
        } catch {
            AppLogger.error("Worktree reclaim kept everything: task state unreadable: \(error.localizedDescription)", category: "Git")
            return nil
        }
    }

    /// Unreadable task state holds every worktree.
    private func inUseReason(_ path: String, holds: [WorktreeTaskHold]?, otherWorktreePaths: [String]) -> String? {
        guard let holds else { return WorktreeTaskUsage.unreadableTaskStateReason }
        return WorktreeTaskUsage.inUseReason(forWorktreePath: path, holds: holds, otherWorktreePaths: otherWorktreePaths)
    }

    /// Publishes what the Reclaim button would do right now (manual mode).
    private func publishStatus(_ worktree: GitWorktreeInfo, report: WorktreeStorageReport, input: WorktreeReclaimInput) {
        var display = input
        display.mode = .manual
        statuses[worktree.path] = WorktreeStorageStatus(
            worktree: worktree,
            isWorkspaceRoot: input.isWorkspaceRoot,
            report: report,
            decision: WorktreeReclaimPolicy.decide(display),
            idle: input.lastActivity.map { input.now.timeIntervalSince($0) },
            // `inUse` also carries keeps that aren't about tasks.
            taskClaim: input.inUse.flatMap { Self.nonTaskKeepReasons.contains($0) ? nil : $0 },
            lastActivity: input.lastActivity
        )
    }

    /// Newest of: the tasks that worked there, the HEAD commit, the git index
    /// and a shallow scan of each artifact.
    private func lastActivity(
        of worktree: GitWorktreeInfo,
        facts: FileFacts,
        holds: [WorktreeTaskHold],
        otherWorktreePaths: [String]
    ) async -> Date? {
        var candidates = [
            WorktreeTaskUsage.latestActivity(forWorktreePath: worktree.path, holds: holds, otherWorktreePaths: otherWorktreePaths),
            facts.indexModified,
            facts.newestArtifactWrite
        ]
        if facts.report.exists, let head = worktree.head {
            candidates.append(await git.commitDate(of: head, at: worktree.path))
        }
        return candidates.compactMap { $0 }.max()
    }

    private nonisolated static func fileFacts(
        worktreePath: String,
        inspector: WorktreeStorageInspector,
        probe: WorktreeActivityProbe,
        now: Date
    ) -> FileFacts {
        let report = inspector.inspect(worktreePath: worktreePath, now: now)
        return FileFacts(
            report: report,
            buildSignal: report.artifacts.lazy
                .compactMap { probe.buildSignal(forArtifactAt: $0.path, rule: $0.rule, now: now) }
                .first,
            newestArtifactWrite: report.artifacts.compactMap { probe.artifactModificationDate($0.path) }.max(),
            indexModified: report.exists ? probe.gitIndexModificationDate(worktreePath: worktreePath) : nil
        )
    }
}
