import Testing
@testable import ASTRA

@Suite("Composer Presentation")
struct ComposerPresentationTests {
    @Test("composer keeps compact input spacing")
    func composerKeepsCompactInputSpacing() {
        #expect(TaskComposerPresentation.usesCompactInputSpacing == true)
        #expect(TaskComposerPresentation.usesForcedExpandedInputHeight == false)
        #expect(TaskComposerPresentation.inputHorizontalPadding == 14)
        #expect(TaskComposerPresentation.inputTopPadding == 12)
        #expect(TaskComposerPresentation.inputBottomPadding == 9)
    }

    @Test("task decision dock stays compact")
    func taskDecisionDockStaysCompact() {
        #expect(TaskComposerPresentation.decisionRowUsesNestedChrome == false)
        #expect(TaskComposerPresentation.decisionRowUsesNestedStroke == false)
        #expect(TaskComposerPresentation.decisionDetailsUsePopover == true)
        #expect(TaskComposerPresentation.decisionActionsUseOverflowMenu == false)
        #expect(TaskComposerPresentation.decisionUtilitiesStayLeftAligned == true)
        #expect(TaskComposerPresentation.decisionSummaryVisibleInCompactRow == false)
        #expect(TaskComposerPresentation.decisionRowHorizontalPadding == 12)
        #expect(TaskComposerPresentation.decisionRowVerticalPadding == 10)
        #expect(TaskComposerPresentation.decisionAccentWidth == 3)
        #expect(TaskComposerPresentation.decisionIconFrame == 24)
        #expect(TaskComposerPresentation.decisionDockBottomPadding == 8)
    }

    @Test("bottom toolbar adds borders without expanding control scale")
    func bottomToolbarAddsBordersWithoutExpandingControlScale() {
        #expect(ComposerToolbarPresentation.addButtonUsesRoundedSquare == true)
        #expect(ComposerToolbarPresentation.addButtonUsesBorderedChrome == true)
        #expect(ComposerToolbarPresentation.addButtonUsesBackgroundFill == false)
        #expect(ComposerToolbarPresentation.runtimePillUsesBorderedChrome == true)
        #expect(ComposerToolbarPresentation.runtimePillUsesBackgroundFill == false)
        #expect(ComposerToolbarPresentation.taskStatusPillUsesBorderedChrome == true)
        #expect(ComposerToolbarPresentation.menuControlsUsePlainButtonStyle == true)
        #expect(ComposerToolbarPresentation.addButtonSize == 30)
        #expect(ComposerToolbarPresentation.submitButtonSize == 30)
        #expect(ComposerToolbarPresentation.verticalPadding == 7)
        #expect(ComposerToolbarPresentation.chipVerticalPadding == 6)
        #expect(ComposerToolbarPresentation.permissionModeUsesFlatChrome == true)
    }
}
