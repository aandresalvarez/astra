import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - Content Selection

@Suite("Content selection")
struct ContentSelectionResolverTests {

    @Test("Effective workspace follows the selected task over stale workspace state")
    func effectiveWorkspaceFollowsSelectedTask() {
        let staleWorkspace = makeWorkspace(name: "JSL")
        let taskWorkspace = makeWorkspace(name: "REDCap")
        let task = makeTask(title: "Get current process ID", workspace: taskWorkspace)

        let resolved = ContentSelectionResolver.effectiveWorkspace(
            selectedTask: task,
            selectedWorkspace: staleWorkspace
        )

        #expect(resolved?.id == taskWorkspace.id)
    }

    @Test("Effective workspace falls back to selected workspace when no task is selected")
    func effectiveWorkspaceFallsBackToSelectedWorkspace() {
        let workspace = makeWorkspace(name: "JSL")

        let resolved = ContentSelectionResolver.effectiveWorkspace(
            selectedTask: nil,
            selectedWorkspace: workspace
        )

        #expect(resolved?.id == workspace.id)
    }

    @Test("Workspace restoration preserves a live current selection")
    func workspaceRestorationPreservesLiveCurrentSelection() {
        let first = makeWorkspace(name: "First")
        let current = makeWorkspace(name: "Current")

        let restored = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, current],
            currentSelection: current,
            lastSelectedWorkspaceID: first.id.uuidString,
            lastSelectedWorkspacePath: first.primaryPath
        )

        #expect(restored?.id == current.id)
    }

    @Test("Workspace restoration falls back by ID then path then first workspace")
    func workspaceRestorationFallsBackByIDPathThenFirst() {
        let first = makeWorkspace(name: "First")
        let byPath = makeWorkspace(name: "By Path")
        let byID = makeWorkspace(name: "By ID")

        let restoredByID = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, byPath, byID],
            currentSelection: nil,
            lastSelectedWorkspaceID: byID.id.uuidString,
            lastSelectedWorkspacePath: byPath.primaryPath
        )
        let restoredByPath = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, byPath],
            currentSelection: byID,
            lastSelectedWorkspaceID: byID.id.uuidString,
            lastSelectedWorkspacePath: byPath.primaryPath
        )
        let restoredFirst = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, byPath],
            currentSelection: nil,
            lastSelectedWorkspaceID: UUID().uuidString,
            lastSelectedWorkspacePath: "/missing"
        )

        #expect(restoredByID?.id == byID.id)
        #expect(restoredByPath?.id == byPath.id)
        #expect(restoredFirst?.id == first.id)
    }

    @Test("Content scene coordinator centralizes workspace routing values")
    @MainActor
    func contentSceneCoordinatorCentralizesWorkspaceRoutingValues() {
        let selectedWorkspace = makeWorkspace(name: "Selected")
        let taskWorkspace = makeWorkspace(name: "Task")
        let task = makeTask(workspace: taskWorkspace)
        let coordinator = ContentSceneCoordinator(
            workspaces: [selectedWorkspace, taskWorkspace],
            selectedTask: task,
            selectedWorkspace: selectedWorkspace,
            lastSelectedWorkspaceID: selectedWorkspace.id.uuidString,
            lastSelectedWorkspacePath: selectedWorkspace.primaryPath
        )

        #expect(coordinator.effectiveWorkspace?.id == taskWorkspace.id)
        #expect(coordinator.effectiveWorkspaceID == taskWorkspace.id)
        #expect(coordinator.workspaceSelectionSignature.contains(taskWorkspace.primaryPath))
        #expect(coordinator.presentation(isComposingTask: false) == .existingTask)
        #expect(coordinator.restoredWorkspace()?.id == selectedWorkspace.id)
    }

    @Test("Content scene coordinator serializes selected workspace persistence")
    @MainActor
    func contentSceneCoordinatorSerializesSelectedWorkspacePersistence() {
        let workspace = makeWorkspace(name: "Persisted")
        let coordinator = ContentSceneCoordinator(
            workspaces: [workspace],
            selectedTask: nil,
            selectedWorkspace: workspace,
            lastSelectedWorkspaceID: "",
            lastSelectedWorkspacePath: ""
        )

        let persisted = coordinator.persistence(for: workspace)
        let cleared = coordinator.persistence(for: nil)

        #expect(persisted.workspaceID == workspace.id.uuidString)
        #expect(persisted.workspacePath == workspace.primaryPath)
        #expect(cleared == .empty)
    }

    @Test("Workspace selection coordinator opens external workspace routes")
    @MainActor
    func workspaceSelectionCoordinatorOpensExternalWorkspaceRoutes() {
        let staleWorkspace = makeWorkspace(name: "Stale")
        let task = makeTask(workspace: staleWorkspace)
        let routedWorkspace = makeWorkspace(name: "Routed")
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: task,
            selectedWorkspace: staleWorkspace,
            isComposingTask: true
        )

        let update = coordinator.open(workspace: routedWorkspace)

        #expect(update.selectedWorkspace?.id == routedWorkspace.id)
        #expect(update.selectedTask == nil)
        #expect(!update.isComposingTask)
        #expect(update.shouldPresentRightRail)
        #expect(!update.shouldRememberShelfStateWhenPresentingRightRail)
    }

    @Test("Workspace selection coordinator opens task routes through the task workspace")
    @MainActor
    func workspaceSelectionCoordinatorOpensTaskRoutesThroughTaskWorkspace() {
        let staleWorkspace = makeWorkspace(name: "Stale")
        let taskWorkspace = makeWorkspace(name: "Task")
        let task = makeTask(workspace: taskWorkspace)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: nil,
            selectedWorkspace: staleWorkspace,
            isComposingTask: true
        )

        let update = coordinator.open(task: task)

        #expect(update.selectedTask?.id == task.id)
        #expect(update.selectedWorkspace?.id == taskWorkspace.id)
        #expect(!update.isComposingTask)
        #expect(update.shouldPresentRightRail)
        #expect(!update.shouldRememberShelfStateWhenPresentingRightRail)
    }

    @Test("Workspace selection coordinator clears selection when no workspace can be restored")
    @MainActor
    func workspaceSelectionCoordinatorClearsSelectionWhenNoWorkspaceCanBeRestored() {
        let workspace = makeWorkspace(name: "Deleted")
        let task = makeTask(workspace: workspace)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: task,
            selectedWorkspace: workspace,
            isComposingTask: true
        )

        let update = coordinator.restore(workspace: nil)

        #expect(update.selectedWorkspace == nil)
        #expect(update.selectedTask == nil)
        #expect(!update.isComposingTask)
        #expect(!update.shouldPresentRightRail)
    }

    @Test("Workspace selection coordinator clears stale selected task after deleting its workspace")
    @MainActor
    func workspaceSelectionCoordinatorClearsStaleTaskAfterDeletingWorkspace() {
        let deletedWorkspace = makeWorkspace(name: "Deleted")
        let nextWorkspace = makeWorkspace(name: "Next")
        let task = makeTask(workspace: deletedWorkspace)
        let coordinator = ContentWorkspaceSelectionCoordinator(
            selectedTask: task,
            selectedWorkspace: deletedWorkspace,
            isComposingTask: true
        )

        let update = coordinator.delete(workspace: deletedWorkspace, nextWorkspace: nextWorkspace)

        #expect(update.selectedWorkspace?.id == nextWorkspace.id)
        #expect(update.selectedTask == nil)
        #expect(!update.isComposingTask)
        #expect(!update.shouldPresentRightRail)
    }
}
// MARK: - Content Detail Presentation

