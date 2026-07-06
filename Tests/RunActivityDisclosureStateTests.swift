import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Run activity disclosure state")
struct RunActivityDisclosureStateTests {
    private static let failedRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private static let successfulRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private static let completedIssueRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    private static let completedTechnicalOutputRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!

    @Test("failed run details open by default and still respect manual collapse")
    func failedRunDetailsOpenByDefaultAndStillRespectManualCollapse() {
        let runID = Self.failedRunID
        let presentation = failedRunPresentation()
        var state = RunActivityDisclosureState()

        #expect(presentation.prefersExpandedDetails)
        #expect(state.isExpanded(runID: runID, presentation: presentation))

        state.toggle(runID: runID, presentation: presentation)

        #expect(!state.isExpanded(runID: runID, presentation: presentation))
    }

    @Test("nonfailure run details stay compact until manually opened")
    func nonfailureRunDetailsStayCompactUntilManuallyOpened() {
        let runID = Self.successfulRunID
        let presentation = successfulToolRunPresentation()
        var state = RunActivityDisclosureState()

        #expect(!presentation.prefersExpandedDetails)
        #expect(!state.isExpanded(runID: runID, presentation: presentation))

        state.toggle(runID: runID, presentation: presentation)

        #expect(state.isExpanded(runID: runID, presentation: presentation))
    }

    @Test("completed run with visible error issue opens details by severity")
    func completedRunWithVisibleErrorIssueOpensDetailsBySeverity() {
        let notice = TaskRunNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            type: "error",
            payload: "Provider stopped before ASTRA received a visible response."
        )
        let presentation = RunActivityPresentation(
            run: completedRunSnapshot(id: Self.completedIssueRunID),
            activity: .empty,
            notices: [notice]
        )

        #expect(presentation.issues.contains { $0.severity == .error })
        #expect(presentation.prefersExpandedDetails)
    }

    @Test("completed run with error technical output opens details by severity")
    func completedRunWithErrorTechnicalOutputOpensDetailsBySeverity() {
        let notice = TaskRunNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            type: "error",
            payload: "Copilot exited with code 1.\n\nProvider error:\nraw stack output"
        )
        let presentation = RunActivityPresentation(
            run: completedRunSnapshot(id: Self.completedTechnicalOutputRunID),
            activity: .empty,
            notices: [notice],
            suppressedNoticeIDs: [notice.id]
        )

        #expect(presentation.technicalOutputs.contains { $0.severity == .error })
        #expect(presentation.prefersExpandedDetails)
    }

    private func failedRunPresentation() -> RunActivityPresentation {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.id = Self.failedRunID
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
        run.id = Self.successfulRunID
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

    private func completedRunSnapshot(id: UUID) -> TaskRunSnapshot {
        let task = makeTask(status: .completed)
        let run = TaskRun(task: task)
        run.id = id
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 2)
        run.stopReason = "completed"
        return TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))
    }
}
