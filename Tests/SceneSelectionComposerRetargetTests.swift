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

    @Test("The workspace-change observer may keep the composer exactly once")
    func retargetIsConsumedOnce() {
        let first = workspace("First")
        let second = workspace("Second")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        model.retargetComposer(to: second)

        #expect(model.consumeComposerRetarget(for: second.id))
        #expect(!model.consumeComposerRetarget(for: second.id))
    }

    @Test("A different workspace change is still treated as leaving the composer")
    func otherWorkspaceChangesAreNotRetargets() {
        let first = workspace("First")
        let second = workspace("Second")
        let third = workspace("Third")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        model.retargetComposer(to: second)

        #expect(!model.consumeComposerRetarget(for: third.id))
        #expect(!model.consumeComposerRetarget(for: nil))
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
        #expect(model.consumeComposerRetarget(for: second.id))
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
        #expect(!model.consumeComposerRetarget(for: second.id))
    }

    @Test("Retargeting to the current workspace is a no-op")
    func retargetToSameWorkspaceIsIgnored() {
        let first = workspace("First")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)

        model.retargetComposer(to: first)

        #expect(!model.consumeComposerRetarget(for: first.id))
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
        #expect(model.consumeComposerRetarget(for: imported.id))
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
        #expect(model.consumeComposerRetarget(for: created.id))
    }

    @Test("Without the flow marker an import is not exempt from the composer-exit rule")
    func importWithoutTheFlowIsNotExempt() {
        let first = workspace("First")
        let imported = workspace("Imported")
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )

        model.apply(coordinator.importWorkspace(imported))

        // The workspace-change observer leaves the composer for any change the
        // token does not cover, so a missing token is what the old behavior was.
        #expect(!model.consumeComposerRetarget(for: imported.id))
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

        #expect(!model.consumeComposerRetarget(for: later.id))
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
