import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The access note shown beside each folder in the prompt's workspace folder
/// list. It reads the same roots the launch grants, so a folder the sandbox or
/// a Docker mount keeps read-only is never presented as an editable folder.
struct AgentPromptWorkspaceFolderLabels {
    private let codeRoot: String
    private let replaced: Set<String>
    private let readOnly: Set<String>

    init(task: AgentTask, codeDir: String) {
        let access = TaskWorkspaceAccess(task: task)
        codeRoot = WorkspacePathPresentation.standardizedPath(codeDir)
        replaced = Set(access.replacedSourceCheckoutPaths.map(WorkspacePathPresentation.standardizedPath))
        readOnly = Set(access.runtimeReadOnlyWorkspacePaths.map(WorkspacePathPresentation.standardizedPath))
    }

    func label(for path: String) -> String {
        if path == codeRoot { return " (active code root)" }
        if replaced.contains(path) { return " (source checkout of the active worktree; read-only, edit the worktree)" }
        if readOnly.contains(path) { return " (read-only for this task; write task files to the task output folder)" }
        return ""
    }
}
