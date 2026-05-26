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
    }

    @Test("Workspace page keeps primary actions and routine rows lean")
    func workspacePageActionsStayLean() {
        #expect(WorkspaceHomePresentation.headerShowsPrimaryNewTaskAction == true)
        #expect(WorkspaceHomePresentation.routinesUseSummaryRows == true)
        #expect(WorkspaceHomePresentation.rowIconFrame == 40)
        #expect(WorkspaceHomePresentation.rowMinHeight == 72)
        #expect(WorkspaceHomePresentation.cardCornerRadius == 12)
    }
}
