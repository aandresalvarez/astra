import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("SceneSelectionModel composer retarget")
struct SceneSelectionComposerRetargetTests {
    @Test("Retargeting moves the open composer to another workspace")
    func retargetKeepsComposerOpen() {
        let first = workspace("First")
        let second = workspace("Second")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)

        model.retargetComposer(to: second)

        #expect(model.isComposingTask)
        #expect(model.selectedWorkspace?.id == second.id)
        #expect(model.activeSurface == .taskComposer(second.id))
    }

    @Test("A later workspace change that is not a compose intent leaves the composer")
    func laterChangeWithoutAnIntentLeavesTheComposer() {
        let first = workspace("First")
        let second = workspace("Second")
        let third = workspace("Third")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        model.retargetComposer(to: second)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: second, isComposingTask: true
        )

        model.apply(coordinator.importWorkspace(third))

        #expect(!model.isComposingTask)
        #expect(model.activeSurface == .workspace(third.id))
    }

    @Test("Retargeting from the implicit composer of an empty workspace starts composing")
    func retargetEstablishesComposition() {
        let first = workspace("First")
        let second = workspace("Second")
        let model = SceneSelectionModel()
        // A workspace with no tasks shows the composer while isComposingTask is false.
        model.openWorkspace(first)
        #expect(!model.isComposingTask)

        model.retargetComposer(to: second)

        #expect(model.isComposingTask)
        #expect(model.selectedWorkspace?.id == second.id)
        #expect(model.activeSurface == .taskComposer(second.id))
    }

    @Test("Retargeting does nothing while a task is open")
    func retargetIgnoredWithATaskOpen() {
        let first = workspace("First")
        let second = workspace("Second")
        let task = AgentTask(title: "Open", goal: "Open", workspace: first)
        let model = SceneSelectionModel()
        model.openTask(task)

        model.retargetComposer(to: second)

        #expect(model.selectedTask?.id == task.id)
        #expect(model.selectedWorkspace?.id == first.id)
        #expect(!model.isComposingTask)
    }

    @Test("Retargeting to the current workspace is a no-op")
    func retargetToSameWorkspaceIsIgnored() {
        let first = workspace("First")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)

        model.retargetComposer(to: first)

        #expect(model.activeSurface == .taskComposer(first.id))
    }

    // MARK: - Sidebar target

    @Test("The sidebar target covers the implicit composer of an empty workspace")
    func targetIncludesTheImplicitComposer() {
        let empty = workspace("Empty")
        let model = SceneSelectionModel()

        model.openWorkspace(empty)

        #expect(!model.isComposingTask)
        #expect(model.newTaskComposerWorkspaceID == empty.id)
    }

    @Test("The sidebar target is the workspace being composed in, and nil on workspace home")
    func targetFollowsTheComposer() {
        let busy = workspace("Busy")
        busy.tasks.append(AgentTask(title: "Existing", goal: "Existing", workspace: busy))
        let model = SceneSelectionModel()

        model.openWorkspace(busy)
        #expect(model.newTaskComposerWorkspaceID == nil)

        model.composeTask(workspace: busy)
        #expect(model.newTaskComposerWorkspaceID == busy.id)
    }

    @Test("The sidebar target is nil while a task is open or when nothing is selected")
    func targetIsNilElsewhere() {
        let first = workspace("First")
        let task = AgentTask(title: "Open", goal: "Open", workspace: first)
        let model = SceneSelectionModel()
        #expect(model.newTaskComposerWorkspaceID == nil)

        model.openTask(task)

        #expect(model.newTaskComposerWorkspaceID == nil)
    }

    // MARK: - Create / import from the switcher

    @Test("A workspace imported from the switcher keeps the composer open on it")
    func importedWorkspaceKeepsTheComposer() {
        let first = workspace("First")
        let imported = workspace("Imported")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.beginComposerWorkspaceFlow()
        model.apply(coordinator.importWorkspace(imported))

        #expect(model.isComposingTask)
        #expect(model.selectedWorkspace?.id == imported.id)
        #expect(model.activeSurface == .taskComposer(imported.id))
    }

    @Test("A workspace created from the implicit composer of an empty workspace also keeps composing")
    func createdWorkspaceKeepsTheImplicitComposer() {
        let first = workspace("First")
        let created = workspace("Created")
        let model = SceneSelectionModel()
        model.openWorkspace(first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: false
        )

        model.beginComposerWorkspaceFlow()
        model.apply(coordinator.create(workspace: created))

        #expect(model.isComposingTask)
        #expect(model.activeSurface == .taskComposer(created.id))
    }

    @Test("Without the flow marker an import leaves the composer for the imported workspace")
    func importWithoutTheFlowIsNotExempt() {
        let first = workspace("First")
        let imported = workspace("Imported")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.apply(coordinator.importWorkspace(imported))

        // Selecting another workspace is not a compose intent, so the model
        // itself leaves the composer; nothing downstream has to guess.
        #expect(!model.isComposingTask)
        #expect(model.activeSurface == .workspace(imported.id))
    }

    @Test("A package review keeps the flow open until the delayed selection lands")
    func packageReviewSelectionKeepsTheComposer() {
        let first = workspace("First")
        let imported = workspace("Imported")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        // importWorkspace() returns after queuing the review; the flow stays open.
        model.beginComposerWorkspaceFlow()
        #expect(model.isInComposerWorkspaceFlow)

        // The user finishes the review later and the selection lands.
        model.apply(coordinator.importWorkspace(imported))

        #expect(model.isComposingTask)
        #expect(model.selectedWorkspace?.id == imported.id)
        #expect(!model.isInComposerWorkspaceFlow)
    }

    @Test("A mixed import re-arms the flow for its package reviews after the legacy half lands")
    func mixedImportReArmsForPackageReviews() {
        let first = workspace("First")
        let legacy = workspace("Legacy")
        let packaged = workspace("Packaged")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.beginComposerWorkspaceFlow()
        model.apply(coordinator.importWorkspace(legacy))
        #expect(model.isComposingTask)
        #expect(!model.isInComposerWorkspaceFlow)

        // A package review is still queued, so the caller puts the flow back.
        model.setComposerWorkspaceFlow(true)
        model.apply(coordinator.importWorkspace(packaged))

        #expect(model.selectedWorkspace?.id == packaged.id)
        #expect(model.isComposingTask)
    }

    @Test("Replacing the selected workspace keeps the composer even though its id is unchanged")
    func replacedWorkspaceWithTheSameIDKeepsTheComposer() {
        let original = workspace("Original")
        let replacement = Workspace(name: "Original", primaryPath: original.primaryPath)
        replacement.id = original.id
        let model = SceneSelectionModel()
        model.composeTask(workspace: original)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: original, isComposingTask: true
        )

        model.beginComposerWorkspaceFlow()
        model.apply(coordinator.importWorkspace(replacement))

        #expect(model.selectedWorkspace === replacement)
        #expect(model.isComposingTask)
    }

    @Test("Restoring the same workspace object never consumes the flow")
    func restoringTheSameObjectKeepsTheFlowOpen() {
        let first = workspace("First")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.beginComposerWorkspaceFlow()
        model.apply(coordinator.restore(workspace: first))

        #expect(model.isInComposerWorkspaceFlow)
    }

    @Test("A flow that ends without selecting anything does not affect a later selection")
    func cancelledFlowDoesNotLeak() {
        let first = workspace("First")
        let later = workspace("Later")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.beginComposerWorkspaceFlow()
        model.endComposerWorkspaceFlow()
        model.apply(coordinator.importWorkspace(later))

        #expect(!model.isComposingTask)
        #expect(model.activeSurface == .workspace(later.id))
    }

    @Test("Restoring the current workspace during a flow does not consume it")
    func restoreDuringFlowKeepsTheMarker() {
        let first = workspace("First")
        let created = workspace("Created")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.beginComposerWorkspaceFlow()
        model.apply(coordinator.restore(workspace: first))
        model.apply(coordinator.create(workspace: created))

        #expect(model.isComposingTask)
        #expect(model.selectedWorkspace?.id == created.id)
    }

    private func workspace(_ name: String) -> Workspace {
        Workspace(name: name, primaryPath: "/tmp/\(UUID().uuidString)")
    }
}
