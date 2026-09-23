import Foundation
import SwiftData
import ASTRAPersistence
import Testing
import ASTRAModels
@testable import ASTRA

/// The single "is a task using this worktree" rule shared by worktree removal
/// and artifact reclamation.
@Suite("Worktree Task Usage")
struct WorktreeTaskUsageTests {
    private func hold(
        _ root: String,
        title: String = "Fix login",
        terminal: Bool = false,
        followUp: Bool = false,
        updatedAt: Date = Date()
    ) -> WorktreeTaskHold {
        WorktreeTaskHold(taskTitle: title, rootPath: root, isTerminal: terminal, hasActiveTurnRequest: followUp, updatedAt: updatedAt)
    }

    @Test("A task that isn't terminal holds its worktree; a finished one doesn't")
    func terminalRelease() {
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/wt/a", holds: [hold("/wt/a")]) == "In use by task “Fix login”")
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/wt/a", holds: [hold("/wt/a", terminal: true)]) == nil)
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/wt/b", holds: [hold("/wt/a")]) == nil)
    }

    @Test("A finished task with a queued follow-up still holds its worktree")
    func queuedFollowUp() {
        let reason = WorktreeTaskUsage.inUseReason(forWorktreePath: "/wt/a", holds: [hold("/wt/a", terminal: true, followUp: true)])
        #expect(reason == "Follow-up queued for task “Fix login”")
    }

    @Test("Paths compare canonically: symlinks, /var aliases and trailing slashes")
    func canonicalPaths() throws {
        let fixture = try WorktreeStorageFixture("usage")
        defer { fixture.cleanUp() }
        let real = try fixture.directory("feature")
        try fixture.directory("alias")
        try fixture.symlink("alias/feature", to: real)

        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: real, holds: [hold(fixture.path("alias/feature"))]) != nil)
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: real, holds: [hold(real + "/")]) != nil)
        // git reports `/private/var/...`; a stored path may say `/var/...`.
        if real.hasPrefix("/private/var/") {
            let unresolved = String(real.dropFirst("/private".count))
            #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: real, holds: [hold(unresolved)]) != nil)
        }
    }

    @Test("Latest activity is the newest update among tasks that worked there")
    func latestActivity() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let holds = [hold("/wt/a", terminal: true, updatedAt: older), hold("/wt/a", terminal: true, updatedAt: newer),
                     hold("/wt/b", updatedAt: Date())]
        #expect(WorktreeTaskUsage.latestActivity(forWorktreePath: "/wt/a", holds: holds) == newer)
        #expect(WorktreeTaskUsage.latestActivity(forWorktreePath: "/wt/c", holds: holds) == nil)
    }

    @MainActor
    @Test("Live tasks claim their pin, or the workspace's worktree only while executing unpinned")
    func holdsFromLiveTasks() {
        let workspace = Workspace(name: "App", primaryPath: "/repos/app")
        workspace.activeWorkingPath = "/worktrees/app/feature"
        let pinned = AgentTask(title: "Pinned", goal: "Work", workspace: workspace)
        #expect(pinned.executionRootPath == "/worktrees/app/feature")

        let unpinnedDraft = AgentTask(title: "Draft", goal: "Work", workspace: workspace)
        unpinnedDraft.executionRootPath = nil
        let unpinnedRunning = AgentTask(title: "Running", goal: "Work", workspace: workspace)
        unpinnedRunning.executionRootPath = nil
        unpinnedRunning.status = .running

        let holds = WorktreeTaskUsage.holds(from: [pinned, unpinnedDraft, unpinnedRunning])
        #expect(holds.map(\.taskTitle) == ["Pinned", "Running"])
        #expect(holds.allSatisfy { $0.rootPath == "/worktrees/app/feature" })
    }
}

/// Review follow-ups: aliases, subfolders, nested worktrees, selected
/// worktrees and queued follow-ups.
@Suite("Worktree Task Usage Scope")
struct WorktreeTaskUsageScopeTests {
    private func hold(_ root: String, terminal: Bool = false, followUp: Bool = false) -> WorktreeTaskHold {
        WorktreeTaskHold(taskTitle: "Fix login", rootPath: root, isTerminal: terminal, hasActiveTurnRequest: followUp, updatedAt: Date())
    }

    @Test("A symlink alias with a different final folder name still matches")
    func aliasWithDifferentBasename() throws {
        let fixture = try WorktreeStorageFixture("usage-alias")
        defer { fixture.cleanUp() }
        let real = try fixture.directory("worktrees/feature")
        try fixture.symlink("current", to: real)
        #expect(WorktreePath.same(fixture.path("current"), real))
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: real, holds: [hold(fixture.path("current"))]) != nil)
    }

    @Test("A task rooted in a subfolder of the worktree holds it")
    func subfolderHolds() {
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/wt/feature", holds: [hold("/wt/feature/packages/api")]) != nil)
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/wt/feature", holds: [hold("/wt/feature-2")]) == nil)
    }

    @Test("A task in a nested worktree holds that worktree, not its parent")
    func nestedWorktreesScopeClaims() {
        let nested = "/repo/.claude/worktrees/agent"
        let holds = [hold(nested + "/Sources")]
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/repo", holds: holds, otherWorktreePaths: ["/repo", nested]) == nil)
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: nested, holds: holds, otherWorktreePaths: ["/repo", nested]) != nil)
    }

    @MainActor
    @Test("A workspace's selected worktree is protected like its root")
    func selectedWorktreeProtected() {
        let workspace = Workspace(name: "App", primaryPath: "/repos/app", additionalPaths: ["/repos/lib"])
        workspace.activeWorkingPath = "/worktrees/app/feature"
        #expect(WorktreeTaskUsage.protectedWorkspacePaths(of: [workspace]) == ["/repos/app", "/repos/lib", "/worktrees/app/feature"])
    }

    @MainActor
    @Test("A queued follow-up holds the path it captured, even after the task is re-pinned")
    func followUpHoldsCapturedPath() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: "/repos/app")
        context.insert(workspace)
        let task = AgentTask(title: "Fix login", goal: "Fix it", workspace: workspace)
        task.executionRootPath = "/worktrees/app/first"
        task.status = .completed
        context.insert(task)
        context.insert(TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1))
        task.executionRootPath = "/worktrees/app/second"
        try context.save()

        let holds = try WorktreeTaskUsage.allHolds(in: context)

        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/worktrees/app/first", holds: holds)
            == "Follow-up queued for task “Fix login”")
        #expect(WorktreeTaskUsage.inUseReason(forWorktreePath: "/worktrees/app/second", holds: holds) == nil)
        _ = container
    }
}
