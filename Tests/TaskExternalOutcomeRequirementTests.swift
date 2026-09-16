import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task external outcome requirements")
@MainActor
struct TaskExternalOutcomeRequirementTests {
    @Test("Durable publication request stays pending until a later receipt")
    func publicationRequestLifecycle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let requestEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(
                kind: .githubPullRequest,
                runID: run.id,
                message: "Review the exact proposal."
            ),
            run: run
        )
        requestEvent.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(requestEvent)
        try context.save()

        let pending = try #require(
            TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run)
        )
        #expect(pending.runID == run.id)
        #expect(pending.sourceEventID == requestEvent.id)

        let receiptEvent = TaskEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationReceipt,
            payload: "{}",
            run: run
        )
        receiptEvent.timestamp = Date(timeIntervalSince1970: 1_001)
        context.insert(receiptEvent)
        try context.save()

        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run) == nil)
    }

    @Test("Publication receipts are scoped to their matching run")
    func receiptFromOlderRunDoesNotClearNewRequest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Create a pull request")
        let oldRun = TaskRun(task: task)
        let newRun = TaskRun(task: task)
        context.insert(task)
        context.insert(oldRun)
        context.insert(newRun)

        let request = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(
                kind: .githubPullRequest,
                runID: newRun.id,
                message: "Review the new run."
            ),
            run: newRun
        )
        request.timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(request)
        let unrelatedReceipt = TaskEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationReceipt,
            payload: "{}",
            run: oldRun
        )
        unrelatedReceipt.timestamp = Date(timeIntervalSince1970: 2_001)
        context.insert(unrelatedReceipt)
        try context.save()

        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task,
            run: newRun
        )?.runID == newRun.id)
    }

    @Test("Durable publication request survives later task text edits")
    func durableRequestOutlivesMutableIntentText() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        context.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(
                kind: .githubPullRequest,
                runID: run.id,
                message: "Review the exact proposal."
            ),
            run: run
        ))
        try context.save()

        task.goal = "Summarize the local changes only"
        task.title = "Summary"
        try context.save()

        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task,
            run: run
        )?.runID == run.id)
    }

    /// The decision dock answers this from its transcript snapshot rather than
    /// from `task.events`, so the two paths must agree on the same rows.
    @Test("Snapshot-shaped events resolve the same pending request as the SwiftData rows")
    func recordResolutionMatchesModelResolution() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Implement the fix and create a pull request")
        let oldRun = TaskRun(task: task)
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(oldRun)
        context.insert(run)

        let staleReceipt = TaskEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationReceipt,
            payload: "{}",
            run: oldRun
        )
        staleReceipt.timestamp = Date(timeIntervalSince1970: 900)
        let requestEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(
                kind: .githubPullRequest,
                runID: run.id,
                message: "Review the exact proposal."
            ),
            run: run
        )
        requestEvent.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(staleReceipt)
        context.insert(requestEvent)
        try context.save()

        let records = [staleReceipt, requestEvent].map(record)
        let pending = try #require(
            TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
                task: task,
                targetRunID: run.id,
                events: records
            )
        )
        #expect(pending == TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run))
        #expect(pending.sourceEventID == requestEvent.id)

        let receipt = TaskOutcomeEventRecord(
            id: UUID(),
            runID: run.id,
            type: TaskExternalOutcomeEventTypes.publicationReceipt,
            payload: "{}",
            timestamp: Date(timeIntervalSince1970: 1_001)
        )
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task,
            targetRunID: run.id,
            events: records + [receipt]
        ) == nil)
    }

    @Test("Legacy failed publication evidence resolves from snapshot-shaped events")
    func legacyFailureResolvesFromRecords() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Publish", goal: "Fix the bug and create a pull request")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        let failedEvent = TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskEventTypes.Tool.resultFailed.rawValue,
            payload: ToolResultFailurePayload(toolID: "bash", message: "gh pr create: permission denied"),
            run: run
        )
        failedEvent.timestamp = Date(timeIntervalSince1970: 1_000)
        context.insert(failedEvent)
        try context.save()

        let fromRecords = try #require(
            TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
                task: task,
                targetRunID: run.id,
                events: [record(failedEvent)]
            )
        )
        #expect(fromRecords.sourceEventID == failedEvent.id)
        #expect(fromRecords == TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task, run: run))
    }

    private func record(_ event: TaskEvent) -> TaskOutcomeEventRecord {
        TaskOutcomeEventRecord(
            id: event.id,
            runID: event.run?.id,
            type: event.type,
            payload: event.payload,
            timestamp: event.timestamp
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
