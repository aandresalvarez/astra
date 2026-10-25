import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Staging and linked metadata recovery", .serialized)
struct PluginStagingTransactionTests {
    @Test("Linked file work cannot complete with a reader that lacks its metadata participant")
    func linkedMetadataRequiresHandler() throws {
        let env = try PluginFileOperationRecoveryTests.Fixture()
        defer { env.removeFiles() }
        let prepared = try env.journal.prepare(storeIdentity: #require(PersistentStoreIdentity.current(for: env.context)),
            pluginIDs: ["example"], changes: [.init(root: .library, name: "example.json",
                replacement: .init(isDirectory: false, directories: [], files: ["": Data("new".utf8)]))],
            linkedMetadataDigest: "metadata-proof")
        #expect(prepared.manifest.version == 2)
        try env.journal.apply(prepared, forward: true)
        let blocked = PluginFileOperationRecovery(journal: env.journal).resumePending(modelContext: env.context)
        #expect(blocked.deferred == 1 && blocked.completed == 0)
        #expect(try env.value() == "new")
        var reconciled = false
        var finished = false
        let handler = PluginFileOperationRecovery.MetadataHandler(reconcile: { file, receipt in
            #expect(file.id == prepared.id && receipt == nil)
            let value = try env.value()
            #expect(value == "old definition")
            reconciled = true
        }, finish: { file, receipt in
            #expect(file.id == prepared.id && receipt == nil)
            let pending = try env.journal.pendingIDs()
            #expect(pending.isEmpty)
            finished = true
        })
        let recovered = PluginFileOperationRecovery(journal: env.journal).resumePending(modelContext: env.context, metadata: handler)
        #expect(recovered.completed == 1 && recovered.deferred == 0 && reconciled && finished)
    }

    @Test("Staging commits a recoverable draft without saving unrelated editor state")
    func stagingOwnsOnlyItsReceipt() throws {
        let env = try PluginFileOperationRecoveryTests.Fixture()
        defer { env.removeFiles() }
        let original = PluginOperationsTests.package(version: "1.0.0")
        try env.library.install(original, sourceMetadata: .localLibrary())
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals"))
        _ = try approvals.save(package: #require(env.library.installedPackage(id: original.id)), status: .approved, approvedBy: "Test")
        let workspace = Workspace(name: "Saved editor", primaryPath: "")
        env.context.insert(workspace)
        try env.context.save()
        workspace.name = "Unsaved editor"
        let draft = PluginOperationsTests.package(version: "2.0.0")
        let report = CapabilityPackageValidator.validate(package: draft, installedPackages: env.library.installedPackages(), checkPrerequisites: false)
        let result = try CapabilityPackageImporter(library: env.library).importValidatedPackage(report,
            modelContext: env.context, approvalRecords: approvals.records())
        #expect(result.staged && env.library.installedPackage(id: original.id)?.version == "1.0.0")
        #expect(env.library.stagedPackage(id: original.id)?.version == "2.0.0")
        let saved = ModelContext(env.container)
        #expect(try saved.fetch(FetchDescriptor<Workspace>()).first?.name == "Saved editor")
        #expect(workspace.name == "Unsaved editor")
        let receipts = try saved.fetch(FetchDescriptor<PluginOperationReceipt>())
        #expect(receipts.count == 1 && receipts[0].completedAt != nil && receipts[0].manifestDigest != nil)
        #expect(receipts[0].workspaceIDStrings.isEmpty)
    }
}
