import CoreData
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Plugins V21 migration", .serialized)
struct PluginV21MigrationTests {
    @Test("Original V20 remains byte-shape compatible with the existing Dev store")
    func originalV20Fingerprint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("fingerprint.store")
        do {
            let container = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV20.self),
                configurations: [ModelConfiguration(url: store)]
            )
            #expect(container.schema.entities.count == 19)
        }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: store)
        let digest = (metadata["NSStoreModelVersionHashesDigest"] as? String)
            ?? (metadata["NSStoreModelVersionHashesDigest"] as? Data)?.base64EncodedString()
        #expect(digest == "6cQiw2kBfDBspXv8xxBgAW4At3UeNNURek6kfI6rMYX3b7pzQkDnTUhCND9fdVJPVar6/Sm5/OqJmiWOsGa7Lw==")
        #expect(metadata["NSStoreModelVersionChecksumKey"] as? String == "uvXqoT2QHoqI1yo2j6ak39BCJrvsbou+4r5HwsWizNw=")
    }

    @Test("V20 aliases and the selected second account survive V21 migration and reopening", arguments: [false, true])
    func originalAccountChoices(shared: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let component = try #require(package.connectors.first)
        let componentID = CapabilityResourceOrigin.componentID(for: component)
        let store = root.appendingPathComponent("accounts.store")
        let ids = try writeOriginalStore(at: store, root: root, package: package, componentID: componentID, shared: shared)

        for pass in 0..<2 {
            let container = try ModelContainer(
                for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: store)]
            )
            container.mainContext.autosaveEnabled = false
            let context = container.mainContext
            if pass == 0 {
                #expect(ASTRASchema.currentVersion == 21)
                let report = try PluginActivationMigration.migrate(modelContext: context, packages: [package])
                #expect(report.activations == ids.workspaces.count)
            }
            let workspaces = try context.fetch(FetchDescriptor<Workspace>())
            let accounts = try context.fetch(FetchDescriptor<Connector>())
            #expect(Set(accounts.map(\.id)) == Set(ids.accounts))
            #expect(accounts.allSatisfy { $0.credentialNamespaceID == nil })
            for (index, id) in ids.workspaces.enumerated() {
                let workspace = try #require(workspaces.first { $0.id == id })
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
                #expect(activation.bindings.count == 2)
                let selected = index == 0 ? ids.accounts[1] : ids.accounts[0]
                #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == selected)
                for (accountID, expectedAlias) in zip(ids.accounts, ["Research", "Personal"]) {
                    let account = try #require(accounts.first { $0.id == accountID })
                    #expect(WorkspaceCapabilityActivation.alias(of: account, in: workspace) == expectedAlias)
                    #expect(account.accountAlias == expectedAlias)
                    #expect(account.name == "Jira \(expectedAlias)")
                }
            }
            #expect(!PluginActivationMigration.needsMigration(modelContext: context, packages: [package]))
            #expect(try PluginActivationMigration.migrate(modelContext: context, packages: [package]) == .init())
        }
    }

    @Test("The first V21 schema owns optional credential generations across reopening")
    func currentAccountGenerationReference() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("credential-reference.store")
        let namespace = UUID()
        let accountID: UUID
        do {
            let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: store)])
            let account = Connector(name: "Versioned account")
            accountID = account.id
            account.credentialNamespaceID = namespace
            container.mainContext.insert(account)
            container.mainContext.insert(Connector(name: "Legacy namespace"))
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: store)])
        let accounts = try reopened.mainContext.fetch(FetchDescriptor<Connector>())
        #expect(accounts.first { $0.id == accountID }?.credentialNamespaceID == namespace)
        #expect(accounts.first { $0.id != accountID }?.credentialNamespaceID == nil)
        #expect(accounts.count == 2)
    }

    private func writeOriginalStore(
        at store: URL, root: URL, package: PluginPackage, componentID: String, shared: Bool
    ) throws -> (workspaces: [UUID], accounts: [UUID]) {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV20.self),
            configurations: [ModelConfiguration(url: store)]
        )
        let context = container.mainContext
        let workspaces = try (0..<(shared ? 2 : 1)).map { index in
            let workspace = ASTRASchemaV20Models.Workspace()
            workspace.name = "Original \(index)"
            let directory = root.appendingPathComponent("workspace-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            workspace.primaryPath = directory.path
            workspace.enabledCapabilityIDs = [package.id]
            workspace.installedPluginIDs = [package.id]
            workspace.installedPluginVersions = [package.version]
            context.insert(workspace)
            return workspace
        }
        let accounts = ["Research", "Personal"].enumerated().map { index, alias in
            let account = ASTRASchemaV20Models.Connector()
            account.name = "Jira \(alias)"
            account.accountAlias = alias
            account.serviceType = "jira"
            account.baseURL = "https://\(alias.lowercased()).example.test"
            account.authMethod = "none"
            account.originPackageID = package.id
            account.originPackageVersion = package.version
            account.originComponentID = componentID
            account.originComponentKind = "connector"
            account.isGlobal = shared
            account.workspace = shared ? nil : workspaces[0]
            account.createdAt = Date(timeIntervalSince1970: Double(index + 1))
            context.insert(account)
            return account
        }
        for (index, workspace) in workspaces.enumerated() {
            workspace.defaultAccountServiceTypes = [" JIRA "]
            workspace.defaultAccountConnectorIDs = [accounts[index == 0 ? 1 : 0].id.uuidString]
            if shared { workspace.enabledGlobalConnectorIDs = accounts.map { $0.id.uuidString } }
        }
        try context.save()
        return (workspaces.map(\.id), accounts.map(\.id))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-v21-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
