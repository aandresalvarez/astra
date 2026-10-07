import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A follow-up turn is graded on what it asked for, and a task pinned to a
/// worktree is searched — and reported — where its code runs.
///
/// Repro from 2026-10-07: a task pinned to `issue-479/wt-a` created
/// notes-a.txt on turn 1. Turn 2 asked to commit it, the commit landed, and
/// the run still ended `no_usable_result` with "did not create the requested
/// file: notes-a.txt", listing the workspace root instead of the worktree.
@Suite("Task deliverable turn scope")
@MainActor
struct TaskDeliverableTurnScopeTests {
    private static let commitTurn = "git add notes-a.txt && git commit -m 'Add notes A'; git log --oneline -2"

    @Test("a follow-up that asks for no file does not owe the original goal's deliverable")
    func followUpWithoutFileRequestCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try fixture.completeFirstTurn()

        let commitRun = try fixture.run(for: fixture.submitFollowUp(Self.commitTurn))

        #expect(TaskDeliverableExpectation.scope(for: fixture.task, run: commitRun) == .turn(Self.commitTurn))
        let result = await TaskDeliverableVerificationService.evaluate(
            task: fixture.task,
            run: commitRun,
            modelContext: fixture.context,
            workspacePath: fixture.worktree
        )
        #expect(result.canComplete)
        #expect(result.status == "not_applicable")
        #expect(TaskDeliverableVerificationService.eventType(for: result) == nil)
        #expect(!TaskCompletionPolicy.decide(deliverableVerification: result).shouldBlockCompletion)
        #expect(TaskCompletionPolicy.decideAfterRequiredExternalOutcome(task: fixture.task, run: commitRun).canComplete)

        // The review surfaces must agree with the gate once the task completes.
        fixture.task.status = .completed
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(task: fixture.task, latestRun: commitRun))
        #expect(!PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(fixture.reviewInput(latestRun: commitRun)))
    }

    @Test("a follow-up that asks for a file is held to it in review when the task asked for none")
    func followUpAddingFileRequirementKeepsReviewGate() throws {
        let fixture = try Fixture(goal: "Explain how the scheduler orders queued work.")
        defer { fixture.removeFiles() }
        _ = try fixture.run(for: fixture.submitInitial())
        #expect(!TaskDeliverableExpectation.requiresDeliverableArtifact(fixture.task))

        let summaryRun = try fixture.run(for: fixture.submitFollowUp("Now write summary.md with that explanation."))
        summaryRun.status = .failed
        summaryRun.stopReason = TaskRunStopReason.noUsableResult.rawValue
        fixture.task.status = .pendingUser

        // Approve must not complete a run that never produced what it owed.
        #expect(PendingTaskReviewPolicy.dismissalReason(for: fixture.task, latestRun: summaryRun) == .noUsableResult)
        #expect(PendingTaskReviewPolicy.reviewState(for: fixture.reviewInput(latestRun: summaryRun)).dismissalReason
            == .noUsableResult)
    }

    @Test("the first turn still owes its named deliverable")
    func firstTurnStillOwesDeliverable() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let firstRun = try fixture.run(for: fixture.submitInitial())

        #expect(TaskDeliverableExpectation.scope(for: fixture.task, run: firstRun) == .task)
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

    @Test("a follow-up that names a new file owes that file and not the original one")
    func followUpNamingFileOwesOnlyThatFile() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try fixture.completeFirstTurn()

        let summaryRun = try fixture.run(for: fixture.submitFollowUp("Now write summary.md with the git log output."))
        let scope = TaskDeliverableExpectation.scope(for: fixture.task, run: summaryRun)

        #expect(TaskDeliverableExpectation.requiredOutputFilenames(fixture.task, scope: scope) == ["summary.md"])
        #expect(TaskDeliverableExpectation.requiresDeliverableArtifact(fixture.task, scope: scope))
    }

    @Test("a referential follow-up owes what the turn it points back to owed")
    func referentialFollowUpInheritsPriorTurn() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try fixture.completeFirstTurn()
        _ = try fixture.run(for: fixture.submitFollowUp(Self.commitTurn))

        let retryRun = try fixture.run(for: fixture.submitFollowUp("try again"))

        #expect(TaskDeliverableExpectation.scope(for: fixture.task, run: retryRun) == .turn(Self.commitTurn))
        #expect(!TaskDeliverableExpectation.requiresDeliverableArtifact(
            fixture.task,
            scope: TaskDeliverableExpectation.scope(for: fixture.task, run: retryRun)
        ))
    }

    @Test("retrying or resuming the first turn keeps the task's own request")
    func retryAndResumeOfFirstTurnKeepTaskScope() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        // A chat-created task keeps the conversation that shaped it; a resume
        // inherits its last message, which is still the original request.
        let planning = TaskEvent(
            task: fixture.task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Please put task-a into notes-a.txt in the worktree."
        )
        planning.timestamp = Date().addingTimeInterval(-120)
        fixture.context.insert(planning)
        _ = try fixture.run(for: fixture.submitInitial())

        let retryRun = try fixture.run(for: ExecutionRequestSubmissionService.submitRetry(
            message: nil,
            continuation: false,
            for: fixture.task,
            into: fixture.context
        ).get().requestID)
        let resumeRun = try fixture.run(for: ExecutionRequestSubmissionService.submitResume(
            message: TaskLifecycleCoordinator.resumeContinuationMessage(for: fixture.task),
            for: fixture.task,
            into: fixture.context
        ).get().requestID)

        #expect(TaskDeliverableExpectation.scope(for: fixture.task, run: retryRun) == .task)
        #expect(TaskDeliverableExpectation.scope(for: fixture.task, run: resumeRun) == .task)
        #expect(TaskDeliverableExpectation.scope(for: fixture.task, run: nil) == .task)
    }

    @Test("a pinned task's missing-deliverable message names the worktree, not the workspace")
    func pinnedTaskMessageNamesWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let firstRun = try fixture.run(for: fixture.submitInitial())

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
        #expect(!decision.canComplete)
        #expect(message.contains("- Working directory: \(fixture.worktree)"))
        #expect(message.contains("Task output folder: \(TaskWorkspaceAccess(task: fixture.task).taskFolder)"))
        #expect(!message.contains("Workspace root: \(fixture.workspaceRoot)"))
    }

    @Test("an unpinned task's missing-deliverable message still names the workspace root")
    func unpinnedTaskMessageNamesWorkspaceRoot() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        fixture.task.executionRootPath = nil

        let message = TaskDeliverableExpectation.missingDeliverableMessage(for: fixture.task)

        #expect(message.contains("- Workspace root: \(fixture.workspaceRoot)"))
        #expect(!message.contains("Working directory"))
    }
}

