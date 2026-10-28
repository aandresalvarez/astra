import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Plugins presentation credential snapshot") @MainActor
struct PluginCredentialReadinessTests {
    @Test("Repeated presentation never reads secrets, and a generation change invalidates readiness")
    func presentationUsesStatusOnly() throws {
        let account = Connector(name: "Fixture", serviceType: "jira", baseURL: "https://fixture.atlassian.net", authMethod: "basic")
        account.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        account.credentialNamespaceID = UUID()
        let store = CountingStore()
        let status = PluginCredentialReadiness.load([PluginCredentialReadiness.Account(account)], store: store)
        #expect(store.reads == 2)
        for _ in 0..<100 {
            #expect(status.messages(for: account, requiredKeys: Set(account.credentialKeys)).isEmpty)
        }
        #expect(store.reads == 2)
        account.credentialNamespaceID = UUID()
        #expect(status.messages(for: account, requiredKeys: Set(account.credentialKeys)).contains { $0.contains("checking") })
    }

    @Test("Projected subsets retain readiness without requiring the original configuration")
    func projectedSubsetUsesSameCredentialIdentity() {
        let account = Connector(name: "Fixture", serviceType: "jira", authMethod: "basic")
        account.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        account.configKeys = ["JIRA_PROJECTS"]
        account.configValues = ["SS,STAR"]
        let status = PluginCredentialReadiness.load([PluginCredentialReadiness.Account(account)], store: CountingStore())
        let projected = TaskExecutionLaunchSnapshotApplicator.detachedConnector(account)
        projected.configValues = ["STAR"]
        projected.credentialKeys = ["JIRA_API_TOKEN"]
        #expect(status.messages(for: projected, requiredKeys: ["JIRA_API_TOKEN"]).isEmpty)
    }

    @Test("Unavailable credentials are distinct from missing and never reported ready")
    func refusedReadIsNotMissing() {
        let account = Connector(name: "Fixture", serviceType: "jira", authMethod: "basic")
        account.credentialKeys = ["JIRA_API_TOKEN"]
        let store = CountingStore(); store.outcome = .unavailable
        let status = PluginCredentialReadiness.load([PluginCredentialReadiness.Account(account)], store: store)
        let messages = status.messages(for: account, requiredKeys: ["JIRA_API_TOKEN"])
        #expect(messages.count == 1 && messages[0].contains("couldn't read"))
        store.outcome = .missing
        let missing = PluginCredentialReadiness.load([PluginCredentialReadiness.Account(account)], store: store)
        #expect(missing.messages(for: account, requiredKeys: ["JIRA_API_TOKEN"]).contains { $0.contains("missing Keychain") })
    }
    @Test("A forty-plugin presentation reuses preloaded definitions and status without reading secrets")
    func fortyPluginPresentation() throws {
        let workspace = Workspace(name: "Synthetic catalog", primaryPath: "/tmp/synthetic-plugin-catalog")
        var packages: [PluginPackage] = []
        var accounts: [Connector] = []
        for index in 0..<40 {
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = "presentation-\(index)"
            package.name = "Presentation \(index)"
            package.localTools = []
            packages.append(package)
            WorkspaceCapabilityActivation.mutate(workspace) {
                $0.enableCapability(package.id)
                $0.recordInstalledPlugin(id: package.id, version: package.version)
            }
            WorkspaceCapabilityActivation.recordAccepted(pluginID: package.id, version: package.version,
                digest: PluginDefinitionDigest.content(of: package), in: workspace)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
            WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: package), on: activation)
            let connector = Connector(name: "Fixture \(index)", serviceType: "tracker",
                baseURL: "https://tracker.example.com", authMethod: "bearer")
            connector.credentialNamespaceID = UUID()
            connector.credentialKeys = ["TRACKER_TOKEN"]
            connector.workspace = workspace
            WorkspaceCapabilityActivation.bind(connector, toComponent: CapabilityResourceOrigin.componentID(for: package.connectors[0]),
                of: activation, isDefault: true)
            accounts.append(connector)
        }
        let secrets = CountingStore()
        let readiness = PluginCredentialReadiness.load(accounts.map(PluginCredentialReadiness.Account.init), store: secrets)
        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: packages,
            approvalRecords: [], packPolicy: .empty)
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: workspace, approvalRecords: [], packPolicy: .empty)
        let before = WorkspaceCapabilityActivation.snapshot(workspace)
        let renderSecrets = CountingStore(); renderSecrets.forbidReads = true
        var durations: [Double] = []
        for index in 0..<20 {
            let start = Date()
            let snapshot = PluginsSurfaceProjection.make(workspace: workspace, capabilities: capabilities,
                catalogPackages: packages, context: policy, credentialReadiness: readiness, secretStore: renderSecrets,
                statuses: [:], query: index.isMultiple(of: 2) ? "" : "Presentation", isRemovable: { _ in true })
            #expect(snapshot.rows.count == 40)
            try #require(snapshot.state.ready.count == 40 && snapshot.state.actionNeeded.isEmpty, "Row: \(String(describing: snapshot.state.allRows.first))")
            durations.append(Date().timeIntervalSince(start) * 1000)
        }
        #expect(secrets.reads == 40 && renderSecrets.reads == 0)
        #expect(WorkspaceCapabilityActivation.snapshot(workspace) == before)
        durations.sort()
        print("PLUGIN_PRESENTATION_BENCHMARK packages=40 renders=20 median_ms=\(durations[10]) max_ms=\(durations.last ?? 0) secret_reads_during_render=0")
    }

}

private final class CountingStore: SecretStore {
    var reads = 0
    var forbidReads = false
    var outcome = SecretReadOutcome.value("synthetic-only")
    func read(key: String, entityID: String) -> SecretReadOutcome { reads += 1; if forbidReads { Issue.record("Presentation read the credential store") }; return outcome }
    func load(key: String, entityID: String) -> String? { Issue.record("Unexpected load"); return nil }
    func save(key: String, value: String, entityID: String, label: String?) -> Bool { Issue.record("Unexpected write"); return false }
    func delete(key: String, entityID: String) -> Bool { Issue.record("Unexpected delete"); return false }
    func deleteAll(entityID: String) { Issue.record("Unexpected deleteAll") }
    func exists(key: String, entityID: String) -> Bool { Issue.record("Unexpected exists"); return false }
}
