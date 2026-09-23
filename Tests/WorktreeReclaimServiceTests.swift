import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// The orchestration layer: triggers, settings, the derived cache, and the
/// guarantees that span a whole pass. Git is scripted; the file system is real.
@Suite("Worktree Reclaim Service")
@MainActor
struct WorktreeReclaimServiceTests {
    nonisolated private static let hour: TimeInterval = 60 * 60
    nonisolated private static let day: TimeInterval = 24 * hour

    /// A primary checkout and one linked worktree, both with backdated
    /// artifacts, served by a scripted git.
    @MainActor
    private struct Setup {
        let fixture: WorktreeStorageFixture
        let git: StubWorktreeGit
        let defaults: InMemoryDefaults
        let service: WorktreeReclaimService
        let primary: GitWorktreeInfo
        let linked: GitWorktreeInfo

        var primaryBuild: String { primary.path + "/.build" }
        var linkedBuild: String { linked.path + "/.build" }
        var worktrees: [GitWorktreeInfo] { [primary, linked] }

        func idle(_ worktree: GitWorktreeInfo, for seconds: TimeInterval) {
            git.commitDates[worktree.head ?? ""] = Date().addingTimeInterval(-seconds)
        }
    }

    private func makeSetup(idle: TimeInterval = 3 * day) throws -> Setup {
        let fixture = try WorktreeStorageFixture("service")
        let primaryPath = try fixture.directory("app")
        let linkedPath = try fixture.directory("worktrees/feature")
        try fixture.swiftPackage(at: "app", buildBytes: 200_000)
        try fixture.swiftPackage(at: "worktrees/feature", buildBytes: 300_000)
        WorktreeStorageFixture.backdate(primaryPath, by: idle)
        WorktreeStorageFixture.backdate(linkedPath, by: idle)

        let primary = GitWorktreeInfo(path: primaryPath, branch: "main", head: "p1", isPrimary: true,
                                      isDetached: false, isLocked: false, isPrunable: false)
        let linked = GitWorktreeInfo(path: linkedPath, branch: "feature", head: "f1", isPrimary: false,
                                     isDetached: false, isLocked: false, isPrunable: false)
        let git = StubWorktreeGit()
        git.worktrees = [primary, linked]
        git.repositories = [GitRepositoryInfo(name: "app", path: primaryPath)]
        let defaults = InMemoryDefaults()
        let probe = WorktreeActivityProbe(
            temporaryDirectory: URL(fileURLWithPath: try fixture.directory("tmp"), isDirectory: true),
            processName: { _ in nil }
        )
        let setup = Setup(
            fixture: fixture,
            git: git,
            defaults: defaults,
            service: WorktreeReclaimService(git: git, defaults: defaults, probe: probe),
            primary: primary,
            linked: linked
        )
        setup.idle(primary, for: idle)
        setup.idle(linked, for: idle)
        return setup
    }

    private func finish(_ setup: Setup) {
        setup.service.cancelScheduledWork()
        setup.service.stopObservingTaskCompletion()
        setup.fixture.cleanUp()
    }

    @Test("Settings default to automatic reclaim after 48 hours")
    func settingsDefaults() {
        let defaults = InMemoryDefaults()
        #expect(WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults))
        #expect(WorktreeStorageSettings.idleThresholdHours(in: defaults) == 48)

        WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: defaults)
        WorktreeStorageSettings.setIdleThresholdHours(72, in: defaults)
        #expect(!WorktreeStorageSettings.isAutomaticReclaimEnabled(in: defaults))
        #expect(WorktreeStorageSettings.idleThresholdHours(in: defaults) == 72)

