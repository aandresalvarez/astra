import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Prepare ASTRA-owned storage before freezing paths into a new request.
@MainActor
enum TaskExecutionResourcePreparation {
    enum ScopeError: LocalizedError {
        case changed

        var errorDescription: String? {
            "The workspace or accepted storage scope changed while waiting. Submit a new turn before preparing task files."
        }
    }

    static func isCurrent(task: AgentTask, scope: TaskExecutionResourceScope?) -> Bool {
        guard let scope else { return true }
        let access = TaskWorkspaceAccess(task: task)
        return scope.isValid && scope.workspacePath == access.effectiveWorkspacePath
            && (scope.workspacePath.isEmpty || scope.coversWrite(to: access.canonicalTaskFolder))
            && scope.resources.filter({ $0.role == .taskStorage }).allSatisfy {
                $0.path == access.canonicalTaskFolder && scope.coversWrite(to: $0.path)
            }
    }

    /// Scoped runs export only while the accepted scope still matches the live
    /// workspace; otherwise state is saved without writing into an edited workspace.
    @discardableResult
    static func saveAndExportIfCurrent(
        task: AgentTask,
        scope: TaskExecutionResourceScope?,
        modelContext: ModelContext,
        auditFields: [String: String] = [:]
    ) -> Bool {
        guard isCurrent(task: task, scope: scope) else {
            return WorkspacePersistenceCoordinator.saveWithoutAutoExport(
                modelContext: modelContext, taskID: task.id, auditFields: auditFields)
        }
        return WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace, modelContext: modelContext, taskID: task.id, auditFields: auditFields)
    }

    /// Scope rejections export only while the live workspace is still the accepted one.
    static func sameWorkspace(task: AgentTask?, scope: TaskExecutionResourceScope?) -> Bool {
        guard let task else { return false }
        return scope?.workspacePath == TaskWorkspaceAccess(task: task).effectiveWorkspacePath
    }

    static func prepare(task: AgentTask, materializeInputs: Bool) throws {
        _ = try TaskStorageBinding.load(for: task)
        guard materializeInputs, task.inputs.contains(where: { EphemeralComposerAttachment.isEphemeralPath($0) }) else { return }
        guard !TaskWorkspaceAccess(task: task).effectiveWorkspacePath.isEmpty else { return }
        let folder = try ensureTaskFolder(task: task)
        let outcome = TaskInputMaterializer.materialize(task: task, taskFolder: folder)
        guard outcome.failed.isEmpty else { throw CocoaError(.fileReadUnknown) }
    }

    static func ensureTaskFolder(task: AgentTask, scope: TaskExecutionResourceScope? = nil) throws -> String {
        guard isCurrent(task: task, scope: scope ?? task.acceptedResourceScope) else { throw ScopeError.changed }
        let access = TaskWorkspaceAccess(task: task)
        let legacy = WorkspaceFileLayout.legacyTaskFolder(workspacePath: access.effectiveWorkspacePath, taskID: task.id)
        let migrationRequired = !FileManager.default.fileExists(atPath: access.canonicalTaskFolder)
            && FileManager.default.fileExists(atPath: legacy)
        if migrationRequired {
            _ = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(workspacePath: access.effectiveWorkspacePath, taskID: task.id)
            guard !FileManager.default.fileExists(atPath: legacy) else { throw CocoaError(.fileWriteUnknown) }
        }
        return try access.ensureTaskFolder()
    }
}
