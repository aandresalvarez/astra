import Foundation
import Testing
@testable import ASTRA

@Suite("Jira Connector Auth")
struct JiraConnectorAuthTests {

    @Test("Jira test authenticates with myself before trusting permissions")
    func myselfAuthenticatesBeforePermissions() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 200,
                body: #"{"accountId":"abc"}"#
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(result.0)
        #expect(result.1.contains("BROWSE_PROJECTS"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/myself",
            "/rest/api/3/mypermissions"
        ])
    }

    @Test("Jira auth outcome includes redacted credential health evidence")
    func jiraOutcomeIncludesCredentialEvidence() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 200,
                body: #"{"accountId":"abc"}"#
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            )
        ])

        let outcome = await JiraConnectorAuthTester(
            connectorID: connector.id,
            baseURL: try #require(URL(string: connector.baseURL)),
            authMethod: connector.authMethod,
            credentials: connector.credentials(store: store),
            config: connector.config,
            transport: transport
        ).test()

        #expect(outcome.success)
        #expect(outcome.fields["credential_evidence"] == "connector_auth_v1")
        #expect(outcome.fields["credential_state"] == "authenticated")
        #expect(outcome.fields["auth_verified"] == "true")
        #expect(!outcome.fields.keys.contains("JIRA_API_TOKEN"))
    }

    @Test("Jira test rejects anonymous permission responses when myself fails")
    func anonymousPermissionsDoNotAuthenticateConnector() async throws {
        let (connector, store) = makeConnector(projects: "SS")
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 401,
                body: #"{"errorMessages":["Unauthorized"]}"#
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.localizedCaseInsensitiveContains("rejected the credentials"))
        #expect(result.1.localizedCaseInsensitiveContains("email"))
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.url?.path == "/rest/api/3/myself")
    }

    @Test("Jira test reports project visibility separately from invalid token")
    func projectNotVisibleIsDistinctFromInvalidToken() async throws {
        let (connector, store) = makeConnector(projects: "ENG")
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 200,
                body: #"{"accountId":"abc"}"#
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["projectKey=ENG"],
                statusCode: 404,
                body: #"{"errorMessages":["No project could be found"]}"#
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("not visible"))
        #expect(!result.1.localizedCaseInsensitiveContains("invalid"))
    }

    @Test("Jira test reports missing CREATE_ISSUES separately from invalid token")
    func missingCreateIssuesIsDistinctFromInvalidToken() async throws {
        let (connector, store) = makeConnector(projects: "ENG")
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 200,
                body: #"{"accountId":"abc"}"#
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["projectKey=ENG"],
                statusCode: 200,
                body: permissionsJSON(browse: true, create: false)
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("CREATE_ISSUES"))
        #expect(result.1.contains("ENG"))
        #expect(!result.1.localizedCaseInsensitiveContains("invalid"))
    }

    @Test("Jira test only reports auth failure when all auth probes are rejected")
    func allAuthProbesRejectedMeansAuthFailed() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 401,
                body: #"{"errorMessages":["Unauthorized"]}"#,
                headers: ["x-seraph-loginreason": "AUTHENTICATED_FAILED"]
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("rejected the credentials"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/myself"
        ])
    }

    @Test("Jira test treats permission endpoint 401 with successful myself as scope failure")
    func myselfSuccessMakesPermissions401ScopeFailure() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 200,
                body: #"{"accountId":"abc"}"#
            ),
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 401,
                body: #"{"errorMessages":["Unauthorized"]}"#
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("permission endpoint was rejected"))
        #expect(result.1.contains("scopes"))
        #expect(!result.1.localizedCaseInsensitiveContains("invalid"))
    }
}

private func makeConnector(projects: String = "") -> (Connector, MockSecretStore) {
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

private func permissionsJSON(browse: Bool, create: Bool? = nil) -> String {
    var permissions: [String] = [
        #""BROWSE_PROJECTS":{"havePermission":\#(browse)}"#
    ]
    if let create {
        permissions.append(#""CREATE_ISSUES":{"havePermission":\#(create)}"#)
    }
    return #"{"permissions":{\#(permissions.joined(separator: ","))}}"#
}

private final class MockConnectorHTTPTransport: ConnectorHTTPTransport {
    struct Stub {
        let path: String
        let queryContains: [String]
        let statusCode: Int
        let body: String
        var headers: [String: String] = [:]
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
            headerFields: stub.headers
        ))
        return (Data(stub.body.utf8), response)
    }
}
