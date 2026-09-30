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

    private func workspace(_ name: String) -> Workspace {
        Workspace(name: name, primaryPath: "/tmp/\(UUID().uuidString)")
    }
}
