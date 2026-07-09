import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

@Suite("Connector Preflight")
@MainActor
struct ConnectorPreflightServiceTests {
    @Test("Non-blocking connector types do not preflight before launch")
    func nonBlockingConnectorsDoNotPreflight() async throws {
        let connector = Connector(name: "GitHub", serviceType: "github", baseURL: "https://api.github.com", authMethod: "bearer")
        let transport = PreflightMockTransport(stubs: [])

        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: [connector],
            store: MockSecretStore(),
            transport: transport
        )

        #expect(issue == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test("Jira connector only preflights when the task asks for Jira")
    func jiraConnectorRequiresRelevantTaskText() {
        let connector = Connector(name: "Jira", serviceType: "jira", baseURL: "https://example.atlassian.net/", authMethod: "basic")

        #expect(ConnectorPreflightService.connectorsRequiringPreflight(
            from: [connector],
            contextText: "Summarize this Swift file"
        ).isEmpty)

        #expect(ConnectorPreflightService.connectorsRequiringPreflight(
            from: [connector],
            contextText: "Create stories for the next sprint in Jira"
        ).map(\.id) == [connector.id])
    }

    @Test("Jira auth failure blocks launch before the agent guesses")
    func jiraAuthFailureBlocksLaunch() async throws {
        let (connector, store) = makePreflightJiraConnector()
        let transport = PreflightMockTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 401,
                body: #"{"errorMessages":["Client must be authenticated to access this resource."]}"#
            ),
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 401,
                body: #"{"errorMessages":["Client must be authenticated to access this resource."]}"#
            )
        ])

        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: [connector],
            store: store,
            transport: transport
        )

        let unwrapped = try #require(issue)
        #expect(unwrapped.serviceType == "jira")
        #expect(unwrapped.message.contains("rejected the credentials"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/mypermissions",
            "/rest/api/3/myself"
        ])
    }

    @Test("Jira connector with project permissions passes preflight")
    func jiraProjectPermissionsPassPreflight() async throws {
        let (connector, store) = makePreflightJiraConnector(projects: "STAR")
        let transport = PreflightMockTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: preflightPermissionsJSON(browse: true)
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["projectKey=STAR", "BROWSE_PROJECTS"],
                statusCode: 200,
                body: preflightPermissionsJSON(browse: true, create: true)
            )
        ])

        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: [connector],
            store: store,
            transport: transport
        )

        #expect(issue == nil)
    }

    @Test("Valid Jira connector can satisfy preflight when a stale connector fails first")
    func validJiraConnectorSatisfiesPreflightWhenStaleConnectorFailsFirst() async throws {
        let staleConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://yourcompany.atlassian.net",
            authMethod: "basic"
        )
        staleConnector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]

        let (validConnector, store) = makePreflightJiraConnector(projects: "STAR")
        validConnector.name = "Jira-new"
        validConnector.baseURL = "https://stanfordmed.atlassian.net"

        let transport = PreflightMockTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: preflightPermissionsJSON(browse: true)
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["projectKey=STAR", "BROWSE_PROJECTS"],
                statusCode: 200,
                body: preflightPermissionsJSON(browse: true, create: true)
            )
        ])

        let candidates = ConnectorPreflightService.connectorsRequiringPreflight(
            from: [staleConnector, validConnector],
            contextText: "Plan work for Jira story STAR-11892",
            store: store
        )
        #expect(candidates.map(\.id) == [validConnector.id])

        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: candidates,
            store: store,
            transport: transport,
            contextText: "Plan work for Jira story STAR-11892"
        )

        #expect(issue == nil)
        #expect(transport.requests.count == 2)
    }

    @Test("Jira preflight ranks the connector scoped to the requested project")
    func jiraPreflightRanksRequestedProjectConnector() async throws {
        let (ssConnector, store) = makePreflightJiraConnector(projects: "SS")
        ssConnector.name = "Jira SS"
        ssConnector.baseURL = "https://stanfordmed.atlassian.net"

        let (starConnector, _) = makePreflightJiraConnector(projects: "STAR")
        starConnector.name = "Jira STAR"
        starConnector.baseURL = "https://stanfordmed.atlassian.net"
        let starEntityID = KeychainSecretStore.connectorEntityID(for: starConnector.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: starEntityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "token", entityID: starEntityID, label: nil)

        let candidates = ConnectorPreflightService.connectorsRequiringPreflight(
            from: [ssConnector, starConnector],
            contextText: "Plan work for Jira story STAR-11892",
            store: store
        )

        #expect(candidates.map(\.id) == [starConnector.id, ssConnector.id])
    }

    @Test("Jira task preflight narrows configured projects to the requested project")
    func jiraTaskPreflightNarrowsToRequestedProject() async throws {
        let (connector, store) = makePreflightJiraConnector(projects: "SS,STAR")
        let transport = PreflightMockTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: preflightPermissionsJSON(browse: true)
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["projectKey=STAR", "BROWSE_PROJECTS"],
                statusCode: 200,
                body: preflightPermissionsJSON(browse: true, create: true)
            )
        ])

        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: [connector],
            store: store,
            transport: transport,
            contextText: "Create stories in Jira for project STAR"
        )

        #expect(issue == nil)
        #expect(transport.requests.count == 2)
        #expect(transport.requests.last?.url?.query?.contains("projectKey=STAR") == true)
        #expect(transport.requests.last?.url?.query?.contains("projectKey=SS") == false)
    }

    @Test("Launch preflight requests credential approval before HTTP connector egress")
    func launchPreflightRequestsCredentialApprovalBeforeHTTPConnectorEgress() async throws {
        let container = try makeConnectorPreflightContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Credential Gate", primaryPath: "/tmp/credential-gate")
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net/",
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.credentialKeys = ["JIRA_API_TOKEN"]
        let task = AgentTask(title: "Use Jira", goal: "Check Jira", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(connector)
        context.insert(task)
        context.insert(run)
        try context.save()

        let store = MockSecretStore()
        store.save(
            key: "JIRA_API_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )
        let expectedLabel = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_API_TOKEN")

        let result = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "test",
            contextText: "Check Jira permissions",
            secretStore: store
        )

        let approvalEvent = try #require(task.events.first {
            $0.type == TaskEventTypes.Tool.permissionApprovalRequested.rawValue
        })
        let payload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))

        #expect(result.status == .connectorCredentialApprovalRequired)
        #expect(result.detail == "Jira connector credential (1 configured credential)")
        #expect(task.status == .pendingUser)
        #expect(run.typedStopReason == .permissionApprovalRequired)
        #expect(payload.request == .connectorCredentials(
            connectorID: connector.id,
            displayName: "Jira connector credential (1 configured credential)",
            labels: [expectedLabel]
        ))
        #expect(payload.grants == [.credential(label: expectedLabel)])
        #expect(payload.displayMessage.contains(expectedLabel) == false)
        #expect(RuntimePermissionDecisionPresentation(payload: approvalEvent.payload).title == "Jira connector needs permission")
    }

    @Test("Launch preflight groups connector credentials into one redacted approval")
    func launchPreflightGroupsConnectorCredentialsIntoOneRedactedApproval() async throws {
        let container = try makeConnectorPreflightContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Credential Gate", primaryPath: "/tmp/credential-gate")
        let connector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            baseURL: "https://example.atlassian.net/",
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        let task = AgentTask(title: "Use Jira", goal: "Check Jira", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(connector)
        context.insert(task)
        context.insert(run)
        try context.save()

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: entityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "secret-token", entityID: entityID, label: nil)
        let emailLabel = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_EMAIL")
        let tokenLabel = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_API_TOKEN")

        let result = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "test",
            contextText: "Check Jira permissions",
            secretStore: store
        )

        let approvalEvent = try #require(task.events.first {
            $0.type == TaskEventTypes.Tool.permissionApprovalRequested.rawValue
        })
        let payload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        let presentation = RuntimePermissionApprovalNoticePresentation(
            notice: TaskRunNotice(
                id: UUID(),
                type: TaskEventTypes.Tool.permissionApprovalRequested.rawValue,
                payload: approvalEvent.payload
            )
        )

        #expect(result.status == .connectorCredentialApprovalRequired)
        #expect(result.detail == "Jira-new connector credentials (2 configured credentials)")
        #expect(Set(payload.grants) == Set([
            .credential(label: emailLabel),
            .credential(label: tokenLabel)
        ]))
        #expect(Set(PermissionBroker.structuredApprovalGrants(from: approvalEvent.payload)) == Set([
            .credential(label: emailLabel),
            .credential(label: tokenLabel)
        ]))
        #expect(payload.request == .connectorCredentials(
            connectorID: connector.id,
            displayName: "Jira-new connector credentials (2 configured credentials)",
            labels: [emailLabel, tokenLabel].sorted()
        ))
        #expect(Set(TaskRuntimePermissionOpenRequestStore.latestApprovalGrants(for: task)) == Set([
            .credential(label: emailLabel),
            .credential(label: tokenLabel)
        ]))
        #expect(payload.displayMessage.contains("JIRA_API_TOKEN") == false)
        #expect(payload.displayMessage.contains("JIRA_EMAIL") == false)
        #expect(payload.displayMessage.contains("connector:\(connector.id.uuidString)") == false)
        #expect(presentation.decision.title == "Jira-new connector needs permission")
        #expect(presentation.decision.summary == "ASTRA wants to expose 2 configured credentials from the Jira-new connector to this task's agent process.")
        #expect(presentation.rawPayload?.contains("JIRA_API_TOKEN") == false)
        #expect(presentation.rawPayload?.contains("connector:\(connector.id.uuidString)") == false)

        let oldRawLabel = "connector:\(connector.id.uuidString):JIRA_API_TOKEN"
        let oldRawMessage = """
        Permission requested for tool: \(oldRawLabel). ASTRA paused before allowing this run to continue.
        What ASTRA observed: \(oldRawLabel) request: \(oldRawLabel)
        Why approval is needed: Connector credential egress requires explicit first-use approval.
        What allowing does: Grants this provider request one time for this run.
        What to check: allow only if this action matches the task and the requested access is expected.
        Detail: \(oldRawLabel)
        Runtime grant: credential(\(oldRawLabel))
        """
        let oldPayload = PermissionApprovalEventPayload(
            brokerVersion: PermissionBroker.brokerVersion,
            providerID: .claudeCode,
            request: .credential(label: oldRawLabel),
            decision: .askUser(message: oldRawMessage, grants: [.credential(label: oldRawLabel)]),
            grants: [.credential(label: oldRawLabel)],
            displayMessage: oldRawMessage
        ).encodedString() ?? oldRawMessage
        let oldPresentation = RuntimePermissionApprovalNoticePresentation(
            notice: TaskRunNotice(
                id: UUID(),
                type: TaskEventTypes.Tool.permissionApprovalRequested.rawValue,
                payload: oldPayload
            )
        )

        #expect(oldPresentation.decision.title == "Connector credentials need permission")
        #expect(oldPresentation.decision.summary.contains("configured connector credentials"))
        #expect(oldPresentation.decision.compactAuditSummary.contains("JIRA_API_TOKEN") == false)
        #expect(oldPresentation.rawPayload?.contains("JIRA_API_TOKEN") == false)
        #expect(oldPresentation.rawPayload?.contains("connector:\(connector.id.uuidString)") == false)

        let unstructuredLegacyPresentation = RuntimePermissionApprovalNoticePresentation(
            notice: TaskRunNotice(
                id: UUID(),
                type: TaskEventTypes.Tool.permissionApprovalRequested.rawValue,
                payload: oldRawMessage
            )
        )
        #expect(unstructuredLegacyPresentation.decision.title == "Connector credentials need permission")
        #expect(unstructuredLegacyPresentation.decision.summary.contains("configured connector credentials"))
        #expect(unstructuredLegacyPresentation.decision.compactAuditSummary.contains("JIRA_API_TOKEN") == false)
        #expect(unstructuredLegacyPresentation.rawPayload?.contains("JIRA_API_TOKEN") == false)
        #expect(unstructuredLegacyPresentation.rawPayload?.contains("connector:\(connector.id.uuidString)") == false)

        let summaryPayload = """
        {
          "status": "completed",
          "environmentKeyNames": ["JIRA_EMAIL", "JIRA_API_TOKEN", "CLIENT_ID", "PATH"],
          "credentialLabels": ["JIRA_EMAIL", "CLIENT_ID"],
          "approvalGrantDescriptions": [
            "credential(\(ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_EMAIL")))",
            "credential(\(oldRawLabel))"
          ],
          "approvalsGranted": []
        }
        """
        let summary = try #require(PolicySummaryPresentation(
            manifest: nil,
            permissionSummaryPayload: summaryPayload
        ))
        let environmentFact = try #require(summary.facts.first { $0.title == "Env keys" })

        #expect(environmentFact.value.contains("PATH"))
        #expect(environmentFact.value.contains("connector credential"))
        #expect(environmentFact.value.contains("JIRA_API_TOKEN") == false)
        #expect(environmentFact.value.contains("JIRA_EMAIL") == false)
        #expect(environmentFact.value.contains("CLIENT_ID") == false)
        #expect(summary.rawPayload?.contains("JIRA_API_TOKEN") == false)
        #expect(summary.rawPayload?.contains("JIRA_EMAIL") == false)
        #expect(summary.rawPayload?.contains("CLIENT_ID") == false)
        #expect(summary.rawPayload?.contains("connector:\(connector.id.uuidString)") == false)
    }

    @Test("Auto exposes configured connector credentials without an approval stop")
    func autoBypassesConnectorCredentialApproval() async throws {
        let container = try makeConnectorPreflightContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Auto Credential", primaryPath: "/tmp/auto-credential")
        let connector = Connector(
            name: "Internal API",
            serviceType: "custom_api",
            baseURL: "https://api.example.test/",
            authMethod: "bearer"
        )
        connector.workspace = workspace
        connector.credentialKeys = ["API_TOKEN"]
        let task = AgentTask(title: "Use API", goal: "Use the Internal API connector", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(connector)
        context.insert(task)
        context.insert(run)
        try context.save()

        let store = MockSecretStore()
        store.save(
            key: "API_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )
        let credentialLabel = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "API_TOKEN")
        let staleRequest = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .connectorCredentials(
                connectorID: connector.id,
                displayName: "Internal API connector credential (1 configured credential)",
                labels: [credentialLabel]
            ),
            reason: "Connector credential access requires approval outside Auto mode.",
            grants: [.credential(label: credentialLabel)],
            requestID: "stale-auto-request"
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: staleRequest, task: task)
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))

        let result = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task,
            run: run,
            modelContext: context,
            phase: "test",
            contextText: task.goal,
            permissionPolicy: .autonomous,
            secretStore: store
        )

        #expect(result.didPass)
        #expect(!task.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalRequested.rawValue })
        #expect(task.events.contains {
            $0.type == TaskEventTypes.System.info.rawValue &&
                $0.payload.contains("Auto mode superseded 1 pending provider permission request")
        })
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
        #expect(run.typedStopReason != .permissionApprovalRequired)
    }

    @Test("Auto honors a typed tombstone over legacy events and preserves a later sandbox approval")
    func autoHonorsTypedTombstoneAndPreservesLaterSandboxApproval() async throws {
        let container = try makeConnectorPreflightContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Auto Sequence", primaryPath: "/tmp/auto-sequence")
        let connector = Connector(
            name: "Internal API Sequence",
            serviceType: "custom_api",
            baseURL: "https://api.example.test/",
            authMethod: "bearer"
        )
        connector.workspace = workspace
        connector.credentialKeys = ["JIRA_API_TOKEN"]
        let task = AgentTask(title: "Auto Sequence", goal: "Use the Internal API connector", workspace: workspace)
        let firstRun = TaskRun(task: task)
        context.insert(workspace)
        context.insert(connector)
        context.insert(task)
        context.insert(firstRun)

        let credentialLabel = ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_API_TOKEN")
        let legacyPayload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .credential(label: credentialLabel),
            reason: "Legacy connector credential request.",
            grants: [.credential(label: credentialLabel)]
        )
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: legacyPayload
        ))
        task.runtimePermissionOpenRequestsJSON = "[]"

        let store = MockSecretStore()
        store.save(
            key: "JIRA_API_TOKEN",
            value: "secret-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )
        try context.save()

        let firstResult = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task,
            run: firstRun,
            modelContext: context,
            phase: "test",
            contextText: task.goal,
            permissionPolicy: .autonomous,
            secretStore: store
        )

        #expect(firstResult.didPass)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))

        let sandboxPayload = PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: .sandboxPath(path: "/tmp/auto-sequence/input", access: "read", toolName: "Bash"),
            reason: "The enabled sandbox denied this path.",
            grants: [.sandboxPath(path: "/tmp/auto-sequence/input", access: "read")],
            requestID: "sandbox-after-auto"
        )
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: sandboxPayload, task: task)
        let secondRun = TaskRun(task: task)
        context.insert(secondRun)

        let secondResult = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
            task: task,
            run: secondRun,
            modelContext: context,
            phase: "test",
            contextText: task.goal,
            permissionPolicy: .autonomous,
            secretStore: store
        )

        #expect(secondResult.didPass)
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task) == [sandboxPayload])
    }
}

