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

    @Test("failed run with an inline banner keeps details collapsed until opened")
    func failedRunWithInlineBannerKeepsDetailsCollapsedUntilOpened() {
        let runID = Self.failedRunID
        let presentation = failedRunPresentation()
        var state = RunActivityDisclosureState()

        // The inline "Run stopped" banner is the visible explanation; the
        // disclosure carries stats/diagnostics and must not auto-open a
        // second block under it.
        #expect(!presentation.prefersExpandedDetails)
        #expect(!state.isExpanded(runID: runID, presentation: presentation))

        state.toggle(runID: runID, presentation: presentation)

        #expect(state.isExpanded(runID: runID, presentation: presentation))
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

    @Test("banner-carried error notice leaves the disclosure quiet")
    func bannerCarriedErrorNoticeLeavesTheDisclosureQuiet() {
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

        #expect(presentation.issues.isEmpty)
        #expect(presentation.technicalOutputs.isEmpty)
        #expect(!presentation.prefersExpandedDetails)
    }

    @Test("short provider error messages keep their actionable last line")
    func shortProviderErrorMessagesKeepTheirActionableLastLine() {
        let payload = """
        ASTRA could not launch because one or more selected capabilities are not fully connected to runtime resources:

        - GitHub: local tool gh — GitHub CLI is not active

        Fix the capability in Manage Capabilities, or disable/exclude it for this task, then retry.
        """
        let issue = RunIssuePresentation(notice: TaskRunNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            type: "error",
            payload: payload
        ))

        // The full message fits the banner, including the fix guidance, so
        // there is nothing left for a raw-output disclosure to add.
        #expect(issue.summary == payload)
        #expect(issue.rawPayload == nil)
    }

    @Test("long provider error dumps stay truncated with raw output preserved")
    func longProviderErrorDumpsStayTruncatedWithRawOutputPreserved() {
        let payload = String(repeating: "diagnostic line of provider output. ", count: 40)
        let issue = RunIssuePresentation(notice: TaskRunNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
            type: "error",
            payload: payload
        ))

        #expect(issue.summary.count < 240)
        #expect(issue.summary.hasSuffix("…"))
        #expect(issue.rawPayload?.contains("diagnostic line") == true)
    }

    @Test("pre-launch policy block surfaces the real remediation, not a generic broader-permissions message")
    func preLaunchPolicyBlockSurfacesRealRemediation() {
        // Shape produced by AgentRuntimeWorker.shouldStartProvider when a
        // .blocked PolicyDiagnostic (e.g. cursor_cli.host-control-plane-unsupported)
        // stops a run before the provider ever launches.
        let payload = """
        Provider policy blocked this run before launch.
        - Host control-plane route is unavailable: Cursor CLI cannot attach ASTRA's host-control MCP route for GitHub metadata/API work, so ASTRA will not fall back to provider-visible native Git or gh credentials. Remediation: Switch to Codex CLI, Claude Code, or a Copilot CLI build with MCP config support, or remove the GitHub host-control capability route for this run.
        """
        let issue = RunIssuePresentation(notice: TaskRunNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
            type: "error",
            payload: payload
        ))

        #expect(issue.title == "Policy blocked this run")
        // Must not fall back to the generic, actively-wrong-for-this-case copy.
        #expect(!issue.summary.contains("broader permissions"))
        #expect(issue.summary.contains("Switch to Codex CLI"))
    }

    @Test("runtime-compatibility launch block is classified as policy blocked, not a generic run stop")
    func runtimeCompatibilityLaunchBlockIsClassifiedAsPolicyBlocked() {
        // Shape produced by AgentRuntimeCapabilityBlockRecorder.apply(_:TaskRuntimeCompatibilityLaunchBlock)
        // when the compatibility resolver blocks before any launch attempt
        // (e.g. an explicitly-selected incompatible runtime, Phase 2).
        let payload = """
        Selected runtime is incompatible with required ASTRA capabilities.
        - Selected runtime is incompatible with required ASTRA capabilities: Cursor CLI cannot satisfy: host-control MCP server for github. Remediation: Switch to a compatible runtime such as Codex CLI, Claude Code, or a Copilot CLI build with task-scoped MCP config support.
        - Runtime: Cursor CLI
        - Missing capabilities: host-control MCP server for github
        """
        let issue = RunIssuePresentation(notice: TaskRunNotice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!,
            type: "error",
            payload: payload
        ))

        #expect(issue.title == "Policy blocked this run")
        #expect(issue.summary.contains("Switch to a compatible runtime"))
    }

    @Test("run details live in the dock for every finished run while it is visible")
    func runDetailsLiveInTheDockForEveryFinishedRunWhileItIsVisible() {
        // Homogeneous across statuses and multi-run threads: any finished run
        // moves its details into the dock inspector while the dock is visible.
        #expect(TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .failed, dockVisible: true
        ))
        #expect(TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .completed, dockVisible: true
        ))
        #expect(TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .cancelled, dockVisible: true
        ))
        #expect(TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .budgetExceeded, dockVisible: true
        ))
        #expect(TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .timeout, dockVisible: true
        ))

        // A live run keeps its inline activity feed.
        #expect(!TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .running, dockVisible: true
        ))
        // No dock (e.g. draft) → thread disclosure stays.
        #expect(!TaskRunNoticePresentationRules.detailsLiveInDock(
            runStatus: .failed, dockVisible: false
        ))
    }

    @Test("error banners render fixed expanded while warnings stay collapsible")
    func errorBannersRenderFixedExpandedWhileWarningsStayCollapsible() {
        func notice(_ type: String) -> TaskRunNotice {
            TaskRunNotice(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
                type: type,
                payload: "payload"
            )
        }

        #expect(TaskRunNoticePresentationRules.rendersFixedExpanded(notice("error")))
        #expect(TaskRunNoticePresentationRules.rendersFixedExpanded(notice("budget.exceeded")))
        #expect(!TaskRunNoticePresentationRules.rendersFixedExpanded(notice("budget.warning")))
        #expect(!TaskRunNoticePresentationRules.rendersFixedExpanded(notice("permission.approval.requested")))
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
