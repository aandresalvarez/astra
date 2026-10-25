import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Approval presentation refresh follows asset changes", .serialized)
struct PluginApprovalDigestCacheTests {
    @Test("A library write invalidates an equal package's cached asset digest", arguments: [false, true])
    func libraryPublicationRefreshesAsset(publishesChanges: Bool) throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        let first = try #require(CapabilityApprovalDigest.memoizedDigest(for: env.package))
        try env.newIcon.write(to: env.icon)
        // The render cache stays on its explicit refresh boundary.
        #expect(CapabilityApprovalDigest.memoizedDigest(for: env.package) == first)
        CapabilityLibrary(directory: env.disk.library.directory, publishesChanges: publishesChanges).publishChange()
        let current = try #require(CapabilityApprovalDigest.memoizedDigest(for: env.package))
        #expect(current == (try CapabilityApprovalDigest.digest(for: env.package)))
        #expect(current != first)
    }

    @Test("An explicit catalog refresh notices asset changes with unchanged package metadata")
    func explicitRefreshRecomputesAsset() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        _ = try env.disk.library.syncApprovedPackages(PluginCatalog.builtInPackages)
        let first = try #require(CapabilityApprovalDigest.memoizedDigest(for: env.package))
        try env.newIcon.write(to: env.icon)
        PluginCatalog().loadApprovedCapabilities(library: env.disk.library, announceLibraryMutations: false)
        let current = try #require(CapabilityApprovalDigest.memoizedDigest(for: env.package))
        #expect(current == (try CapabilityApprovalDigest.digest(for: env.package)))
        #expect(current != first)
    }

    @Test("Forward file recovery refreshes assets even while its mirror is still pending")
    func pendingRecoveryDoesNotLeaveOldAssetDigest() throws {
        let env = try Fixture()
        defer { env.disk.removeFiles() }
        let workspace = Workspace(name: "Cache recovery", primaryPath: "")
        env.disk.context.insert(workspace)
        try env.disk.context.save()
        let first = try #require(CapabilityApprovalDigest.memoizedDigest(for: env.package))
        let prepared = try env.disk.journal.prepare(
            storeIdentity: #require(PersistentStoreIdentity.current(for: env.disk.context)), pluginIDs: [env.package.id],
            changes: [.init(root: .library, name: "assets", replacement: PluginFileImage(
                isDirectory: true, directories: [], files: ["icon.svg": env.newIcon]))])
        let outcome = PluginOperationCommit.save(id: prepared.id, kind: .update, pluginIDs: [env.package.id],
            workspaceIDs: [workspace.id], manifestDigest: prepared.digest, modelContext: env.disk.context)
        guard case .committed = outcome else { Issue.record("Fixture did not save its receipt"); return }
        let recovery = PluginFileOperationRecovery(journal: env.disk.journal)
            .resumePending(modelContext: env.disk.context, export: { _, _ in false })
        #expect(recovery.completed == 0 && recovery.deferred == 1)
        #expect(try Data(contentsOf: env.icon) == env.newIcon)
        let current = try #require(CapabilityApprovalDigest.memoizedDigest(for: env.package))
        #expect(current == (try CapabilityApprovalDigest.digest(for: env.package)))
        #expect(current != first)
    }

    @MainActor
    private struct Fixture {
        let disk: PluginFileOperationRecoveryTests.Fixture
        let package: PluginPackage
        let icon: URL
        let newIcon = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h.5v.5H0z\"/></svg>".utf8)
        init() throws {
            disk = try PluginFileOperationRecoveryTests.Fixture()
            let assets = disk.library.directory.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            icon = assets.appendingPathComponent("icon.svg")
            try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8).write(to: icon)
            var definition = PluginOperationsTests.package(version: "1.0.0")
            definition.id = "asset-cache-" + UUID().uuidString
            definition.sourceMetadata = .builtIn()
            definition.sourceMetadata?.url = disk.library.directory
            definition.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: definition.icon)
            package = definition
        }
    }
}
