import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Connector mutation requirements")
@MainActor
struct ConnectorMutationRequirementTests {
    @Test("A staged mutation stays pending until a receipt or a decline")
    func stagedMutationLifecycle() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)

        stage(digest: String(repeating: "a", count: 64), at: 1_000, task: task, run: run, context: context)
        try context.save()

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task)
        #expect(pending.count == 1)
        #expect(pending.first?.target == "STAR / Bug")
        #expect(ConnectorMutationRequirementResolver.hasPendingMutation(task: task))

        resolve(
            type: ConnectorMutationEventTypes.receipt,
            digest: String(repeating: "a", count: 64),
            at: 1_001,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: task).isEmpty)
    }

    /// The regression this seam is most likely to grow: treating any terminal
    /// event as "handled". A 503 must leave the proposal on the dock.
    @Test("A failed send leaves the proposal pending")
    func failureDoesNotRetireAProposal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let digest = String(repeating: "b", count: 64)

        stage(digest: digest, at: 2_000, task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.failed,
            digest: digest,
            at: 2_001,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: task).count == 1)
    }

    @Test("Resolving one proposal leaves a second one pending")
    func resolutionIsScopedToItsDigest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let first = String(repeating: "c", count: 64)
        let second = String(repeating: "d", count: 64)

        stage(digest: first, at: 3_000, target: "STAR / Bug", task: task, run: run, context: context)
        stage(digest: second, at: 3_001, target: "STAR / Task", task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.declined,
            digest: first,
            at: 3_002,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task)
        #expect(pending.map(\.requestDigest) == [second])
    }

    @Test("Pending proposals come back in the order they were staged")
    func pendingProposalsAreOldestFirst() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let first = String(repeating: "e", count: 64)
        let second = String(repeating: "f", count: 64)

        stage(digest: second, at: 4_001, task: task, run: run, context: context)
        stage(digest: first, at: 4_000, task: task, run: run, context: context)
        try context.save()

        #expect(
            ConnectorMutationRequirementResolver.pendingMutations(task: task).map(\.requestDigest)
                == [first, second]
        )
    }

    /// Declining does not delete the staged file, so a rescan sees it again.
    /// `recordedDigests` is what stops that turning into a resurrected row.
    @Test("Recorded digests include proposals that were already resolved")
    func recordedDigestsSurviveResolution() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let digest = String(repeating: "9", count: 64)

        stage(digest: digest, at: 5_000, task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.declined,
            digest: digest,
            at: 5_001,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: task).isEmpty)
        #expect(ConnectorMutationRequirementResolver.recordedDigests(task: task) == [digest])
    }

    // MARK: - Helpers

    private func makeTask(context: ModelContext) -> (AgentTask, TaskRun) {
        let task = AgentTask(title: "File a ticket", goal: "File a Jira ticket for the age filter gap")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        return (task, run)
    }

    private func stage(
        digest: String,
        at timestamp: TimeInterval,
        target: String = "STAR / Bug",
        task: AgentTask,
        run: TaskRun,
        context: ModelContext
    ) {
        let event = TaskEvent.structuredPayloadEvent(
            task: task,
            type: ConnectorMutationEventTypes.staged,
            payload: TaskStagedConnectorMutation(
                runID: run.id,
                serviceType: "jira",
                operation: "create_issue",
                connectorID: UUID().uuidString,
                connectorAlias: "jira",
                target: target,
                summary: "Add an age filter to dose_era",
                stagedPayloadPath: "/tmp/\(digest).json",
                requestDigest: digest
            ),
            run: run
        )
        event.timestamp = Date(timeIntervalSince1970: timestamp)
        context.insert(event)
    }

    private func resolve(
        type: String,
        digest: String,
        at timestamp: TimeInterval,
        task: AgentTask,
        run: TaskRun,
        context: ModelContext
    ) {
        let event = TaskEvent(
            task: task,
            type: type,
            payload: #"{"version":1,"requestDigest":"\#(digest)"}"#,
            run: run
        )
        event.timestamp = Date(timeIntervalSince1970: timestamp)
        context.insert(event)
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
