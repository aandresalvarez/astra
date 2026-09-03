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

        let staged = "/tmp/jira-create_issue-run-1.json"
        stage(path: staged, at: 1_000, task: task, run: run, context: context)
        try context.save()

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task)
        #expect(pending.count == 1)
        #expect(pending.first?.target == "STAR / Bug")
        #expect(ConnectorMutationRequirementResolver.hasPendingMutation(task: task))

        resolve(
            type: ConnectorMutationEventTypes.receipt,
            path: staged,
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
        let staged = "/tmp/jira-create_issue-run-1.json"

        stage(path: staged, at: 2_000, task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.failed,
            path: staged,
            at: 2_001,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: task).count == 1)
    }

    @Test("Resolving one proposal leaves a second one pending")
    func resolutionIsScopedToItsStagedFile() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let first = "/tmp/jira-create_issue-run-1.json"
        let second = "/tmp/jira-create_issue-run-2.json"

        stage(path: first, at: 3_000, target: "STAR / Bug", task: task, run: run, context: context)
        stage(path: second, at: 3_001, target: "STAR / Task", task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.declined,
            path: first,
            at: 3_002,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task)
        #expect(pending.map(\.stagedPayloadPath) == [second])
    }

    /// The collapse that path identity exists to prevent. Two proposals whose
    /// bytes are identical — the user declined a ticket and then asked for the
    /// same one again — are two decisions, not one, and declining the first
    /// must not silently answer for the second.
    @Test("Two proposals with identical content are two separate reviews")
    func identicalContentStillYieldsTwoReviews() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let sharedDigest = String(repeating: "c", count: 64)
        let first = "/tmp/jira-create_issue-run-1.json"
        let second = "/tmp/jira-create_issue-run-2.json"

        stage(path: first, digest: sharedDigest, at: 3_100, task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.declined,
            path: first,
            at: 3_101,
            task: task,
            run: run,
            context: context
        )
        stage(path: second, digest: sharedDigest, at: 3_102, task: task, run: run, context: context)
        try context.save()

        let pending = ConnectorMutationRequirementResolver.pendingMutations(task: task)
        #expect(pending.map(\.stagedPayloadPath) == [second])
        #expect(pending.first?.requestDigest == sharedDigest)
        #expect(ConnectorMutationRequirementResolver.recordedStagedPaths(task: task) == [first, second])
    }

    @Test("Pending proposals come back in the order they were staged")
    func pendingProposalsAreOldestFirst() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let first = "/tmp/jira-create_issue-run-1.json"
        let second = "/tmp/jira-create_issue-run-2.json"

        stage(path: second, at: 4_001, task: task, run: run, context: context)
        stage(path: first, at: 4_000, task: task, run: run, context: context)
        try context.save()

        #expect(
            ConnectorMutationRequirementResolver.pendingMutations(task: task).map(\.stagedPayloadPath)
                == [first, second]
        )
    }

    /// Declining does not delete the staged file, so a rescan sees it again.
    /// `recordedStagedPaths` is what stops that turning into a resurrected row.
    @Test("Recorded staged paths include proposals that were already resolved")
    func recordedStagedPathsSurviveResolution() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (task, run) = makeTask(context: context)
        let staged = "/tmp/jira-create_issue-run-1.json"

        stage(path: staged, at: 5_000, task: task, run: run, context: context)
        resolve(
            type: ConnectorMutationEventTypes.declined,
            path: staged,
            at: 5_001,
            task: task,
            run: run,
            context: context
        )
        try context.save()

        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: task).isEmpty)
        #expect(ConnectorMutationRequirementResolver.recordedStagedPaths(task: task) == [staged])
    }

    // MARK: - Helpers

    private func makeTask(context: ModelContext) -> (AgentTask, TaskRun) {
        let task = AgentTask(title: "File a ticket", goal: "File a Jira ticket for the age filter gap")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        return (task, run)
    }

    /// A proposal is identified by the file the broker staged it in, so the
    /// helpers take a path and derive a plausible digest from it rather than
    /// the other way round.
    private func stage(
        path: String,
        digest: String? = nil,
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
                stagedPayloadPath: path,
                requestDigest: digest ?? Self.digest(for: path)
            ),
            run: run
        )
        event.timestamp = Date(timeIntervalSince1970: timestamp)
        context.insert(event)
    }

    private func resolve(
        type: String,
        path: String,
        at timestamp: TimeInterval,
        task: AgentTask,
        run: TaskRun,
        context: ModelContext
    ) {
        let event = TaskEvent(
            task: task,
            type: type,
            payload: #"{"version":2,"stagedPayloadPath":"\#(path)"}"#,
            run: run
        )
        event.timestamp = Date(timeIntervalSince1970: timestamp)
        context.insert(event)
    }

    /// Any stable 64-hex string will do: these tests are about identity, and
    /// identity is the path. The digest only has to be well-formed.
    private static func digest(for path: String) -> String {
        String(String(UInt64(bitPattern: Int64(path.hashValue)), radix: 16).padding(
            toLength: 64, withPad: "0", startingAt: 0))
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
