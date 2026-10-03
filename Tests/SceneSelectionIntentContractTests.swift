import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// What each way of changing the scene's selection means, stated once, as the
/// surface it must land on. The model is the only writer: an intent carries its
/// own result, and nothing downstream infers it from a state difference.
@MainActor
@Suite("Scene selection intent contract")
struct SceneSelectionIntentContractTests {
    // MARK: - Compose in a workspace

    private enum Start: CaseIterable {
        case nothing, workspaceHome, composerOfFirst, taskOfFirst
    }

    private func model(starting start: Start, first: Workspace) -> SceneSelectionModel {
        let model = SceneSelectionModel()
        switch start {
        case .nothing: break
        case .workspaceHome: model.openWorkspace(first)
        case .composerOfFirst: model.composeTask(workspace: first)
        case .taskOfFirst: model.openTask(AgentTask(title: "Open", goal: "Open", workspace: first))
        }
        return model
    }

    @Test("Composing in a workspace lands on that workspace's composer from every starting surface",
          arguments: Start.allCases)
    private func composeLandsOnTheComposerFromAnywhere(start: Start) {
        let first = workspace("First")
        let second = workspace("Second")

        for target in [first, second] {
            let model = model(starting: start, first: first)

            model.composeTask(workspace: target)

            #expect(model.selectedTask == nil)
            #expect(model.activeSurface == .taskComposer(target.id))
            #expect(model.newTaskComposerWorkspaceID == target.id)
        }
    }

    // MARK: - Every other change of workspace leaves the composer

    private func composing(in first: Workspace) -> (SceneSelectionModel, ContentWorkspaceSelectionCoordinator) {
        let model = SceneSelectionModel()
        model.composeTask(workspace: first)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil, selectedWorkspace: first, isComposingTask: true
        )
        return (model, coordinator)
    }

    @Test("Opening another workspace leaves the composer for its home")
    func openingAWorkspaceLeavesTheComposer() {
        let first = workspace("First")
        let second = workspace("Second")
        let (model, coordinator) = composing(in: first)

        model.apply(coordinator.open(workspace: second))

        #expect(model.activeSurface == .workspace(second.id))
    }

    @Test("Deleting the composer's workspace leaves the composer for the next workspace")
    func deletingTheComposerWorkspaceLeavesTheComposer() {
        let first = workspace("First")
        let next = workspace("Next")
        let (model, coordinator) = composing(in: first)

        model.apply(coordinator.delete(workspace: first, nextWorkspace: next))

        #expect(!model.isComposingTask)
        #expect(model.activeSurface == .workspace(next.id))
    }

    @Test("Deleting a different workspace keeps the composer")
    func deletingAnotherWorkspaceKeepsTheComposer() {
        let first = workspace("First")
        let other = workspace("Other")
        let (model, coordinator) = composing(in: first)

        model.apply(coordinator.delete(workspace: other, nextWorkspace: nil))

        #expect(model.activeSurface == .taskComposer(first.id))
    }

    @Test("Restoring a different workspace leaves the composer, and restoring the same one keeps it")
    func restoreLeavesOnlyWhenTheWorkspaceChanged() {
        let first = workspace("First")
        let other = workspace("Other")
        let (model, coordinator) = composing(in: first)

        model.apply(coordinator.restore(workspace: first))
        #expect(model.activeSurface == .taskComposer(first.id))

        model.apply(coordinator.restore(workspace: other))
        #expect(!model.isComposingTask)
        #expect(model.activeSurface == .workspace(other.id))
    }

    @Test("Creating a workspace outside the composer's switcher leaves the composer for it")
    func creatingAWorkspaceElsewhereLeavesTheComposer() {
        let first = workspace("First")
        let created = workspace("Created")
        let (model, coordinator) = composing(in: first)

        model.apply(coordinator.create(workspace: created))

        #expect(model.activeSurface == .workspace(created.id))
    }

    private func workspace(_ name: String) -> Workspace {
        Workspace(name: name, primaryPath: "/tmp/\(UUID().uuidString)")
    }
}
