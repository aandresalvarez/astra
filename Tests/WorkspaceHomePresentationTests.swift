import Testing
@testable import ASTRA

@Suite("WorkspaceHomePresentation")
struct WorkspaceHomePresentationTests {
    @Test("Workspace page separates sections into tabs with instructions open by default")
    func workspacePageUsesSectionTabs() {
        #expect(WorkspaceHomePresentation.usesSectionTabs == true)
        #expect(WorkspaceHomePresentation.defaultSection == .instructions)
        #expect(WorkspaceHomePresentation.sectionSelectionPersistsPerWorkspace == true)
        #expect(WorkspaceHomeSection.allCases == [.instructions, .capabilities, .access, .memory, .board, .apps, .routines])
        #expect(WorkspaceHomeSection.allCases.map(\.title) == [
            "Instructions", "Capabilities", "Access", "Memory", "Task board", "Apps", "Routines"
        ])
    }

    @Test("Workspace instructions render as an open Markdown document")
    func workspaceInstructionsRenderAsOpenMarkdown() {
        #expect(WorkspaceInstructionPresentation.rendersCommonMark == true)
        #expect(WorkspaceInstructionPresentation.preservesAuthoredLineBreaks == true)
        #expect(WorkspaceHomePresentation.instructionEditorStaysInline == true)
        #expect(WorkspaceHomePresentation.emptyInstructionsUseSinglePrompt == true)
        #expect(WorkspaceHomePresentation.instructionBlockUsesPrimaryCTAWhenEmpty == true)
        #expect(WorkspaceInstructionPresentation.emptyPromptTitle == "Tell the agent how you work")
        #expect(WorkspaceInstructionPresentation.emptyPromptBody == "Add conventions, tone, and what to avoid. They apply to every task in this workspace.")
        #expect(WorkspaceInstructionPresentation.emptyActionTitle == "Write instructions")
        #expect(WorkspaceInstructionPresentation.editorHasFormattingToolbar == true)
    }

    @Test("Memory and Access tabs split what the old Setup tab combined")
    func memoryAndAccessTabsSplitSetupConcerns() {
        #expect(WorkspaceHomeSection.memory.title == "Memory")
        #expect(WorkspaceHomeSection.memory.id == "memory")
        #expect(WorkspaceHomeSection.access.title == "Access")
        #expect(WorkspaceHomeSection.access.id == "access")
    }

    @Test("Workspace page keeps primary actions and routine rows lean")
    func workspacePageActionsStayLean() {
        #expect(WorkspaceHomePresentation.usesKanbanMeasuredPageRail == true)
        #expect(WorkspaceHomePresentation.headerShowsWorkspaceStatus == false)
        #expect(WorkspaceHomePresentation.headerUsesOverviewMetrics == false)
        #expect(WorkspaceHomePresentation.headerUsesCompactOverviewMetrics == false)
        #expect(WorkspaceHomePresentation.statusCountsStayOnBoard == true)
        #expect(WorkspaceHomePresentation.usesMinimumWelcomeRailWidth == true)
        #expect(WorkspaceHomePresentation.headerShowsPrimaryNewTaskAction == false)
        #expect(WorkspaceHomePresentation.routinesUseSummaryRows == true)
        #expect(WorkspaceHomePresentation.rowIconFrame == 40)
        #expect(WorkspaceHomePresentation.rowMinHeight == 56)
        #expect(WorkspaceHomePresentation.cardCornerRadius == 12)
        #expect(WorkspaceHomePresentation.minimumWelcomeRailWidth == 920)
    }
}
