import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Task decision dock presentation")
struct TaskDecisionDockPresentationTests {
    @Test("Git publish request takes priority over generic pending review")
    func gitPublishRequestUsesTypedReviewAction() throws {
        var input = context(status: .pendingUser)
        input.hasGitPublishRequest = true

        let presentation = try #require(TaskDecisionDockPresentation.build(input))

        #expect(presentation.id == "git-publish-approval")
        #expect(presentation.title == "Publication approval needed")
        #expect(presentation.primaryAction?.kind == .reviewGitPublish)
        #expect(presentation.primaryAction?.title == "Review & publish")
        #expect(!actionTitles(presentation).contains("Approve result"))
    }

    @Test("completed task with a prepared GitHub review offers posting approval")
    func completedTaskOffersGitHubReview() throws {
        var input = context(status: .completed)
        input.githubReviewPath = "/tmp/pr1139_review.json"

        let presentation = try #require(TaskDecisionDockPresentation.build(input))

        #expect(presentation.id == "github-review-approval")
        #expect(presentation.primaryAction?.kind == .reviewGitHubReview)
        #expect(presentation.primaryAction?.title == "Review comments")
    }

    @Test("a failed task keeps Retry alongside a prepared GitHub review")
    func failedTaskKeepsRetryWithGitHubReview() throws {
        var input = context(status: .failed)
        input.githubReviewPath = "/tmp/pr1139_review.json"

        let presentation = try #require(TaskDecisionDockPresentation.build(input))
        #expect(presentation.primaryAction?.kind == .reviewGitHubReview)
        #expect(presentation.secondaryActions.contains { $0.kind == .retry })
    }

