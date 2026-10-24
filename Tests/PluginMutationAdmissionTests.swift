import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin mutation admission", .serialized)
struct PluginMutationAdmissionTests {
    enum Entry: String, CaseIterable { case install, enable, create, createAndEnable, createFacade, createAndEnableFacade, add }

    @Test("Every Add/Create entry refuses another writer before changing files or approval", arguments: Entry.allCases)
    func refusesHeldLibrary(entry: Entry) throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let package = try PluginSourcesTests.package(id: env.id, version: "1.0.0")
        let approvals = env.approvals.records()
        try env.store.exclusively(pluginID: "another-plugin") {
            #expect(throws: PluginSourceStoreError.self) { try invoke(entry, package, env: env) }
        }
        #expect(env.library.installedPackage(id: env.id) == nil)
        #expect(WorkspaceCapabilityActivation.activation(for: env.id, in: env.workspace) == nil)
        #expect(env.approvals.records() == approvals)
    }

    @Test("A committed Remove's blocked recovery refuses a new Add/Create", arguments: Entry.allCases)
    func refusesPendingRemove(entry: Entry) throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        // No secret namespace is involved in this file/mirror admission test.
        var definition = try PluginSourcesTests.package(id: env.id, version: "1.0.0")
        definition.skills = []
        _ = try env.importLocal(definition)
        let package = try #require(env.library.installedPackage(id: env.id))
        _ = try env.approvals.save(package: package, status: .approved, approvedBy: "Admission test")
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(package.id) }
        try env.context.save()
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Refused mirror directory".utf8).write(to: support)
        #expect(throws: PluginOperationProblem.self) { try env.service.remove(package, modelContext: env.context) }
        #expect(env.library.installedPackage(id: env.id) == nil)
        let approvals = env.approvals.records()
        #expect(throws: PluginDefinitionChange.Failure.self) { try invoke(entry, package, env: env) }
        #expect(env.library.installedPackage(id: env.id) == nil)
        #expect(WorkspaceCapabilityActivation.activation(for: env.id, in: env.workspace) == nil)
        #expect(env.approvals.records() == approvals)
        try FileManager.default.removeItem(at: support)
        #expect(PluginSourceOperationRecovery(library: env.library, store: env.store).resumePending(modelContext: env.context) == 0)
        // A later retry is admitted once the earlier deletion has finished.
        try invoke(entry, package, env: env)
        #expect(env.library.installedPackage(id: env.id) != nil || entry == .enable)
    }

    @Test("Nested permission expires and cannot authorize another plugin or store")
    func permitIsCallScoped() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        var captured: PluginMutationScope.Permit?
        try PluginMutationScope.perform(pluginID: env.id, library: env.library, store: env.store, modelContext: env.context) { permit in
            captured = permit
            #expect(throws: PluginSourceStoreError.self) {
                try PluginMutationScope.perform(pluginID: "another", library: env.library, store: env.store,
                    modelContext: env.context, permit: permit) { _ in Issue.record("Wrong plugin admitted") }
            }
            let other = try env.disk.reopen()
            #expect(throws: PluginSourceStoreError.self) {
                try PluginMutationScope.perform(pluginID: env.id, library: env.library, store: env.store,
                    modelContext: other.mainContext, permit: permit) { _ in Issue.record("Wrong store admitted") }
            }
            // A nested event without the explicit permit still encounters the lock.
            #expect(throws: PluginSourceStoreError.self) {
                try PluginMutationScope.perform(pluginID: env.id, library: env.library, store: env.store,
                    modelContext: env.context) { _ in Issue.record("Reentrant action admitted") }
            }
        }
        let stale = try #require(captured)
        #expect(throws: PluginSourceStoreError.self) {
            try PluginMutationScope.perform(pluginID: env.id, library: env.library, store: env.store,
                modelContext: env.context, permit: stale) { _ in Issue.record("Expired scope admitted") }
        }
    }

    @Test("Creating a library directory does not invalidate the nested permit")
    func directoryCreationKeepsIdentity() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let directory = env.disk.root.appendingPathComponent("NewLibrary", isDirectory: true)
        let library = CapabilityLibrary(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try PluginMutationScope.perform(pluginID: env.id, library: library, store: env.store, modelContext: env.context) { permit in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(try PluginMutationScope.perform(pluginID: env.id, library: library, store: env.store,
                modelContext: env.context, permit: permit) { _ in true })
        }
    }

    @Test("An independently held file lock refuses Add promptly before approval")
    func fileLockIsNotBypassed() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        try env.store.exclusively(pluginID: "initialize-lock") {}
        let descriptor = open(env.store.libraryLockURL.path, O_RDWR | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }
        let package = try PluginSourcesTests.package(id: env.id, version: "1.0.0")
        let start = ContinuousClock.now
        #expect(throws: PluginSourceStoreError.libraryBusy) { try invoke(.add, package, env: env) }
        #expect(start.duration(to: .now) < .milliseconds(250))
        #expect(env.library.installedPackage(id: env.id) == nil)
    }

    private func invoke(_ entry: Entry, _ package: PluginPackage,
        env: PluginSourceDefinitionOperationTests.Fixture) throws {
        let installer = CapabilityInstaller(library: env.library, sourceStore: env.store)
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: env.workspace, approvalRecords: env.approvals.records())
        switch entry {
        case .install:
            _ = try installer.install(package, into: env.workspace, modelContext: env.context, policyContext: policy)
        case .enable:
            _ = try installer.enable(package, in: env.workspace, modelContext: env.context, policyContext: policy)
        case .create, .createAndEnable:
            _ = try env.service.creationService.create(package, enableHere: entry == .createAndEnable, sourceURL: nil,
                workspace: env.workspace, modelContext: env.context, policyContext: policy)
        case .createFacade, .createAndEnableFacade:
            _ = try env.service.create(package, enableHere: entry == .createAndEnableFacade, sourceURL: nil,
                workspace: env.workspace, modelContext: env.context, policyContext: policy, traceID: "admission-regression")
        case .add:
            _ = try env.service.add(package, workspace: env.workspace, modelContext: env.context,
                policyContext: policy, approvalStore: env.approvals, traceID: "admission-regression")
        }
    }
}
