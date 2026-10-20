import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// One update's unpublished skill generations. The activation remains the
/// durable owner; this preparation only retains rollback/commit resources.
@MainActor
final class PluginUpdateSkillCredentials {
    private let modelContext: ModelContext
    private let persistence: any SkillSecretPersisting.Type
    private var prepared: [UUID: PluginCredentialGenerationTransaction] = [:]
    private(set) var released: Set<UUID> = []
    var producerLease: PluginCredentialProducerLease? { prepared.values.first?.producerLease }

    init(modelContext: ModelContext, persistence: any SkillSecretPersisting.Type) {
        self.modelContext = modelContext
        self.persistence = persistence
    }

    /// Lazy: reviewed/withheld/no-op activations must not rotate a generation
    /// merely because the update examined them. Call before the first write.
    func prepare(_ activation: PluginActivation, in workspace: Workspace, package: PluginPackage) throws {
        guard prepared[activation.id] == nil else { return }
        let previous = Set(PluginRuntimeProjection.secretNamespaces(of: activation, package: nil))
        let components = Set(package.skills.map(CapabilityResourceOrigin.componentID(for:)))
        let transaction: PluginCredentialGenerationTransaction
        do {
            transaction = try PluginCredentialGenerationTransaction.prepareCopy(activation: activation,
                workspaceID: workspace.id, modelContext: modelContext, skillName: package.name,
                persistence: persistence, additionalComponents: components, producerLease: producerLease)
        } catch PluginOperations.OperationError.secretReadFailed(let key) {
            throw PluginUpdateService.UpdateError.secretReadFailed(component: package.name, key: key)
        } catch PluginOperations.OperationError.secretSaveFailed(let key) {
            throw PluginUpdateService.UpdateError.secretCopyFailed(component: package.name, key: key)
        }
        prepared[activation.id] = transaction
        released.formUnion(previous)
        WorkspaceCapabilityActivation.setCredentialNamespaceSeed(transaction.generation, on: activation)
    }

    func owns(_ namespace: UUID) -> Bool { prepared.values.contains { $0.namespaces.contains(namespace) } }
    func completed() { prepared.values.forEach { $0.completed() } }
    func discard() { prepared.values.forEach { $0.discard() } }
}
