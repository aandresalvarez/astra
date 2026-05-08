import Foundation
import Testing
@testable import ASTRA

@Suite("Connector Preflight")
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
