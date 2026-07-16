import Foundation
import ASTRAModels

struct ContentWorkspaceSelectionPersistence: Equatable {
    let workspaceID: String
    let workspacePath: String

    static let empty = ContentWorkspaceSelectionPersistence(workspaceID: "", workspacePath: "")
}

enum ContentSelectionResolver {
    static func effectiveWorkspace(selectedTask: AgentTask?, selectedWorkspace: Workspace?) -> Workspace? {
        selectedTask?.workspace ?? selectedWorkspace
    }

    static func workspace(for app: WorkspaceApp?, in workspaces: [Workspace]) -> Workspace? {
        guard let app else { return nil }
        return workspace(id: app.workspaceID, in: workspaces)
    }

    static func workspace(id: UUID?, in workspaces: [Workspace]) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
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
    case workspaceApp
    case workspaceAppStudio
    case newTaskComposer
    case workspaceHome
    case noWorkspace

    static func resolve(
        selectedTask: AgentTask?,
        effectiveWorkspace: Workspace?,
        isComposingTask: Bool,
        selectedWorkspaceApp: WorkspaceApp? = nil,
        isComposingWorkspaceApp: Bool = false
    ) -> ContentDetailPresentation {
        if let selectedTask {
            return selectedTask.status == .draft ? .draftTask : .existingTask
        }

        guard let effectiveWorkspace else {
            return .noWorkspace
        }

        if isComposingWorkspaceApp {
            return .workspaceAppStudio
        }

        if isComposingTask {
            return .newTaskComposer
        }

        if let selectedWorkspaceApp {
            return selectedWorkspaceApp.lifecycleStatus == .draft ? .workspaceAppStudio : .workspaceApp
        }

        if effectiveWorkspace.tasks.isEmpty {
            return .newTaskComposer
        }

        return .workspaceHome
    }
}

enum ScheduleCreationGate {
    static func canPresent(effectiveWorkspace: Workspace?) -> Bool {
        effectiveWorkspace != nil
    }
}

struct ContentWorkspaceSelectionUpdate {
    enum WorkspaceAppSurfacePolicy {
        case clear
        case preserveIfWorkspaceMatches
    }

    let selectedTask: AgentTask?
    let selectedWorkspace: Workspace?
    let isComposingTask: Bool
    let workspaceAppSurfacePolicy: WorkspaceAppSurfacePolicy
    let shouldPresentRightRail: Bool
    let shouldRememberShelfStateWhenPresentingRightRail: Bool
}

@MainActor
struct ContentWorkspaceSelectionCoordinator {
    let selectedTask: AgentTask?
    let selectedWorkspace: Workspace?
    let isComposingTask: Bool

    func restore(workspace restored: Workspace?) -> ContentWorkspaceSelectionUpdate {
        guard let restored else {
            return ContentWorkspaceSelectionUpdate(
                selectedTask: nil,
                selectedWorkspace: nil,
                isComposingTask: false,
                workspaceAppSurfacePolicy: .preserveIfWorkspaceMatches,
                shouldPresentRightRail: false,
                shouldRememberShelfStateWhenPresentingRightRail: true
            )
        }

        return ContentWorkspaceSelectionUpdate(
            selectedTask: selectedTask,
            selectedWorkspace: restored,
            isComposingTask: isComposingTask,
            workspaceAppSurfacePolicy: .preserveIfWorkspaceMatches,
            shouldPresentRightRail: false,
            shouldRememberShelfStateWhenPresentingRightRail: true
        )
    }

    func open(workspace: Workspace) -> ContentWorkspaceSelectionUpdate {
        ContentWorkspaceSelectionUpdate(
            selectedTask: nil,
            selectedWorkspace: workspace,
            isComposingTask: false,
            workspaceAppSurfacePolicy: .clear,
            shouldPresentRightRail: true,
            shouldRememberShelfStateWhenPresentingRightRail: false
        )
    }

    func open(task: AgentTask) -> ContentWorkspaceSelectionUpdate {
        ContentWorkspaceSelectionUpdate(
            selectedTask: task,
            selectedWorkspace: task.workspace ?? selectedWorkspace,
            isComposingTask: false,
            workspaceAppSurfacePolicy: .clear,
            shouldPresentRightRail: true,
            shouldRememberShelfStateWhenPresentingRightRail: false
        )
    }

    func create(workspace: Workspace) -> ContentWorkspaceSelectionUpdate {
        ContentWorkspaceSelectionUpdate(
            selectedTask: selectedTask,
            selectedWorkspace: workspace,
            isComposingTask: isComposingTask,
            workspaceAppSurfacePolicy: .preserveIfWorkspaceMatches,
            shouldPresentRightRail: false,
            shouldRememberShelfStateWhenPresentingRightRail: true
        )
    }

    func importWorkspace(_ workspace: Workspace?) -> ContentWorkspaceSelectionUpdate {
        ContentWorkspaceSelectionUpdate(
            selectedTask: selectedTask,
            selectedWorkspace: workspace ?? selectedWorkspace,
            isComposingTask: isComposingTask,
            workspaceAppSurfacePolicy: .preserveIfWorkspaceMatches,
            shouldPresentRightRail: false,
            shouldRememberShelfStateWhenPresentingRightRail: true
        )
    }

    func delete(workspace deleted: Workspace, nextWorkspace: Workspace?) -> ContentWorkspaceSelectionUpdate {
        let deletedCurrentWorkspace = selectedWorkspace?.id == deleted.id
        let deletedSelectedTaskWorkspace = selectedTask?.workspace?.id == deleted.id

        return ContentWorkspaceSelectionUpdate(
            selectedTask: deletedSelectedTaskWorkspace ? nil : selectedTask,
            selectedWorkspace: deletedCurrentWorkspace ? nextWorkspace : selectedWorkspace,
            isComposingTask: deletedSelectedTaskWorkspace ? false : isComposingTask,
            workspaceAppSurfacePolicy: .preserveIfWorkspaceMatches,
            shouldPresentRightRail: false,
            shouldRememberShelfStateWhenPresentingRightRail: true
        )
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

    func workspace(for app: WorkspaceApp?) -> Workspace? {
        ContentSelectionResolver.workspace(for: app, in: workspaces)
    }

    func workspace(id: UUID?) -> Workspace? {
        ContentSelectionResolver.workspace(id: id, in: workspaces)
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
