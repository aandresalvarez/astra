import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// Auto asks nothing, so a Jira write an Auto run staged is sent at the run
/// boundary without the review sheet — through the same coordinator checks an
/// approved send uses — and the chat records it. Ask and Custom keep the sheet.
@Suite("Connector mutation auto send")
@MainActor
struct ConnectorMutationAutoSendTests {
    @Test("Auto sends what the run staged, once, and records that Auto sent it")
    func autoSendsAndRecords() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender(body: #"{"key":"STAR-901"}"#)

        try fixture.stage(summary: "Age filter missing")

        await RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context,
            policyLevel: .autonomous,
            connectorMutationCoordinator: fixture.coordinator(sender: sender)
        )

        #expect(sender.count == 1)
        let receiptEvent = try #require(fixture.task.events.first { $0.type == ConnectorMutationEventTypes.receipt })
        let record = try #require(ExternalActionRecordProjection.record(
            type: receiptEvent.type,
            payload: receiptEvent.payload,
            eventID: receiptEvent.id,
            timestamp: receiptEvent.timestamp
        ))
        #expect(record.authorization == .autoPolicy)
        #expect(record.title == "Created STAR-901")
        #expect(record.url?.absoluteString == "https://jira.auto.test/browse/STAR-901")
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    @Test("Ask and Custom send nothing; the proposal waits for review")
    func askAndCustomSendNothing() async throws {
        for level in [AgentPolicyLevel.review, .custom] {
            let fixture = try AutoSendFixture()
            let sender = AutoSendRecordingSender()
            try fixture.stage(summary: "Age filter missing")

            await RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
                task: fixture.task,
                run: fixture.run,
                modelContext: fixture.context,
                policyLevel: level,
                connectorMutationCoordinator: fixture.coordinator(sender: sender)
            )

            #expect(sender.count == 0, "\(level.rawValue)")
            #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.receipt })
            #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
        }
    }

    @Test("Auto does not send a proposal another run staged")
    func autoLeavesAnotherRunsProposal() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender()
        try fixture.stage(summary: "Staged by an earlier Ask run", stagingRunID: UUID().uuidString)

        await RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context,
            policyLevel: .autonomous,
            connectorMutationCoordinator: fixture.coordinator(sender: sender)
        )

        #expect(sender.count == 0)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
    }

    @Test("Auto stops at the first write that does not go out and says so")
    func autoStopsAtTheFirstRefusal() async throws {
        let fixture = try AutoSendFixture()
        let sender = AutoSendRecordingSender(statusCode: 400, body: #"{"errorMessages":["Field 'priority' is required"]}"#)
        try fixture.stage(summary: "The epic")
        try fixture.stage(summary: "A story under the epic")

        await RunBoundaryDiscovery.recordWhatTheRunLeftForTheUser(
            task: fixture.task,
            run: fixture.run,
            modelContext: fixture.context,
            policyLevel: .autonomous,
            connectorMutationCoordinator: fixture.coordinator(sender: sender)
        )

        #expect(sender.count == 1, "the dependent proposal is not sent after its parent failed")
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 2)
        let notice = try #require(fixture.task.events.first { $0.payload.hasPrefix("Auto could not send") }?.payload)
        #expect(notice.contains("The epic"))
        #expect(notice.contains("It and 1 more are waiting for your review."))
    }
}

@MainActor
private final class AutoSendFixture {
    let container: ModelContainer
    let context: ModelContext
    let task: AgentTask
    let run: TaskRun
    let connector: Connector
    let workspaceRoot: URL

    init() throws {
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
        workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-connector-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Auto send", primaryPath: workspaceRoot.path)
        task = AgentTask(title: "File a ticket", goal: "File a Jira ticket")
        run = TaskRun(task: task)
        connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.auto.test", authMethod: "basic")
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        task.workspace = workspace
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        context.insert(connector)
        try context.save()
    }

    deinit { try? FileManager.default.removeItem(at: workspaceRoot) }

    func coordinator(sender: AutoSendRecordingSender) -> ConnectorMutationCoordinator {
        ConnectorMutationCoordinator(
            modelContext: context,
            sender: sender,
            secretStore: AutoSendSecretStore(),
            durableEventSave: { _, _, _, _ in }
        )
    }

    /// Stages through the broker's own writer, named after `stagingRunID` the
    /// way the broker names a file after the run that wrote it.
    func stage(summary: String, stagingRunID: String? = nil) throws {
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: taskFolder, isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try ConnectorMutationStaging.stage(
            serviceType: "jira",
            operation: "create_issue",
            connector: HostControlConnector(
                id: connector.id.uuidString,
                alias: "jira",
                envPrefix: "JIRA_JIRA",
                name: "Jira",
                serviceType: "jira",
                baseURL: "https://jira.auto.test",
                authMethod: "basic",
                env: [:],
                credentials: [:],
                config: [:]
            ),
            target: "STAR / Bug",
            summary: summary,
            requestMethod: "POST",
            requestPath: "/rest/api/2/issue",
            body: ["fields": ["project": ["key": "STAR"], "issuetype": ["name": "Bug"], "summary": summary]],
            configuration: HostControlToolConfiguration(
                taskFolder: taskFolder,
                runID: stagingRunID ?? run.id.uuidString,
                connectorsJSON: "{\"connectors\":[]}",
                environment: [:]
            )
        )
    }
}

private final class AutoSendRecordingSender: ConnectorMutationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    let statusCode: Int
    let body: String

    init(statusCode: Int = 201, body: String = "{}") {
        self.statusCode = statusCode
        self.body = body
    }

    var count: Int { lock.withLock { sent } }

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        lock.withLock { sent += 1 }
        return ConnectorMutationHTTPResponse(statusCode: statusCode, body: body)
    }
}

private struct AutoSendSecretStore: SecretStore {
    func load(key: String, entityID _: String) -> String? {
        ["JIRA_EMAIL": "user@example.com", "JIRA_API_TOKEN": "auto-token"][key]
    }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID: String) -> Bool { load(key: key, entityID: entityID) != nil }
}

@Suite("Connector proposal guidance by level")
struct ConnectorProposalGuidanceTests {
    private static let contract = HostControlPlanePromptGuidance.mutationUnderReviewContract(usesHostControlCLIRelay: false)

    @Test("Auto tells the agent a staged write is sent at the end of the turn")
    func autoGuidanceSaysItIsSent() {
        let prompt = HostControlPlanePromptGuidance.appendingAutoSendGuidance(to: Self.contract, permissionPolicy: .autonomous)
        #expect(prompt.hasPrefix(Self.contract))
        #expect(prompt.contains("sent by ASTRA with the connector credential when this turn ends"))
    }

    @Test("Ask keeps the review contract and a prompt without it gains nothing")
    func askAndUnrelatedPromptsAreUnchanged() {
        for policy in [PermissionPolicy.restricted, .interactive] {
            #expect(HostControlPlanePromptGuidance.appendingAutoSendGuidance(to: Self.contract, permissionPolicy: policy) == Self.contract)
        }
        #expect(HostControlPlanePromptGuidance.appendingAutoSendGuidance(to: "Fix the bug", permissionPolicy: .autonomous) == "Fix the bug")
    }
}
