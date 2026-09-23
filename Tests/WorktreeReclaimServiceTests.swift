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
        #expect(setup.service.lastReclaim(.automatic, among: setup.worktrees) == summary)
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
        #expect(setup.service.lastReclaim(.automatic, among: setup.worktrees) == nil)
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
        #expect(setup.service.lastReclaim(.manual, among: setup.worktrees) == summary)
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

    @Test("A task that starts using a worktree mid-pass keeps its artifacts")
    func taskStartingMidPassIsKept() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let calls = CallCounter()
        let linkedPath = setup.linked.path
        setup.service.attach(
            taskHolds: {
                // The first read is the pass's snapshot; the second is the
                // last look before deleting.
                calls.increment() == 1 ? [] : [WorktreeTaskHold(
                    taskTitle: "Late start", rootPath: linkedPath, isTerminal: false,
                    hasActiveTurnRequest: false, updatedAt: Date()
                )]
            },
            workspaceRoots: { [] }
        )

        let summary = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.kept.contains(.init(worktreeName: "feature", reason: "In use by task “Late start”")))
        #expect(setup.service.statuses[setup.linked.path]?.decision.reason == "In use by task “Late start”")
    }

    @Test("An artifact skipped mid-pass stays measured and is retried")
    func skippedArtifactIsRetried() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let lockFile = SwiftPMWorkspaceLock.lockFileURL(
            forScratchPath: setup.linkedBuild,
            temporaryDirectory: URL(fileURLWithPath: setup.fixture.path("tmp"), isDirectory: true)
        )
        let lockBox = LockBox()
        let calls = CallCounter()
        setup.service.attach(
            taskHolds: {
                // A build takes SwiftPM's lock after the policy said "reclaim".
                if calls.increment() == 2 { lockBox.lock = SwiftPMWorkspaceLock.tryAcquire(lockFile: lockFile) }
                return []
            },
            workspaceRoots: { [] }
        )
        defer { lockBox.lock?.release() }

        _ = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(lockBox.lock != nil)
        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        let status = try #require(setup.service.statuses[setup.linked.path])
        #expect(status.report.artifactBytes > 0)
        #expect(status.decision.reason == "Build in progress (SwiftPM holds its lock)")
        let retry = try #require(setup.service.pendingRecheckDates[setup.linked.path])
        #expect(abs(retry.timeIntervalSinceNow - WorktreeActivityProbe.recentWriteWindow) < 60)
    }

    @Test("A HEAD change withdraws a removal suggestion at once")
    func headChangeWithdrawsSuggestion() async throws {
        let setup = try makeSetup(idle: 9 * Self.day)
        defer { finish(setup) }
        setup.git.ancestry["f1>origin/main"] = .ancestor
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: setup.worktrees)
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(setup.service.statuses[setup.linked.path]?.decision.suggestRemoval == true)

        let moved = GitWorktreeInfo(path: setup.linked.path, branch: "feature", head: "f2", isPrimary: false,
                                    isDetached: false, isLocked: false, isPrunable: false)
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: [setup.primary, moved])

        #expect(setup.service.statuses[setup.linked.path]?.decision.suggestRemoval == false)
        #expect(setup.service.statuses[setup.linked.path]?.worktree == moved)
    }

    @Test("Unreadable task state keeps every worktree, even for the Reclaim button")
    func unreadableTaskStateFailsClosed() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        setup.service.attach(taskHolds: { throw CocoaError(.coderReadCorrupt) }, workspaceRoots: { [] })

        let summary = await setup.service.reclaimNow(repoPath: setup.primary.path, worktrees: setup.worktrees)

        #expect(summary.freedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: setup.primaryBuild))
        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.kept.allSatisfy { $0.reason == WorktreeTaskUsage.unreadableTaskStateReason })
        #expect(summary.kept.count == 2)
    }

    @Test("A task that ran in a subfolder schedules the recheck for its checkout")
    func subfolderTaskRechecksCheckout() throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        try "gitdir: /repos/app/.git/worktrees/feature\n".write(toFile: setup.linked.path + "/.git", atomically: true, encoding: .utf8)
        let subfolder = try setup.fixture.directory("worktrees/feature/packages/api")

        setup.service.handleTaskReachedTerminalState(
            TaskTerminalStateChange(taskID: UUID(), status: .completed, workingPath: subfolder)
        )

        #expect(setup.service.pendingRecheckDates[setup.linked.path] != nil)
        #expect(setup.service.pendingRecheckDates[subfolder] == nil)
    }

    @Test("Selecting a worktree withdraws its removal suggestion at once")
    func selectionWithdrawsSuggestion() async throws {
        let setup = try makeSetup(idle: 9 * Self.day)
        defer { finish(setup) }
        setup.git.ancestry["f1>origin/main"] = .ancestor
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: setup.worktrees)
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        #expect(setup.service.statuses[setup.linked.path]?.decision.suggestRemoval == true)

        let linkedPath = setup.linked.path
        setup.service.attach(taskHolds: { [] }, workspaceRoots: { [linkedPath] })
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: setup.worktrees)

        #expect(setup.service.statuses[setup.linked.path]?.decision.suggestRemoval == false)
        #expect(setup.service.statuses[setup.linked.path]?.isWorkspaceRoot == true)
    }

    @Test("Reclaiming the newest activity signal doesn't make a worktree look older")
    func reclaimKeepsObservedActivity() async throws {
        // Artifacts touched 3 days ago, HEAD from 9 days ago: automatic mode
        // reclaims, and the removal suggestion must not appear afterwards.
        let setup = try makeSetup(idle: 3 * Self.day)
        defer { finish(setup) }
        setup.git.commitDates["f1"] = Date().addingTimeInterval(-9 * Self.day)
        setup.git.ancestry["f1>origin/main"] = .ancestor

        _ = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)
        #expect(!FileManager.default.fileExists(atPath: setup.linkedBuild))

        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: nil)
        let status = try #require(setup.service.statuses[setup.linked.path])
        #expect(status.decision.suggestRemoval == false)
        #expect(abs((status.idle ?? 0) - 3 * Self.day) < 60 * 60)
    }

    @Test("A worktree selected in a workspace mid-pass keeps its artifacts")
    func selectedMidPassIsKept() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let calls = CallCounter()
        let linkedPath = setup.linked.path
        setup.service.attach(
            taskHolds: { [] },
            // First read: the pass's snapshot. Second: the last look before deleting.
            workspaceRoots: { calls.increment() == 1 ? [] : [linkedPath] }
        )

        let summary = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.kept.contains(.init(worktreeName: "feature", reason: "Workspace checkout")))
    }

    @Test("Unreadable workspace state keeps everything in automatic mode")
    func unreadableWorkspaceStateFailsClosed() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        setup.service.attach(taskHolds: { [] }, workspaceRoots: { throw CocoaError(.coderReadCorrupt) })

        let summary = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(summary.freedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.kept.contains(.init(worktreeName: "feature", reason: WorktreeReclaimService.unreadableWorkspaceStateReason)))
    }

    @Test("Turning automatic reclaim off stops a pass that is already running")
    func turningOffMidPassStopsDeletion() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let calls = CallCounter()
        let defaults = setup.defaults
        setup.service.attach(
            taskHolds: {
                if calls.increment() == 2 { WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: defaults) }
                return []
            },
            workspaceRoots: { [] }
        )

        let summary = await setup.service.evaluate(repoPath: setup.primary.path, worktrees: setup.worktrees, mode: .automatic)

        #expect(FileManager.default.fileExists(atPath: setup.linkedBuild))
        #expect(summary.kept.contains(.init(worktreeName: "feature", reason: "Automatic reclaim turned off")))
    }

    @Test("A settings change schedules a fresh pass when on, and cancels work when off")
    func settingsChangeReschedules() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: setup.defaults)
        await setup.service.runLaunchPass(workspaces: [
            WorktreeStorageWorkspacePaths(primaryPath: setup.primary.path, additionalPaths: [])
        ])
        #expect(!setup.service.hasScheduledLaunchPass)

        WorktreeStorageSettings.setAutomaticReclaimEnabled(true, in: setup.defaults)
        setup.service.automaticReclaimSettingsChanged()
        #expect(setup.service.hasScheduledLaunchPass)

        WorktreeStorageSettings.setAutomaticReclaimEnabled(false, in: setup.defaults)
        setup.service.automaticReclaimSettingsChanged()
        #expect(!setup.service.hasScheduledLaunchPass)
        #expect(setup.service.pendingRecheckDates.isEmpty)
    }

    @Test("Opening the sheet while a measurement is queued doesn't measure twice")
    func measurementsAreNotRepeated() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }

        // The panel's refresh queues a measurement of new worktrees, and the
        // sheet opening asks again before that one has run.
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: setup.worktrees)
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: 600)
        await setup.service.refresh(repoPath: setup.primary.path, worktrees: setup.worktrees, maxAge: 600)

        #expect(setup.service.measuredWorktreeCount == 2)
    }

    @Test("A repository's sheet shows only its own reclaim results")
    func summariesStayWithTheirRepository() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        _ = await setup.service.reclaimNow(repoPath: setup.primary.path, worktrees: setup.worktrees)

        let elsewhere = GitWorktreeInfo(path: "/repos/other", branch: "main", head: "o1", isPrimary: true,
                                        isDetached: false, isLocked: false, isPrunable: false)
        #expect(setup.service.lastReclaim(.manual, among: setup.worktrees) != nil)
        #expect(setup.service.lastReclaim(.manual, among: [elsewhere]) == nil)
    }

    @Test("A repository first seen after the launch pass gets its own automatic pass")
    func newRepositoryGetsAutomaticPass() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let other = try setup.fixture.directory("other")
        let otherWorktree = GitWorktreeInfo(path: other, branch: "main", head: "o1", isPrimary: true,
                                            isDetached: false, isLocked: false, isPrunable: false)

        setup.service.reconcile(repoPath: other, worktrees: [otherWorktree])
        #expect(!setup.service.hasScheduledRepositoryPass(other), "the launch pass covers it")

        await setup.service.runLaunchPass(workspaces: [
            WorktreeStorageWorkspacePaths(primaryPath: setup.primary.path, additionalPaths: [])
        ])
        setup.service.reconcile(repoPath: setup.primary.path, worktrees: setup.worktrees)
        #expect(!setup.service.hasScheduledRepositoryPass(setup.primary.path), "already covered")

        setup.service.reconcile(repoPath: other, worktrees: [otherWorktree])
        #expect(setup.service.hasScheduledRepositoryPass(other))
    }

    @Test("The launch pass reads the workspace list when it fires")
    func launchPassReadsCurrentWorkspaces() async throws {
        let setup = try makeSetup()
        defer { finish(setup) }
        let reads = CallCounter()
        let primaryPath = setup.primary.path
        setup.service.attach(
            taskHolds: { [] },
            workspaceRoots: { [] },
            workspaces: {
                _ = reads.increment()
                return [WorktreeStorageWorkspacePaths(primaryPath: primaryPath, additionalPaths: [])]
            }
        )

        setup.service.scheduleLaunchPass(delay: 0)
        #expect(reads.increment() == 1, "nothing is read until the pass fires")
        // The pass hops to a file-system queue, so yielding alone can't drain it.
        for _ in 0..<4_000 where setup.service.hasScheduledLaunchPass {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(!setup.service.hasScheduledLaunchPass)
        #expect(!FileManager.default.fileExists(atPath: setup.linkedBuild), "the pass evaluated the workspace it read")
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

/// Counts provider calls across the service's reads.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class LockBox: @unchecked Sendable {
    var lock: SwiftPMWorkspaceLock.HeldLock?
}
