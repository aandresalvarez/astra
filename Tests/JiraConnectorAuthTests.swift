import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Jira Connector Auth")
struct JiraConnectorAuthTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // testConnection() needs ConnectorAuditLoggingSeam

    @Test("Jira test authenticates with permission probe first")
    func permissionProbeAuthenticatesBeforeMyself() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
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
            "/rest/api/3/mypermissions"
        ])
    }

    @Test("Jira test normalizes service type before selecting auth tester")
    func jiraServiceTypeIsCaseInsensitive() async throws {
        let (connector, store) = makeConnector(serviceType: "Jira")
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(result.0)
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/mypermissions"
        ])
    }

    @Test("Generic connector test preserves query parameters embedded in test path")
    func genericConnectorTestPreservesEmbeddedQueryParameters() async throws {
        let connector = Connector(
            name: "Confluence",
            serviceType: "confluence",
            baseURL: "https://example.atlassian.net/wiki",
            authMethod: "none"
        )
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/wiki/rest/api/content",
                queryContains: ["limit=1"],
                statusCode: 200,
                body: #"{"results":[]}"#
            )
        ])

        let result = await connector.testConnection(store: MockSecretStore(), transport: transport)

        #expect(result.0)
        #expect(transport.requests.first?.url?.path == "/wiki/rest/api/content")
        #expect(transport.requests.first?.url?.query == "limit=1")
    }

    @Test("REDCap connector validation uses form POST by default")
    func redcapConnectorValidationUsesFormPostByDefault() async throws {
        let connector = Connector(
            name: "REDCap",
            serviceType: "redcap",
            baseURL: "https://redcap.stanford.edu/api/",
            authMethod: "api_key"
        )
        connector.credentialKeys = ["REDCAP_API_TOKEN"]
        let store = MockSecretStore()
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "redcap-token",
            entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
            label: nil
        )
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(path: "/api/", queryContains: [], statusCode: 200, body: #"{"ok":true}"#),
            .init(path: "/api", queryContains: [], statusCode: 200, body: #"{"ok":true}"#)
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(result.0)
        #expect(transport.requests.first?.httpMethod == "POST")
        let body = String(data: transport.requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("content=version"))
        #expect(body.contains("token=redcap-token"))
    }

    @Test("Jira auth outcome includes redacted credential health evidence")
    func jiraOutcomeIncludesCredentialEvidence() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
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

    @Test("Jira test accepts mypermissions success even when myself would fail")
    func permissionsSuccessOverridesMyselfFailure() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: true)
            ),
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 401,
                body: #"{"errorMessages":["Unauthorized"]}"#
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(result.0)
        #expect(result.1.contains("BROWSE_PROJECTS"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/mypermissions"
        ])
    }

    @Test("Jira test reports missing global Browse Projects permission")
    func missingBrowseProjectsIsDistinctFromInvalidToken() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 200,
                body: permissionsJSON(browse: false)
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("BROWSE_PROJECTS"))
        #expect(!result.1.localizedCaseInsensitiveContains("invalid"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/mypermissions"
        ])
    }

    @Test("Jira test reports project visibility separately from invalid token")
    func projectNotVisibleIsDistinctFromInvalidToken() async throws {
        let (connector, store) = makeConnector(projects: "ENG")
        let transport = MockConnectorHTTPTransport(stubs: [
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

    @Test("Jira read-only auth accepts project Browse permission without Create Issues")
    func projectBrowsePermissionDoesNotRequireCreateIssues() async throws {
        let (connector, store) = makeConnector(projects: "ENG")
        let transport = MockConnectorHTTPTransport(stubs: [
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

        #expect(result.0)
        #expect(result.1.contains("BROWSE_PROJECTS"))
        #expect(!result.1.contains("CREATE_ISSUES"))
        #expect(!result.1.localizedCaseInsensitiveContains("invalid"))
        #expect(transport.requests.last?.url?.query?.contains("permissions=BROWSE_PROJECTS") == true)
        #expect(transport.requests.last?.url?.query?.contains("CREATE_ISSUES") == false)
    }

    @Test("Jira test only reports auth failure when all auth probes are rejected")
    func allAuthProbesRejectedMeansAuthFailed() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 401,
                body: #"{"errorMessages":["Unauthorized"]}"#
            ),
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
        #expect(result.1.contains("both permission and account probes"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/mypermissions",
            "/rest/api/3/myself"
        ])
    }

    @Test("Jira test treats permission endpoint 401 with successful myself fallback as scope failure")
    func myselfFallbackSuccessMakesPermissions401ScopeFailure() async throws {
        let (connector, store) = makeConnector()
        let transport = MockConnectorHTTPTransport(stubs: [
            .init(
                path: "/rest/api/3/mypermissions",
                queryContains: ["permissions=BROWSE_PROJECTS"],
                statusCode: 401,
                body: #"{"errorMessages":["Unauthorized"]}"#
            ),
            .init(
                path: "/rest/api/3/myself",
                queryContains: [],
                statusCode: 200,
                body: #"{"accountId":"abc"}"#
            )
        ])

        let result = await connector.testConnection(store: store, transport: transport)

        #expect(!result.0)
        #expect(result.1.contains("permission endpoint was rejected"))
        #expect(result.1.contains("scopes"))
        #expect(!result.1.localizedCaseInsensitiveContains("invalid"))
        #expect(transport.requests.map { $0.url?.path } == [
            "/rest/api/3/mypermissions",
            "/rest/api/3/myself"
        ])
    }
}

private func makeConnector(serviceType: String = "jira", projects: String = "") -> (Connector, MockSecretStore) {
    let connector = Connector(
        name: "Jira",
        serviceType: serviceType,
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
