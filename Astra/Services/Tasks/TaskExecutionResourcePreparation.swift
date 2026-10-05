import Foundation
import ASTRAModels
import ASTRAPersistence

/// Prepare ASTRA-owned storage before freezing paths into a new request.
@MainActor
enum TaskExecutionResourcePreparation {
    static func prepare(task: AgentTask, materializeInputs: Bool) throws {
        guard materializeInputs, task.inputs.contains(where: { EphemeralComposerAttachment.isEphemeralPath($0) }) else { return }
        guard !TaskWorkspaceAccess(task: task).effectiveWorkspacePath.isEmpty else { return }
        let folder = try ensureTaskFolder(task: task)
        let outcome = TaskInputMaterializer.materialize(task: task, taskFolder: folder)
        guard outcome.failed.isEmpty else { throw CocoaError(.fileReadUnknown) }
    }

    static func ensureTaskFolder(task: AgentTask) throws -> String {
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
