import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Removing an authored resource publishes its retirement intent and domain
/// receipt before any secret can be collected. Saved requests and recovery
/// mirrors, rather than the vanished row, decide the namespace's lifetime.
@MainActor
enum SkillRetirement {
    enum Failure: Error, LocalizedError {
        case changedSkill, pendingEdits, recoveryRequired, saveFailed
        var errorDescription: String? {
            switch self {
            case .changedSkill: "This skill changed or cannot be deleted. Reopen it before retrying."
            case .pendingEdits: "Save other edits before deleting this skill."
            case .recoveryRequired: "Finish recovery in Plugins before deleting this skill."
            case .saveFailed: "The skill could not be deleted. Its saved settings and secrets were kept."
            }
        }
    }

    static func remove(_ skill: Skill, modelContext: ModelContext,
                       persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil) throws {
        guard skill.modelContext === modelContext, !skill.isDeleted, !skill.isSystemBuiltIn,
              skill.originPackageID == nil else { throw Failure.changedSkill }
        guard !modelContext.hasChanges else { throw Failure.pendingEdits }
        // A second Delete must keep the original recovery action. Admission
        // must not complete the previous receipt and silently replay deletion.
        try requireReady(modelContext: modelContext)
        do {
            try PluginMutationScope.perform(pluginID: "__skill_credentials__", library: CapabilityLibrary(),
                store: PluginSourceStore(), modelContext: modelContext) { _ in
                    try removeReady(skill, modelContext: modelContext, persist: persist, rewriteMirror: rewriteMirror)
                }
        } catch PluginSourceStoreError.pluginBusy(_) { throw PluginSourceStoreError.libraryBusy }
    }

    private static func removeReady(_ skill: Skill, modelContext: ModelContext,
                                    persist: (ModelContext) throws -> Void, rewriteMirror: ((Workspace) -> Bool)?) throws {
        guard skill.modelContext === modelContext, !skill.isDeleted, !skill.isSystemBuiltIn,
              skill.originPackageID == nil else { throw Failure.changedSkill }
        guard !modelContext.hasChanges else { throw Failure.pendingEdits }
        let saved = ModelContext(modelContext.container)
        let id = skill.id
        let rows = try saved.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id }))
        guard rows.count == 1, let source = rows.first, source.updatedAt == skill.updatedAt,
              source.secretNamespaceID == skill.secretNamespaceID, source.environmentKeys == skill.environmentKeys,
              source.environmentValues == skill.environmentValues else { throw Failure.changedSkill }
        let workspaces = try saved.fetch(FetchDescriptor<Workspace>()).map(\.id)
        try requireReady(modelContext: modelContext)
        let namespace = skill.secretNamespaceID
        let journal = try SkillCredentialGenerationJournal(modelContext: modelContext)
        let lease = try journal?.acquireLease()
        if let lease { try journal?.record([namespace], lease: lease) }
        modelContext.delete(skill)
        switch PluginStateCommit.save(workspaceIDs: workspaces, pluginIDs: [], kind: .remove,
            modelContext: modelContext, persist: persist, export: rewriteMirror) {
        case .completed:
            lease?.release()
            // Idempotent collection logs and keeps debt on read/delete failure;
            // a committed deletion must never be presented as an undone save.
            SkillCredentialGenerationJournal.resumeAfterWorkspaceRecovery(modelContext: modelContext)
        case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
        case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
        case .notCommitted:
            modelContext.rollback()
            throw Failure.saveFailed
        }
    }

    static func recover(_ id: UUID, modelContext: ModelContext) throws {
        try SkillCredentialEditor.recover(id, modelContext: modelContext)
    }

    private static func requireReady(modelContext: ModelContext) throws {
        do {
            guard try PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore()).pendingIDs().isEmpty else {
                throw Failure.recoveryRequired
            }
            if let pending = try PluginPendingOperations.capture(modelContext: modelContext).first { throw pending.problem }
        } catch let problem as PluginOperationProblem { throw problem }
        catch let problem as Failure { throw problem }
        catch { throw Failure.recoveryRequired }
    }
}
