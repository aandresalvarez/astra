import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Account credential namespaces remain independent", .serialized)
struct PluginAccountNamespaceTests {
    @Test("An explicit generation neither reads nor overwrites the legacy UUID and endpoint aliases")
    func explicitNamespaceHasNoLegacyFallback() throws {
        let account = Connector(name: "Isolated", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "bearer")
        account.credentialKeys = ["API_TOKEN"]
        let store = MockSecretStore()
        let legacy = KeychainSecretStore.connectorEntityIDs(for: account)
        for id in legacy { #expect(store.save(key: "API_TOKEN", value: "legacy-value", entityID: id, label: nil)) }
        account.credentialNamespaceID = UUID()
        #expect(account.credentials(store: store).isEmpty)
        #expect(ConnectorSecretPersistence.saveCredential("new-value", key: "API_TOKEN",
            facts: ConnectorSecretFacts(connector: account), store: store))
        #expect(account.credentials(store: store)["API_TOKEN"] == "new-value")
        #expect(KeychainSecretStore.connectorEntityIDs(for: account).count == 1)
        for id in legacy { #expect(store.load(key: "API_TOKEN", entityID: id) == "legacy-value") }
    }

    @Test("A frozen account and attached snapshot preserve their generation through Codable")
    func frozenMetadataPreservesItsAlias() throws {
        let account = Connector(name: "Frozen", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "bearer")
        account.credentialKeys = ["API_TOKEN"]
        account.credentialNamespaceID = UUID()
        let store = MockSecretStore()
        #expect(ConnectorSecretPersistence.saveCredential("accepted", key: "API_TOKEN", facts: .init(connector: account), store: store))
        let record = try JSONDecoder().decode(PluginAccountRecord.self, from: JSONEncoder().encode(PluginAccountRecord(account)))
        let attached = try JSONDecoder().decode(ConnectorSnapshotConfig.self, from: JSONEncoder().encode(ConnectorSnapshotConfig(connector: account)))
        let accepted = account.credentialNamespaceID
        account.credentialNamespaceID = UUID()
        #expect(ConnectorSecretPersistence.saveCredential("current", key: "API_TOKEN", facts: .init(connector: account), store: store))
        #expect(record.makeAccount().credentials(store: store)["API_TOKEN"] == "accepted")
        #expect(attached.credentialNamespaceID == accepted)
        #expect(account.credentials(store: store)["API_TOKEN"] == "current")
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        old.removeValue(forKey: "credentialNamespaceID")
        #expect(try JSONDecoder().decode(PluginAccountRecord.self, from: JSONSerialization.data(withJSONObject: old)).credentialNamespaceID == nil)
    }

    @Test("Own recovery preserves the namespace, while a chosen file cannot borrow it or endpoint aliases")
    func recoveryAndChosenImportHaveDifferentAuthority() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let account = Connector(name: "Portable", serviceType: "custom", baseURL: "https://api.example.com", authMethod: "bearer")
        account.credentialKeys = ["API_TOKEN"]
        account.credentialNamespaceID = UUID()
        account.workspace = env.workspace
        env.context.insert(account)
        try env.context.save()
        let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        #expect(config.connectors?.first?.credentialNamespaceID == account.credentialNamespaceID)
        let recoveredStore = try container()
        let recovered = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: recoveredStore.mainContext,
            capabilityTrust: .preserveRecordedState).workspace
        let recoveredAccount = try #require(recovered.connectors.first)
        #expect(recoveredAccount.credentialNamespaceID == account.credentialNamespaceID)
        let selectedStore = try container()
        let selected = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: selectedStore.mainContext,
            capabilityTrust: .validate(.init(approvedPackageIDs: [], installedPackageIDs: [], availablePackIDs: []))).workspace
        let selectedAccount = try #require(selected.connectors.first)
        #expect(selectedAccount.credentialNamespaceID != nil && selectedAccount.credentialNamespaceID != account.credentialNamespaceID)
        let store = MockSecretStore()
        #expect(ConnectorSecretPersistence.saveCredential("private", key: "API_TOKEN", facts: .init(connector: account), store: store))
        #expect(recoveredAccount.credentials(store: store)["API_TOKEN"] == "private")
        #expect(selectedAccount.credentials(store: store).isEmpty)
        withExtendedLifetime((recoveredStore, selectedStore)) {}
    }

    @Test("A queued request owns its accepted generation, not every future generation of its logical account")
    func pendingRequestUsesNamespaceOwnership() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        let account = Connector(name: "Queued", serviceType: "custom", baseURL: "https://api.example.com")
        account.credentialNamespaceID = UUID()
        account.credentialKeys = ["API_TOKEN"]
        account.workspace = env.workspace
        env.context.insert(account)
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(env.package.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        WorkspaceCapabilityActivation.bind(account, toComponent: "connector:custom:api", of: activation, isDefault: true)
        let accepted = account.keychainCleanup
        let task = AgentTask(title: "Accepted account", goal: "Use its saved generation", workspace: env.workspace)
        env.context.insert(task)
        env.context.insert(TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, pluginDefinitions: []))
        try env.context.save()
        account.credentialNamespaceID = UUID()
        try env.context.save()
        let references = try #require(PendingTaskCredentialReferences.capture(modelContext: env.context))
        #expect(references.holdsAccount(accepted))
        #expect(!references.holdsAccount(account.keychainCleanup))
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
