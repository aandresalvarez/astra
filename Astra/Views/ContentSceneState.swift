import Foundation

struct ContentWorkspaceSelectionPersistence: Equatable {
    let workspaceID: String
    let workspacePath: String

    static let empty = ContentWorkspaceSelectionPersistence(workspaceID: "", workspacePath: "")
}

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

@MainActor
struct ContentSceneCoordinator {
    let workspaces: [Workspace]
    let selectedTask: AgentTask?
    let selectedWorkspace: Workspace?
    let lastSelectedWorkspaceID: String
    let lastSelectedWorkspacePath: String

    var effectiveWorkspace: Workspace? {
        ContentSelectionResolver.effectiveWorkspace(
            selectedTask: selectedTask,
            selectedWorkspace: selectedWorkspace
        )
    }

    var effectiveWorkspaceID: UUID? {
        effectiveWorkspace?.id
    }

    var workspaceSelectionSignature: String {
        workspaces
            .map { "\($0.id.uuidString)|\($0.primaryPath)" }
            .joined(separator: ",")
    }

    func restoredWorkspace() -> Workspace? {
        ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: workspaces,
            currentSelection: selectedWorkspace,
            lastSelectedWorkspaceID: lastSelectedWorkspaceID,
            lastSelectedWorkspacePath: lastSelectedWorkspacePath
        )
    }

    func persistence(for workspace: Workspace?) -> ContentWorkspaceSelectionPersistence {
        guard let workspace else { return .empty }
        return ContentWorkspaceSelectionPersistence(
            workspaceID: workspace.id.uuidString,
            workspacePath: workspace.primaryPath
        )
    }

    func presentation(isComposingTask: Bool) -> ContentDetailPresentation {
        ContentDetailPresentation.resolve(
            selectedTask: selectedTask,
            effectiveWorkspace: effectiveWorkspace,
            isComposingTask: isComposingTask
        )
    }
}
