import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Task decision dock presentation")
struct TaskDecisionDockPresentationTests {
    @Test("dock summarizes result evidence and groups status details")
    func dockSummarizesResultEvidenceAndGroupsStatusDetails() throws {
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
        #expect(dock.title == "Result ready")
        #expect(dock.compactMeta == "1 artifact · 1 file changed · not verified")
        #expect(dock.summary == "Review the result before closing.")
        #expect(dock.metrics.isEmpty)
        #expect(dock.details.contains {
            $0.id == "goal" &&
                $0.title == "Goal" &&
                $0.summary == "Create Masterball puzzle web solver"
        })
        #expect(dock.details.contains {
            $0.id == "proof" &&
                $0.title == "Proof" &&
                $0.summary == "No validation contract. ASTRA found 1 artifact."
        })
        #expect(dock.details.contains {
            $0.id == "run" &&
                $0.title == "Run" &&
                $0.summary.contains("Run finished - Needs review")
        })
        #expect(dock.details.contains {
            $0.id == "run" &&
                $0.summary.contains("ask a follow-up")
        })
        #expect(!actionTitles(dock).contains { $0.localizedCaseInsensitiveContains("verification") })
        #expect(dock.usesOverflowMenu == false)
        #expect(dock.showsDetailsToggle)
        #expect(dock.utilityActions.isEmpty)
        #expect(dock.secondaryDecisionActions.isEmpty)
        let proofDetail = try #require(dock.details.first { $0.id == "proof" })
        #expect(!proofDetail.summary.contains("Artifacts: none recorded"))
    }

    @Test("cancelled dock keeps partial result compact by default")
    func cancelledDockKeepsPartialResultCompactByDefault() throws {
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
        #expect(dock.compactMeta == "Partial result · 1 artifact · 1 file changed · not verified")
        #expect(dock.summary == "Review the partial result, then retry or close.")
        #expect(!dock.prefersExpandedDetails)
        #expect(dock.details.contains { $0.id == "goal" })
        #expect(dock.details.contains { $0.id == "run" && $0.summary.contains("Run cancelled - Needs review") })
        #expect(dock.metrics.isEmpty)
        #expect(dock.utilityActions.isEmpty)
        #expect(dock.secondaryDecisionActions.map(\.kind) == [.closeTask])
    }

    @Test("artifact open is suppressed when thread already shows artifact card")
    func artifactOpenIsSuppressedWhenThreadAlreadyShowsArtifactCard() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .completed,
            artifactPaths: ["/tmp/index.html"],
            visibleThreadAffordances: [.artifactOpen, .runDetails]
        ))

        let dock = try #require(presentation)
        #expect(!dock.utilityActions.contains { $0.kind == .openArtifact })
        #expect(!dock.secondaryDecisionActions.contains { $0.kind == .openArtifact })
        #expect(dock.details.contains { $0.id == "proof" })
        #expect(dock.details.contains { $0.id == "run" })
        #expect(dock.showsDetailsToggle)
    }

    @Test("failed live dock exposes the shared report action only when routed")
    func failedDockExposesReportProblemAction() throws {
        let disabled = try #require(TaskDecisionDockPresentation.build(context(status: .failed)))
        #expect(!disabled.utilityActions.contains { $0.kind == .reportProblem })

        let enabled = try #require(TaskDecisionDockPresentation.build(context(
            status: .failed,
            canReportProblem: true
        )))
        let report = try #require(enabled.utilityActions.first { $0.kind == .reportProblem })
        #expect(report.title == "Report a Problem")
        #expect(report.systemImage == "exclamationmark.bubble")
    }

    @Test("task feedback path never reads generic event payloads or run output")
    func feedbackSourceUsesPersistedAllowlistOnly() throws {
        let root = try TestRepositoryRoot.resolve()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/TaskMainView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func reportCurrentFailure()"))
        let end = try #require(source.range(
            of: "private func approveSimilarRuntimePermissionForTask",
            range: start.upperBound..<source.endIndex
        ))
        let feedbackPath = String(source[start.lowerBound..<end.lowerBound])
        #expect(!feedbackPath.contains("failureReason"))
        #expect(!feedbackPath.contains(".payload"))
        #expect(!feedbackPath.contains(".output"))
    }

    @Test("details toggle is hidden when there are no run details")
    func detailsToggleIsHiddenWhenThereAreNoRunDetails() throws {
        let dock = TaskDecisionDockPresentation(
            id: "empty",
            icon: "info.circle",
            tone: .neutral,
            title: "Empty",
            summary: "No details",
            metrics: [],
            details: [],
            primaryAction: nil,
            secondaryActions: [],
            overflowActions: [],
            prefersExpandedDetails: false
        )
        #expect(dock.details.isEmpty)
        #expect(!dock.showsDetailsToggle)
    }

    @Test("artifact open remains available when thread has no visible artifact card")
    func artifactOpenRemainsAvailableWhenThreadHasNoVisibleArtifactCard() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .completed,
            artifactPaths: ["/tmp/index.html"],
            visibleThreadAffordances: [.runDetails]
        ))

        let dock = try #require(presentation)
        #expect(dock.utilityActions.map(\.kind).contains(.openArtifact))
    }

    @Test("dock does not offer inferred verification when contract already exists")
    func dockDoesNotOfferInferredVerificationWhenContractAlreadyExists() throws {
        let mission = MissionControlPresentation(
            objective: "Create Masterball puzzle web solver",
            statusTitle: "Verified",
            statusSummary: "1/1 required proofs passed",
            tone: .verified,
            activeStepTitle: nil,
            validationSummary: "passed: 1/1 required, 1 assertions",
            assertionRows: [],
            latestHandoffSummary: "Review the result.",
            blockerCount: 0,
            artifactCount: 1,
            changedFileCount: 1,
            budgetSummary: "42.1k used / unlimited",
            nextAction: "Review the result.",
            correction: nil,
            sourcePointerCount: 9
        )

        let presentation = TaskDecisionDockPresentation.build(context(
            status: .completed,
            mission: mission,
            artifactPaths: ["/tmp/index.html"]
        ))

        let dock = try #require(presentation)
        #expect(!actionTitles(dock).contains { $0.localizedCaseInsensitiveContains("verification") })
    }

    @Test("dock does not offer inferred verification after deliverable verification passes")
    func dockDoesNotOfferInferredVerificationAfterDeliverableVerificationPasses() throws {
        let mission = MissionControlPresentation(
            objective: "Create Masterball puzzle web solver",
            statusTitle: "Completed",
            statusSummary: "No validation contract recorded",
            tone: .attention,
            activeStepTitle: nil,
            validationSummary: "No validation contract",
            assertionRows: [],
            latestHandoffSummary: "Review the result.",
            blockerCount: 0,
            artifactCount: 1,
            changedFileCount: 1,
            budgetSummary: "42.1k used / unlimited",
            nextAction: "Review the result.",
            correction: nil,
            sourcePointerCount: 9
        )

        let presentation = TaskDecisionDockPresentation.build(context(
            status: .completed,
            mission: mission,
            verification: TaskVerificationPresentation(
                title: "Verification passed",
                summary: "Verified",
                detail: "passed via deliverable_verification · Artifacts: 1 current · Deliverable quality: syntax_verified · Deliverable syntax verified for 1 artifact.",
                systemImage: "checkmark.seal.fill",
                tone: .verified
            ),
            artifactPaths: ["/tmp/index.html"]
        ))

        let dock = try #require(presentation)
        #expect(dock.compactMeta == "1 artifact · 1 file changed · syntax checked")
        #expect(dock.details.contains { $0.id == "proof" && $0.summary == "Syntax checked for 1 artifact." })
        #expect(!actionTitles(dock).contains { $0.localizedCaseInsensitiveContains("verification") })
    }

    @Test("correction dock keeps one primary action and moves dismiss to overflow")
    func correctionDockKeepsOnePrimaryActionAndMovesDismissToOverflow() throws {
        let mission = MissionControlPresentation(
            objective: "Create Masterball puzzle web solver",
            statusTitle: "Needs attention",
            statusSummary: "browser-check failed",
            tone: .failed,
            activeStepTitle: "Repair browser behavior",
            validationSummary: "failed: browser-check",
            assertionRows: [],
            latestHandoffSummary: "Fix the browser-visible behavior.",
            blockerCount: 1,
            artifactCount: 1,
            changedFileCount: 1,
            budgetSummary: "52.7k used / unlimited",
            nextAction: "Approve the correction or create a separate task.",
            correction: MissionControlCorrection(
                correctiveStepID: "repair-browser",
                failedAssertionID: "browser-check",
                status: "proposed",
                suggestedRepair: "Fix the browser-visible behavior or update the expected evidence, then rerun validation."
            ),
            sourcePointerCount: 9
        )

        let presentation = TaskDecisionDockPresentation.build(context(
            status: .completed,
            mission: mission,
            artifactPaths: ["/tmp/index.html"]
        ))

        let dock = try #require(presentation)
        #expect(dock.title == "Correction needed")
        #expect(dock.summary == "Fix browser-check, then rerun validation.")
        #expect(dock.primaryAction?.kind == .approveCorrection)
        #expect(dock.secondaryActions.map(\.kind) == [.createCorrectionTask])
        #expect(dock.overflowActions.contains { $0.kind == .dismissCorrection })
        #expect(dock.utilityActions.isEmpty)
        #expect(dock.secondaryDecisionActions.map(\.kind).contains(.createCorrectionTask))
        #expect(dock.secondaryDecisionActions.map(\.kind).contains(.dismissCorrection))
        #expect(dock.details.contains {
            $0.id == "correction" &&
                $0.summary.contains("Fix the browser-visible behavior")
        })
    }

    @Test("policy-blocked pending review shows the real diagnostic remediation, not generic broader-permissions copy")
    func policyBlockedPendingReviewShowsRealRemediation() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .pendingUser,
            pendingReviewState: PendingTaskReviewState(isDismissed: false, dismissalReason: .policyBlocked),
            launchBlock: TaskRunLaunchBlockPayload(
                kind: .runtimeIncompatible,
                title: "Selected runtime is incompatible with required ASTRA capabilities",
                message: "Copilot CLI cannot satisfy: host-control MCP server for github.",
                remediation: "Switch to Codex CLI, Claude Code, or a Copilot CLI build with MCP config support, or remove the GitHub host-control capability route for this run."
            )
        ))

        let dock = try #require(presentation)
        #expect(dock.title == "Selected runtime is incompatible with required ASTRA capabilities")
        #expect(dock.summary.contains("Switch to Codex CLI"))
        #expect(!dock.summary.contains("Retry with broader policy permissions"))
    }

    @Test("policy-blocked pending review with a suggested runtime offers a one-click switch action")
    func policyBlockedPendingReviewOffersSwitchRuntimeAction() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .pendingUser,
            pendingReviewState: PendingTaskReviewState(isDismissed: false, dismissalReason: .policyBlocked),
            launchBlock: TaskRunLaunchBlockPayload(
                kind: .runtimeIncompatible,
                title: "Selected runtime is incompatible with required ASTRA capabilities",
                message: "Copilot CLI cannot satisfy: host-control MCP server for github.",
                suggestedRuntimeID: AgentRuntimeID.codexCLI.rawValue
            )
        ))

        let dock = try #require(presentation)
        let switchAction = try #require(dock.secondaryActions.first { $0.kind == .switchRuntime })
        #expect(switchAction.title == "Switch to Codex CLI")
        #expect(switchAction.payload == AgentRuntimeID.codexCLI.rawValue)
    }

    @Test("policy-blocked pending review offers no switch action when there is no retry handler")
    func policyBlockedPendingReviewWithoutRetryHandlerOffersNoSwitchAction() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .pendingUser,
            pendingReviewState: PendingTaskReviewState(isDismissed: false, dismissalReason: .policyBlocked),
            canRetry: false,
            launchBlock: TaskRunLaunchBlockPayload(
                kind: .runtimeIncompatible,
                title: "Selected runtime is incompatible with required ASTRA capabilities",
                message: "Copilot CLI cannot satisfy: host-control MCP server for github.",
                suggestedRuntimeID: AgentRuntimeID.codexCLI.rawValue
            )
        ))

        let dock = try #require(presentation)
        #expect(!dock.secondaryActions.contains { $0.kind == .switchRuntime })
    }

    @Test("policy-blocked pending review without a suggested runtime offers no switch action")
    func policyBlockedPendingReviewWithoutSuggestionOffersNoSwitchAction() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .pendingUser,
            pendingReviewState: PendingTaskReviewState(isDismissed: false, dismissalReason: .policyBlocked)
        ))

        let dock = try #require(presentation)
        #expect(!dock.secondaryActions.contains { $0.kind == .switchRuntime })
    }

    @Test("policy-blocked pending review falls back to generic copy when no diagnostic remediation is available")
    func policyBlockedPendingReviewFallsBackWithoutRemediation() throws {
        let presentation = TaskDecisionDockPresentation.build(context(
            status: .pendingUser,
            pendingReviewState: PendingTaskReviewState(isDismissed: false, dismissalReason: .policyBlocked)
        ))

        let dock = try #require(presentation)
        #expect(dock.title == "Policy blocked")
        #expect(dock.summary.contains("Retry with broader policy permissions"))
    }

    private func context(
        status: TaskStatus,
        mission: MissionControlPresentation? = nil,
        verification: TaskVerificationPresentation? = nil,
        artifactPaths: [String] = [],
        canReportProblem: Bool = false,
        visibleThreadAffordances: Set<TaskThreadAffordance>? = nil,
        pendingReviewState: PendingTaskReviewState = .none,
        canRetry: Bool = true,
        launchBlock: TaskRunLaunchBlockPayload? = nil
    ) -> TaskDecisionDockPresentation.Context {
        let affordances = visibleThreadAffordances ?? defaultVisibleThreadAffordances(
            mission: mission,
            artifactPaths: artifactPaths
        )
        return TaskDecisionDockPresentation.Context(
            status: status,
            isClosed: false,
            review: TaskPresentationState.reviewPresentation(status: status, isClosed: false),
            mission: mission,
            verification: verification,
            pendingReviewState: pendingReviewState,
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
            canRetry: canRetry,
            canResume: false,
            canReportProblem: canReportProblem,
            canToggleDone: true,
            hasProviderSession: false,
            failureReason: nil,
            launchBlock: launchBlock,
            artifactPaths: artifactPaths,
            visibleThreadAffordances: affordances
        )
    }

    private func defaultVisibleThreadAffordances(
        mission: MissionControlPresentation?,
        artifactPaths: [String]
    ) -> Set<TaskThreadAffordance> {
        var affordances: Set<TaskThreadAffordance> = [.runDetails]
        if mission != nil {
            affordances.insert(.missionControlDetails)
        }
        if !artifactPaths.isEmpty {
            affordances.insert(.artifactOpen)
        }
        return affordances
    }

    private func actionTitles(_ dock: TaskDecisionDockPresentation) -> [String] {
        ([dock.primaryAction].compactMap { $0 } +
            dock.secondaryActions +
            dock.overflowActions +
            dock.utilityActions +
            dock.secondaryDecisionActions)
            .map(\.title)
    }
}