@Suite("ContentDetailPresentation")
struct ContentDetailPresentationTests {

    @Test("Zero-task workspaces open directly into the new-task composer")
    func zeroTaskWorkspaceShowsComposer() {
        let workspace = makeWorkspace(name: "GitHub PRs")

        let presentation = ContentDetailPresentation.resolve(
            selectedTask: nil,
            effectiveWorkspace: workspace,
            isComposingTask: false
        )

        #expect(presentation == .newTaskComposer)
    }

    @Test("Workspaces with tasks show the workspace home")
    func workspaceWithTasksShowsHome() {
        let workspace = makeWorkspace(name: "GitHub PRs")
        let task = makeTask(workspace: workspace)
        workspace.tasks.append(task)

        let presentation = ContentDetailPresentation.resolve(
            selectedTask: nil,
            effectiveWorkspace: workspace,
            isComposingTask: false
        )

        #expect(presentation == .workspaceHome)
    }

    @Test("Selected tasks take precedence over empty workspace composer")
    func selectedTaskTakesPrecedence() {
        let workspace = makeWorkspace(name: "GitHub PRs")
        let task = makeTask(status: .queued, workspace: workspace)

        let presentation = ContentDetailPresentation.resolve(
            selectedTask: task,
            effectiveWorkspace: workspace,
            isComposingTask: false
        )

        #expect(presentation == .existingTask)
    }
}

// MARK: - New Workspace

@Suite("NewWorkspaceDraft")
struct NewWorkspaceDraftTests {

    @Test("Blank workspace names cannot be created")
    func blankNameCannotCreate() {
        let draft = NewWorkspaceDraft(name: "   ", instructions: "Context")

        #expect(!draft.canCreate)
    }

    @Test("Placeholder workspace names fall back to folder name")
    func placeholderWorkspaceNameFallsBackToFolderName() {
        let workspace = Workspace(name: "Untitled", primaryPath: "/tmp/omop-cohort-gen")

        #expect(workspace.name == "Omop Cohort Gen")
    }

    @Test("Keyboard-smash workspace names fall back to folder name")
    func keyboardSmashWorkspaceNameFallsBackToFolderName() {
        let workspace = Workspace(name: "Asdfadsf", primaryPath: "/tmp/jira-support-tickets")

        #expect(workspace.name == "Jira Support Tickets")
    }

    @Test("Workspace draft trims name and optional instructions")
    func trimsNameAndInstructions() {
        let draft = NewWorkspaceDraft(
            name: "  GitHub PRs  ",
            instructions: "\nUse alvaro as my GitHub username.  \n"
        )

        #expect(draft.canCreate)
        #expect(draft.trimmedName == "GitHub PRs")
        #expect(draft.trimmedInstructions == "Use alvaro as my GitHub username.")
    }

    @Test("Selected workspace capabilities contribute setup requirements")
    func selectedCapabilitiesRequireConfiguration() {
        var draft = NewWorkspaceDraft(name: "Research Ops")
        draft.selectedCapabilityIDs = ["jira-workflow", "github-workflow"]

        #expect(draft.capabilitySetupIssues(githubCLIReady: false) == [
            "Jira: Jira base URL",
            "Jira: Jira email",
            "Jira: Jira API token",
            "GitHub: Authenticated gh CLI"
        ])

        draft.capabilityConfiguration.jiraBaseURL = "https://example.atlassian.net"
        draft.capabilityConfiguration.jiraEmail = "user@example.com"
        draft.capabilityConfiguration.jiraAPIToken = "token"

        #expect(draft.capabilitySetupIssues(githubCLIReady: true).isEmpty)
        #expect(draft.canCreate)
    }
}
