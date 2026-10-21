import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin Update admission", .serialized)
struct PluginUpdateAdmissionTests {
    @Test("Restoring equal saved bindings in a different order retains their persistent identities")
    func bindingOrderDoesNotRecreateSavedRows() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginRenameAndMissingTests.twoOfEach()
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let ordered = activation.bindings.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        try #require(ordered.count == 2)
        activation.bindings = Array(ordered.reversed())
        try env.context.save()
        let snapshot = WorkspaceCapabilityActivation.snapshot(env.workspace)
        try #require(activation.bindings.map(\.id) != snapshot.activations.first?.bindings.map(\.id))
        let originalBindings = Set(activation.bindings.map(\.persistentModelID))
        WorkspaceCapabilityActivation.restore(snapshot, to: env.workspace)
        #expect(!env.context.hasChanges)
        #expect(Set(activation.bindings.map(\.persistentModelID)) == originalBindings)
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == snapshot)
    }

    @Test("A failed private Update restores a clean context so a real retry can succeed")
    func failureDoesNotCreatePendingEditorWork() throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        try env.installer.enable(env.package, in: env.workspace, modelContext: env.context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let accepted = PluginActivationRecord(activation)
        var updated = env.package
        updated.version = "2.0.0"
        updated.skills = PluginOperationsTests.package(version: "2.0.0").skills
        #expect(throws: (any Error).self) {
            _ = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release,
                persist: { _ in throw NSError(domain: "synthetic.update.retry", code: 1) })
        }
        #expect(PluginActivationRecord(activation) == accepted)
        #expect(!env.context.hasChanges)
        #expect(try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release) == 1)
        #expect(activation.recordedVersion == "2.0.0")
    }

    @Test("Update cannot save or roll back an unrelated unsaved edit", arguments: [false, true])
    func unrelatedEditIsUntouched(failsSave: Bool) throws {
        let env = try PluginAddCommitTests.Fixture()
        defer { env.disk.removeFiles() }
        try env.installer.enable(env.package, in: env.workspace, modelContext: env.context)
        let originalName = env.workspace.name
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.workspace))
        let accepted = PluginActivationRecord(activation)
        let receiptCount = try env.context.fetchCount(FetchDescriptor<PluginOperationReceipt>())
        env.workspace.name = "Unrelated edit still in progress"
        try #require(env.context.hasChanges)
        var updated = env.package
        updated.version = "2.0.0"
        var persistCalled = false
        #expect(throws: PluginUpdateService.UpdateError.pendingEdits) {
            _ = try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [updated], mode: .release,
                persist: { context in
                    persistCalled = true
                    if failsSave { throw NSError(domain: "synthetic.update.admission", code: 1) }
                    try context.save()
                })
        }
        #expect(!persistCalled)
        #expect(env.workspace.name == "Unrelated edit still in progress")
        #expect(env.context.hasChanges)
        #expect(PluginActivationRecord(activation) == accepted)
        let saved = ModelContext(env.context.container)
        #expect(try saved.fetch(FetchDescriptor<Workspace>()).first?.name == originalName)
        #expect(try saved.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == receiptCount)
    }
}
