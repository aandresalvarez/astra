import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Source plugin update admission", .serialized)
struct PluginSourceUpdateAdmissionTests {
    @Test("A rejected source import keeps pending editor work and rolls back files and provenance")
    func sourceImportDoesNotConsumePendingEdits() throws {
        let fixture = try PluginSourcesTests.Fixture()
        let id = "source-pending-editor"
        let folder = fixture.root.appendingPathComponent("source", isDirectory: true)
        try fixture.write(["capability.json": try PluginSourcesTests.packageJSON(id: id, version: "1.0.0")], in: folder)
        let source = try #require(PluginSource.make(from: folder.path))
        try fixture.store.save([source])
        let coordinator = PluginSourceCoordinator(store: fixture.store, installedPackages: { fixture.library.installedPackages() })
        coordinator.reload()
        let offered = try #require(coordinator.listings.first?.plugins.first)
        let workspace = Workspace(name: "Saved editor", primaryPath: fixture.root.appendingPathComponent("workspace").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        fixture.context.insert(workspace)
        try fixture.context.save()
        let receipts = try fixture.context.fetchCount(FetchDescriptor<PluginOperationReceipt>())
        workspace.name = "Unfinished editor change"
        #expect(throws: PluginUpdateService.UpdateError.pendingEdits) {
            try CapabilityCatalogActionService(library: fixture.library, sourceStore: fixture.store)
                .importReviewed(offered, workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        }
        #expect(workspace.name == "Unfinished editor change")
        #expect(fixture.context.hasChanges)
        let saved = ModelContext(fixture.context.container)
        #expect(try saved.fetch(FetchDescriptor<Workspace>()).first?.name == "Saved editor")
        #expect(try saved.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == receipts)
        #expect(fixture.library.installedPackage(id: id) == nil)
        #expect(fixture.store.provenance()[id] == nil)
        #expect(try PluginFileOperationJournal(library: fixture.library, approvals: CapabilityApprovalStore()).pendingIDs().isEmpty)
    }
}
