import Testing
@testable import ASTRA

@Suite("TaskPresentationState")
struct TaskPresentationStateTests {
    @Test("review presentation separates run outcome from closure state")
    func reviewPresentationSeparatesRunOutcomeFromClosureState() {
        let finished = TaskPresentationState.reviewPresentation(status: .completed, isClosed: false)
        let closed = TaskPresentationState.reviewPresentation(status: .completed, isClosed: true)

        #expect(finished.runOutcomeLabel == "Run finished")
        #expect(finished.reviewLabel == "Needs review")
        #expect(finished.composerLabel == "Needs review")
        #expect(finished.decisionTitle == "Ready to close?")

        #expect(closed.runOutcomeLabel == "Run finished")
        #expect(closed.reviewLabel == "Closed")
        #expect(closed.composerLabel == "Closed")
        #expect(closed.decisionTitle == "Task closed")
    }

    @Test("terminal outcomes that are not closed still need review",
          arguments: [
            TaskStatus.completed,
            .failed,
            .cancelled,
            .budgetExceeded
          ])
    func terminalOutcomesNeedReviewUntilClosed(status: TaskStatus) {
        let open = TaskPresentationState.reviewPresentation(status: status, isClosed: false)
        let closed = TaskPresentationState.reviewPresentation(status: status, isClosed: true)

        #expect(open.reviewLabel == "Needs review")
        #expect(open.composerLabel == "Needs review")
        #expect(closed.reviewLabel == TaskPresentationState.closedColumnTitle)
        #expect(closed.composerLabel == TaskPresentationState.closedColumnTitle)
    }

    @Test("pending user is input state not closed state")
    func pendingUserNeedsInput() {
        let presentation = TaskPresentationState.reviewPresentation(status: .pendingUser, isClosed: false)

        #expect(presentation.runOutcomeLabel == "Waiting for input")
        #expect(presentation.reviewLabel == "Needs input")
        #expect(presentation.composerLabel == "Needs input")
    }

    @Test("quiet statuses do not show composer review labels",
          arguments: [
            TaskStatus.draft,
            .queued,
            .running
          ])
    func quietStatusesDoNotShowComposerReviewLabels(status: TaskStatus) {
        let presentation = TaskPresentationState.reviewPresentation(status: status, isClosed: false)

        #expect(presentation.reviewLabel == nil)
        #expect(presentation.composerLabel == nil)
    }
}
