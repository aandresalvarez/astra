import Foundation
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
