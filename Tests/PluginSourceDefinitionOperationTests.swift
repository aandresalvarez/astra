import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Source imports and approvals share commit proof", .serialized)
struct PluginSourceDefinitionOperationTests {
    @Test("A source import records completed file and source proof, including after reopening")
    func sourceImportPersistsOwnership() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let installed = try #require(env.library.installedPackage(id: env.id))
        #expect(env.store.provenance()[env.id] == .init(sourceID: plugin.source.id, digest: PluginSourceCatalog.contentDigest(installed)))
        let reopened = try env.disk.reopen()
        let receipts = try reopened.mainContext.fetch(FetchDescriptor<PluginOperationReceipt>())
        #expect(receipts.count == 1 && receipts[0].completedAt != nil && receipts[0].manifestDigest != nil)
        #expect(PluginSourceOperationRecovery(library: env.library, store: env.store).resumePending(modelContext: reopened.mainContext) == 0)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
    }

    @Test("A source draft keeps the active owner until approval promotes the exact staged source")
    func stagedSourcePromotesOnApproval() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        let sourceID = try env.installApprovedSource()
        let before = try #require(env.store.provenance()[env.id])
        let (plugin, coordinator) = try env.offered(version: "2.0.0")
        let result = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        #expect(result.staged && env.library.installedPackage(id: env.id)?.version == "1.0.0")
        let pending = try #require(env.store.provenance()[env.id])
        #expect(pending.sourceID == before.sourceID && pending.digest == before.digest)
        #expect(pending.pendingReview?.sourceID == sourceID)
        #expect(pending.pendingReview?.digest == (try CapabilityApprovalDigest.digest(for: #require(env.library.stagedPackage(id: env.id)))))
        let reopened = try env.disk.reopen()
        let installed = try env.service.approveStaged(try env.service.reviewStaged(id: env.id), modelContext: reopened.mainContext, approvalStore: env.approvals)
        #expect(installed.version == "2.0.0" && env.library.stagedPackage(id: env.id) == nil)
        #expect(env.store.provenance()[env.id] == .init(sourceID: sourceID, digest: PluginSourceCatalog.contentDigest(installed)))
        #expect(env.approvals.record(for: installed)?.status == .approved)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
    }

    @Test("A local staged replacement retains the active source until approval then becomes local")
    func localDraftDoesNotForgetActiveOwnerEarly() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        let sourceID = try env.installApprovedSource()
        let draft = try PluginSourcesTests.package(id: env.id, version: "2.0.0")
        let result = try env.importLocal(draft)
        #expect(result.staged && env.library.installedPackage(id: env.id)?.version == "1.0.0")
        let pending = try #require(env.store.provenance()[env.id])
        #expect(pending.sourceID == sourceID && pending.pendingReview != nil && pending.pendingReview?.sourceID == nil)
        let installed = try env.service.approveStaged(try env.service.reviewStaged(id: env.id), modelContext: env.context, approvalStore: env.approvals)
        #expect(installed.version == "2.0.0")
        #expect(env.store.provenance()[env.id] == nil)
    }

    @Test("Replacing staged bytes behind the recorded review cannot change the approved source")
    func changedDraftIsRefused() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        _ = try env.installApprovedSource()
        let (plugin, coordinator) = try env.offered(version: "2.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let before = try #require(env.store.provenance()[env.id])
        var changed = try #require(env.library.stagedPackage(id: env.id))
        changed.skills[0].behaviorInstructions = "Different instructions, never reviewed."
        try env.library.stage(.init(package: changed, manifestURL: nil, assetRootURL: nil))
        #expect(throws: (any Error).self) {
            try env.service.approveStaged(try env.service.reviewStaged(id: env.id), modelContext: env.context, approvalStore: env.approvals)
        }
        #expect(env.library.installedPackage(id: env.id)?.version == "1.0.0")
        #expect(env.store.provenance()[env.id] == before)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
    }

    @Test("Reimporting an identical missing copy commits source removal and a mirror retry without activation changes")
    func sameBytesLocalImportIncludesMirrors() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        let (plugin, coordinator) = try env.offered(version: "1.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let installed = try #require(env.library.installedPackage(id: env.id))
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs.append(installed.id) }
        WorkspaceCapabilityActivation.recordAccepted(pluginID: installed.id, version: installed.version,
            digest: PluginDefinitionDigest.content(of: installed), in: env.workspace)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: installed.id, in: env.workspace))
        WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: installed), on: activation)
        try env.context.save()
        let activationID = activation.id
        // A missing library copy can be reimported without a version change;
        // the activation still records exactly these bytes, so reconciliation
        // itself has no reason to export this workspace again.
        _ = try env.library.removePackage(id: installed.id, trustedBuiltInIDs: [])
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked mirror directory".utf8).write(to: support)
        do {
            _ = try env.importLocal(installed)
            Issue.record("A committed local import with a blocked mirror must report pending recovery")
        } catch let error as PluginOperationProblem {
            guard case .savedRecoveryPending(let id) = error else { throw error }
            let receipt = try #require(try PluginOperationCommit.read(id, container: env.disk.container))
            #expect(receipt.workspaceIDs == [env.workspace.id] && receipt.completedAt == nil)
        }
        #expect(env.store.provenance()[env.id] == nil)
        #expect(WorkspaceCapabilityActivation.activation(for: env.id, in: env.workspace)?.id == activationID)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().count == 1)
        try FileManager.default.removeItem(at: support)
        let reopened = try env.disk.reopen()
        #expect(PluginSourceOperationRecovery(library: env.library, store: env.store).resumePending(modelContext: reopened.mainContext) == 0)
        #expect(env.store.provenance()[env.id] == nil)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
    }

    @Test("A window cannot approve or discard a later draft using its earlier review", arguments: [false, true])
    func staleWindowDoesNotApproveNewDraft(sameVersion: Bool) throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        _ = try env.installApprovedSource()
        let (first, firstCoordinator) = try env.offered(version: "2.0.0")
        _ = try env.service.importReviewed(first, workspace: env.workspace, modelContext: env.context, coordinator: firstCoordinator)
        let review = try env.service.reviewStaged(id: env.id)
        let nextVersion = sameVersion ? "2.0.0" : "3.0.0"
        let (later, laterCoordinator) = try env.offered(version: nextVersion, instructions: "New instructions from the later review")
        _ = try env.service.importReviewed(later, workspace: env.workspace, modelContext: env.context, coordinator: laterCoordinator)
        let provenance = env.store.provenance()[env.id]
        let approvals = env.approvals.records()
        #expect(throws: (any Error).self) { try env.service.discardStaged(review, modelContext: env.context) }
        #expect(throws: (any Error).self) {
            try env.service.approveStaged(review, modelContext: env.context, approvalStore: env.approvals)
        }
        #expect(env.library.installedPackage(id: env.id)?.version == "1.0.0")
        #expect(env.library.stagedPackage(id: env.id)?.version == nextVersion)
        #expect(env.store.provenance()[env.id] == provenance && env.approvals.records() == approvals)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
        let refreshed = try env.service.reviewStaged(id: env.id)
        let accepted = try env.service.approveStaged(refreshed, modelContext: env.context, approvalStore: env.approvals)
        #expect(accepted.version == nextVersion)
        #expect(accepted.skills[0].behaviorInstructions == "New instructions from the later review")
    }

    @Test("Discard clears only the reviewed draft and its origin, retaining the active copy", arguments: [false, true])
    func discardRetainsActiveSource(localDraft: Bool) throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        _ = try env.installApprovedSource()
        let active = env.store.provenance()[env.id]
        if localDraft { _ = try env.importLocal(PluginSourcesTests.package(id: env.id, version: "2.0.0")) }
        else {
            let (plugin, coordinator) = try env.offered(version: "2.0.0")
            _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        }
        let review = try env.service.reviewStaged(id: env.id)
        env.workspace.name = "Unsaved discard editor"
        try env.service.discardStaged(review, modelContext: env.context)
        #expect(env.library.stagedPackage(id: env.id) == nil)
        #expect(env.library.installedPackage(id: env.id)?.version == "1.0.0")
        #expect(env.store.provenance()[env.id] == active)
        let reopened = try env.disk.reopen()
        #expect(try reopened.mainContext.fetch(FetchDescriptor<Workspace>()).first?.name == "Source operations")
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs().isEmpty)
        #expect(PluginSourceOperationRecovery(library: env.library, store: env.store).resumePending(modelContext: reopened.mainContext) == 0)
    }

    @Test("Staging cannot accidentally save an unrelated editor's changes")
    func stagingUsesIndependentContext() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        _ = try env.installApprovedSource()
        env.workspace.name = "Unsaved editor name"
        let (plugin, coordinator) = try env.offered(version: "2.0.0")
        _ = try env.service.importReviewed(plugin, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let saved = try ModelContext(env.disk.container).fetch(FetchDescriptor<Workspace>())
        #expect(saved.first?.name == "Source operations")
        #expect(env.workspace.name == "Unsaved editor name")
    }

    @MainActor
    struct Fixture {
        let disk: PluginFileOperationRecoveryTests.Fixture
        let store: PluginSourceStore
        let workspace: Workspace
        let id = "source-operation-" + UUID().uuidString.lowercased()
        var library: CapabilityLibrary { disk.library }
        var context: ModelContext { disk.context }
        var approvals: CapabilityApprovalStore { CapabilityApprovalStore() }
        var service: CapabilityCatalogActionService { .init(library: library, sourceStore: store) }
        init() throws {
            disk = try PluginFileOperationRecoveryTests.Fixture()
            store = PluginSourceStore(root: disk.root.appendingPathComponent("Sources"))
            let path = disk.root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            workspace = Workspace(name: "Source operations", primaryPath: path.path)
            disk.context.insert(workspace)
            try disk.context.save()
        }
        func offered(version: String, instructions: String? = nil) throws -> (SourcedPlugin, PluginSourceCoordinator) {
            let folder = disk.root.appendingPathComponent("Repository")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var package = try PluginSourcesTests.package(id: id, version: version)
            if let instructions { package.skills[0].behaviorInstructions = instructions }
            try JSONEncoder().encode(package).write(to: folder.appendingPathComponent("capability.json"), options: .atomic)
            let source = try #require(PluginSource.make(from: folder.path))
            try store.save([source])
            let coordinator = PluginSourceCoordinator(store: store, installedPackages: { library.installedPackages() })
            coordinator.reload()
            return (try #require(coordinator.listings.first?.plugins.first), coordinator)
        }
        func installApprovedSource() throws -> String {
            let (plugin, coordinator) = try offered(version: "1.0.0")
            _ = try service.importReviewed(plugin, workspace: workspace, modelContext: context, coordinator: coordinator)
            _ = try approvals.save(package: #require(library.installedPackage(id: id)), status: .approved, approvedBy: "Test")
            return plugin.source.id
        }
        func importLocal(_ package: PluginPackage) throws -> CapabilityPackageImportResult {
            let report = CapabilityPackageValidator.validate(package: package, installedPackages: library.installedPackages(), checkPrerequisites: false)
            return try service.importPlugin(report, workspace: workspace, modelContext: context, traceID: "source-operation-test")
        }
    }
}
