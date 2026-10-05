import Foundation
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
