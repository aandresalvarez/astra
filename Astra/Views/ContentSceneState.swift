import Foundation

enum ContentSelectionResolver {
    static func effectiveWorkspace(selectedTask: AgentTask?, selectedWorkspace: Workspace?) -> Workspace? {
        selectedTask?.workspace ?? selectedWorkspace
    }
}

enum ContentWorkspaceSelectionResolver {
    static func restoredWorkspace(
        workspaces: [Workspace],
        currentSelection: Workspace?,
        lastSelectedWorkspaceID: String,
        lastSelectedWorkspacePath: String
    ) -> Workspace? {
        guard !workspaces.isEmpty else { return nil }

        if let currentSelection,
           workspaces.contains(where: { $0.id == currentSelection.id }) {
            return currentSelection
        }

        return workspaces.first(where: { $0.id.uuidString == lastSelectedWorkspaceID }) ??
            workspaces.first(where: { $0.primaryPath == lastSelectedWorkspacePath }) ??
            workspaces.first
    }
}

enum ContentDetailPresentation: Equatable {
    case draftTask
    case existingTask
    case newTaskComposer
    case workspaceHome
    case noWorkspace

    static func resolve(
        selectedTask: AgentTask?,
        effectiveWorkspace: Workspace?,
        isComposingTask: Bool
    ) -> ContentDetailPresentation {
        if let selectedTask {
            return selectedTask.status == .draft ? .draftTask : .existingTask
        }

        guard let effectiveWorkspace else {
            return .noWorkspace
        }

        if isComposingTask || effectiveWorkspace.tasks.isEmpty {
            return .newTaskComposer
        }

        return .workspaceHome
    }
}
