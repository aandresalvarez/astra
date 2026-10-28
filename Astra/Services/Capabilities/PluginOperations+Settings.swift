import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

extension PluginOperations {
    struct SettingChange {
        let skill: PluginSkill
        let key: String
        let value: String
        var component: String { CapabilityResourceOrigin.componentID(for: skill) }
        var field: String { PluginActivation.settingKey(componentID: component, key: key) }
    }

    static func setSetting(
        _ key: String, to value: String, of skill: PluginSkill, package: PluginPackage,
        in workspace: Workspace, modelContext: ModelContext,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws {
        try setSettings([SettingChange(skill: skill, key: key, value: value)], package: package,
            in: workspace, modelContext: modelContext, secrets: secrets, persist: persist, rewriteMirror: rewriteMirror)
    }

    /// One activation generation for all replacements, including different
    /// components. Never read a value the person is explicitly replacing.
    /// Unreplaced unreadable values still prevent publication of the whole edit.
    static func setSettings(
        _ changes: [SettingChange], package: PluginPackage, in workspace: Workspace, modelContext: ModelContext,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport,
        rewriteMirror: ((Workspace) -> Bool)? = nil, vault: SecretStore = KeychainSecretStore()
    ) throws {
        guard !modelContext.hasChanges else { throw OperationError.pendingEdits }
        guard workspace.modelContext === modelContext, !workspace.isDeleted else { throw OperationError.workspaceChanged }
        try PluginActivationAdmission.requireCurrent(in: workspace, modelContext: modelContext)
        guard let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) else {
            throw OperationError.notAdded(pluginID: package.id)
        }
        guard changes.allSatisfy({ package.skills.contains($0.skill) }),
              !PluginRuntimeProjection.awaitsUpdate(activation, to: package) else { throw OperationError.updateRequired }
        guard !changes.isEmpty, changes.allSatisfy({ !$0.key.isEmpty }),
              Set(changes.map(\.field)).count == changes.count else { throw OperationError.invalidSettings }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        let replacements = changes.filter {
            Skill.isSecretEnvironmentKey($0.key) || activation.secretSettingKeys.contains($0.field)
        }.map {
            PluginCredentialGenerationTransaction.Replacement(component: $0.component, key: $0.key,
                value: Skill.isSecretEnvironmentKey($0.key) && !$0.value.isEmpty ? $0.value : nil)
        }
        let prepared = replacements.isEmpty ? nil : try PluginCredentialGenerationTransaction.prepare(
            activation: activation, workspaceID: workspace.id, replacements: replacements,
            skillName: package.name, modelContext: modelContext, persistence: secrets ?? SkillSecretSeam.required, vault: vault)
        if let prepared { WorkspaceCapabilityActivation.setCredentialNamespaceSeed(prepared.generation, on: activation) }
        for change in changes {
            let secret = Skill.isSecretEnvironmentKey(change.key)
            WorkspaceCapabilityActivation.setConfigValue(secret ? nil : change.value, forKey: change.field, on: activation)
            WorkspaceCapabilityActivation.setSecretRecorded(secret && !change.value.isEmpty, forKey: change.field, on: activation)
        }
        workspace.updatedAt = Date()
        do {
            try save(workspace, modelContext: modelContext, restoring: snapshot,
                pluginIDs: [package.id], rewriteMirror: rewriteMirror, persist: persist)
            prepared?.completed(keeping: Set(PluginRuntimeProjection.secretNamespaces(of: activation, package: nil)))
        } catch {
            if !PluginOperationProblem.preventsRollback(error) { prepared?.discard() }
            throw error
        }
    }
}