@MainActor
private final class Fixture {
    static let goal = """
    Create notes-a.txt containing task-a in the working directory.
    Then run: sleep 45; echo task-a > notes-a.txt; pwd; ls
    """

    let root: String
    let workspaceRoot: String
    let worktree: String
    let container: ModelContainer
    let context: ModelContext
    let task: AgentTask

    init(goal: String = Fixture.goal) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-deliverable-turn-scope-\(UUID().uuidString)", isDirectory: true)
        root = base.path
        workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true).path
        worktree = base.appendingPathComponent("issue-479/wt-a", isDirectory: true).path
        for path in [workspaceRoot, worktree] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        context = ModelContext(container)
        let workspace = Workspace(name: "Turn Scope", primaryPath: workspaceRoot)
        task = AgentTask(title: "Notes A", goal: goal, workspace: workspace)
        task.executionRootPath = worktree
        context.insert(workspace)
        context.insert(task)
        try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try context.save()
    }

    func removeFiles() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func submitInitial() throws -> UUID {
        try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get().requestID
    }

    func submitFollowUp(_ message: String) throws -> UUID {
        try ExecutionRequestSubmissionService.submitFollowUp(message: message, for: task, into: context).get().requestID
    }

    /// Admits the request onto a fresh, already-finished run, the way the
    /// queue and worker bind them, and settles it.
    func run(for requestID: UUID) throws -> TaskRun {
        let request = try #require(try TaskTurnRequestRepository.request(id: requestID, in: context))
        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-30)
        run.completedAt = Date()
        run.status = .completed
        run.stopReason = "completed"
        context.insert(run)
        TaskTurnRequestStateMachine.transition(request, to: .admitted)
        TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
        TaskTurnRequestStateMachine.transition(request, to: .completed)
        try context.save()
        return run
    }

    /// The review dock's input, with the latest run's scope resolved the way
    /// `recomputeDecisionOutcomes` caches it.
    func reviewInput(latestRun: TaskRun) -> PendingTaskReviewSnapshotInput {
        PendingTaskReviewSnapshotInput(
            task: task,
            snapshot: TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task)),
            latestRunScope: TaskDeliverableExpectation.RunScope(
                runID: latestRun.id,
                scope: TaskDeliverableExpectation.scope(for: task, run: latestRun)
            )
        )
    }

    /// Turn 1 wrote notes-a.txt into the worktree well before any later turn.
    func completeFirstTurn() throws -> TaskRun {
        let firstRun = try run(for: submitInitial())
        let notes = (worktree as NSString).appendingPathComponent("notes-a.txt")
        try "task-a\n".write(toFile: notes, atomically: true, encoding: .utf8)
        let earlier = Date().addingTimeInterval(-3_600)
        try FileManager.default.setAttributes(
            [.creationDate: earlier, .modificationDate: earlier],
            ofItemAtPath: notes
        )
        firstRun.startedAt = earlier.addingTimeInterval(-30)
        firstRun.completedAt = earlier.addingTimeInterval(1)
        return firstRun
    }
}
