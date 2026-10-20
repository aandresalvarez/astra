import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence

@MainActor
@Suite("Plugin relationship rollback", .serialized)
struct PluginRelationshipRollbackTests {
    @Test("Workspace rollback preserves a shared account's bindings in both workspaces", arguments: [false, true])
    func sharedBindingRollback(onDisk: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-binding-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            configurations: [onDisk ? ModelConfiguration(url: root.appendingPathComponent("test.store"))
                : ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let seed = ModelContext(container)
        let deleted = Workspace(name: "A", primaryPath: root.appendingPathComponent("a").path)
        let survivor = Workspace(name: "B", primaryPath: root.appendingPathComponent("b").path)
        let account = Connector(name: "Shared", serviceType: "jira")
        account.isGlobal = true
        seed.insert(deleted)
        seed.insert(survivor)
        seed.insert(account)
        for workspace in [deleted, survivor] {
            let activation = PluginActivation(pluginID: "shared-plugin")
            seed.insert(activation)
            activation.workspace = workspace
            WorkspaceCapabilityActivation.bind(account, toComponent: "connector:jira:account", of: activation)
        }
        try seed.save()
        let id = deleted.id
        for attempt in 0..<3 {
            let context = ModelContext(container)
            let workspace = try #require(try context.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
            SwiftDataDeletionPreparation.prepare(workspace)
            context.delete(workspace)
            context.rollback()
            workspace.name = "Restored \(attempt)"
            try context.save()
            let durable = ModelContext(container)
            #expect(try durable.fetchCount(FetchDescriptor<Workspace>()) == 2)
            #expect(try durable.fetchCount(FetchDescriptor<PluginActivation>()) == 2)
            #expect(try durable.fetchCount(FetchDescriptor<AccountBinding>()) == 2)
            let restored = try #require(try durable.fetch(FetchDescriptor<Connector>()).first)
            #expect(restored.accountBindings.count == 2)
        }
        let context = ModelContext(container)
        let workspace = try #require(try context.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })).first)
        SwiftDataDeletionPreparation.prepare(workspace)
        context.delete(workspace)
        try context.save()
        let durable = ModelContext(container)
        #expect(try durable.fetchCount(FetchDescriptor<Workspace>()) == 1)
        #expect(try durable.fetchCount(FetchDescriptor<PluginActivation>()) == 1)
        #expect(try durable.fetchCount(FetchDescriptor<AccountBinding>()) == 1)
        let remaining = try #require(try durable.fetch(FetchDescriptor<Connector>()).first)
        #expect(remaining.id == account.id)
        #expect(remaining.accountBindings.first?.activation?.workspace?.id == survivor.id)
    }
}