    @Test("Staged connector mutation takes the dock with a typed review action")
    func stagedConnectorMutationUsesTypedReviewAction() throws {
        var input = context(status: .completed)
        input.pendingConnectorMutationTargets = ["STAR / Bug"]

        let presentation = try #require(TaskDecisionDockPresentation.build(input))

        #expect(presentation.id == "connector-mutation-approval")
        #expect(presentation.title == "Send approval needed")
        #expect(presentation.primaryAction?.kind == .reviewConnectorMutation)
        #expect(presentation.primaryAction?.title == "Review & send")
        // Names the destination up front. "Approve" with nothing outside ASTRA
        // in the sentence is how a user clicks through a write to a live system.
        #expect(presentation.summary.contains("before ASTRA sends it"))
        #expect(presentation.details.contains {
            $0.id == "connector-mutation.targets" &&
                $0.title == "Destination" &&
                $0.summary == "STAR / Bug"
        })
        #expect(!actionTitles(presentation).contains("Approve result"))
    }

    /// Single-use approval means two writes are two decisions, and the dock is
    /// where that stops being an invariant and becomes something a user can see.
    @Test("Two staged mutations are counted and both destinations are named")
    func twoStagedConnectorMutationsAreBothNamed() throws {
        var input = context(status: .completed)
        input.pendingConnectorMutationTargets = ["STAR / Bug", "STAR / Task"]

        let presentation = try #require(TaskDecisionDockPresentation.build(input))

        #expect(presentation.title == "2 sends need approval")
        #expect(presentation.details.contains {
            $0.id == "connector-mutation.targets" &&
                $0.title == "Destinations" &&
                $0.summary == "STAR / Bug · STAR / Task"
        })
    }

    /// Ordering, pinned because it is a judgement call rather than an accident.
    /// A staged mutation blocks nothing, so it yields to the request the agent
    /// is actually waiting on — and outranks the advisory rows, because it is
    /// the only one that puts something into a system outside ASTRA.
    @Test("A staged mutation yields to git publish and outranks a correction")
    func stagedMutationSitsBetweenPublicationAndAdvisoryRows() throws {
        var publishing = context(status: .completed)
        publishing.pendingConnectorMutationTargets = ["STAR / Bug"]
        publishing.hasGitPublishRequest = true
        #expect(try #require(TaskDecisionDockPresentation.build(publishing)).id == "git-publish-approval")

        var correcting = context(
            status: .completed,
            mission: missionNeedingCorrection()
        )
        correcting.pendingConnectorMutationTargets = ["STAR / Bug"]
        let dock = try #require(TaskDecisionDockPresentation.build(correcting))
        #expect(dock.id == "connector-mutation-approval")
    }

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

    // MARK: - Connector credential prompts in Auto

    /// Auto does not dismiss a connector's credential prompt, so the only thing
    /// it can do for the user is not repeat it. "Allow once" lives in the run it
    /// resumes: production task 2A0E30EC asked eight times, and a follow-up or a
    /// Retry asks again even once each prompt covers every connector.
    @Test("Auto leads a connector credential prompt with the task-scoped approval")
    func autoLeadsConnectorCredentialPromptWithTaskScope() throws {
        let dock = try #require(TaskDecisionDockPresentation.build(connectorCredentialContext(isAuto: true)))

        #expect(dock.id == "runtime-permission")
        #expect(dock.primaryAction?.kind == .allowSimilar)
        #expect(dock.primaryAction?.title == "Allow for task & continue")
        // The tooltip keeps the request's own wording.
        #expect(dock.primaryAction?.help == "Allow these connectors for task")
        #expect(dock.secondaryActions.map(\.kind) == [.retry, .allowOnce])
        #expect(dock.secondaryActions.last?.title == "Allow once & continue")
        let scope = dock.details.first { $0.id == "permission.scope" }?.summary
        #expect(scope == TaskDecisionDockPresentation.taskScopedPermissionScope)
    }

    @Test("Ask keeps the one-run approval first for the same connector credential prompt")
    func askKeepsOneRunApprovalFirstForConnectorCredentials() throws {
        let dock = try #require(TaskDecisionDockPresentation.build(connectorCredentialContext(isAuto: false)))

        #expect(dock.primaryAction?.kind == .allowOnce)
        #expect(dock.primaryAction?.title == "Allow once & continue")
        #expect(dock.secondaryActions.map(\.kind) == [.retry, .allowSimilar])
        #expect(dock.secondaryActions.last?.title == "Allow similar")
        let scope = dock.details.first { $0.id == "permission.scope" }?.summary
        #expect(scope == "Scope: one time for this run.")
    }

    @Test("Auto keeps the one-run approval first for a request that is not a connector credential")
    func autoKeepsOneRunApprovalFirstForOtherRequests() throws {
        var input = connectorCredentialContext(isAuto: true)
        input.runtimePermissionIsConnectorCredential = false

        let dock = try #require(TaskDecisionDockPresentation.build(input))

        #expect(dock.primaryAction?.kind == .allowOnce)
        #expect(dock.primaryAction?.title == "Allow once & continue")
        #expect(dock.secondaryActions.map(\.kind) == [.retry, .allowSimilar])
    }

    /// Nothing to lead with: a request with no reusable grant (content-bound, or
    /// a sandbox path) can only be answered once, in any mode.
    @Test("Auto keeps the one-run approval first when no task-scoped approval exists")
    func autoKeepsOneRunApprovalFirstWithoutATaskScopedApproval() throws {
        var input = connectorCredentialContext(isAuto: true)
        input.canApproveSimilarRuntimePermission = false

        let dock = try #require(TaskDecisionDockPresentation.build(input))

        #expect(!input.prefersTaskScopedRuntimePermission)
        #expect(dock.primaryAction?.kind == .allowOnce)
        #expect(dock.secondaryActions.map(\.kind) == [.retry])
    }

    @Test("Auto still leads with the task-scoped approval when there is no one-run handler")
    func autoLeadsWithTaskScopeWithoutAOneRunHandler() throws {
        var input = connectorCredentialContext(isAuto: true)
        input.canApprove = false

        let dock = try #require(TaskDecisionDockPresentation.build(input))

        #expect(dock.primaryAction?.kind == .allowSimilar)
        #expect(dock.secondaryActions.map(\.kind) == [.retry])
        #expect(!actionTitles(dock).contains("Allow once"))
    }

    /// The label is derived from the request itself, so the flag cannot drift
    /// from what the dock is actually asking about.
    @Test("The dock builder reads the Auto flag and the request kind from the real payload")
    func builderMarksConnectorCredentialRequestsFromThePayload() throws {
        let credentials = TaskRuntimePermissionState.build(events: [
            .init(type: "permission.approval.requested", payload: connectorCredentialPayload(), timestamp: Date())
        ])
        #expect(credentials.decision?.isConnectorCredentialRequest == true)
        #expect(credentials.canApproveSimilarForTask)

        let auto = try #require(TaskDecisionDockContextBuilder.build(dockBuilderInput(credentials, isAuto: true)))
        #expect(auto.title == "Jira-new and REDCap connectors need permission")
        #expect(auto.primaryAction?.kind == .allowSimilar)
        #expect(auto.primaryAction?.title == "Allow for task & continue")
        #expect(auto.primaryAction?.help == "Allow these connectors for task")

        let ask = try #require(TaskDecisionDockContextBuilder.build(dockBuilderInput(credentials, isAuto: false)))
        #expect(ask.primaryAction?.kind == .allowOnce)

        let shell = TaskRuntimePermissionState.build(events: [
            .init(type: "permission.approval.requested", payload: shellCommandPayload(), timestamp: Date())
        ])
        #expect(shell.decision?.isConnectorCredentialRequest == false)
        let autoShell = try #require(TaskDecisionDockContextBuilder.build(dockBuilderInput(shell, isAuto: true)))
        #expect(autoShell.primaryAction?.kind == .allowOnce)
    }

    /// A finished run left this request: nothing is paused, so "Allow once" only
    /// ever approved the task and granted nothing. Only the task-scoped approval
    /// records the grant the next run reads, so it leads in every mode.
    @Test("An offer leads with the task-scoped approval in Ask too, and has no Allow once")
    func offerLeadsWithTaskScopeInAskAndOffersNoAllowOnce() throws {
        var input = connectorCredentialContext(isAuto: false)
        input.runtimePermissionIsOffer = true

        let dock = try #require(TaskDecisionDockPresentation.build(input))

        #expect(dock.primaryAction?.kind == .allowSimilar)
        #expect(dock.primaryAction?.title == "Allow for this task")
        #expect(dock.secondaryActions.map(\.kind) == [.retry])
        #expect(!actionTitles(dock).contains { $0.hasPrefix("Allow once") })
        let scope = dock.details.first { $0.id == "permission.scope" }?.summary
        #expect(scope == TaskDecisionDockPresentation.offeredConnectorPermissionScope)
    }

    @Test("A future-use offer never exposes a one-run approval")
    func offerWithoutTaskScopeHasNoMisleadingApproval() throws {
        var input = connectorCredentialContext(isAuto: false)
        input.runtimePermissionIsOffer = true
        input.canApproveSimilarRuntimePermission = false

        let dock = try #require(TaskDecisionDockPresentation.build(input))

        #expect(dock.primaryAction == nil)
    }

    @Test("The dock builder recognises explicit future-use intent instead of parsing request ids")
    func builderRecognisesExplicitFutureUse() throws {
        let offerID = BrokeredCredentialApprovalRecord.offerRequestID(forConnectors: [Self.jiraConnectorID])
        let offer = TaskRuntimePermissionState.build(events: [
            .init(type: "permission.approval.requested", payload: connectorCredentialPayload(requestID: offerID, behavior: .futureUse), timestamp: Date())
        ])
        #expect(offer.decision?.isConnectorCredentialOffer == true)
        let dock = try #require(TaskDecisionDockContextBuilder.build(dockBuilderInput(offer, isAuto: false)))
        #expect(dock.primaryAction?.kind == .allowSimilar)
        #expect(!actionTitles(dock).contains { $0.hasPrefix("Allow once") })

        let pause = TaskRuntimePermissionState.build(events: [
            .init(type: "permission.approval.requested", payload: connectorCredentialPayload(), timestamp: Date())
        ])
        #expect(pause.decision?.isConnectorCredentialOffer == false)
        let pauseDock = try #require(TaskDecisionDockContextBuilder.build(dockBuilderInput(pause, isAuto: false)))
        #expect(pauseDock.primaryAction?.kind == .allowOnce)
    }

    /// Jira and REDCap are brokered: their tokens stay inside ASTRA and are
    /// stripped from the agent's environment. The prompt cannot know the service
    /// from the request alone, so it says only what is true of every connector.
    @Test("Connector credential copy says ASTRA uses the credentials, never that the agent is handed them")
    func credentialCopyNeverClaimsExposure() {
        let payload = connectorCredentialPayload()
        let approval = RuntimePermissionApprovalText(payload: payload)
        let decision = RuntimePermissionDecisionPresentation(payload: payload)

        #expect(decision.summary == "ASTRA wants to use 3 saved credentials from the Jira-new and REDCap connectors for this task.")
        for copy in [approval.payload, decision.summary, decision.check, decision.scope] {
            let lowered = copy.lowercased()
            for claim in ["expose", "inject", "provider environment", "agent process"] {
                #expect(!lowered.contains(claim), "\(claim) in: \(copy)")
            }
        }
    }

    private func connectorCredentialContext(isAuto: Bool) -> TaskDecisionDockPresentation.Context {
        var input = context(status: .pendingUser)
        input.hasRuntimePermissionRequest = true
        input.runtimePermissionTitle = "Jira-new and REDCap connectors need permission"
        input.runtimePermissionSummary = "ASTRA wants to use 3 saved credentials for this task."
        input.runtimePermissionScope = "Scope: one time for this run."
        input.runtimePermissionAllowSimilarLabel = "Allow these connectors for task"
        input.canApproveSimilarRuntimePermission = true
        input.runtimePermissionIsConnectorCredential = true
        input.isAutoPermissionMode = isAuto
        return input
    }

    private static let jiraConnectorID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let redcapConnectorID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func connectorCredentialPayload(requestID: String? = nil, behavior: PermissionApprovalBehavior? = nil) -> String {
        let request = PermissionRequest.connectorCredentials(
            connectorID: Self.jiraConnectorID,
            displayName: "Jira-new and REDCap connector credentials (3 configured credentials)",
            labels: [
                ConnectorRuntimeProjection.credentialLabel(connectorID: Self.jiraConnectorID, key: "JIRA_API_TOKEN"),
                ConnectorRuntimeProjection.credentialLabel(connectorID: Self.jiraConnectorID, key: "JIRA_EMAIL"),
                ConnectorRuntimeProjection.credentialLabel(connectorID: Self.redcapConnectorID, key: "REDCAP_API_TOKEN")
            ]
        )
        return PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: request,
            reason: "Connector credential egress requires explicit first-use approval.",
            grants: PermissionBroker.approvalGrants(for: request),
            requestID: requestID,
            behavior: behavior
        )
    }

    private func shellCommandPayload() -> String {
        let request = PermissionRequest.shell(command: "gh pr list", toolName: "Bash")
        return PermissionBroker.approvalPayloadString(
            providerID: .claudeCode,
            request: request,
            reason: "The shell command is outside the current policy.",
            grants: PermissionBroker.approvalGrants(for: request)
        )
    }

    private func dockBuilderInput(
        _ runtimePermission: TaskRuntimePermissionState,
        isAuto: Bool
    ) -> TaskDecisionDockContextBuilder.Input {
        TaskDecisionDockContextBuilder.Input(
            status: .pendingUser,
            isClosed: false,
            review: TaskPresentationState.reviewPresentation(status: .pendingUser, isClosed: false),
            mission: nil,
            verification: nil,
            pendingReviewState: .none,
            runtimePermission: runtimePermission,
            executableApprovedPlan: nil,
            skipPermissions: isAuto,
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
            launchBlock: nil,
            artifactPaths: [],
            extraDetails: []
        )
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
        launchBlock: TaskRunLaunchBlockPayload? = nil,
        executableApprovedPlan: TaskPlanPayload? = nil,
        canResume: Bool = false,
        hasProviderSession: Bool = false
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
            hasExecutableApprovedPlan: executableApprovedPlan != nil,
            planActionTitle: executableApprovedPlan?.title,
            planActionDetail: executableApprovedPlan?.title,
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
            canResume: canResume,
            canReportProblem: canReportProblem,
            canToggleDone: true,
            hasProviderSession: hasProviderSession,
            failureReason: nil,
            launchBlock: launchBlock,
            artifactPaths: artifactPaths,
            visibleThreadAffordances: affordances
        )
    }

    private func missionNeedingCorrection() -> MissionControlPresentation {
        MissionControlPresentation(
            objective: "File the age-filter ticket",
            statusTitle: "Needs attention",
            statusSummary: "browser-check failed",
            tone: .failed,
            activeStepTitle: "Repair browser behavior",
            validationSummary: "failed: browser-check",
            assertionRows: [],
            latestHandoffSummary: "Fix the browser-visible behavior.",
            blockerCount: 1,
            artifactCount: 0,
            changedFileCount: 0,
            budgetSummary: "12.0k used / unlimited",
            nextAction: "Approve the correction or create a separate task.",
            correction: MissionControlCorrection(
                correctiveStepID: "repair-browser",
                failedAssertionID: "browser-check",
                status: "proposed",
                suggestedRepair: "Fix the browser-visible behavior, then rerun validation."
            ),
            sourcePointerCount: 3
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
