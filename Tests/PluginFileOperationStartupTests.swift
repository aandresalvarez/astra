import Foundation
import os
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin file startup and publication", .serialized)
struct PluginFileOperationStartupTests {
    @Test("Startup refuses an unresolvable root before plugin admission")
    func startupBlocksUncertainFiles() throws {
        let fixture = try PluginFileOperationRecoveryTests.Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try FileManager.default.moveItem(at: fixture.library.directory, to: fixture.root.appendingPathComponent("Previous"))
        try FileManager.default.createDirectory(at: fixture.library.directory, withIntermediateDirectories: false)
        let blocker = PluginFileOperationStartup.blocker(modelContext: fixture.context, library: fixture.library,
            approvals: CapabilityApprovalStore(directory: fixture.root.appendingPathComponent("Approvals")))
        #expect(blocker?.title == "A plugin change needs recovery")
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
    }

    @Test("Startup finishes committed files before admitting the app, leaving mirror debt for its own phase")
    func startupLeavesMirrorDebt() throws {
        let fixture = try PluginFileOperationRecoveryTests.Fixture()
        defer { fixture.removeFiles() }
        let prepared = try fixture.prepare()
        try fixture.commit(prepared)
        #expect(PluginFileOperationStartup.blocker(modelContext: fixture.context, library: fixture.library,
            approvals: CapabilityApprovalStore(directory: fixture.root.appendingPathComponent("Approvals"))) == nil)
        #expect(try fixture.value() == "new definition")
        #expect(try PluginOperationCommit.read(prepared.id, container: fixture.container)?.completedAt == nil)
        #expect(try fixture.journal.pendingIDs() == [prepared.id])
    }

    @Test("Isolated preparation publishes no live library or approval changes")
    func preparationDoesNotPublish() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let observers = [Notification.Name.capabilityPackagesChanged, .capabilityApprovalsChanged, .capabilityCatalogPersistenceChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in changes.withLock { $0 += 1 } }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals"))
        let journal = PluginFileOperationJournal(library: env.library, approvals: approvals)
        _ = try PluginLibraryPreparation.prepare(source: CapabilityPackageSource(
            package: PluginOperationsTests.package(version: "2.0.0"), manifestURL: nil, assetRootURL: nil),
            library: env.library, approvalStore: approvals, approvedBy: "Tests",
            storeIdentity: try #require(PersistentStoreIdentity.current(for: env.context)), journal: journal)
        #expect(changes.withLock { $0 } == 0)
        #expect(env.library.installedPackages().isEmpty)
        #expect(approvals.records().isEmpty)
    }
}
