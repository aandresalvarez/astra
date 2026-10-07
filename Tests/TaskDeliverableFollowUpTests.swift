import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A turn after the task was accepted as complete does not owe the original
/// deliverable again, and a task pinned to a worktree is reported where its
/// code runs.
///
/// Repro from 2026-10-07: a task pinned to `issue-479/wt-a` created
/// notes-a.txt and completed. A follow-up committed it, the commit landed,
/// and the run still ended `no_usable_result` with "did not create the
/// requested file: notes-a.txt", listing the workspace root, not the worktree.
@Suite("Task deliverable follow-up turns")
@MainActor
struct TaskDeliverableFollowUpTests {
    @Test("a turn after the task completed does not owe the original deliverable")
    func turnAfterCompletionDoesNotOweOriginalDeliverable() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-3_600))
        try fixture.writeNotes(modifiedAt: firstRun.startedAt.addingTimeInterval(5))
        fixture.recordCompletion(of: firstRun)

        let commitRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))

        #expect(TaskDeliverableExpectation.requiresDeliverableArtifact(fixture.task))
        #expect(!TaskDeliverableExpectation.owesDeliverable(fixture.task, run: commitRun))
        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: commitRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(result.canComplete)
        #expect(result.status == "not_applicable")
        #expect(TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: commitRun).canComplete)

        // The review dock agrees once the follow-up completes.
        fixture.task.status = .completed
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(task: fixture.task, latestRun: commitRun))
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(fixture.reviewInput()))
    }

    @Test("the first turn still owes its named deliverable")
    func firstTurnStillOwesDeliverable() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: firstRun))
        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: firstRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(!result.canComplete)
        #expect(result.level == .noArtifact)
        #expect(result.checks.contains { $0.id == "artifact.required_files" && $0.summary.contains("notes-a.txt") })
    }

    @Test("a retry of a first turn that never completed still owes the deliverable")
    func retryOfIncompleteFirstTurnStillOwes() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let failedRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-600))
        failedRun.status = .failed
        failedRun.stopReason = TaskRunStopReason.noUsableResult.rawValue

        let retryRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: retryRun))
        #expect(!TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: retryRun).canComplete)
    }

    @Test("only a completion recorded before the run started counts")
    func completionOfTheSameRunDoesNotCount() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let run = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))
        fixture.recordCompletion(of: run)

        #expect(TaskDeliverableExpectation.owesDeliverable(fixture.task, run: run))
    }

    @Test("a pinned task's missing-deliverable message names the worktree, not the workspace")
    func pinnedTaskMessageNamesWorktree() async throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        let firstRun = fixture.makeRun(startedAt: Date().addingTimeInterval(-30))

        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: firstRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(result.summary.contains("- Working directory: \(fixture.worktree)"))
        #expect(!result.summary.contains("Workspace root: \(fixture.workspaceRoot)"))

        // The completion gate has no execution path to hand in; it names the
        // code working directory the pin resolves to.
        let decision = TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: firstRun)
        let message = try #require(decision.userVisibleMessage)
        #expect(message.contains("- Working directory: \(fixture.worktree)"))
        #expect(message.contains("Task output folder: \(TaskWorkspaceAccess(task: fixture.task).taskFolder)"))
        #expect(!message.contains("Workspace root: \(fixture.workspaceRoot)"))
    }

    @Test("an unpinned task's missing-deliverable message still names the workspace root")
    func unpinnedTaskMessageNamesWorkspaceRoot() throws {
        let fixture = try DeliverableFollowUpFixture()
        defer { fixture.removeFiles() }
        fixture.task.executionRootPath = nil

        let message = TaskDeliverableExpectation.missingDeliverableMessage(for: fixture.task)

        #expect(message.contains("- Workspace root: \(fixture.workspaceRoot)"))
        #expect(!message.contains("Working directory"))
    }
}

@MainActor
private final class DeliverableFollowUpFixture {
    let root: String
    let workspaceRoot: String
    let worktree: String
    let container: ModelContainer
    let context: ModelContext
    let task: AgentTask

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-deliverable-follow-up-\(UUID().uuidString)", isDirectory: true)
        root = base.path
        workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true).path
        worktree = base.appendingPathComponent("issue-479/wt-a", isDirectory: true).path
        for path in [workspaceRoot, worktree] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        let workspace = Workspace(name: "Follow-up", primaryPath: workspaceRoot)
        task = AgentTask(
            title: "Notes A",
            goal: """
            Create notes-a.txt containing task-a in the working directory.
            Then run: sleep 45; echo task-a > notes-a.txt; pwd; ls
            """,
            workspace: workspace
        )
        task.executionRootPath = worktree
        context.insert(workspace)
        context.insert(task)
        try TaskWorkspaceAccess(task: task).ensureTaskFolder()
    }

    func removeFiles() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func makeRun(startedAt: Date) -> TaskRun {
        let run = TaskRun(task: task)
        run.startedAt = startedAt
        run.completedAt = startedAt.addingTimeInterval(20)
        run.status = .completed
        run.stopReason = TaskRunStopReason.completed.rawValue
        context.insert(run)
        return run
    }

    /// What `TaskSuccessfulCompletionService` records once every gate passed.
    func recordCompletion(of run: TaskRun) {
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.completed, payload: "Completed.", run: run)
        event.timestamp = run.completedAt ?? run.startedAt
        context.insert(event)
    }

    func writeNotes(modifiedAt date: Date) throws {
        let notes = (worktree as NSString).appendingPathComponent("notes-a.txt")
        try "task-a\n".write(toFile: notes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: notes)
    }

    func reviewInput() -> PendingTaskReviewSnapshotInput {
        PendingTaskReviewSnapshotInput(task: task, snapshot: TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task)))
    }
}
