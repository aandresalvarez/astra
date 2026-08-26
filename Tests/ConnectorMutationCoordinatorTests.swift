import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
@testable import HostControlToolSupport

/// Covers the half of a connector write the agent is *not* allowed to do: the
/// commit. Everything here is about the app refusing to send something other
/// than what the user read, and about the credential reaching exactly one place.
@Suite("Connector mutation commit")
@MainActor
struct ConnectorMutationCoordinatorTests {
    /// The plan's central claim. A payload rewritten after staging must not be
    /// reviewable, let alone sendable.
    @Test("A payload rewritten after staging is refused at review time")
    func rewrittenPayloadIsRefusedAtReview() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()

        try Data("{\"tampered\":true}".utf8).write(to: URL(fileURLWithPath: pending.stagedPayloadPath))

        #expect(throws: ConnectorMutationCoordinatorError.self) {
            try fixture.coordinator().prepare(task: fixture.task, pending: pending)
        }
    }

    /// Refused at `prepare`, not at `send`. The sheet is built from the
    /// resolved operation — the route, the connector, the destination it will
    /// actually POST to — so a proposal ASTRA would never send cannot be
    /// rendered as one awaiting a click.
    @Test("A staged operation ASTRA does not recognise is never sent")
    func unknownOperationIsNeverSent() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(operation: "delete_project")
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)

        #expect(
            throws: ConnectorMutationCoordinatorError
                .unsupportedOperation(serviceType: "jira", operation: "delete_project")
        ) {
            try coordinator.prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.isEmpty)
    }

    /// The envelope is agent-writable, so a trusted `path` would aim an
    /// authenticated POST anywhere on the connector's host.
    @Test("A staged path that disagrees with ASTRA's route is never sent")
    func rewrittenRouteIsNeverSent() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(requestPath: "/rest/api/2/user")
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)

        #expect(
            throws: ConnectorMutationCoordinatorError.routeMismatch(
                staged: "POST /rest/api/2/user",
                expected: "POST /rest/api/2/issue"
            )
        ) {
            try coordinator.prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.isEmpty)
    }

    /// The envelope's own `connector_alias` is a label the agent wrote; only its
    /// `connector_id` decides where the credential goes. A sheet that repeated
    /// the label would let "sandbox" sit above a production address.
    @Test("The review names the connector ASTRA resolved, not the one the envelope claims")
    func reviewNamesTheResolvedConnector() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(connectorAlias: "jira-sandbox")

        let proposal = try fixture.coordinator().prepare(task: fixture.task, pending: pending)

        #expect(proposal.connectorAlias == "Jira")
        #expect(proposal.proposedConnectorAlias == "jira-sandbox")
        #expect(proposal.destinationURL == "https://jira.commit.test/rest/api/2/issue")
        #expect(
            proposal.fields.contains {
                $0.id == "endpoint" && $0.value == "POST https://jira.commit.test/rest/api/2/issue"
            }
        )
        // Shown, not silently corrected: the disagreement is the interesting part.
        let warning = try #require(proposal.warnings.first)
        #expect(proposal.warnings.count == 1)
        #expect(warning.contains("jira-sandbox"))
        #expect(warning.contains("Jira"))
    }

    /// An alias that only differs in case is the same connector, and warning
    /// about it would teach the user to click through the warnings that matter.
    @Test("An alias that matches the resolved connector raises no warning")
    func matchingAliasRaisesNoWarning() throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal(connectorAlias: "jira")

        let proposal = try fixture.coordinator().prepare(task: fixture.task, pending: pending)

        #expect(proposal.connectorAlias == "Jira")
        #expect(proposal.warnings.isEmpty)
    }

    /// The sheet can sit open for minutes. Re-pointing the connector in
    /// Configure › Connectors in that window would send the approved bytes to a
    /// host nobody approved.
    @Test("A connector re-pointed while the review was open is refused at send")
    func rePointedConnectorIsRefusedAtSend() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        fixture.connector.baseURL = "https://jira.elsewhere.test"

        await #expect(
            throws: ConnectorMutationCoordinatorError.connectorChangedSinceReview(
                reviewed: "Jira (https://jira.commit.test/rest/api/2/issue)",
                now: "Jira (https://jira.elsewhere.test/rest/api/2/issue)"
            )
        ) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.isEmpty)
    }

    @Test("A connector that is no longer the staged service is never used")
    func connectorServiceMismatchIsNeverSent() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender()
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        fixture.connector.serviceType = "github"

        await #expect(
            throws: ConnectorMutationCoordinatorError
                .connectorServiceMismatch(expected: "jira", found: "github")
        ) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.isEmpty)
    }

    @Test("An approved proposal is sent verbatim and retires on its receipt")
    func approvedProposalIsSentAndRetired() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 201,
                body: #"{"id":"10001","key":"STAR-12558","self":"https://jira.commit.test/rest/api/2/issue/10001"}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let receipt = try await coordinator.send(task: fixture.task, proposal: proposal)

        #expect(receipt.createdKey == "STAR-12558")
        #expect(receipt.createdURL == "https://jira.commit.test/browse/STAR-12558")
        #expect(receipt.statusCode == 201)

        let request = try #require(sender.requests.first)
        #expect(request.url.absoluteString == "https://jira.commit.test/rest/api/2/issue")
        #expect(request.method == "POST")
        // Byte-for-byte what the digest covered, not a re-encoding of it.
        #expect(request.body == proposal.requestBody)
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).isEmpty)
    }

    @Test("A rejected send is recorded but leaves the proposal reviewable")
    func rejectedSendLeavesTheProposalPending() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(
                statusCode: 503,
                body: #"{"errorMessages":["Jira is temporarily unavailable"],"errors":{}}"#
            )
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        await #expect(
            throws: ConnectorMutationCoordinatorError.requestFailed(
                statusCode: 503,
                message: "Jira is temporarily unavailable"
            )
        ) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.failed })
        #expect(ConnectorMutationRequirementResolver.pendingMutations(task: fixture.task).count == 1)
    }

    /// The write happened; only the bookkeeping failed. Reporting that as a
    /// failure is what used to turn one approved ticket into two real ones,
    /// because the row stayed pending and the send button came back.
    @Test("A receipt that could not be saved is still a send, and terminal")
    func unrecordedReceiptIsStillASend() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-9"}"#)
        )
        let coordinator = fixture.coordinator(
            sender: sender,
            durableEventSave: { _, _, _, _ in throw FixtureSaveFailure() }
        )
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)

        let error = await #expect(throws: ConnectorMutationCoordinatorError.self) {
            try await coordinator.send(task: fixture.task, proposal: proposal)
        }

        #expect(error == .sentButNotRecorded(target: "STAR-9", reason: FixtureSaveFailure.message))
        // The sheet reads this to decide the send button does not come back.
        #expect(error?.isTerminal == true)
        #expect(sender.requests.count == 1)
        // Not recorded as a failure either — a `failed` event is what a retry
        // would be built on.
        #expect(!fixture.task.events.contains { $0.type == ConnectorMutationEventTypes.failed })

        // And it cannot be offered for review again, which is where the second
        // click would have come from.
        #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: pending)
        }
        #expect(sender.requests.count == 1)
    }

    /// The in-memory guard dies with the process, and the case it exists for —
    /// a receipt that never reached the store — is exactly the case with no
    /// durable record to fall back on. The on-disk marker is what covers it.
    @Test("A sent proposal is still refused after the in-memory guard is lost")
    func sentMarkerSurvivesTheInMemoryGuard() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-7"}"#)
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)
        _ = try await coordinator.send(task: fixture.task, proposal: proposal)

        #expect(FileManager.default.fileExists(atPath: pending.stagedPayloadPath + ".sent"))

        // Stands in for a relaunch: the process forgets, the marker does not.
        ConnectorMutationCoordinator.resetSentStagedPathsForTesting()

        #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try fixture.coordinator(sender: sender).prepare(task: fixture.task, pending: pending)
        }
        await #expect(throws: ConnectorMutationCoordinatorError.alreadySent("STAR / Bug")) {
            try await fixture.coordinator(sender: sender).send(task: fixture.task, proposal: proposal)
        }
        #expect(sender.requests.count == 1)
    }

    /// The design fails if committing reintroduces the credential anywhere the
    /// agent or the transcript can see it.
    @Test("The credential reaches the Authorization header and nothing else")
    func credentialStaysOutOfEverythingButTheHeader() async throws {
        let fixture = try Fixture()
        let pending = try fixture.stageProposal()
        let sender = RecordingSender(
            response: ConnectorMutationHTTPResponse(statusCode: 201, body: #"{"key":"STAR-1"}"#)
        )
        let coordinator = fixture.coordinator(sender: sender)
        let proposal = try coordinator.prepare(task: fixture.task, pending: pending)
        try fixture.recordStagedEvent(pending)
        _ = try await coordinator.send(task: fixture.task, proposal: proposal)

        let request = try #require(sender.requests.first)
        #expect(request.authorizationHeader.hasPrefix("Basic "))
        #expect(!request.authorizationHeader.contains(Fixture.apiToken))

        let transcript = fixture.task.events.map(\.payload).joined(separator: "\n")
        #expect(!transcript.contains(Fixture.apiToken))
        #expect(!transcript.contains(request.authorizationHeader))
        let stagedBytes = try String(contentsOf: URL(fileURLWithPath: pending.stagedPayloadPath), encoding: .utf8)
        #expect(!stagedBytes.contains(Fixture.apiToken))
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        static let apiToken = "super-secret-token-value"

        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun
        let connector: Connector
        let workspaceRoot: URL

        init() throws {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [configuration]
            )
            context = container.mainContext
            workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-connector-commit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

            let workspace = Workspace(name: "Commit", primaryPath: workspaceRoot.path)
            task = AgentTask(title: "File a ticket", goal: "File a Jira ticket")
            run = TaskRun(task: task)
            connector = Connector(
                name: "Jira",
                serviceType: "jira",
                baseURL: "https://jira.commit.test",
                authMethod: "basic"
            )
            connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
            task.workspace = workspace
            context.insert(workspace)
            context.insert(task)
            context.insert(run)
            context.insert(connector)
            try context.save()
        }

        deinit { try? FileManager.default.removeItem(at: workspaceRoot) }

        var taskFolder: String { TaskWorkspaceAccess(task: task).taskFolder }

        func coordinator(
            sender: any ConnectorMutationSending = RecordingSender(),
            durableEventSave: @escaping ConnectorMutationCoordinator.DurableEventSave = { _, _, _, _ in }
        ) -> ConnectorMutationCoordinator {
            ConnectorMutationCoordinator(
                modelContext: context,
                sender: sender,
                secretStore: FixtureSecretStore(values: [
                    "JIRA_EMAIL": "user@example.com",
                    "JIRA_API_TOKEN": Self.apiToken
                ]),
                durableEventSave: durableEventSave
            )
        }

        /// Stages through the same writer the broker uses, so the envelope under
        /// test is the envelope production produces.
        func stageProposal(
            operation: String = "create_issue",
            requestPath: String = "/rest/api/2/issue",
            connectorAlias: String = "jira"
        ) throws -> TaskStagedConnectorMutation {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: taskFolder, isDirectory: true),
                withIntermediateDirectories: true
            )
            let hostConnector = HostControlConnector(
                id: connector.id.uuidString,
                alias: connectorAlias,
                envPrefix: "JIRA_JIRA",
                name: "Jira",
                serviceType: "jira",
                baseURL: "https://jira.commit.test",
                authMethod: "basic",
                env: [:],
                credentials: [:],
                config: [:]
            )
            let staged = try ConnectorMutationStaging.stage(
                serviceType: "jira",
                operation: operation,
                connector: hostConnector,
                target: "STAR / Bug",
                summary: "Age filter missing on three domains",
                requestMethod: "POST",
                requestPath: requestPath,
                body: ["fields": [
                    "project": ["key": "STAR"],
                    "issuetype": ["name": "Bug"],
                    "summary": "Age filter missing on three domains"
                ]],
                configuration: HostControlToolConfiguration(
                    taskFolder: taskFolder,
                    runID: "run-1",
                    connectorsJSON: "{\"connectors\":[]}",
                    environment: [:]
                )
            )
            return TaskStagedConnectorMutation(
                runID: run.id,
                serviceType: staged.serviceType,
                operation: staged.operation,
                connectorID: staged.connectorID,
                connectorAlias: staged.connectorAlias,
                target: staged.target,
                summary: staged.summary,
                stagedPayloadPath: staged.path,
                requestDigest: staged.digest
            )
        }

        func recordStagedEvent(_ pending: TaskStagedConnectorMutation) throws {
            context.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: ConnectorMutationEventTypes.staged,
                payload: pending,
                run: run
            ))
            try context.save()
        }
    }
}

/// Stands in for the store being unwritable at the moment the receipt is saved.
private struct FixtureSaveFailure: LocalizedError {
    static let message = "the task store could not be written"
    var errorDescription: String? { Self.message }
}

private final class RecordingSender: ConnectorMutationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ConnectorMutationHTTPRequest] = []
    let response: ConnectorMutationHTTPResponse

    init(response: ConnectorMutationHTTPResponse = ConnectorMutationHTTPResponse(statusCode: 201, body: "{}")) {
        self.response = response
    }

    var requests: [ConnectorMutationHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return response
    }
}

private struct FixtureSecretStore: SecretStore {
    let values: [String: String]

    func load(key: String, entityID _: String) -> String? { values[key] }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID _: String) -> Bool { values[key] != nil }
}
