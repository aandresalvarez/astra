import Testing
@testable import ASTRA

@Suite("Workspace Canvas Panel Presentation")
struct WorkspaceCanvasPanelPresentationTests {
    @Test("plan shelf uses lean row chrome")
    func planShelfUsesLeanRowChrome() {
        #expect(PlanShelfPresentation.showsTopSummaryChips == false)
        #expect(PlanShelfPresentation.metadataIsInlineUnderTitle == true)
        #expect(PlanShelfPresentation.usesCardChromeForCollapsedStepRows == false)
        #expect(PlanShelfPresentation.usesRowDividers == true)
        #expect(PlanShelfPresentation.addStepUsesBorderedChrome == false)
        #expect(PlanShelfPresentation.approvalNoticeUsesCardChrome == false)
        #expect(PlanShelfPresentation.footerUsesBarBackground == false)
    }

    @Test("plan shelf hides secondary controls until expansion")
    func planShelfHidesSecondaryControlsUntilExpansion() {
        #expect(PlanShelfPresentation.showsStepActionsOnlyWhenExpanded == true)
        #expect(PlanShelfPresentation.showsStatusBadgesOnlyForExceptionalStates == true)
    }

    @Test("plan shelf groups current next and done steps")
    func planShelfGroupsCurrentNextAndDoneSteps() {
        let steps = [
            TaskPlanStep(id: "research", title: "Research MED13", status: .done),
            TaskPlanStep(id: "outline", title: "Outline content", status: .done),
            TaskPlanStep(id: "draft", title: "Draft homepage", status: .running),
            TaskPlanStep(id: "style", title: "Style responsive layout", status: .pending),
            TaskPlanStep(id: "cta", title: "Add donation CTA", status: .pending),
            TaskPlanStep(id: "review", title: "Review accuracy", status: .blocked),
            TaskPlanStep(id: "handoff", title: "Handoff", status: .skipped)
        ]

        let groups = PlanShelfStepGrouping.groups(for: steps)

        #expect(groups.map(\.kind) == [.current, .next, .done])
        #expect(groups[0].steps.map(\.step.id) == ["draft", "review"])
        #expect(groups[0].steps.map(\.originalIndex) == [2, 5])
        #expect(groups[1].steps.map(\.step.id) == ["style", "cta"])
        #expect(groups[2].steps.map(\.step.id) == ["research", "outline", "handoff"])
    }
}
