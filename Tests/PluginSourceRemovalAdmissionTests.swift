import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Source removal consent admission", .serialized)
struct PluginSourceRemovalAdmissionTests {
    @Test("Stale global consent is refused before preparing source metadata", arguments: [false, true])
    func staleScopePrecedesMetadata(missing: Bool) throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let installed = try #require(env.library.installedPackage(id: env.id))
        if missing { _ = try env.library.removePackage(id: env.id, trustedBuiltInIDs: []) }
        let consent = try PluginRemovalScope.capture(pluginID: env.id, modelContext: env.context)
        let other = Workspace(name: "Changed after confirmation", primaryPath: env.disk.root.appendingPathComponent("other").path)
        env.context.insert(other)
        WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(env.id) }
        try env.context.save()
        let before = env.store.provenance()[env.id]
        let files = RemovalAdmissionFiles()
        let store = PluginSourceStore(root: env.store.root, fileManager: files)
        let service = CapabilityCatalogActionService(library: env.library, sourceStore: store)
        #expect(throws: PluginRemovalScope.Failure.scopeChanged) {
            if missing { _ = try service.forgetMissing(pluginID: env.id, modelContext: env.context, confirmedScope: consent) }
            else { _ = try service.remove(installed, modelContext: env.context, confirmedScope: consent) }
        }
        #expect(files.metadataPreparations == 0)
        #expect(store.provenance()[env.id] == before)
        #expect(try PluginSourceOperationJournal(store: store).pendingIDs().isEmpty)
        #expect(WorkspaceCapabilityActivation.activation(for: env.id, in: other) != nil)
    }
}

private final class RemovalAdmissionFiles: FileManager, @unchecked Sendable {
    var metadataPreparations = 0
    override func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.lastPathComponent == "OperationIntents" { metadataPreparations += 1 }
        try super.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }
}
