import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Jira project scope preserves credential identity")
@MainActor
struct JiraScopedCredentialPreflightTests {
    @Test("Editor and task preflight authenticate the same account for every project scope",
          arguments: ["Jira STAR-42", "Jira SS-42", "Jira SS and STAR", "Check Jira"],
          ["generation", "legacy-id", "legacy-provenance"])
    func scopedCredentials(context: String, identity: String) async throws {
        let connector = makeConnector()
        let store = MockSecretStore()
        if identity == "generation" { connector.credentialNamespaceID = UUID() }
        let entityIDs = KeychainSecretStore.connectorEntityIDs(for: connector)
        let entityID = try #require(identity == "legacy-provenance" ? entityIDs.last : entityIDs.first)
        store.save(key: "JIRA_EMAIL", value: "fixture@example.test", entityID: entityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "fixture-token", entityID: entityID, label: nil)
        if identity == "generation" {
            // An old slot must never silently substitute a different account.
            let legacy = KeychainSecretStore.connectorEntityID(for: connector.id)
            store.save(key: "JIRA_EMAIL", value: "other@example.test", entityID: legacy, label: nil)
            store.save(key: "JIRA_API_TOKEN", value: "other-token", entityID: legacy, label: nil)
        }
        let before = PluginAccountRecord.forLaunch(connector)
        let editor = AuthenticatedPermissionsTransport()
        let editorResult = await connector.testConnection(store: store, transport: editor)
        #expect(editorResult.0)
        #expect(editor.projects == ["SS", "STAR"])

        let runtime = AuthenticatedPermissionsTransport()
        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: [connector], store: store, transport: runtime, contextText: context
        )
        #expect(issue == nil)
        let expected = context == "Jira STAR-42" ? ["STAR"] : context == "Jira SS-42" ? ["SS"] : ["SS", "STAR"]
        #expect(runtime.projects == expected)
        #expect(!runtime.requests.isEmpty)
        #expect(runtime.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == editor.requests.first?.value(forHTTPHeaderField: "Authorization") })
        #expect(PluginAccountRecord.forLaunch(connector) == before)
        #expect(connector.modelContext == nil)
    }

    @Test("A missing selected generation does not fall back to old account credentials")
    func missingGenerationFailsClosed() async {
        let connector = makeConnector()
        connector.credentialNamespaceID = UUID()
        let store = MockSecretStore()
        let legacy = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_EMAIL", value: "fixture@example.test", entityID: legacy, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "fixture-token", entityID: legacy, label: nil)
        let transport = AuthenticatedPermissionsTransport()
        let issue = await ConnectorPreflightService.firstBlockingIssue(
            connectors: [connector], store: store, transport: transport, contextText: "Jira STAR-42"
        )
        #expect(issue != nil)
        #expect(transport.requests.isEmpty)
    }

    private func makeConnector() -> Connector {
        let connector = Connector(name: "Fixture Jira", serviceType: "jira",
                                  baseURL: "https://fixture.atlassian.net", authMethod: "basic")
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = ["SS,STAR"]
        connector.originPackageID = "jira-workflow"
        connector.originComponentID = "jira"
        connector.originComponentKind = "connector"
        connector.createdAt = Date(timeIntervalSince1970: 100)
        connector.updatedAt = Date(timeIntervalSince1970: 200)
        return connector
    }
}

private final class AuthenticatedPermissionsTransport: ConnectorHTTPTransport {
    private(set) var requests: [URLRequest] = []
    var projects: [String] {
        requests.compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "projectKey" }?.value
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let auth = "Basic " + Data("fixture@example.test:fixture-token".utf8).base64EncodedString()
        let valid = request.value(forHTTPHeaderField: "Authorization") == auth
        let response = try #require(HTTPURLResponse(url: url, statusCode: valid ? 200 : 401,
                                                    httpVersion: nil, headerFields: nil))
        let body = #"{"permissions":{"BROWSE_PROJECTS":{"havePermission":true},"CREATE_ISSUES":{"havePermission":true}}}"#
        return (Data(body.utf8), response)
    }
}
