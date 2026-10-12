import Foundation
import Observation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// The admission loop re-asserts `.waitingForResource` on every 500 ms
/// fallback tick while a lock is held. SwiftData's `@Model` setters notify
/// observers on every assignment, equal value or not, and the sidebar reads
/// `turnRequests.map(\.snapshot)` in its body — so an unconditional
/// same-state assignment re-rendered the whole sidebar twice a second
/// (2026-10-07 prod freeze: the live-lock started inside that pump).
@Suite("Turn-request state machine observation", .serialized)
@MainActor
struct TaskTurnRequestStateMachineTests {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeRequest(in context: ModelContext) throws -> TaskTurnRequest {
        let workspace = Workspace(name: "Observation", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        guard case let .success(submission) = TaskTurnSubmissionService.submit(
            message: "Queued follow-up",
            for: task,
            into: context
        ) else {
            Issue.record("Submission failed")
            throw CancellationError()
        }
        return try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
    }

    /// Whether `mutation` invalidates an observer that read the request the
    /// way the sidebar does.
    private func invalidatesSnapshotObservers(
        _ request: TaskTurnRequest,
        during mutation: () -> Void
    ) -> Bool {
        let flag = Flag()
        withObservationTracking {
            _ = request.snapshot
        } onChange: {
            flag.fired = true
        }
        mutation()
        return flag.fired
    }

    @Test("An equal re-assignment of a @Model property still invalidates observers")
    func equalAssignmentInvalidatesObservers() throws {
        // Pins the platform behavior the state machine's equality guards
        // exist for. If SwiftData ever stops notifying on equal values, this
        // fails and the guards become redundant, not wrong.
        let container = try makeContainer()
        let request = try makeRequest(in: container.mainContext)
        let summary = request.blockerSummary
        #expect(invalidatesSnapshotObservers(request) {
            request.blockerSummary = summary
        })
    }

    @Test("Repeated same-state waitingForResource transitions with identical values notify nobody")
    func repeatedSameStateTransitionIsSilent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let request = try makeRequest(in: context)
        let blockerID = UUID()
        let summary = "Workspace is locked by another task."
        let runID = UUID()

        let first = TaskTurnRequestStateMachine.transition(
            request,
            to: .waitingForResource,
            runID: runID,
            blockingTaskID: blockerID,
            blockerSummary: summary
        )
        #expect(first.changed)
        try context.save()

        for _ in 0..<5 {
            var result: TaskTurnRequestStateMachine.TransitionResult?
            let fired = invalidatesSnapshotObservers(request) {
                result = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .waitingForResource,
                    runID: runID,
                    blockingTaskID: blockerID,
                    blockerSummary: summary
                )
            }
            #expect(!fired)
            #expect(result?.changed == false)
            #expect(!context.hasChanges)
        }
        #expect(request.blockingTaskID == blockerID)
        #expect(request.blockerSummary == summary)
        #expect(request.runID == runID)
    }

    @Test("A same-state transition with a nil blocker still clears a stale one")
    func sameStateTransitionClearsStaleBlocker() throws {
        let container = try makeContainer()
        let request = try makeRequest(in: container.mainContext)
        _ = TaskTurnRequestStateMachine.transition(
            request,
            to: .waitingForResource,
            blockingTaskID: UUID(),
            blockerSummary: "Workspace is locked by another task."
        )

        var result: TaskTurnRequestStateMachine.TransitionResult?
        let fired = invalidatesSnapshotObservers(request) {
            result = TaskTurnRequestStateMachine.transition(request, to: .waitingForResource)
        }
        #expect(fired)
        #expect(result?.changed == true)
        #expect(request.blockingTaskID == nil)
        #expect(request.blockerSummary == nil)

        // Once cleared, re-asserting nil is silent too.
        #expect(!invalidatesSnapshotObservers(request) {
            _ = TaskTurnRequestStateMachine.transition(request, to: .waitingForResource)
        })
    }

    @Test("A same-state transition with a new blocker summary updates it")
    func sameStateTransitionUpdatesChangedBlocker() throws {
        let container = try makeContainer()
        let request = try makeRequest(in: container.mainContext)
        let blockerID = UUID()
        _ = TaskTurnRequestStateMachine.transition(
            request,
            to: .waitingForResource,
            blockingTaskID: blockerID,
            blockerSummary: "Waiting behind an earlier request for Workspace."
        )

        var result: TaskTurnRequestStateMachine.TransitionResult?
        let fired = invalidatesSnapshotObservers(request) {
            result = TaskTurnRequestStateMachine.transition(
                request,
                to: .waitingForResource,
                blockingTaskID: blockerID,
                blockerSummary: "Workspace is locked by another task."
            )
        }
        #expect(fired)
        #expect(result?.changed == true)
        #expect(request.blockerSummary == "Workspace is locked by another task.")
    }
}
