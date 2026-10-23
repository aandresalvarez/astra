import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Turn off changes membership only. Resource rows and credential generations
/// belong to their owners, never to a catalog name match.
@MainActor
struct CapabilityActivationDisabler {
    enum Problem: Error, Equatable, LocalizedError {
        case changedWorkspace, changedResource, cannotTurnOff, pendingEdits, recoveryRequired, saveFailed, libraryBusy
        case savedRecoveryPending(UUID), commitUncertain(UUID)

        var operationID: UUID? {
            switch self {
            case .savedRecoveryPending(let id), .commitUncertain(let id): id
            default: nil
            }
        }
        var errorDescription: String? {
            switch self {
            case .changedWorkspace: "This workspace changed. Reopen Plugins before retrying."
            case .changedResource: "This shared skill changed. Reopen Plugins before retrying."
            case .cannotTurnOff: "Workspace skills are removed through Skills."
            case .pendingEdits: "Save other edits before turning this plugin off."
            case .recoveryRequired: "Finish plugin recovery before turning this plugin off."
            case .saveFailed: "The change could not be saved. The previous plugin state was kept."
            case .libraryBusy: "Another plugin operation is in progress. Retry when it finishes."
            case .savedRecoveryPending(let id): PluginOperationProblem.savedRecoveryPending(id).localizedDescription
            case .commitUncertain(let id): PluginOperationProblem.commitUncertain(id).localizedDescription
            }
        }
    }

    struct Result: Equatable {
        var packageID: String
        var disabledSkillIDs: [UUID] = []
        var persisted = true
        var problem: Problem?
        // Retain audit compatibility; Turn off has no destructive result.
        var disabledConnectorIDs: [UUID] { [] }
        var disabledToolIDs: [UUID] { [] }
        var removedWorkspaceSkillIDs: [UUID] { [] }
        var removedWorkspaceConnectorIDs: [UUID] { [] }
    }

    @discardableResult
    func disable(
        _ package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        sourceStore: PluginSourceStore = PluginSourceStore(),
        persist: (ModelContext) throws -> Void = { try $0.save() },
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) -> Result {
        do {
            guard PluginsSurfacePresentation.offersTurnOff(package) else { throw Problem.cannotTurnOff }
            // Check and commit under the same nonblocking source lock. State
            // Turn off must refuse existing recovery debt, never implicitly
            // finish or replay it before validating this request.
            return try sourceStore.exclusively(pluginID: package.id) {
                try requireReady(workspace, modelContext: modelContext, library: library)
                if package.id.hasPrefix("skill."), package.sourceMetadata?.kind == "shared" {
                    guard let rowID = CapabilityInstaller.syntheticSkillRowID(of: package) else { throw Problem.changedResource }
                    let saved = ModelContext(modelContext.container)
                    let rows = try saved.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.id == rowID }))
                    guard rows.count == 1, let row = rows.first, row.isGlobal, !row.isSystemBuiltIn else { throw Problem.changedResource }
                }
                return apply(package, in: workspace, modelContext: modelContext, persist: persist, rewriteMirror: rewriteMirror)
            }
        } catch let problem as Problem { return Result(packageID: package.id, persisted: false, problem: problem) }
        catch let problem as PluginSourceStoreError {
            switch problem {
            case .libraryBusy, .pluginBusy(_):
                return Result(packageID: package.id, persisted: false, problem: .libraryBusy)
            default:
                return Result(packageID: package.id, persisted: false, problem: .recoveryRequired)
            }
        } catch let problem as PluginOperationProblem {
            return Result(packageID: package.id, persisted: false, problem: Self.problem(problem))
        } catch { return Result(packageID: package.id, persisted: false, problem: .recoveryRequired) }
    }

    private func apply(_ package: PluginPackage, in workspace: Workspace, modelContext: ModelContext,
                       persist: (ModelContext) throws -> Void, rewriteMirror: ((Workspace) -> Bool)?) -> Result {
        let before = WorkspaceCapabilityActivation.snapshot(workspace)
        var result = Result(packageID: package.id)
        if let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) {
            guard activation.isEnabled else { return result }
            WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.removeAll { $0 == package.id } }
        } else if let rowID = CapabilityInstaller.syntheticSkillRowID(of: package) {
            let id = rowID.uuidString
            guard WorkspaceCapabilityActivation.hasSharedResource(.skill, id: rowID, in: workspace) else { return result }
            WorkspaceCapabilityActivation.mutate(workspace) { $0.globalSkillIDs.removeAll { $0 == id } }
            result.disabledSkillIDs = [rowID]
        } else {
            guard WorkspaceCapabilityActivation.turnOffPendingLegacyPlugin(package.id, in: workspace) else { return result }
        }
        workspace.updatedAt = Date()
        switch PluginStateCommit.save(workspace: workspace, pluginIDs: [package.id], modelContext: modelContext,
            persist: persist, export: rewriteMirror) {
        case .completed: break
        case .pendingRecovery(let id): result.problem = .savedRecoveryPending(id)
        case .indeterminate(let id, _): result.persisted = false; result.problem = .commitUncertain(id)
        case .notCommitted:
            modelContext.rollback()
            WorkspaceCapabilityActivation.restore(before, to: workspace)
            result = Result(packageID: package.id, persisted: false, problem: .saveFailed)
        }
        return result
    }

    private func requireReady(_ workspace: Workspace, modelContext: ModelContext, library: CapabilityLibrary) throws {
        guard workspace.modelContext === modelContext, !workspace.isDeleted else { throw Problem.changedWorkspace }
        guard !modelContext.hasChanges else { throw Problem.pendingEdits }
        let id = workspace.id
        let savedContext = ModelContext(modelContext.container)
        let rows = try savedContext.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id }))
        guard rows.count == 1, let saved = rows.first,
              WorkspaceCapabilityActivation.snapshot(saved) == WorkspaceCapabilityActivation.snapshot(workspace) else {
            throw Problem.changedWorkspace
        }
        guard try PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore()).pendingIDs().isEmpty else {
            throw Problem.recoveryRequired
        }
        if let pending = try PluginPendingOperations.capture(modelContext: modelContext).first {
            guard pending.snapshot.manifestDigest == nil else { throw Problem.recoveryRequired }
            throw pending.problem
        }
    }

    private static func problem(_ problem: PluginOperationProblem) -> Problem {
        switch problem {
        case .savedRecoveryPending(let id): .savedRecoveryPending(id)
        case .commitUncertain(let id): .commitUncertain(id)
        }
    }
}
