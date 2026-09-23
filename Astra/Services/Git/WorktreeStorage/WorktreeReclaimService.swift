import Foundation
import ASTRACore

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
    @Published private(set) var lastManualReclaim: WorktreeReclaimSummary?
    @Published private(set) var lastAutomaticReclaim: WorktreeReclaimSummary?
    /// When each scheduled automatic recheck fires, by worktree path.
    private(set) var pendingRecheckDates: [String: Date] = [:]

    nonisolated static let measurementTTL: TimeInterval = 10 * 60
    nonisolated static let launchDelay: TimeInterval = 120
    /// Rechecks fire a little after the threshold so rounding never re-keeps.
    private static let recheckSlack: TimeInterval = 60

    private let git: WorktreeStorageGitReading
    private let defaults: UserDefaults
    private let inspector: WorktreeStorageInspector
    private let reclaimer: WorktreeReclaimer
    private let resolver: WorktreeMergeStateResolver
    private let clock: () -> Date
    private var taskHolds: @MainActor () -> [WorktreeTaskHold] = { [] }
    private var workspaceRoots: @MainActor () -> [String] = { [] }
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
    func attach(
        taskHolds: @escaping @MainActor () -> [WorktreeTaskHold],
        workspaceRoots: @escaping @MainActor () -> [String]
    ) {
        self.taskHolds = taskHolds
        self.workspaceRoots = workspaceRoots
    }

    /// Cancels the pending launch pass and every scheduled recheck.
    func cancelScheduledWork() {
        launchPass?.cancel()
        launchPass = nil
        rechecks.values.forEach { $0.cancel() }
        rechecks.removeAll()
        pendingRecheckDates.removeAll()
    }

    // MARK: - Triggers

    /// Launch trigger: after `delay`, finish interrupted reclaims and evaluate
    /// every workspace repository once.
    func scheduleLaunchPass(workspaces: [WorktreeStorageWorkspacePaths], delay: TimeInterval = launchDelay) {
        launchPass?.cancel()
        launchPass = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.runLaunchPass(workspaces: workspaces)
        }
    }

    func runLaunchPass(workspaces: [WorktreeStorageWorkspacePaths]) async {
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
            let worktrees = await git.listWorktrees(at: repository)
                .filter { seen.insert(WorktreePath.canonical($0.path)).inserted }
            guard !worktrees.isEmpty else { continue }
            _ = await evaluate(repoPath: repository, worktrees: worktrees, mode: .automatic)
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
        guard let path = change.workingPath,
              WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults) else { return }
        let reclaimAfter = WorktreeStorageSettings.thresholds(in: defaults).reclaimAfter
        // `git worktree list` works from any checkout of the repository.
        scheduleRecheck(repoPath: path, worktreePath: path, at: clock().addingTimeInterval(reclaimAfter))
    }

    // MARK: - Panel

    /// Called on every panel refresh: measures worktrees the cache hasn't
    /// seen and forgets removed ones. Cheap when nothing changed.
    func reconcile(repoPath: String, worktrees: [GitWorktreeInfo]) {
        guard !worktrees.isEmpty else { return }
        let paths = Set(worktrees.map(\.path))
        for removed in (repoWorktreePaths[repoPath] ?? []).subtracting(paths) {
            statuses[removed] = nil
        }
        repoWorktreePaths[repoPath] = paths
        let unmeasured = worktrees.filter { statuses[$0.path] == nil && !measuringPaths.contains($0.path) }
        guard !unmeasured.isEmpty else { return }
        Task { await self.refresh(repoPath: repoPath, worktrees: unmeasured, maxAge: nil) }
    }

    /// Re-measures worktrees whose entry is older than `maxAge`, or all of
    /// them when `maxAge` is nil. Changes nothing on disk.
    func refresh(repoPath: String, worktrees: [GitWorktreeInfo], maxAge: TimeInterval?) async {
        let now = clock()
        let stale = worktrees.filter { worktree in
            guard let maxAge, let status = statuses[worktree.path] else { return true }
            return now.timeIntervalSince(status.report.measuredAt) >= maxAge
        }
        guard !stale.isEmpty else { return }
        _ = await enqueue { await self.runPass(repoPath: repoPath, worktrees: stale, mode: .manual, act: false) }
    }

    /// The Reclaim button: manual mode on every worktree of the repository.
    @discardableResult
    func reclaimNow(repoPath: String, worktrees: [GitWorktreeInfo]) async -> WorktreeReclaimSummary {
        isReclaiming = true
        defer { isReclaiming = false }
        let summary = await evaluate(repoPath: repoPath, worktrees: worktrees, mode: .manual)
        lastManualReclaim = summary
        return summary
    }

    /// Bytes the Reclaim button would free across the given worktrees.
    func reclaimableBytes(in worktrees: [GitWorktreeInfo]) -> Int64 {
        worktrees.reduce(0) { $0 + (statuses[$1.path]?.reclaimableBytes ?? 0) }
    }

    // MARK: - Evaluation

    /// One serialized pass that may act: manual mode always reclaims what the
    /// policy allows; automatic mode only when the setting is on.
    func evaluate(repoPath: String, worktrees: [GitWorktreeInfo], mode: WorktreeReclaimMode) async -> WorktreeReclaimSummary {
        let act = mode == .manual || WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults)
        let summary = await enqueue {
            await self.runPass(repoPath: repoPath, worktrees: worktrees, mode: mode, act: act)
        }
        if mode == .automatic, summary.freedBytes > 0 {
            lastAutomaticReclaim = summary
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
            let worktrees = await self.git.listWorktrees(at: repoPath).filter { WorktreePath.same($0.path, worktreePath) }
            guard !worktrees.isEmpty else { return }
            _ = await self.evaluate(repoPath: repoPath, worktrees: worktrees, mode: .automatic)
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

    private func runPass(
        repoPath: String,
        worktrees: [GitWorktreeInfo],
        mode: WorktreeReclaimMode,
        act: Bool
    ) async -> WorktreeReclaimSummary {
        let now = clock()
        let paths = worktrees.map(\.path)
        measuringPaths.formUnion(paths)
        defer { measuringPaths.subtract(paths) }

        let inspector = self.inspector
        let probe = reclaimer.probe
        let facts = await WorktreeStorageWork.run {
            paths.map { Self.fileFacts(worktreePath: $0, inspector: inspector, probe: probe, now: now) }
        }

        let holds = taskHolds()
        let roots = Set(workspaceRoots().map(WorktreePath.canonical))
        let thresholds = WorktreeStorageSettings.thresholds(in: defaults)
        let defaultBranch = await git.getDefaultBaseBranch(at: repoPath, remote: nil)
        resolver.beginPass()

        var toReclaim: [(worktree: String, artifacts: [String])] = []
        var leftovers: [(worktree: String, paths: [String])] = []
        var kept: [WorktreeReclaimSummary.Kept] = []
        for (worktree, fact) in zip(worktrees, facts) {
            var input = WorktreeReclaimInput(
                worktree: worktree,
                isWorkspaceRoot: roots.contains(WorktreePath.canonical(worktree.path)),
                artifactBytes: fact.report.artifactBytes,
                lastActivity: await lastActivity(of: worktree, facts: fact, holds: holds),
                buildSignal: fact.buildSignal,
                inUse: WorktreeTaskUsage.inUseReason(forWorktreePath: worktree.path, holds: holds),
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

            let decision = WorktreeReclaimPolicy.decide(input)
            var display = input
            display.mode = .manual
            statuses[worktree.path] = WorktreeStorageStatus(
                report: fact.report,
                decision: WorktreeReclaimPolicy.decide(display),
                idle: input.lastActivity.map { now.timeIntervalSince($0) }
            )
            if !fact.report.interruptedReclaims.isEmpty {
                leftovers.append((worktree.path, fact.report.interruptedReclaims))
            }
            if act, decision.reclaimArtifacts {
                toReclaim.append((worktree.path, fact.report.artifacts.map(\.path)))
            } else if fact.report.artifactBytes > 0 {
                kept.append(.init(worktreeName: worktree.displayName, reason: decision.reason))
            }
            if mode == .automatic, act, let recheckAt = decision.recheckAt {
                scheduleRecheck(repoPath: repoPath, worktreePath: worktree.path, at: recheckAt)
            }
        }

        let reclaimer = self.reclaimer
        let jobs = toReclaim
        let sweeps = mode == .automatic || act ? leftovers : []
        let outcome = await WorktreeStorageWork.run { () -> WorktreeReclaimOutcome in
            var outcome = WorktreeReclaimOutcome()
            for sweep in sweeps {
                outcome.merge(reclaimer.sweepLeftovers(sweep.paths, inWorktree: sweep.worktree))
            }
            for job in jobs {
                outcome.merge(reclaimer.reclaim(artifactPaths: job.artifacts, inWorktree: job.worktree, now: now))
            }
            return outcome
        }

        // Re-measure what changed so the panel shows the freed space.
        let changed = Set(jobs.map(\.worktree) + sweeps.map(\.worktree))
        if !changed.isEmpty {
            let refreshed = await WorktreeStorageWork.run { changed.map { inspector.inspect(worktreePath: $0, now: now) } }
            for report in refreshed {
                guard let status = statuses[report.worktreePath] else { continue }
                statuses[report.worktreePath] = WorktreeStorageStatus(
                    report: report,
                    decision: WorktreeReclaimDecision(
                        reclaimArtifacts: false,
                        suggestRemoval: status.decision.suggestRemoval,
                        reason: report.artifactBytes > 0 ? status.decision.reason : "No build artifacts",
                        recheckAt: nil
                    ),
                    idle: status.idle
                )
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
            outcome: outcome,
            kept: kept,
            reclaimedWorktreeCount: reclaimedWorktrees.count
        )
    }

    /// Newest of: the tasks that worked there, the HEAD commit, the git index
    /// and a shallow scan of each artifact.
    private func lastActivity(of worktree: GitWorktreeInfo, facts: FileFacts, holds: [WorktreeTaskHold]) async -> Date? {
        var candidates = [
            WorktreeTaskUsage.latestActivity(forWorktreePath: worktree.path, holds: holds),
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
