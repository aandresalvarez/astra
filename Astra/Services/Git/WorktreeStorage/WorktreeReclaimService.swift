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
    private static let maxLaunchReadAttempts = 3
    /// Repositories an automatic pass has covered (or is about to), by
    /// canonical path.
    private var automaticallyEvaluatedRepositories: Set<String> = []
    private var repositoryPasses: [String: Task<Void, Never>] = [:]
    /// Worktrees measured so far; lets tests prove work isn't repeated.
    private(set) var measuredWorktreeCount = 0
    private var repoWorktreePaths: [String: Set<String>] = [:]
    private var passChain: Task<Void, Never>?
    private var rechecks: [String: Task<Void, Never>] = [:]
    private var launchPass: Task<Void, Never>?
    private var terminalObserver: NSObjectProtocol?

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
    func scheduleLaunchPass(delay: TimeInterval = launchDelay) {
        launchPass?.cancel()
        launchPass = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            do {
                let current = try self.workspaces()
                self.failedLaunchReads = 0
                await self.runLaunchPass(workspaces: current)
                // A settings change may have replaced this task meanwhile.
                if !Task.isCancelled { self.launchPass = nil }
            } catch {
                if !Task.isCancelled { self.launchPass = nil }
                self.failedLaunchReads += 1
                AppLogger.error("Worktree launch pass deferred: workspace state unreadable (attempt \(self.failedLaunchReads)): \(error.localizedDescription)", category: "Git")
                if self.failedLaunchReads < Self.maxLaunchReadAttempts {
                    self.scheduleLaunchPass(delay: Self.launchDelay)
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

    func runLaunchPass(workspaces: [WorktreeStorageWorkspacePaths]) async {
        hasRunLaunchPass = true
        var repositories: [String] = []
        for workspace in workspaces {
            let scanned = await git.scanForGitRepositories(
                primaryPath: workspace.primaryPath,
                additionalPaths: workspace.additionalPaths
            )
            for repository in scanned.map(\.path) where !repositories.contains(where: { WorktreePath.same($0, repository) }) {
                repositories.append(repository)
            }
        }
        var seen = Set<String>()
        for repository in repositories {
            // Two configured paths can be checkouts of one repository; each
            // worktree is evaluated once.
            let listed = await git.listWorktrees(at: repository)
            // An empty list means git failed: leave the repository uncovered so
            // the panel's next look schedules another try.
            guard !listed.isEmpty else { continue }
            automaticallyEvaluatedRepositories.insert(WorktreePath.canonical(repository))
            let worktrees = listed.filter { seen.insert(WorktreePath.canonical($0.path)).inserted }
            guard !worktrees.isEmpty else { continue }
            _ = await evaluate(repoPath: repository, worktrees: worktrees, mode: .automatic)
        }
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
    }

    func stopObservingTaskCompletion() {
        if let terminalObserver { NotificationCenter.default.removeObserver(terminalObserver) }
        terminalObserver = nil
    }

    func handleTaskReachedTerminalState(_ change: TaskTerminalStateChange) {
        guard WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults) else { return }
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
        for root in roots {
            scheduleRecheck(repoPath: root, worktreePath: root, at: clock().addingTimeInterval(reclaimAfter))
        }
    }

    // MARK: - Panel

    /// Called on every panel refresh: measures worktrees the cache hasn't
    /// seen, re-evaluates any whose HEAD, branch, lock or prune state moved,
    /// and forgets removed ones. Cheap when nothing changed.
    func reconcile(repoPath: String, worktrees: [GitWorktreeInfo]) {
        guard !worktrees.isEmpty else { return }
        let paths = Set(worktrees.map(\.path))
        for removed in (repoWorktreePaths[repoPath] ?? []).subtracting(paths) {
            statuses[removed] = nil
        }
        repoWorktreePaths[repoPath] = paths
        scheduleFirstAutomaticPassIfNeeded(repoPath: repoPath)
        let roots = currentWorkspaceRoots()
        var stale: [GitWorktreeInfo] = []
        for worktree in worktrees where !measuringPaths.contains(worktree.path) {
            guard let status = statuses[worktree.path] else {
                stale.append(worktree)
                continue
            }
            let isWorkspaceRoot = Self.isProtected(worktree.path, roots: roots, otherWorktreePaths: Array(paths))
            guard status.worktree != worktree || status.isWorkspaceRoot != isWorkspaceRoot else { continue }
            // Withdraw a "Merged · Remove" suggestion at once: it described a
            // HEAD, or a selection, that has changed. The refresh decides afresh.
            var decision = status.decision
            decision.suggestRemoval = false
            statuses[worktree.path] = WorktreeStorageStatus(
                worktree: worktree,
                isWorkspaceRoot: isWorkspaceRoot,
                report: status.report,
                decision: decision,
                idle: status.idle
            )
            stale.append(worktree)
        }
        guard !stale.isEmpty else { return }
        Task { await self.refresh(repoPath: repoPath, worktrees: stale, maxAge: nil, context: worktrees) }
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

    private func scheduleRecheck(repoPath: String, worktreePath: String, at date: Date) {
        rechecks[worktreePath]?.cancel()
        pendingRecheckDates[worktreePath] = date
        let delay = min(max(0, date.timeIntervalSince(clock())) + Self.recheckSlack, 8 * 24 * 60 * 60)
        rechecks[worktreePath] = Task { @MainActor [weak self] in
            // The default continuous clock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.rechecks[worktreePath] = nil
            self.pendingRecheckDates[worktreePath] = nil
            let all = await self.git.listWorktrees(at: repoPath)
            let worktrees = all.filter { WorktreePath.same($0.path, worktreePath) }
            guard !worktrees.isEmpty else { return }
            _ = await self.evaluate(repoPath: repoPath, worktrees: worktrees, mode: .automatic, context: all)
        }
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
        let report: WorktreeStorageReport
        let buildSignal: WorktreeBuildSignal?
        let newestArtifactWrite: Date?
        let indexModified: Date?
    }

    private struct ReclaimJob: Sendable {
        let worktree: String
        let name: String
        let artifacts: [WorktreeArtifactMeasurement]
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
        let facts = await WorktreeStorageWork.run {
            paths.map { Self.fileFacts(worktreePath: $0, inspector: inspector, probe: probe, now: now) }
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
            let checkedAt = clock()
            let current = currentTaskHolds()
            let currentRoots = mode == .automatic ? currentWorkspaceRoots() : []
            let currentThresholds = WorktreeStorageSettings.thresholds(in: defaults)
            let stillEnabled = mode == .manual || WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults)
            for job in candidates {
                guard var input = inputs[job.worktree] else { continue }
                guard stillEnabled else {
                    kept.append(.init(worktreeName: job.name, reason: "Automatic reclaim turned off"))
                    continue
                }
                if let reason = inUseReason(job.worktree, holds: current, otherWorktreePaths: allPaths) {
                    input.inUse = reason
                }
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
                    continue
                }
                jobs.append(job)
                let step = reclaimer.prepare(
                    artifactPaths: job.artifacts.map(\.path),
                    inWorktree: job.worktree,
                    now: checkedAt,
                    quickActivityCheck: true
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
            for fact in fresh {
                let path = fact.report.worktreePath
                guard var input = inputs[path], let status = statuses[path] else { continue }
                input.artifactBytes = fact.report.artifactBytes
                input.buildSignal = fact.buildSignal
                input.lastActivity = preservedActivity(
                    path,
                    observed: [input.lastActivity, fact.newestArtifactWrite, fact.indexModified].compactMap { $0 }.max()
                )
                input.now = later
                publishStatus(status.worktree, report: fact.report, input: input)
                guard mode == .automatic, act, fact.report.artifactBytes > 0 else { continue }
                let retry = WorktreeReclaimPolicy.decide(input)
                if let recheckAt = retry.recheckAt ?? (retry.reclaimArtifacts
                    ? later.addingTimeInterval(WorktreeActivityProbe.recentWriteWindow) : nil) {
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
        var recorded = defaults.dictionary(forKey: AppStorageKeys.worktreeObservedActivity) as? [String: Double] ?? [:]
        let previous = recorded[path].map { Date(timeIntervalSince1970: $0) }
        guard let observed, observed > (previous ?? .distantPast) else { return previous ?? observed }
        recorded[path] = observed.timeIntervalSince1970
        recorded = recorded.filter { WorktreeFileSystem.isRealDirectory($0.key) }
        defaults.set(recorded, forKey: AppStorageKeys.worktreeObservedActivity)
        return observed
    }

    nonisolated static let unreadableWorkspaceStateReason = "Workspace state couldn't be read"

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
            idle: input.lastActivity.map { input.now.timeIntervalSince($0) }
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