private func makeConnectorPreflightContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func makePreflightJiraConnector(projects: String = "") -> (Connector, MockSecretStore) {
    let connector = Connector(
        name: "Jira",
        serviceType: "jira",
        baseURL: "https://example.atlassian.net/",
        authMethod: "basic"
    )
    connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
    if !projects.isEmpty {
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = [projects]
    }

    let store = MockSecretStore()
    let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
    store.save(key: "JIRA_EMAIL", value: "user@example.com", entityID: entityID, label: nil)
    store.save(key: "JIRA_API_TOKEN", value: "token", entityID: entityID, label: nil)
    return (connector, store)
}

private func preflightPermissionsJSON(browse: Bool, create: Bool? = nil) -> String {
    var permissions: [String] = [
        #""BROWSE_PROJECTS":{"havePermission":\#(browse)}"#
    ]
    if let create {
        permissions.append(#""CREATE_ISSUES":{"havePermission":\#(create)}"#)
    }
    return #"{"permissions":{\#(permissions.joined(separator: ","))}}"#
}

private final class PreflightMockTransport: ConnectorHTTPTransport {
    struct Stub {
        let path: String
        let queryContains: [String]
        let statusCode: Int
        let body: String
    }

    let stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let query = url.query ?? ""
        let stub = try #require(stubs.last { stub in
            url.path == stub.path && stub.queryContains.allSatisfy { query.contains($0) }
        })
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (Data(stub.body.utf8), response)
    }
}