        WorktreeStorageSettings.setIdleThresholdHours(5, in: defaults)
        #expect(WorktreeStorageSettings.idleThresholdHours(in: defaults) == 48, "unknown choices fall back")
    }

    @Test("An automatic pass reclaims an idle linked worktree, keeps the primary, and says so")
    func automaticPassReclaimsIdleWorktree() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }

        let summary = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(!FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(FileManager.default.fileExists(atPath: setup.primaryBuild))
        #expect(summary.freedBytes >= 300_000)
        #expect(summary.reclaimedWorktreeCount == 1)
        #expect(summary.kept == [.init(worktreeName: "main", reason: "Primary checkout")])
        #expect(setup.service.lastAutomaticReclaim == summary)
        #expect(setup.service.statuses[setup.linked.path]?.report.artifactBytes == 0)
    }

    @Test("Automatic passes change nothing when the setting is off")
    func automaticPassRespectsSetting() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: setup.defaults)

        let summary = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.freedBytes == 0)
        #expect(setup.service.lastAutomaticReclaim == nil)
        #expect(setup.service.pendingRecheckDates.isEmpty)
    }

    @Test("A recently active worktree is kept and rechecked when it can be idle enough")
    func recentlyActiveIsRechecked() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let lastCommit = Date().addingTimeInterval(-Self.hour)
        setup.git.commitDates["f1"] = lastCommit

        _ = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        let recheck = try #require(setup.service.pendingRecheckDates[setup.linked.path])
        #expect(abs(recheck.timeIntervalSince(lastCommit.addingTimeInterval(48 * Self.hour))) < 1)
    }

    @Test("A worktree held by a task is kept, even by the Reclaim button")
    func heldWorktreeIsKept() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        setup.service.attach(
            taskHolds: {
                [WorktreeTaskHold(taskTitle: "Fix login", rootPath: setup.linked.path, isTerminal: false,
                                  hasActiveTurnRequest: false, updatedAt: Date().addingTimeInterval(-3 * Self.day))]
            },
            workspaceRoots: { [] }
        )

        let summary = await setup.service.reclaimNow(repoPath: setup.primary.path, worktrees: setup.worktrees)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.kept.contains(.init(worktreeName: "feature", reason: "In use by task “Fix login”")))
        #expect(setup.service.lastManualReclaim == summary)
    }

    @Test("The Reclaim button includes the primary checkout")
    func manualReclaimIncludesPrimary() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }

        let summary = await setup.service.reclaimNow(repoPath: setup.primary.path, worktrees: setup.worktrees)

        #expect(!FileManager.default.fileExists(atPath: setup.primaryBuild))
        #expect(!FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.reclaimedWorktreeCount == 2)
        #expect(setup.service.reclaimableBytes(in: setup.worktrees) == 0)
    }

    @Test("Automatic mode keeps a workspace root that is a linked worktree")
    func workspaceRootIsKept() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        setup.service.attach(taskHolds: { [] }, workspaceRoots: { [setup.linked.path] })

        _ = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
    }

    @Test("A finished task schedules a recheck once its worktree can be idle enough")
    func terminalTaskSchedulesRecheck() throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let change = TaskTerminalStateChange(taskID: UUID(), status: .completed, workingPath: setup.linked.path)

        setup.service.handleTaskReachedTerminalState(change)

        let recheck = try #require(setup.service.pendingRecheckDates[setup.linked.path])
        #expect(abs(recheck.timeIntervalSinceNow - 48 * Self.hour) < 60)
    }

    @Test("A finished task schedules nothing when automatic reclaim is off")
    func terminalTaskRespectsSetting() throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: setup.defaults)

        setup.service.handleTaskReachedTerminalState(
            TaskTerminalStateChange(taskID: UUID(), status: .failed, workingPath: setup.linked.path)
        )

        #expect(setup.service.pendingRecheckDates.isEmpty)
    }

    @Test("The service hears terminal transitions through the notification")
    func terminalNotificationReachesService() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        setup.service.startObservingTaskCompletion()

        NotificationCenter.default.post(
            name: .taskDidReachTerminalState,
            object: TaskTerminalStateChange(taskID: UUID(), status: .cancelled, workingPath: setup.linked.path)
        )
        for _ in 0..<50 where setup.service.pendingRecheckDates[setup.linked.path] == nil {
            await Task.yield()
        }

        #expect(setup.service.pendingRecheckDates[setup.linked.path] != nil)
    }

    @Test("A terminal status change posts the task's pinned checkout")
    func stateMachinePostsTerminalChange() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Repo", primaryPath: "/repos/app")
        context.insert(workspace)
        let task = AgentTask(title: "Fix login", goal: "Fix it", workspace: workspace)
        task.executionRootPath = "/worktrees/app/feature"
        context.insert(task)

        let recorder = TerminalChangeRecorder(taskID: task.id)
        let observer = NotificationCenter.default.addObserver(
            forName: .taskDidReachTerminalState, object: nil, queue: nil
        ) { notification in
            recorder.record(notification.object as? TaskTerminalStateChange)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = TaskStateMachine.cancelFromLifecycle(task, modelContext: context)

        #expect(result.changed)
        #expect(recorder.changes == [TaskTerminalStateChange(taskID: task.id, status: .cancelled, workingPath: "/worktrees/app/feature")])
        // A repeated terminal write is not a new event.
        _ = TaskStateMachine.cancelFromLifecycle(task, modelContext: context)
        #expect(recorder.changes.count == 1)
        _ = container
    }

    @Test("Reconcile measures new worktrees, forgets removed ones, and never evicts on an empty list")
    func reconcileKeepsCacheHonest() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(setup.service.statuses.count == 2)
        // The panel's refresh records the full list first; both are measured.
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: setup.worktrees)

        setup.service.reconcile(repoPath: setup.primary.path, worktrees: [])
        #expect(setup.service.statuses.count == 2, "a failed git worktree list must not wipe the cache")

        setup.service.reconcile(repoPath: setup.primary.path, worktrees: [setup.primary])
        #expect(setup.service.statuses[setup.linked.path] == nil)
        #expect(setup.service.statuses[setup.primary.path] != nil)
    }

    @Test("Measurements younger than the TTL are kept")
    func refreshHonorsTTL() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        let first = try #require(setup.service.statuses[setup.linked.path]?.report.measuredAt)

        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: 600)
        #expect(setup.service.statuses[setup.linked.path]?.report.measuredAt == first)

        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(try #require(setup.service.statuses[setup.linked.path]?.report.measuredAt) > first)
    }

    @Test("A panel refresh deletes nothing")
    func refreshIsReadOnly() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(FileManager.default.fileExists(atPath: setup.primaryBuild))
        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(setup.service.reclaimableBytes(in: setup.worktrees) >= 500_000)
    }

    @Test("The launch pass finishes interrupted reclaims even when automatic reclaim is off")
    func launchPassSweepsLeftovers() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: setup.defaults)
        let leftover = "\(setup.linked.path)/.build\(WorktreeFileSystem.reclaimingMarker)\(UUID().uuidString)"
        try FileManager.default.moveItem(atPath: setup.linkedBuild, toPath: leftover)

        await setup.service.runLaunchPass(workspaces: [
            WorktreeStorageWorkspacePaths(primaryPath: setup.primary.path, additionalPaths: [])
        ])

        #expect(!FileManager.default.fileExists(atPath: leftover))
        #expect(FileManager.default.fileExists(atPath: setup.primaryBuild))
    }

    @Test("A merged, clean, stale worktree is suggested for removal; a dirty one isn't")
    func removalSuggestion() async throws {
        let setup = try makeSetup(idle: 9 * Self.day)
        defer { finish(setup) }
        setup.git.ancestry["f1>origin/main"] = .ancestor

        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(setup.service.statuses[setup.linked.path]?.decision.suggestRemoval == true)
        #expect(setup.service.statuses[setup.primary.path]?.decision.suggestRemoval == false)

        setup.git.dirtyPaths = [setup.linked.path]
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(setup.service.statuses[setup.linked.path]?.decision.suggestRemoval == false)
    }

    @Test("No worktree is ever removed, whatever the pass decides")
    func neverRemovesWorktrees() async throws {
        let setup = try makeSetup(idle: 30 * Self.day)
        defer { finish(setup) }
        setup.git.ancestry["f1>origin/main"] = .ancestor

        _ = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)
        _ = await setup.service.reclaimNow(repoPath: setup.primary.path, worktrees: setup.worktrees)

        #expect(FileManager.default.fileExists(atPath: setup.linked.path + "/Package.swift"))
        #expect(FileManager.default.fileExists(atPath: setup.primary.path + "/Package.swift"))
    }
}

/// Collects terminal changes for one task. Notifications from other suites'
/// tasks share the default center, so everything else is ignored.
private final class TerminalChangeRecorder: @unchecked Sendable {
    private let taskID: UUID
    private let lock = NSLock()
    private var recorded: [TaskTerminalStateChange] = []

    init(taskID: UUID) {
        self.taskID = taskID
    }

    var changes: [TaskTerminalStateChange] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ change: TaskTerminalStateChange?) {
        guard let change, change.taskID == taskID else { return }
        lock.lock(); defer { lock.unlock() }
        recorded.append(change)
    }
}
