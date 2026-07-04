import Foundation
import Testing
@testable import ASTRA

@MainActor
@Suite("SceneSelectionModel")
struct SceneSelectionModelTests {
    @Test("Opening a task adopts its workspace and clears app surfaces")
    func openTaskAdoptsWorkspaceAndClearsAppSurfaces() {
        let staleWorkspace = makeWorkspace(name: "Stale")
        let taskWorkspace = makeWorkspace(name: "Task")
        let task = makeTask(workspace: taskWorkspace)
        let app = makeApp(workspace: staleWorkspace)
        let model = SceneSelectionModel()

        model.openWorkspace(staleWorkspace)
        model.openApp(app, workspace: staleWorkspace)
        model.composeApp(workspace: staleWorkspace)
        model.openTask(task)

        #expect(model.selectedTask?.id == task.id)
        #expect(model.selectedWorkspace?.id == taskWorkspace.id)
        #expect(model.selectedWorkspaceApp == nil)
        #expect(!model.isComposingTask)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .task(task.id))
    }

    @Test("Opening a workspace clears task, app, and composer selections")
    func openWorkspaceClearsConflictingSelections() {
        let taskWorkspace = makeWorkspace(name: "Task")
        let nextWorkspace = makeWorkspace(name: "Next")
        let task = makeTask(workspace: taskWorkspace)
        let app = makeApp(workspace: taskWorkspace)
        let model = SceneSelectionModel()

        model.openTask(task)
        model.openApp(app, workspace: taskWorkspace)
        model.composeTask()
        model.openWorkspace(nextWorkspace)

        #expect(model.selectedTask == nil)
        #expect(model.selectedWorkspace?.id == nextWorkspace.id)
        #expect(model.selectedWorkspaceApp == nil)
        #expect(!model.isComposingTask)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .workspace(nextWorkspace.id))
    }

    @Test("Task and app composers are mutually exclusive")
    func composersAreMutuallyExclusive() {
        let workspace = makeWorkspace(name: "Workspace")
        let model = SceneSelectionModel()

        model.openWorkspace(workspace)
        model.composeTask()
        model.composeApp()

        #expect(model.selectedWorkspace?.id == workspace.id)
        #expect(model.selectedTask == nil)
        #expect(model.selectedWorkspaceApp == nil)
        #expect(!model.isComposingTask)
        #expect(model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .appComposer(workspace.id))

        model.composeTask()

        #expect(model.isComposingTask)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .taskComposer(workspace.id))
    }

    @Test("Opening an app clears task and task composer state")
    func openAppClearsTaskSurfaces() {
        let workspace = makeWorkspace(name: "Apps")
        let task = makeTask(workspace: workspace)
        let app = makeApp(workspace: workspace)
        let model = SceneSelectionModel()

        model.openTask(task)
        model.composeTask()
        model.openApp(app, workspace: workspace)

        #expect(model.selectedTask == nil)
        #expect(model.selectedWorkspace?.id == workspace.id)
        #expect(model.selectedWorkspaceApp?.id == app.id)
        #expect(!model.isComposingTask)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .workspaceApp(app.id))
    }

    @Test("Clearing removes transient scene selections while preserving workspace")
    func clearRemovesTransientSelections() {
        let workspace = makeWorkspace(name: "Workspace")
        let app = makeApp(workspace: workspace)
        let model = SceneSelectionModel()

        model.openApp(app, workspace: workspace)
        model.composeApp()
        model.clear()

        #expect(model.selectedTask == nil)
        #expect(model.selectedWorkspace?.id == workspace.id)
        #expect(model.selectedWorkspaceApp == nil)
        #expect(!model.isComposingTask)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .workspace(workspace.id))
    }

    @Test("Workspace-change observer preserves app surfaces bound to the selected workspace")
    func workspaceChangePolicyPreservesMatchingAppSurfaces() {
        let workspace = makeWorkspace(name: "Apps")
        let otherWorkspace = makeWorkspace(name: "Other")
        let app = makeApp(workspace: workspace)
        let model = SceneSelectionModel()

        model.openApp(app, workspace: workspace)
        #expect(!model.shouldClearWorkspaceAppSurfaceAfterWorkspaceChange)

        model.openApp(app, workspace: otherWorkspace)
        #expect(model.shouldClearWorkspaceAppSurfaceAfterWorkspaceChange)
    }

