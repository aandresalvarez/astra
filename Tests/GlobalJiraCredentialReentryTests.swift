import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Global Jira credential recovery", .serialized)
struct GlobalJiraCredentialReentryTests {
    @Test("Global Jira refuses partial and invalid re-entry, then authenticates using the committed replacement pair")
    func globalJiraRecoversBothKeys() async throws {
        try await AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let account = Connector(name: "Jira-new", serviceType: "jira", baseURL: "https://jira.example.test", authMethod: "basic")
            account.isGlobal = true
            account.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
            account.credentialValues = ["", ""]
            env.context.insert(account)
            try env.context.save()
            let oldSlot = KeychainSecretStore.connectorEntityID(for: account.id)
            for (key, value) in ["JIRA_EMAIL": "old@example.test", "JIRA_API_TOKEN": "old-test-token"] {
                try #require(AstraSecureKeychainStore.save(service: oldSlot, account: key, value: value, label: nil))
            }
            let vault = JiraRefusingVault(refused: Set(KeychainSecretStore.connectorEntityIDs(for: account)))
            #expect(ConnectorCredentialEditor.unreadableKeys(of: account, vault: vault) == ["JIRA_API_TOKEN", "JIRA_EMAIL"])
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                _ = try ConnectorCredentialEditor.save(["JIRA_API_TOKEN": "new-test-token"], on: account,
                    modelContext: env.context, vault: vault)
            }
            let invalid = try ConnectorCredentialEditor.save(["JIRA_API_TOKEN": "new-test-token", "JIRA_EMAIL": "not-an-email"],
                on: account, modelContext: env.context, vault: vault)
            #expect(invalid?.key == "JIRA_EMAIL")
            #expect(invalid?.outcome.isSaved == false)
            #expect(account.credentialNamespaceID == nil)
            #expect(!env.context.hasChanges)
            #expect(AstraSecureKeychainStore.read(service: oldSlot, account: "JIRA_EMAIL") == .value("old@example.test"))
            #expect(AstraSecureKeychainStore.read(service: oldSlot, account: "JIRA_API_TOKEN") == .value("old-test-token"))

            #expect(throws: ConnectorCredentialEditor.Failure.saveFailed) {
                _ = try ConnectorCredentialEditor.save(["JIRA_API_TOKEN": "new-test-token", "JIRA_EMAIL": "new@example.test"],
                    on: account, modelContext: env.context, persist: { _ in throw CocoaError(.fileWriteUnknown) }, vault: vault)
            }
            #expect(!env.context.hasChanges)
            #expect(account.credentialNamespaceID == nil)

            // The real form also edits ordinary account metadata. Its Save
            // commits those edits before entering the clean credential boundary.
            account.connectorDescription = "Edited in the account form"
            #expect(throws: ConnectorCredentialEditor.Failure.pendingEdits) {
                _ = try ConnectorCredentialEditor.save(["JIRA_API_TOKEN": "new-test-token", "JIRA_EMAIL": "new@example.test"],
                    on: account, modelContext: env.context, vault: vault)
            }
            try #require(CapabilityPersistence.saveResourceMutation(workspace: env.workspace,
                isGlobal: account.isGlobal, modelContext: env.context))
            #expect(!env.context.hasChanges)

            let failure = try ConnectorCredentialEditor.save(["JIRA_API_TOKEN": "new-test-token", "JIRA_EMAIL": "new@example.test"],
                on: account, modelContext: env.context, vault: vault)
            #expect(failure == nil)
            #expect(account.credentialNamespaceID != nil)
            #expect(ConnectorCredentialEditor.unreadableKeys(of: account, vault: vault).isEmpty)
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first { $0.id == account.id })
            #expect(saved.isGlobal && saved.originPackageID == nil)
            #expect(saved.connectorDescription == "Edited in the account form")
            let result = await saved.testConnection(store: KeychainSecretStore(), transport: JiraPermissionTransport())
            #expect(result.0)
            #expect(result.1.contains("BROWSE_PROJECTS"))
        }
    }
}

private struct JiraPermissionTransport: ConnectorHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        #expect(url.host == "jira.example.test")
        #expect(url.path == "/rest/api/3/mypermissions")
        #expect(request.httpMethod == "GET")
        let expected = "Basic " + Data("new@example.test:new-test-token".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(#"{"permissions":{"BROWSE_PROJECTS":{"havePermission":true}}}"#.utf8), response)
    }
}


private struct JiraRefusingVault: SecretStore {
    let refused: Set<String>
    private let real = KeychainSecretStore()
    init(refused: Set<String>) { self.refused = refused }
    func read(key: String, entityID: String) -> SecretReadOutcome {
        refused.contains(entityID) ? .unavailable : real.read(key: key, entityID: entityID)
    }
    func load(key: String, entityID: String) -> String? {
        refused.contains(entityID) ? nil : real.load(key: key, entityID: entityID)
    }
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        real.save(key: key, value: value, entityID: entityID, label: label)
    }
    func delete(key: String, entityID: String) -> Bool { real.delete(key: key, entityID: entityID) }
    func deleteAll(entityID: String) { real.deleteAll(entityID: entityID) }
    func exists(key: String, entityID: String) -> Bool {
        !refused.contains(entityID) && real.exists(key: key, entityID: entityID)
    }
}
