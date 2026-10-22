import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Global plugin removal consent", .serialized)
struct PluginRemovalScopeTests {
    @Test("Remove rejects changes in another workspace before creating file work", arguments: ["add", "edit", "replace", "delete", "same-revision"], [false, true])
    func changedOtherWorkspace(change: String, missing: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let other = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("other").path)
        env.context.insert(other)
        if change != "add" {
            WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(package.id) }
        }
        try env.context.save()
        if missing { _ = try env.library.removePackage(id: package.id) }
        let consent = try PluginRemovalScope.capture(pluginID: package.id, modelContext: env.context)
        switch change {
        case "add": WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(package.id) }
        case "edit", "same-revision":
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: other))
            let revision = activation.revision
            WorkspaceCapabilityActivation.setConfigValue("new-project", forKey: "skill:report-agent#PROJECT", on: activation)
            if change == "same-revision" { activation.revision = revision }
        case "replace":
            let previous = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: other))
            let revision = previous.revision
            env.context.delete(previous)
            try env.context.save()
            WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(package.id) }
            let replacement = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: other))
            replacement.revision = revision
        default:
            let previous = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: other))
            env.context.delete(previous)
        }
        try env.context.save()
        let current = try PluginRemovalScope.capture(pluginID: package.id, modelContext: env.context)
        #expect(current != consent)
        let receipts = try env.context.fetch(FetchDescriptor<PluginOperationReceipt>()).map(\.id)
        let service = CapabilityCatalogActionService(library: env.library)
        #expect(throws: PluginRemovalScope.Failure.scopeChanged) {
            if missing { _ = try service.forgetMissing(pluginID: package.id, modelContext: env.context, confirmedScope: consent) }
            else { _ = try service.remove(package, modelContext: env.context, confirmedScope: consent) }
        }
        #expect(try PluginRemovalScope.capture(pluginID: package.id, modelContext: env.context) == current)
        #expect(try env.context.fetch(FetchDescriptor<PluginOperationReceipt>()).map(\.id) == receipts)
        #expect(try PluginFileOperationJournal(library: env.library, approvals: CapabilityApprovalStore()).pendingIDs().isEmpty)
        #expect((env.library.installedPackage(id: package.id) == nil) == missing)
    }

    @Test("A stable global scope removes all confirmed activations", arguments: [false, true])
    func stableScope(missing: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let other = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("other").path)
        try FileManager.default.createDirectory(atPath: other.primaryPath, withIntermediateDirectories: true)
        env.context.insert(other)
        WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(package.id) }
        try env.context.save()
        if missing { _ = try env.library.removePackage(id: package.id) }
        let consent = try PluginRemovalScope.capture(pluginID: package.id, modelContext: env.context)
        #expect(consent.workspaces.count == 2)
        let service = CapabilityCatalogActionService(library: env.library)
        if missing { _ = try service.forgetMissing(pluginID: package.id, modelContext: env.context, confirmedScope: consent) }
        else { _ = try service.remove(package, modelContext: env.context, confirmedScope: consent) }
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) == nil)
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: other) == nil)
    }

    @Test("Fresh storage invalidates consent even while the executing context is stale")
    func anotherContextCannotHideChanges() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let consent = try PluginRemovalScope.capture(pluginID: package.id, modelContext: env.context)
        let writer = ModelContext(env.container)
        writer.autosaveEnabled = false
        let other = Workspace(name: "Other context", primaryPath: env.root.appendingPathComponent("writer").path)
        writer.insert(other)
        WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(package.id) }
        try writer.save()
        #expect(throws: PluginRemovalScope.Failure.scopeChanged) {
            try CapabilityCatalogActionService(library: env.library).remove(package, modelContext: env.context, confirmedScope: consent)
        }
        let observer = ModelContext(env.container)
        let saved = try observer.fetch(FetchDescriptor<Workspace>()).first { $0.id == other.id }
        #expect(saved.flatMap { WorkspaceCapabilityActivation.activation(for: package.id, in: $0) } != nil)
    }
    @Test("Pending legacy enablement is included in global removal consent")
    func pendingLegacyScope() throws {
        let fixture = try PluginMigrationFixture()
        let other = try fixture.workspace(fixture.bID)
        let consent = try PluginRemovalScope.capture(pluginID: "gcloud-workflow", modelContext: fixture.context)
        #expect(consent.workspaces.first { $0.id == other.id }?.legacyEnabled == true)
        #expect(WorkspaceCapabilityActivation.turnOffPendingLegacyPlugin("gcloud-workflow", in: other))
        try fixture.context.save()
        #expect(throws: PluginRemovalScope.Failure.scopeChanged) {
            try PluginRemovalScope.requireCurrent(pluginID: "gcloud-workflow", confirmedScope: consent, modelContext: fixture.context)
        }
    }

    @Test("Opening Remove never commits another editor's pending changes")
    func pendingEditsRefuseCapture() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        env.workspace.name = "Unsaved editor"
        #expect(throws: PluginOperations.OperationError.pendingEdits) {
            try PluginRemovalScope.capture(pluginID: package.id, modelContext: env.context)
        }
        #expect(env.context.hasChanges)
        #expect(env.workspace.name == "Unsaved editor")
    }

}
