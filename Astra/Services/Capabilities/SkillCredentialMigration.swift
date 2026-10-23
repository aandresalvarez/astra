import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Publishes legacy authored values through the same generation and receipt
/// protocol as explicit edits. No startup write owns an accepted namespace.
@MainActor
enum SkillCredentialMigration {
    @discardableResult
    static func migrate(_ skill: Skill, modelContext: ModelContext,
                        persist: (ModelContext) throws -> Void = { try $0.save() },
                        rewriteMirror: ((Workspace) -> Bool)? = nil) throws -> Bool {
        guard skill.modelContext === modelContext, !skill.isDeleted, skill.originPackageID == nil else {
            throw SkillCredentialEditor.Failure.changedSkill
        }
        guard !modelContext.hasChanges else { throw SkillCredentialEditor.Failure.pendingEdits }
        let saved = ModelContext(modelContext.container)
        let id = skill.id
        let previous = Snapshot(skill)
        let rows = try saved.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id }))
        guard rows.count == 1, rows.first.map(Snapshot.init) == previous else { throw SkillCredentialEditor.Failure.changedSkill }
        try requireReady(modelContext: modelContext)
        guard skill.environmentValues.dropFirst(skill.environmentKeys.count).allSatisfy({ $0.isEmpty }) else {
            throw SkillCredentialEditor.Failure.legacyFieldsNeedReview
        }
        guard skill.environmentKeys.indices.contains(where: {
            Skill.isSecretEnvironmentKey(skill.environmentKeys[$0]) && !skill.normalizedEnvironmentValue(at: $0).isEmpty
        }) else { return false }
        var seen = Set<String>()
        for key in skill.environmentKeys where Skill.isSecretEnvironmentKey(key) {
            guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespacesAndNewlines),
                  seen.insert(key.uppercased()).inserted else { throw SkillCredentialEditor.Failure.legacyFieldsNeedReview }
        }
        // Former consumers can still have recovery mirrors naming this row.
        let workspaces = try saved.fetch(FetchDescriptor<Workspace>()).map(\.id)
        let prepared = try SkillCredentialGenerationTransaction.prepareLegacy(skill: skill, modelContext: modelContext)
        var attemptedCommit = false
        do {
            try requireReady(modelContext: modelContext)
            skill.credentialNamespaceID = prepared.namespaceID
            for index in skill.environmentKeys.indices where Skill.isSecretEnvironmentKey(skill.environmentKeys[index])
                && index < skill.environmentValues.count { skill.environmentValues[index] = "" }
            skill.updatedAt = Date()
            attemptedCommit = true
            switch PluginStateCommit.save(workspaceIDs: workspaces, pluginIDs: [], kind: .configure,
                modelContext: modelContext, persist: persist, export: rewriteMirror) {
            case .completed: prepared.completed()
            case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
            case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
            case .notCommitted: throw SkillCredentialEditor.Failure.saveFailed
            }
            return true
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            if attemptedCommit { modelContext.rollback() }
            previous.restore(skill)
            prepared.discard()
            throw error
        }
    }

    private static func requireReady(modelContext: ModelContext) throws {
        guard try PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore()).pendingIDs().isEmpty else {
            throw SkillCredentialEditor.Failure.recoveryRequired
        }
        if let pending = try PluginPendingOperations.capture(modelContext: modelContext).first { throw pending.problem }
    }

    private struct Snapshot: Equatable {
        let namespace: UUID?
        let keys, values: [String]
        let origin: String?
        let updatedAt: Date
        init(_ skill: Skill) {
            namespace = skill.credentialNamespaceID; keys = skill.environmentKeys; values = skill.environmentValues
            origin = skill.originPackageID; updatedAt = skill.updatedAt
        }
        func restore(_ skill: Skill) {
            skill.credentialNamespaceID = namespace; skill.environmentKeys = keys; skill.environmentValues = values
            skill.updatedAt = updatedAt
        }
    }
}
