import Testing
@testable import ASTRA

@Suite("Task decision dock presentation")
struct TaskDecisionDockPresentationTests {
    @Test("dock keeps Mission Control and task status details")
    func dockKeepsMissionControlAndTaskStatusDetails() throws {
        let mission = MissionControlPresentation(
            objective: "Create Masterball puzzle web solver",
            statusTitle: "Completed",
            statusSummary: "No validation contract recorded",
            tone: .attention,
            activeStepTitle: nil,
            validationSummary: "No validation contract",
            assertionRows: [],
            latestHandoffSummary: "Review the result and mark the task done if no follow-up is needed.",
            blockerCount: 0,
            artifactCount: 1,
            changedFileCount: 1,
            budgetSummary: "42.1k used / unlimited",
            nextAction: "Review the result, approve it, or ask a follow-up.",
            correction: nil,
            sourcePointerCount: 9
        )

        let presentation = TaskDecisionDockPresentation.build(context(
            status: .completed,
            mission: mission,
            verification: TaskVerificationPresentation(
                title: "Not automatically verified",
                summary: "Not automatically verified",
                detail: "No validation contract or automated check was available for this task. · Artifacts: none recorded · No automated verification evidence recorded.",
                systemImage: "checkmark.circle",
                tone: .attention
            ),
            artifactPaths: ["/tmp/index.html"]
        ))

        let dock = try #require(presentation)
        #expect(dock.metrics.map(\.id) == ["validation", "files", "artifacts", "budget"])
        #expect(dock.details.contains {
            $0.id == "mission-control" &&
                $0.title == "Mission Control" &&
                $0.summary == "Completed: No validation contract recorded"
        })
        #expect(dock.details.contains {
            $0.id == "mission-objective" &&
                $0.summary == "Create Masterball puzzle web solver"
        })
        #expect(dock.details.contains {
            $0.id == "mission-validation" &&
                $0.summary == "No validation contract"
        })
        #expect(dock.details.contains {
            $0.id == "task-status" &&
                $0.summary == "Run finished - Needs review"
        })
        #expect(dock.details.contains {
            $0.id == "handoff" &&
                $0.summary.contains("Review the result")
        })
        #expect(dock.details.contains {
            $0.id == "next-action" &&
                $0.summary.contains("ask a follow-up")
        })
        let verificationDetail = try #require(dock.details.first { $0.id == "verification" })
        #expect(!verificationDetail.summary.contains("Artifacts: none recorded"))
        #expect(verificationDetail.summary.contains("No automated verification evidence recorded."))
    }

    @Test("cancelled dock expands preserved state by default")
    func cancelledDockExpandsPreservedStateByDefault() throws {
        let mission = MissionControlPresentation(
            objective: "Create Masterball puzzle web solver",
            statusTitle: "Needs attention",
            statusSummary: "cancelled",
            tone: .failed,
            activeStepTitle: nil,
            validationSummary: "No validation contract",
            assertionRows: [],
            latestHandoffSummary: "Review the partial result before retrying.",
            blockerCount: 0,
            artifactCount: 1,
            changedFileCount: 1,
            budgetSummary: "14.3k used / unlimited",
            nextAction: "Retry or close the task.",
            correction: nil,
            sourcePointerCount: 7
        )

        let presentation = TaskDecisionDockPresentation.build(context(
            status: .cancelled,
            mission: mission,
            artifactPaths: ["/tmp/index.html"]
        ))

        let dock = try #require(presentation)
        #expect(dock.title == "Run cancelled")
        #expect(dock.prefersExpandedDetails)
        #expect(dock.details.contains { $0.id == "mission-control" })
        #expect(dock.details.contains { $0.id == "task-status" && $0.summary == "Run cancelled - Needs review" })
        #expect(dock.metrics.contains { $0.id == "artifacts" && $0.value == "1" })
    }

    private func context(
        status: TaskStatus,
        mission: MissionControlPresentation? = nil,
        verification: TaskVerificationPresentation? = nil,
        artifactPaths: [String] = []
    ) -> TaskDecisionDockPresentation.Context {
        TaskDecisionDockPresentation.Context(
            status: status,
            isClosed: false,
            review: TaskPresentationState.reviewPresentation(status: status, isClosed: false),
            mission: mission,
            verification: verification,
            pendingReviewState: .none,
            hasRuntimePermissionRequest: false,
            runtimePermissionTitle: nil,
            runtimePermissionSummary: nil,
            runtimePermissionScope: nil,
            runtimePermissionCommandPreview: nil,
            runtimePermissionAllowSimilarLabel: nil,
            canApproveSimilarRuntimePermission: false,
            hasExecutableApprovedPlan: false,
            planActionTitle: nil,
            planActionDetail: nil,
            planModeLabel: nil,
            canOpenPlan: false,
            isPlanCanvasVisible: false,
            canRunApprovedPlan: false,
            latestRunHasNoUsableResult: false,
            completedTaskNeedsArtifactAttention: false,
            canCancel: true,
            canRun: true,
            canApprove: true,
            canRetry: true,
            canResume: false,
            canToggleDone: true,
            hasProviderSession: false,
            failureReason: nil,
            artifactPaths: artifactPaths
        )
    }
}
