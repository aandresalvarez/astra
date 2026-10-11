import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence
import ASTRACore

// Deleting a connector must never remove a Keychain namespace another stored
// connector still reads: a connector recreated under a new ID shares the old
// one's stable endpoint or package namespace.

private func credentialCleanupContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

/// A temporary dedicated keychain, installed through task-locals only, so
/// these reads and writes never reach the developer's real Keychain.
private func withTemporaryCredentialKeychain<T>(_ body: () throws -> T) rethrows -> T {
    let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
    let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
    AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
    defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: []) }
    return try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
        try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
            try body()
        }
    }
}

private func credentialPackage(id: String) -> PluginPackage {
    var package = PluginPackage(
        id: id, name: id, icon: "link", description: "d",
        author: "a", category: "c", tags: [], version: "1.0.0",
        skills: [],
        connectors: [PluginConnector(
            name: "\(id) Connector", serviceType: "svc-\(id)", icon: "link",
            description: "d", baseURL: "https://\(id).example.com", authMethod: "api_key",
            credentialHints: [.init(key: "SVC_TOKEN", hint: "h")],
            configHints: [], notes: ""
        )],
        localTools: [], templates: []
    )
    package.governance = .builtInApproved(riskLevel: .medium)
    return package
}

/// A connector with `original`'s namespace-defining facts under a new ID.
private func recreation(of original: Connector) -> Connector {
    let copy = Connector(name: original.name, serviceType: original.serviceType, baseURL: original.baseURL)
    copy.originPackageID = original.originPackageID
    copy.originComponentID = original.originComponentID
    return copy
}

@Suite("Connector credential cleanup", .serialized)
@MainActor
struct ConnectorCredentialCleanupTests {
    @Test("A deleted connector's cleanup keeps the stable namespace a recreated connector still reads")
    func cleanupSparesSharedStableNamespace() throws {
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        try withTemporaryCredentialKeychain {
            let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
            let recreated = recreation(of: deleted)
            context.insert(deleted)
            context.insert(recreated)
            try context.save()
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: deleted))
            let own = KeychainSecretStore.connectorEntityID(for: deleted.id)
            #expect(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "shared", label: nil))
            #expect(AstraSecureKeychainStore.save(service: own, account: "TOKEN", value: "own", label: nil))

            let cleanup = deleted.keychainCleanup
            context.delete(deleted)
            try context.save()
            #expect(ConnectorCredentialCleanup.run([cleanup], modelContext: context))
            #expect(KeychainService.load(key: "TOKEN", connector: recreated) == "shared")
            #expect(AstraSecureKeychainStore.load(service: own, account: "TOKEN") == nil)

            // Once nothing shares it, the stable namespace goes too.
            let last = recreated.keychainCleanup
            context.delete(recreated)
            try context.save()
            #expect(ConnectorCredentialCleanup.run([last], modelContext: context))
            #expect(AstraSecureKeychainStore.load(service: stable, account: "TOKEN") == nil)
        }
    }

    @Test("Disabling a package keeps the credentials a recreated connector outside it still reads")
    func disableSparesSharedNamespace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-credential-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try credentialCleanupContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Shared", primaryPath: root.path)
        context.insert(workspace)
        let package = credentialPackage(id: "shared-pkg")
        let installer = CapabilityInstaller(library: CapabilityLibrary(directory: root), appVersion: SemanticVersion(1, 0, 0))

        try withTemporaryCredentialKeychain {
            _ = try installer.install(
                package, into: workspace, modelContext: context, credentialInputs: ["SVC_TOKEN": "secret-value"]
            )
            let installed = try #require(workspace.connectors.first)
            let recreated = recreation(of: installed)
            recreated.isGlobal = true
            context.insert(recreated)
            try context.save()
            #expect(KeychainService.load(key: "SVC_TOKEN", connector: recreated) == "secret-value")

            let capabilities = WorkspaceCapabilities(
                workspace: workspace,
                globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })),
                globalConnectors: try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
            )
            let installedID = installed.id
            let result = CapabilityActivationDisabler().disable(
                package, in: workspace, capabilities: capabilities, modelContext: context, availablePackages: [package]
            )
            #expect(result.removedWorkspaceConnectorIDs == [installedID])
            #expect(KeychainService.load(key: "SVC_TOKEN", connector: recreated) == "secret-value")
            #expect(KeychainService.load(key: "SVC_TOKEN", connectorID: installedID) == nil)
        }
    }
}
