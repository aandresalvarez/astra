import Testing
@testable import ASTRA

@Suite("WorkspaceHomePresentation")
struct WorkspaceHomePresentationTests {
    @Test("Workspace context uses lean summary rows")
    func workspaceContextUsesLeanSummaryRows() {
        #expect(WorkspaceHomePresentation.usesWorkspaceContextCard == true)
        #expect(WorkspaceHomePresentation.usesKanbanMeasuredPageRail == true)
        #expect(WorkspaceHomePresentation.contextRowsUseSummaryPattern == true)
        #expect(WorkspaceHomePresentation.contextCardShowsCapabilitiesRow == true)
        #expect(WorkspaceHomePresentation.contextCardAlignsWithBoardColumns == true)
        #expect(WorkspaceHomePresentation.instructionEditorStaysInsideContextCard == true)
        #expect(WorkspaceInstructionPresentation.usesReadableExpandedBlocks == true)
        #expect(WorkspaceHomePresentation.headerShowsWorkspaceStatus == false)
        #expect(WorkspaceHomePresentation.headerUsesOverviewMetrics == false)
        #expect(WorkspaceHomePresentation.headerUsesCompactOverviewMetrics == false)
        #expect(WorkspaceHomePresentation.statusCountsStayOnBoard == true)
        #expect(WorkspaceHomePresentation.instructionsArePrimaryWorkspaceSurface == true)
        #expect(WorkspaceHomePresentation.instructionsExpandByDefaultWhenConfigured == false)
        #expect(WorkspaceHomePresentation.instructionsShowPreviewWhenConfigured == true)
        #expect(WorkspaceHomePresentation.emptyInstructionsUseSinglePrompt == true)
        #expect(WorkspaceHomePresentation.instructionBlockUsesPrimaryCTAWhenEmpty == true)
        #expect(WorkspaceHomePresentation.usesMinimumWelcomeRailWidth == true)
    }

    @Test("Workspace page keeps primary actions and routine rows lean")
    func workspacePageActionsStayLean() {
        #expect(WorkspaceHomePresentation.headerShowsPrimaryNewTaskAction == false)
        #expect(WorkspaceHomePresentation.routinesUseSummaryRows == true)
        #expect(WorkspaceHomePresentation.rowIconFrame == 40)
        #expect(WorkspaceHomePresentation.rowMinHeight == 56)
        #expect(WorkspaceHomePresentation.cardCornerRadius == 12)
        #expect(WorkspaceHomePresentation.minimumWelcomeRailWidth == 920)
        #expect(WorkspaceInstructionPresentation.emptyPromptTitle == "Tell the agent how you work")
        #expect(WorkspaceInstructionPresentation.emptyPromptBody == "Add conventions, tone, and what to avoid. They apply to every task in this workspace.")
        #expect(WorkspaceInstructionPresentation.emptyActionTitle == "Write instructions")
        #expect(WorkspaceInstructionPresentation.configuredSubtitle == "Workspace prompt")
        #expect(WorkspaceInstructionPresentation.previewItemLimit == 2)
    }

    @Test("Workspace instructions summarize and group repeated guidance")
    func workspaceInstructionsSummarizeAndGroupRepeatedGuidance() {
        let instructions = """
        try to use Test-driven development (TDD) , write regression and e2e test . validate results by runnign the full test suite. on git pull requests: always use first principles to adres the isues found. once a solution is in please add detailed comments for the reviewer.

        try to use Test-driven development (TDD) , write regression and e2e test . validate results by runnign the full test suite.

        on git pull requests:
        always use first principles to adres the isues found.
        once a solution is in please add detailed comments for the reviewer.
        """

        let blocks = WorkspaceInstructionPresentation.blocks(from: instructions)

        #expect(WorkspaceInstructionPresentation.subtitle(for: instructions) == "4 guidance items")
        #expect(WorkspaceInstructionPresentation.previewItems(from: instructions) == [
            "try to use Test-driven development (TDD), write regression and e2e test.",
            "validate results by runnign the full test suite."
        ])
        #expect(blocks == [
            WorkspaceInstructionBlock(title: nil, items: [
                "try to use Test-driven development (TDD), write regression and e2e test.",
                "validate results by runnign the full test suite."
            ]),
            WorkspaceInstructionBlock(title: "On git pull requests", items: [
                "always use first principles to adres the isues found.",
                "once a solution is in please add detailed comments for the reviewer."
            ])
        ])
    }
}
