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

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
