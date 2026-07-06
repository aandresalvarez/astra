import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Connector Preflight")
@MainActor
struct ConnectorPreflightServiceTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // firstBlockingIssue -> testConnection() needs ConnectorAuditLoggingSeam

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
        #expect(result.detail == expectedLabel)
        #expect(task.status == .pendingUser)
        #expect(run.typedStopReason == .permissionApprovalRequired)
        #expect(payload.request == .credential(label: expectedLabel))
        #expect(payload.grants == [.credential(label: expectedLabel)])
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
