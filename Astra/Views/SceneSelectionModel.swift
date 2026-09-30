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
    private var retargetedComposerWorkspaceID: UUID?
    private var keepsComposerThroughWorkspaceFlow = false

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

    /// The workspace a new task would start in, while the detail pane shows the
    /// new-task composer: the explicit one, or the one a workspace with no tasks
    /// shows on its own. `isComposingTask` alone misses the second.
    var newTaskComposerWorkspaceID: UUID? {
        let workspace = selectedTask?.workspace ?? selectedWorkspace
        let presentation = ContentDetailPresentation.resolve(
            selectedTask: selectedTask,
            effectiveWorkspace: workspace,
            isComposingTask: isComposingTask,
            selectedWorkspaceApp: selectedWorkspaceApp,
            isComposingWorkspaceApp: isComposingWorkspaceApp
        )
        return presentation == .newTaskComposer ? workspace?.id : nil
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

    /// Moves the new-task composer to another workspace without leaving it. A
    /// workspace with no tasks shows the composer without `isComposingTask`
    /// being set, so this also establishes composition rather than requiring it.
    /// The scene's workspace-change observer treats every other change while
    /// composing as leaving the composer (a sidebar click), so this records the
    /// one change it must let through; `consumeComposerRetarget` reads it back.
    func retargetComposer(to workspace: Workspace) {
        guard selectedTask == nil, selectedWorkspace?.id != workspace.id else { return }
        retargetedComposerWorkspaceID = workspace.id
        composeTask(workspace: workspace)
    }

    /// Marks that the workspace create or import the composer's switcher started
    /// will select a workspace: `apply` then keeps the composer (and its draft)
    /// open on it instead of leaving for that workspace's home. The flow ends
    /// when that selection lands, or when the sheet or panel closes without one.
    func beginComposerWorkspaceFlow() {
        keepsComposerThroughWorkspaceFlow = true
    }

    var isInComposerWorkspaceFlow: Bool { keepsComposerThroughWorkspaceFlow }

    func endComposerWorkspaceFlow() {
        keepsComposerThroughWorkspaceFlow = false
    }

    /// True once for the workspace a `retargetComposer` just selected.
    func consumeComposerRetarget(for workspaceID: UUID?) -> Bool {
        defer { retargetedComposerWorkspaceID = nil }
        return workspaceID != nil && workspaceID == retargetedComposerWorkspaceID
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
        let keepsComposer = keepsComposerThroughWorkspaceFlow
            && update.selectedTask == nil
            && update.selectedWorkspace != nil
            && update.selectedWorkspace?.id != selectedWorkspace?.id

        selectedWorkspace = update.selectedWorkspace
        selectedTask = update.selectedTask
        isComposingTask = update.isComposingTask || keepsComposer
        if keepsComposer {
            keepsComposerThroughWorkspaceFlow = false
            retargetedComposerWorkspaceID = update.selectedWorkspace?.id
        }
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
