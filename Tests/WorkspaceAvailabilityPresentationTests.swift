import Testing
@testable import ASTRA

@Suite("Workspace availability presentation")
struct WorkspaceAvailabilityPresentationTests {
    @Test("Zero workspaces hides list controls, Routines, and the titlebar command")
    func zeroWorkspacesHidesWorkspaceDependentControls() {
        let presentation = WorkspaceAvailabilityPresentation(workspaceCount: 0)

        #expect(!presentation.hasWorkspaces)
        #expect(!presentation.showsListControls)
        #expect(!presentation.showsRoutinesSection)
        #expect(!presentation.showsTitlebarCreationCommand)
    }

    @Test("One or more workspaces shows all workspace-dependent controls")
    func nonZeroWorkspacesShowsWorkspaceDependentControls() {
        for count in [1, 2, 10] {
            let presentation = WorkspaceAvailabilityPresentation(workspaceCount: count)

            #expect(presentation.hasWorkspaces)
            #expect(presentation.showsListControls)
            #expect(presentation.showsRoutinesSection)
            #expect(presentation.showsTitlebarCreationCommand)
        }
    }

    @Test("Copy constants match the proposed first-run hierarchy")
    func copyConstantsAreStable() {
        #expect(WorkspaceAvailabilityPresentation.sidebarEmptyPlaceholder == "Workspaces will appear here.")
        #expect(WorkspaceAvailabilityPresentation.onboardingTitle == "Add your first workspace")
        #expect(WorkspaceAvailabilityPresentation.onboardingBody == "Create a workspace or import an existing folder.")
        #expect(WorkspaceAvailabilityPresentation.onboardingFootnote == "ASTRA reopens it automatically next time.")
    }
}
