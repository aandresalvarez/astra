import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Source removal commit participant", .serialized)
struct PluginSourceRemovalTests {
    @Test("A refused library deletion keeps source ownership until the saved Remove is replayed")
    func failedDeletionRetainsSourceProof() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let installed = try #require(env.library.installedPackage(id: env.id))
        let before = env.store.provenance()[env.id]
        let files = SourceRemovalFiles(directory: env.library.directory)
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: files)
        files.refusesRemoval = true
        let service = CapabilityCatalogActionService(library: library, sourceStore: env.store)
        var operationID: UUID?
        do {
            _ = try service.remove(installed, modelContext: env.context)
            Issue.record("A committed Remove with refused file work must report pending")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        #expect(env.store.provenance()[env.id] == before)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs() == [id])
        #expect(library.installedPackage(id: env.id) != nil)
        try env.store.recordProvenance(pluginID: "unrelated", sourceID: "independent", digest: "other")
        files.refusesRemoval = false
        let reopened = try env.disk.reopen()
        #expect(PluginSourceOperationRecovery(library: library, store: env.store).resumePending(modelContext: reopened.mainContext) == 0)
        #expect(env.store.provenance()[env.id] == nil)
        #expect(env.store.provenance()["unrelated"]?.sourceID == "independent")
        #expect(library.installedPackage(id: env.id) == nil)
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
    }

    @Test("A refused preparation leaves the installed source unchanged and no guessed forget intent")
    func failureBeforeSaveKeepsOwner() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let installed = try #require(env.library.installedPackage(id: env.id))
        let before = env.store.provenance()[env.id]
        let files = SourceRemovalFiles(directory: env.library.directory)
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: files)
        files.refusesPreparation = true
        #expect(throws: (any Error).self) {
            try CapabilityCatalogActionService(library: library, sourceStore: env.store).remove(installed, modelContext: env.context)
        }
        #expect(library.installedPackage(id: env.id) != nil)
        #expect(env.store.provenance()[env.id] == before)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
    }

    @Test("Forgetting a missing source plugin includes workspaces that only held an import")
    func pendingImportMirrorIsPartOfRemove() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        _ = try env.library.removePackage(id: env.id, trustedBuiltInIDs: [])
        let pending = RetiredPluginActivation.PendingImport(digest: "held", source: "plugin-source:\(plugin.source.id)",
            settings: ["skill:legacy#REGION": "eu"], overriddenComponentIDs: nil, overridingRowIDs: nil, accounts: nil, knownComponentIDs: nil)
        WorkspaceCapabilityActivation.recordPendingImport(pending, pluginID: env.id, in: env.workspace)
        try env.context.save()
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked recovery mirror".utf8).write(to: support)
        var operationID: UUID?
        do {
            _ = try env.service.forgetMissing(pluginID: env.id, modelContext: env.context)
            Issue.record("Dropping a held import still owes a recovery mirror")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        #expect(try PluginOperationCommit.read(id, container: env.disk.container)?.workspaceIDs == [env.workspace.id])
        #expect(WorkspaceCapabilityActivation.pendingImport(pluginID: env.id, in: env.workspace) == nil)
        try FileManager.default.removeItem(at: support)
        let reopened = try env.disk.reopen()
        #expect(PluginSourceOperationRecovery(library: env.library, store: env.store).resumePending(modelContext: reopened.mainContext) == 0)
        let config = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
        #expect(config.retiredPlugins?.isEmpty ?? true)
    }

    @Test("Completed source removal preserves retired namespace identity and a matching committed receipt")
    func retiredIdentityPrecedesForget() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let installed = try #require(env.library.installedPackage(id: env.id))
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs.append(installed.id) }
        WorkspaceCapabilityActivation.recordAccepted(pluginID: installed.id, version: installed.version,
            digest: PluginDefinitionDigest.content(of: installed), in: env.workspace)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: installed.id, in: env.workspace))
        WorkspaceCapabilityActivation.setNamespaceSeed("source-import-seed", on: activation)
        try env.context.save()
        _ = try env.service.remove(installed, modelContext: env.context)
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).first?.source == "plugin-source:\(plugin.source.id)")
        #expect(env.store.provenance()[env.id] == nil)
        let reopened = try env.disk.reopen()
        let receipts = try reopened.mainContext.fetch(FetchDescriptor<PluginOperationReceipt>())
        #expect(receipts.contains { $0.kindRawValue == PluginOperationReceipt.Kind.remove.rawValue && $0.completedAt != nil && $0.manifestDigest != nil })
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
    }
}

private final class SourceRemovalFiles: FileManager {
    let directory: URL
    var refusesRemoval = false
    var refusesPreparation = false
    init(directory: URL) { self.directory = directory.standardizedFileURL; super.init() }
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        if refusesPreparation, url.standardizedFileURL == directory { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }
    override func removeItem(at url: URL) throws {
        if refusesRemoval, url.deletingLastPathComponent().standardizedFileURL == directory { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
