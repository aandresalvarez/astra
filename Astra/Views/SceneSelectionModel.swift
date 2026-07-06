import Foundation
import SwiftUI
import ASTRAModels

enum SceneSelectionSurface: Equatable {
    case none
    case workspace(UUID)
    case task(UUID)
    case workspaceApp(UUID)
    case taskComposer(UUID?)
    case appComposer(UUID?)
}

struct SceneSelectionApplyResult: Equatable {
    let clearedWorkspaceAppSurface: Bool
    let cancelledWorkspaceAppComposer: Bool
}

/// The single mutable owner for ContentView's scene selection tuple.
///
/// Pure route restoration stays in `ContentSceneState`; this model owns the
/// stateful invariant that task, workspace app, task composer, and app composer
/// surfaces are mutually exclusive while the selected workspace is retained as
/// the durable context those surfaces sit inside.
@MainActor
final class SceneSelectionModel: ObservableObject {
    @Published private(set) var selectedTask: AgentTask?
    @Published private(set) var selectedWorkspace: Workspace?
    @Published private(set) var selectedWorkspaceApp: WorkspaceApp?
    @Published private(set) var isComposingWorkspaceApp = false
    @Published private(set) var isComposingTask = false

    var activeSurface: SceneSelectionSurface {
        if let selectedTask {
            return .task(selectedTask.id)
        }
        if isComposingWorkspaceApp {
            return .appComposer(selectedWorkspace?.id)
        }
        if isComposingTask {
            return .taskComposer(selectedWorkspace?.id)
        }
        if let selectedWorkspaceApp {
            return .workspaceApp(selectedWorkspaceApp.id)
        }
        if let selectedWorkspace {
            return .workspace(selectedWorkspace.id)
        }
        return .none
    }

    var shouldClearWorkspaceAppSurfaceAfterWorkspaceChange: Bool {
        if isComposingWorkspaceApp { return false }
        guard let selectedWorkspaceApp else { return false }
        return selectedWorkspaceApp.workspaceID != selectedWorkspace?.id
    }

    func restoreWorkspace(_ workspace: Workspace?) {
        selectedTask = nil
        selectedWorkspace = workspace
        clearTransientSurfaces()
    }

    func openWorkspace(_ workspace: Workspace?) {
        selectedTask = nil
        selectedWorkspace = workspace
        clearTransientSurfaces()
    }

    func openTask(_ task: AgentTask?) {
        guard let task else {
            selectedTask = nil
            isComposingTask = false
            return
        }
        if let taskWorkspace = task.workspace {
            selectedWorkspace = taskWorkspace
        }
        selectedTask = task
        selectedWorkspaceApp = nil
        isComposingTask = false
        isComposingWorkspaceApp = false
    }

    func openApp(_ app: WorkspaceApp?, workspace: Workspace? = nil) {
        if let workspace {
            selectedWorkspace = workspace
        }
        selectedTask = nil
        selectedWorkspaceApp = app
        isComposingTask = false
        isComposingWorkspaceApp = false
    }

    func composeTask(workspace: Workspace? = nil) {
        if let workspace {
            selectedWorkspace = workspace
        }
        selectedTask = nil
        selectedWorkspaceApp = nil
        isComposingTask = true
        isComposingWorkspaceApp = false
    }

    func composeApp(workspace: Workspace? = nil) {
        if let workspace {
            selectedWorkspace = workspace
        }
        selectedTask = nil
        selectedWorkspaceApp = nil
        isComposingTask = false
        isComposingWorkspaceApp = true
    }

    func clear() {
        selectedTask = nil
        clearTransientSurfaces()
    }

    func clearWorkspaceAppSurface() {
        selectedWorkspaceApp = nil
        isComposingWorkspaceApp = false
    }

    @discardableResult
    func apply(_ update: ContentWorkspaceSelectionUpdate) -> SceneSelectionApplyResult {
        let previousSelectedWorkspaceApp = selectedWorkspaceApp
        let wasComposingWorkspaceApp = isComposingWorkspaceApp
        let preserveWorkspaceAppSurface = shouldPreserveWorkspaceAppSurface(for: update)

        selectedWorkspace = update.selectedWorkspace
        selectedTask = update.selectedTask
        isComposingTask = update.isComposingTask
        if !preserveWorkspaceAppSurface {
            selectedWorkspaceApp = nil
            isComposingWorkspaceApp = false
        }

        return SceneSelectionApplyResult(
            clearedWorkspaceAppSurface: (previousSelectedWorkspaceApp != nil || wasComposingWorkspaceApp)
                && selectedWorkspaceApp == nil
                && !isComposingWorkspaceApp,
            cancelledWorkspaceAppComposer: wasComposingWorkspaceApp && !isComposingWorkspaceApp
        )
    }

    private func clearTransientSurfaces() {
        selectedWorkspaceApp = nil
        isComposingTask = false
        isComposingWorkspaceApp = false
    }

    private func shouldPreserveWorkspaceAppSurface(for update: ContentWorkspaceSelectionUpdate) -> Bool {
        guard update.workspaceAppSurfacePolicy == .preserveIfWorkspaceMatches,
              update.selectedTask == nil,
              let workspaceID = update.selectedWorkspace?.id else {
            return false
        }
        if isComposingWorkspaceApp {
            return selectedWorkspace?.id == workspaceID
        }
        if let selectedWorkspaceApp {
            return selectedWorkspaceApp.workspaceID == workspaceID
        }
        return false
    }
}