    @Test("Workspace-change observer preserves active app composer intent")
    func workspaceChangePolicyPreservesAppComposer() {
        let workspace = makeWorkspace(name: "Studio")
        let model = SceneSelectionModel()

        model.composeApp(workspace: workspace)

        #expect(!model.shouldClearWorkspaceAppSurfaceAfterWorkspaceChange)
        #expect(model.activeSurface == .appComposer(workspace.id))
    }

    @Test("Passive workspace restoration preserves active app composer for the same workspace")
    func passiveRestorePreservesAppComposerForSameWorkspace() {
        let workspace = makeWorkspace(name: "Studio")
        let model = SceneSelectionModel()
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil,
            selectedWorkspace: workspace,
            isComposingTask: false
        )

        model.composeApp(workspace: workspace)
        let result = model.apply(coordinator.restore(workspace: workspace))

        #expect(!result.clearedWorkspaceAppSurface)
        #expect(!result.cancelledWorkspaceAppComposer)
        #expect(model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .appComposer(workspace.id))
    }

    @Test("Passive workspace restoration clears app composer when the workspace no longer matches")
    func passiveRestoreClearsAppComposerForDifferentWorkspace() {
        let original = makeWorkspace(name: "Original")
        let restored = makeWorkspace(name: "Restored")
        let model = SceneSelectionModel()
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil,
            selectedWorkspace: original,
            isComposingTask: false
        )

        model.composeApp(workspace: original)
        let result = model.apply(coordinator.restore(workspace: restored))

        #expect(result.clearedWorkspaceAppSurface)
        #expect(result.cancelledWorkspaceAppComposer)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .workspace(restored.id))
    }

    @Test("Passive workspace restoration preserves matching app detail")
    func passiveRestorePreservesMatchingAppDetail() {
        let workspace = makeWorkspace(name: "Apps")
        let app = makeApp(workspace: workspace)
        let model = SceneSelectionModel()
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil,
            selectedWorkspace: workspace,
            isComposingTask: false
        )

        model.openApp(app, workspace: workspace)
        let result = model.apply(coordinator.restore(workspace: workspace))

        #expect(!result.clearedWorkspaceAppSurface)
        #expect(model.selectedWorkspaceApp?.id == app.id)
        #expect(model.activeSurface == .workspaceApp(app.id))
    }

    @Test("Explicit workspace open clears matching app detail")
    func explicitWorkspaceOpenClearsMatchingAppDetail() {
        let workspace = makeWorkspace(name: "Apps")
        let app = makeApp(workspace: workspace)
        let model = SceneSelectionModel()
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil,
            selectedWorkspace: workspace,
            isComposingTask: false
        )

        model.openApp(app, workspace: workspace)
        let result = model.apply(coordinator.open(workspace: workspace))

        #expect(result.clearedWorkspaceAppSurface)
        #expect(model.selectedWorkspaceApp == nil)
        #expect(model.activeSurface == .workspace(workspace.id))
    }

    @Test("Applying workspace restoration can clear all selection when no workspace remains")
    func restoreCanClearWorkspaceSelection() {
        let workspace = makeWorkspace(name: "Workspace")
        let task = makeTask(workspace: workspace)
        let model = SceneSelectionModel()

        model.openTask(task)
        model.restoreWorkspace(nil)

        #expect(model.selectedTask == nil)
        #expect(model.selectedWorkspace == nil)
        #expect(model.selectedWorkspaceApp == nil)
        #expect(!model.isComposingTask)
        #expect(!model.isComposingWorkspaceApp)
        #expect(model.activeSurface == .none)
    }

    private func makeApp(workspace: Workspace) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: "review-board",
            name: "Review Board",
            manifestRelativePath: ".astra/apps/review-board/manifest.json",
            appDirectoryRelativePath: ".astra/apps/review-board",
            manifestDigest: "digest"
        )
    }
}
