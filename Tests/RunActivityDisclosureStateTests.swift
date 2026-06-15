import Foundation
import Testing
@testable import ASTRA

@Suite("Run activity disclosure state")
struct RunActivityDisclosureStateTests {
    @Test("failed run details open by default and still respect manual collapse")
    func failedRunDetailsOpenByDefaultAndStillRespectManualCollapse() {
        let runID = UUID()
        let presentation = failedRunPresentation()
        var state = RunActivityDisclosureState()

        #expect(presentation.prefersExpandedDetails)
        #expect(state.isExpanded(runID: runID, presentation: presentation))

        state.toggle(runID: runID, presentation: presentation)

        #expect(!state.isExpanded(runID: runID, presentation: presentation))
    }

    @Test("nonfailure run details stay compact until manually opened")
    func nonfailureRunDetailsStayCompactUntilManuallyOpened() {
        let runID = UUID()
        let presentation = successfulToolRunPresentation()
        var state = RunActivityDisclosureState()

        #expect(!presentation.prefersExpandedDetails)
        #expect(!state.isExpanded(runID: runID, presentation: presentation))

        state.toggle(runID: runID, presentation: presentation)

        #expect(state.isExpanded(runID: runID, presentation: presentation))
    }

    private func failedRunPresentation() -> RunActivityPresentation {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.id = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        run.status = .failed
        run.completedAt = Date(timeIntervalSince1970: 2)
        run.stopReason = "capability_runtime_resources_missing"
        let events = [
            makeEvent(
                task: task,
                type: "error",
                payload: """
                ASTRA could not launch because one or more selected capabilities are not fully connected to runtime resources:

                - GitHub: local tool gh — GitHub CLI is not active
                """,
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: events, runs: [run])
        return snapshot.activityPresentation(for: snapshot.latestRun!)
    }

    private func successfulToolRunPresentation() -> RunActivityPresentation {
        let task = makeTask(status: .completed)
        let run = TaskRun(task: task)
        run.id = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 2)
        run.stopReason = "completed"
        let events = [
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read: /tmp/report.md",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: events, runs: [run])
        return snapshot.activityPresentation(for: snapshot.latestRun!)
    }
}
