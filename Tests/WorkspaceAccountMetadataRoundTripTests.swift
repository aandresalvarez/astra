import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
@Suite("Workspace account metadata round trips", .serialized)
struct WorkspaceAccountMetadataRoundTripTests {
    private func container(at url: URL? = nil) throws -> ModelContainer {
        let configuration = url.map { ModelConfiguration(url: $0) }
            ?? ModelConfiguration(isStoredInMemoryOnly: true)
        let result = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                        configurations: [configuration])
        result.mainContext.autosaveEnabled = false
        return result
    }

    private func fixture() throws -> (URL, ModelContainer, Workspace, [Connector]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-account-mirror-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try container(at: root.appendingPathComponent("source.store"))
        let workspace = Workspace(name: "Accounts", primaryPath: root.path)
        store.mainContext.insert(workspace)
        let connectors = ["Research", "Personal"].map { alias in
            let connector = Connector(name: "\(alias) Jira", serviceType: "jira",
                                      baseURL: "https://\(alias.lowercased()).example.test")
            connector.accountAlias = alias
            connector.workspace = workspace
            store.mainContext.insert(connector)
            return connector
        }
        workspace.defaultAccountServiceTypes = ["jira"]
        workspace.defaultAccountConnectorIDs = [connectors[1].id.uuidString]
        try store.mainContext.save()
        return (root, store, workspace, connectors)
    }

    private func verify(_ config: WorkspaceConfigManager.WorkspaceConfig, ids: [UUID],
                        aliases: [String]) throws {
        #expect(config.defaultAccountServiceTypes == ["jira"])
        #expect(config.defaultAccountConnectorIDs == [ids[1].uuidString])
        for (id, alias) in zip(ids, aliases) {
            let connector = try #require(config.connectors?.first { $0.id == id.uuidString })
            #expect(connector.accountAlias == alias)
        }
    }

    private func verify(_ workspace: Workspace, in context: ModelContext, ids: [UUID],
                        aliases: [String]) throws {
        #expect(workspace.defaultAccountServiceTypes == ["jira"])
        #expect(workspace.defaultAccountConnectorIDs == [ids[1].uuidString])
        let connectors = try context.fetch(FetchDescriptor<Connector>())
        #expect(connectors.count == 2)
        for (id, alias) in zip(ids, aliases) {
            let connector = try #require(connectors.first { $0.id == id })
            #expect(connector.accountAlias == alias)
            #expect(connector.workspace?.id == workspace.id)
        }
    }

    @Test("Explicit export, JSON load, import, and re-export preserve account choices and aliases")
    func explicitRoundTrip() throws {
        let (root, source, workspace, connectors) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = connectors.map(\.id)
        let file = root.appendingPathComponent("export.json")
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.mainContext, url: file)
        let config = try WorkspaceConfigManager.loadConfig(from: file)
        try verify(config, ids: ids, aliases: ["Research", "Personal"])

        let destination = try container()
        let restored = WorkspaceConfigManager.importWorkspace(from: config, modelContext: destination.mainContext)
        try destination.mainContext.save()
        #expect(restored.id == workspace.id)
        try verify(restored, in: destination.mainContext, ids: ids, aliases: ["Research", "Personal"])
        let exportedAgain = try #require(WorkspaceConfigManager.export(
            workspace: restored, modelContext: destination.mainContext))
        try verify(exportedAgain, ids: ids, aliases: ["Research", "Personal"])
    }

    @Test("Automatic saved-state mirrors recover the saved account fields, then reflect the next save")
    func automaticMirrorRecovery() async throws {
        let (root, source, workspace, connectors) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = connectors.map(\.id)
        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
            workspace: workspace, modelContext: source.mainContext)
        // Pending UI edits must not replace the durable account choices in a
        // projection prepared from a saved-store snapshot.
        connectors[1].accountAlias = "Unsaved label"
        workspace.defaultAccountConnectorIDs = [ids[0].uuidString]
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
        let first = try await awaitMirror(mirror) {
            $0.defaultAccountConnectorIDs == [ids[1].uuidString]
                && $0.connectors?.first(where: { $0.id == ids[1].uuidString })?.accountAlias == "Personal"
        }
        try verify(first, ids: ids, aliases: ["Research", "Personal"])
        let recoveredStore = try container()
        let recovered = WorkspaceConfigManager.importWorkspace(from: first, modelContext: recoveredStore.mainContext)
        try recoveredStore.mainContext.save()
        try verify(recovered, in: recoveredStore.mainContext, ids: ids, aliases: ["Research", "Personal"])

        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
            workspace: workspace, modelContext: source.mainContext)
        let second = try await awaitMirror(mirror) {
            $0.defaultAccountConnectorIDs == [ids[0].uuidString]
                && $0.connectors?.first(where: { $0.id == ids[1].uuidString })?.accountAlias == "Unsaved label"
        }
        #expect(second.defaultAccountServiceTypes == ["jira"])
    }

    @Test("Missing optional account fields decode independently in older workspace files",
          arguments: ["neither", "servicesOnly", "idsOnly"])
    func olderWorkspaceFiles(fields: String) throws {
        let (root, source, workspace, connectors) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("legacy.json")
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.mainContext, url: file)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        if fields != "servicesOnly" { json.removeValue(forKey: "defaultAccountServiceTypes") }
        if fields != "idsOnly" { json.removeValue(forKey: "defaultAccountConnectorIDs") }
        var records = try #require(json["connectors"] as? [[String: Any]])
        for index in records.indices { records[index].removeValue(forKey: "accountAlias") }
        json["connectors"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let config = try WorkspaceConfigManager.loadConfig(from: file)
        let destination = try container()
        let restored = WorkspaceConfigManager.importWorkspace(from: config, modelContext: destination.mainContext)
        try destination.mainContext.save()
        #expect(restored.defaultAccountServiceTypes == (fields == "servicesOnly" ? ["jira"] : []))
        #expect(restored.defaultAccountConnectorIDs == (fields == "idsOnly" ? [connectors[1].id.uuidString] : []))
        #expect(try destination.mainContext.fetch(FetchDescriptor<Connector>()).allSatisfy { $0.accountAlias == nil })
    }

    @Test("Import maps default account IDs onto a reused shared connector without overwriting its metadata")
    func reusedGlobalAccount() throws {
        let (root, source, workspace, connectors) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = connectors[1]
        shared.isGlobal = true
        shared.workspace = nil
        workspace.enabledGlobalConnectorIDs = [shared.id.uuidString]
        try source.mainContext.save()
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: source.mainContext))

        let destination = try container()
        let existing = Connector(name: shared.name, serviceType: shared.serviceType, baseURL: shared.baseURL)
        existing.isGlobal = true
        existing.accountAlias = "Existing account label"
        destination.mainContext.insert(existing)
        try destination.mainContext.save()
        let restored = WorkspaceConfigManager.importWorkspace(from: config, modelContext: destination.mainContext)
        try destination.mainContext.save()
        #expect(existing.id != shared.id)
        #expect(restored.defaultAccountConnectorIDs == [existing.id.uuidString])
        #expect(restored.defaultAccountServiceTypes == ["jira"])
        #expect(existing.accountAlias == "Existing account label")
        #expect(existing.workspace == nil)
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<Connector>()) == 2)
    }

    @Test("A picked file remaps its default onto fresh account IDs while preserving the alias")
    func validatedAccountDefaultRemapsToFreshIdentity() throws {
        let (root, source, workspace, connectors) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: source.mainContext))
        let destination = try container()
        let result = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: destination.mainContext,
            capabilityTrust: .validate(.init(approvedPackageIDs: [], installedPackageIDs: [], availablePackIDs: []))
        )
        try destination.mainContext.save()
        let restoredDefault = try #require(result.workspace.connectors.first { $0.accountAlias == "Personal" })
        #expect(restoredDefault.id != connectors[1].id)
        #expect(result.workspace.defaultAccountServiceTypes == ["jira"])
        #expect(result.workspace.defaultAccountConnectorIDs == [restoredDefault.id.uuidString])
    }

    private func awaitMirror(_ url: URL, matching condition: (WorkspaceConfigManager.WorkspaceConfig) -> Bool)
        async throws -> WorkspaceConfigManager.WorkspaceConfig {
        for _ in 0..<500 {
            if let config = try? WorkspaceConfigManager.loadConfig(from: url), condition(config) { return config }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The saved account metadata never reached the workspace mirror")
        throw CocoaError(.fileReadUnknown)
    }
}
