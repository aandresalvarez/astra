import Foundation
import SwiftData
import Testing
import ASTRACore
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin Update admission", .serialized)
struct PluginUpdateAdmissionTests {
    @Test("Update rollback restores account modification and binding ordering timestamps")
    func rollbackIncludesAccountModificationTime() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try ConnectorCredentialEditorTests.Fixture()
            defer { env.disk.disk.removeFiles() }
            let account = try env.enable()
            let before = PluginAccountRecord(account)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.package.id, in: env.disk.workspace))
            let binding = try #require(activation.bindings.first)
            let beforeActivation = PluginActivationRecord(activation)
            let restore = PluginUpdateService.captureState(of: [env.disk.workspace])
            account.updatedAt = account.updatedAt.addingTimeInterval(60)
            account.notes = "Rejected update notes"
            binding.createdAt = binding.createdAt.addingTimeInterval(60)
            restore()
            #expect(PluginAccountRecord(account) == before)
            #expect(PluginActivationRecord(activation) == beforeActivation)
        }
    }

    @Test("Restoring equal saved bindings in a different order retains their persistent identities")
    func bindingOrderDoesNotRecreateSavedRows() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginRenameAndMissingTests.twoOfEach()
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        try #require(activation.bindings.count == 2)
        let captured = WorkspaceCapabilityActivation.snapshot(env.workspace)
        let record = try #require(captured.activations.first)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        var object = try #require(json as? [String: Any])
        let bindings = try #require(object["bindings"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding -> (String, [String: Any])? in
            guard let id = binding["id"] as? String else { return nil }
            return (id, binding)
        })
        // SwiftData may reorder an unordered relationship during save. Force
        // the equivalent saved record's order opposite the actual backing
        // array, without dirtying or depending on the model's physical order.
        object["bindings"] = activation.bindings.reversed().compactMap { byID[$0.id.uuidString] }
        let reversed = try JSONDecoder().decode(PluginActivationRecord.self,
            from: JSONSerialization.data(withJSONObject: object))
        let snapshot = WorkspaceCapabilityActivation.Snapshot(state: captured.state, activations: [reversed],
            retired: captured.retired, pendingLegacy: captured.pendingLegacy, updatedAt: captured.updatedAt)
        try #require(activation.bindings.map(\.id) != snapshot.activations.first?.bindings.map(\.id))
        let originalBindings = Set(activation.bindings.map(\.persistentModelID))
        WorkspaceCapabilityActivation.restore(snapshot, to: env.workspace)
        #expect(!env.context.hasChanges)
        #expect(Set(activation.bindings.map(\.persistentModelID)) == originalBindings)
        #expect(WorkspaceCapabilityActivation.snapshot(env.workspace) == captured)
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
        #expect(!env.context.hasChanges, "Pending models after rollback: \(env.context.changedModelsArray.map { String(reflecting: type(of: $0)) })")
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
