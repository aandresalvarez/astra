import Foundation
import ASTRACore
import ASTRAModels

enum TaskDecisionDockTone: String, Equatable {
    case neutral
    case running
    case attention
    case success
    case failed
    case verified
    case closed
}

enum TaskDecisionDockActionKind: String, Equatable {
    case stop
    case stopRun
    case cancelTurnRequest
    case allowOnce
    case allowSimilar
    case reviewGitPublish
    case approveResult
    case dismissReview
    case approveCorrection
    case createCorrectionTask
    case dismissCorrection
    case openPlan
    case runApprovedPlan
    case runTask
    case retry
    case resume
    case reportProblem
    case openArtifact
    case closeTask
    case closeAnyway
    case closeWithoutRunningPlan
    case reopenTask
    case switchRuntime
    case repairDockerImage
}

enum TaskThreadAffordance: Hashable {
    case artifactOpen
    case runDetails
    case missionControlDetails
    case planDetails
}

struct TaskDecisionDockAction: Equatable, Identifiable {
    var id: String { "\(kind.rawValue):\(payload ?? ""):\(title)" }
    var kind: TaskDecisionDockActionKind
    var title: String
    var systemImage: String
    var payload: String?
    var help: String?
    var isEnabled: Bool = true
}

struct TaskDecisionDockMetric: Equatable, Identifiable {
    var id: String
    var title: String
    var value: String
    var tone: TaskDecisionDockTone
}

struct TaskDecisionDockDetail: Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var systemImage: String
    var tone: TaskDecisionDockTone
    var isMonospaced: Bool = false
}

struct TaskDecisionDockPresentation: Equatable {
    struct Context: Equatable {
        var status: TaskStatus
        var isClosed: Bool
        var review: TaskReviewPresentation
        var mission: MissionControlPresentation?
        var verification: TaskVerificationPresentation?
        var pendingReviewState: PendingTaskReviewState
        var hasRuntimePermissionRequest: Bool
        var runtimePermissionTitle: String?
        var runtimePermissionSummary: String?
        var runtimePermissionScope: String?
        var runtimePermissionCommandPreview: String?
        var runtimePermissionAllowSimilarLabel: String?
        var canApproveSimilarRuntimePermission: Bool
        var hasGitPublishRequest: Bool = false
        var hasExecutableApprovedPlan: Bool
        var planActionTitle: String?
        var planActionDetail: String?
        var planModeLabel: String?
        var canOpenPlan: Bool
        var isPlanCanvasVisible: Bool
        var canRunApprovedPlan: Bool
        var latestRunHasNoUsableResult: Bool
        var completedTaskNeedsArtifactAttention: Bool
        var canCancel: Bool
        var canRun: Bool
        var canApprove: Bool
        var canRetry: Bool
        var canResume: Bool
        var canReportProblem: Bool = false
        var canToggleDone: Bool
        var hasProviderSession: Bool
        var failureReason: String?
        var launchBlock: TaskRunLaunchBlockPayload?
        var dockerRecoveryImage: String? = nil
        var isDockerRecoveryBusy: Bool = false
        var artifactPaths: [String]
        var extraDetails: [TaskDecisionDockDetail] = []
        var visibleThreadAffordances: Set<TaskThreadAffordance> = []
    }

    var id: String
    var icon: String
    var tone: TaskDecisionDockTone
    var title: String
    var summary: String
    /// Short dot-separated evidence ("3 artifacts · 2 files changed ·
    /// syntax checked") rendered inline after the title in the compact row.
    /// `summary` stays hover/accessibility copy per the decision-dock spec.
    var compactMeta: String? = nil
    var metrics: [TaskDecisionDockMetric]
    var details: [TaskDecisionDockDetail]
    var primaryAction: TaskDecisionDockAction?
    var secondaryActions: [TaskDecisionDockAction]
    var overflowActions: [TaskDecisionDockAction]
    var prefersExpandedDetails: Bool

    var hasDetails: Bool { !details.isEmpty }
    var hasActions: Bool { primaryAction != nil || !secondaryActions.isEmpty || !overflowActions.isEmpty }
    var utilityActions: [TaskDecisionDockAction] {
        flattenedSupportActions.filter(\.kind.isDecisionDockUtility)
    }
    var showsDetailsToggle: Bool { hasDetails }
    var secondaryDecisionActions: [TaskDecisionDockAction] {
        flattenedSupportActions.filter { !$0.kind.isDecisionDockUtility }
    }
    var usesOverflowMenu: Bool { false }

    private var flattenedSupportActions: [TaskDecisionDockAction] {
        var seen = Set<String>()
        var result: [TaskDecisionDockAction] = []
        for action in secondaryActions + overflowActions {
            guard seen.insert(action.id).inserted else { continue }
            result.append(action)
        }
        return result
    }

    static func build(_ context: Context) -> TaskDecisionDockPresentation? {
        if context.isClosed {
            return closedPresentation(context)
        }

        if context.hasRuntimePermissionRequest {
            return runtimePermissionPresentation(context)
        }

        if context.hasGitPublishRequest {
            return gitPublishPresentation(context)
        }

        if let correction = context.mission?.correction {
            return correctionPresentation(context, correction: correction)
        }

        if context.hasExecutableApprovedPlan {
            return planPresentation(context)
        }

        switch context.status {
        case .running:
            guard context.canCancel else { return passivePresentation(context, title: "Task running") }
            return runningPresentation(context)
        case .pendingUser:
            guard !context.pendingReviewState.isDismissed || context.pendingReviewState.dismissalReason != nil else {
                return passivePresentation(context, title: "Review dismissed")
            }
            return pendingReviewPresentation(context)
        case .queued:
            return queuedPresentation(context)
        case .failed, .budgetExceeded:
            return failedPresentation(context)
        case .completed:
            if context.completedTaskNeedsArtifactAttention || context.latestRunHasNoUsableResult {
                return noUsableResultPresentation(context)
            }
            return completedPresentation(context)
        case .cancelled:
            return cancelledPresentation(context)
        case .draft:
            return context.mission == nil && context.verification == nil && context.extraDetails.isEmpty
                ? nil
                : passivePresentation(context, title: "Draft")
        }
    }

    private static func runningPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        return TaskDecisionDockPresentation(
            id: "running",
            icon: "stop.circle.fill",
            tone: .running,
            title: "Task running",
            summary: firstNonEmpty(context.extraDetails.first?.summary, "The agent is working. Stop it here if you need to change direction."),
            metrics: metrics(context),
            details: details(context),
            primaryAction: action(.stop, title: "Stop", systemImage: "stop.fill"),
            secondaryActions: [],
            overflowActions: [],
            prefersExpandedDetails: context.extraDetails.contains { $0.tone == .attention || $0.tone == .failed }
        )
    }

    private static func runtimePermissionPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        var dockDetails = details(context)
        appendIfPresent(
            TaskDecisionDockDetail(
                id: "permission.scope",
                title: "Permission scope",
                summary: context.runtimePermissionScope ?? "",
                systemImage: "scope",
                tone: .attention
            ),
            to: &dockDetails
        )
        appendIfPresent(
            TaskDecisionDockDetail(
                id: "permission.command",
                title: "Command",
                summary: context.runtimePermissionCommandPreview ?? "",
                systemImage: "terminal",
                tone: .attention,
                isMonospaced: true
            ),
            to: &dockDetails
        )

        return TaskDecisionDockPresentation(
            id: "runtime-permission",
            icon: "hand.raised.fill",
            tone: .attention,
            title: context.runtimePermissionTitle ?? "Permission needed",
            summary: context.runtimePermissionSummary ?? "The provider needs one-time permission before it can continue.",
            metrics: metrics(context),
            details: dockDetails,
            primaryAction: context.canApprove
                ? action(.allowOnce, title: "Allow once & continue", systemImage: "lock.open.fill")
                : nil,
            secondaryActions: [
                context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
                context.canApproveSimilarRuntimePermission
                    ? action(
                        .allowSimilar,
                        title: "Allow similar",
                        systemImage: "checkmark.shield",
                        help: context.runtimePermissionAllowSimilarLabel ?? "Allow similar requests for this task."
                    )
                    : nil
            ].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: true
        )
    }

    private static func gitPublishPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "git-publish-approval",
            icon: "arrow.triangle.branch",
            tone: .attention,
            title: "Publication approval needed",
            summary: "Review the exact branch, files, commit, and draft pull request before ASTRA publishes it.",
            metrics: metrics(context),
            details: details(context),
            primaryAction: action(
                .reviewGitPublish,
                title: "Review & publish",
                systemImage: "arrow.up.doc.fill"
            ),
            secondaryActions: [
                context.canRetry ? action(.retry, title: "Retry agent", systemImage: "arrow.clockwise") : nil,
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: supportAndCloseOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: true
        )
    }

    private static func correctionPresentation(
        _ context: Context,
        correction: MissionControlCorrection
    ) -> TaskDecisionDockPresentation {
        let correctionDetail = TaskDecisionDockDetail(
            id: "correction",
            title: "Fix",
            summary: "\(correction.failedAssertionID): \(correction.suggestedRepair)",
            systemImage: "wrench.and.screwdriver",
            tone: .failed
        )
        return TaskDecisionDockPresentation(
            id: "correction-\(correction.correctiveStepID)",
            icon: "wrench.and.screwdriver.fill",
            tone: .failed,
            title: "Correction needed",
            summary: "Fix \(correction.failedAssertionID), then rerun validation.",
            metrics: metrics(context),
            details: details(context, additional: [correctionDetail]),
            primaryAction: action(
                .approveCorrection,
                title: correction.status == "approved" ? "Approved" : "Approve",
                systemImage: "checkmark",
                payload: correction.correctiveStepID,
                isEnabled: correction.status != "approved"
            ),
            secondaryActions: [
                firstArtifactAction(context),
                action(.createCorrectionTask, title: "Create task", systemImage: "plus.square", payload: correction.correctiveStepID)
            ].compactMap { $0 },
            overflowActions: [
                action(.dismissCorrection, title: "Dismiss", systemImage: "xmark", payload: correction.correctiveStepID)
            ] + closeOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: true
        )
    }

    private static func planPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        let title = context.planActionTitle ?? "Approve next step"
        return TaskDecisionDockPresentation(
            id: "approved-plan",
            icon: title == "Run remaining plan" ? "play.circle.fill" : "checkmark.circle.fill",
            tone: title == "Run remaining plan" ? .attention : .verified,
            title: title,
            summary: context.planActionDetail ?? "Review the next approved plan step, then continue.",
            metrics: metrics(context),
            details: details(context, additional: [
                context.planModeLabel.map {
                    TaskDecisionDockDetail(
                        id: "plan.mode",
                        title: "Execution mode",
                        summary: $0,
                        systemImage: "slider.horizontal.3",
                        tone: .neutral
                    )
                }
            ].compactMap { $0 }),
            primaryAction: action(
                .runApprovedPlan,
                title: title,
                systemImage: title == "Run remaining plan" ? "play.fill" : "checkmark",
                isEnabled: context.canRunApprovedPlan
            ),
            secondaryActions: [
                context.canOpenPlan
                    ? action(
                        .openPlan,
                        title: context.isPlanCanvasVisible ? "Hide Plan" : "Open Plan",
                        systemImage: "list.bullet.clipboard"
                    )
                    : nil
            ].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: TaskPresentationState.closeWithoutRunningPlanActionTitle),
            prefersExpandedDetails: false
        )
    }

    private static func pendingReviewPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        let dismissalReason = context.pendingReviewState.dismissalReason
        let isBlocked = dismissalReason == .policyBlocked
        let isMissingArtifact = dismissalReason == .noUsableResult || dismissalReason == .missingRequiredArtifact
        let title = isMissingArtifact
            ? "No usable result"
            : (isBlocked ? (context.launchBlock?.title ?? "Policy blocked") : "Needs your review")
        let summary: String
        if isBlocked {
            summary = context.launchBlock?.remediation.map { "The run stopped before completion. \($0) Dismissing will not mark it completed." }
                ?? "The run stopped before completion. Retry with broader policy permissions; dismissing will not mark it completed."
        } else if isMissingArtifact {
            summary = "The task did not create the expected artifact. Retry or dismiss without marking it completed."
        } else {
            summary = "Review the latest output, then approve it or retry the task."
        }

        return TaskDecisionDockPresentation(
            id: "pending-review-\(dismissalReason.map(String.init(describing:)) ?? "normal")",
            icon: isBlocked ? "shield.slash.fill" : (isMissingArtifact ? "doc.badge.exclamationmark" : "person.crop.circle.badge.questionmark"),
            tone: isBlocked || isMissingArtifact ? .failed : .attention,
            title: title,
            summary: summary,
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canApprove
                ? action(
                    dismissalReason == nil ? .approveResult : .dismissReview,
                    title: dismissalReason == nil ? "Approve result" : "Dismiss",
                    systemImage: "checkmark"
                )
                : nil,
            secondaryActions: [
                isBlocked ? suggestedRuntimeSwitchAction(context) : nil,
                context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: supportAndCloseOverflowActions(
                context,
                closeTitle: isMissingArtifact ? TaskPresentationState.closeAnywayActionTitle : nil
            ),
            prefersExpandedDetails: isBlocked || isMissingArtifact
        )
    }

    private static func suggestedRuntimeSwitchAction(_ context: Context) -> TaskDecisionDockAction? {
        // Gated on canRetry like the adjacent .retry action — without a
        // handler to actually run the switched task, offering this button
        // would silently no-op when tapped.
        guard context.canRetry,
              let rawID = context.launchBlock?.suggestedRuntimeID,
              let runtime = AgentRuntimeID(rawValue: rawID) else { return nil }
        return action(
            .switchRuntime,
            title: "Switch to \(runtime.displayName)",
            systemImage: "arrow.triangle.2.circlepath",
            payload: rawID,
            help: "Switch this task to \(runtime.displayName) and retry."
        )
    }

    private static func queuedPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "queued",
            icon: "play.circle.fill",
            tone: .running,
            title: "Ready to run",
            summary: "Start this task now, or send a message below to refine it first.",
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canRun ? action(.runTask, title: "Run task", systemImage: "play.fill") : nil,
            secondaryActions: [],
            overflowActions: closeOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: false
        )
    }

    private static func failedPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        let overBudget = context.status == .budgetExceeded
        let dockerRecoveryAction = context.dockerRecoveryImage.map { image in
            action(
                .repairDockerImage,
                title: context.isDockerRecoveryBusy ? "Checking image…" : "Repair image and retry",
                systemImage: "wrench.and.screwdriver.fill",
                payload: image,
                help: "Diagnose and repair \(image), verify it, then retry this task.",
                isEnabled: !context.isDockerRecoveryBusy
            )
        }
        return TaskDecisionDockPresentation(
            id: overBudget ? "budget-exceeded" : "failed",
            icon: overBudget ? "speedometer" : "exclamationmark.triangle.fill",
            tone: .failed,
            title: overBudget ? "Budget exceeded" : "Run stopped",
            summary: overBudget
                ? "Raise the budget and resume, or retry this task from scratch."
                : (context.failureReason ?? "The run failed. Review the output, then resume or retry."),
            metrics: metrics(context),
            details: details(context),
            primaryAction: dockerRecoveryAction ?? (context.canResume && context.hasProviderSession
                ? action(.resume, title: "Resume", systemImage: "play.fill")
                : (context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil)),
            secondaryActions: [
                dockerRecoveryAction != nil && context.canResume && context.hasProviderSession
                    ? action(.resume, title: "Resume", systemImage: "play.fill")
                    : nil,
                dockerRecoveryAction != nil && context.canRetry
                    ? action(.retry, title: "Retry", systemImage: "arrow.clockwise")
                    : (context.canResume && context.hasProviderSession && context.canRetry
                        ? action(.retry, title: "Retry", systemImage: "arrow.clockwise")
                        : nil),
                context.canReportProblem
                    ? action(.reportProblem, title: "Report a Problem", systemImage: "exclamationmark.bubble")
                    : nil,
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: supportAndCloseOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: true
        )
    }

    private static func noUsableResultPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "completed-no-usable-result",
            icon: "doc.badge.exclamationmark",
            tone: .attention,
            title: "No usable result",
            summary: "Expected artifact was not created.",
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
            secondaryActions: [
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: supportAndCloseOverflowActions(
                context,
                closeTitle: TaskPresentationState.closeAnywayActionTitle
            ),
            prefersExpandedDetails: true
        )
    }

    private static func completedPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        let verification = context.verification
        let title: String
        let icon: String
        let tone: TaskDecisionDockTone
        if verification?.tone == .verified {
            title = "Result verified"
            icon = verification?.systemImage ?? "checkmark.seal.fill"
            tone = .verified
        } else if verification?.tone == .failed {
            title = "Verification failed"
            icon = verification?.systemImage ?? "exclamationmark.triangle.fill"
            tone = .failed
        } else {
            title = "Result ready"
            icon = "checkmark.circle.fill"
            tone = .success
        }

        return TaskDecisionDockPresentation(
            id: "completed",
            icon: icon,
            tone: tone,
            title: title,
            summary: "Review the result before closing.",
            compactMeta: compactEvidenceMeta(context),
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canToggleDone ? action(.closeTask, title: TaskPresentationState.closeTaskActionTitle, systemImage: "checkmark.circle") : nil,
            secondaryActions: [
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: [],
            prefersExpandedDetails: verification?.tone == .failed
        )
    }

    private static func cancelledPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "cancelled",
            icon: "xmark.circle.fill",
            tone: .attention,
            title: "Run cancelled",
            summary: "Review the partial result, then retry or close.",
            compactMeta: compactEvidenceMeta(context, prefix: "Partial result"),
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
            secondaryActions: [
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: supportAndCloseOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: false
        )
    }

    private static func closedPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "closed",
            icon: "checkmark.circle.fill",
            tone: .closed,
            title: "Task closed",
            summary: "Reopen it here if you need to continue with this task.",
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canToggleDone ? action(.reopenTask, title: TaskPresentationState.reopenTaskActionTitle, systemImage: "arrow.uturn.backward") : nil,
            secondaryActions: [
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: [],
            prefersExpandedDetails: false
        )
    }

    private static func passivePresentation(_ context: Context, title: String) -> TaskDecisionDockPresentation? {
        let dockDetails = details(context)
        guard context.mission != nil || context.verification != nil || !dockDetails.isEmpty else { return nil }
        return TaskDecisionDockPresentation(
            id: "passive-\(context.status.rawValue)",
            icon: context.verification?.systemImage ?? "info.circle",
            tone: context.verification.map(tone(from:)) ?? .neutral,
            title: title,
            summary: context.verification?.detail ?? context.mission?.latestHandoffSummary ?? context.review.decisionDetail,
            metrics: metrics(context),
            details: dockDetails,
            primaryAction: nil,
            secondaryActions: [
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: supportAndCloseOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: false
        )
    }

    private static func metrics(_ _: Context) -> [TaskDecisionDockMetric] {
        []
    }

    private static func details(
        _ context: Context,
        additional: [TaskDecisionDockDetail] = []
    ) -> [TaskDecisionDockDetail] {
        var output = context.extraDetails

        if let mission = context.mission {
            appendIfPresent(TaskDecisionDockDetail(
                id: "goal",
                title: "Goal",
                summary: mission.objective,
                systemImage: "scope",
                tone: .neutral
            ), to: &output)

            if let activeStep = mission.activeStepTitle {
                appendIfPresent(TaskDecisionDockDetail(
                    id: "active-step",
                    title: "Active step",
                    summary: activeStep,
                    systemImage: "list.bullet.rectangle",
                    tone: .neutral
                ), to: &output)
            }

            appendIfPresent(TaskDecisionDockDetail(
                id: "proof",
                title: "Proof",
                summary: proofSummary(context),
                systemImage: proofIcon(context),
                tone: proofTone(context)
            ), to: &output)
        } else if context.verification != nil || !context.artifactPaths.isEmpty {
            appendIfPresent(TaskDecisionDockDetail(
                id: "proof",
                title: "Proof",
                summary: proofSummary(context),
                systemImage: proofIcon(context),
                tone: proofTone(context)
            ), to: &output)
        }

        appendIfPresent(TaskDecisionDockDetail(
            id: "run",
            title: "Run",
            summary: runSummary(context),
            systemImage: taskStatusIcon(for: context.status, isClosed: context.isClosed),
            tone: taskStatusTone(context)
        ), to: &output)

        for detail in additional {
            appendIfPresent(detail, to: &output)
        }

        return dedupedDetails(output)
    }

    private static func verificationSummary(_ verification: TaskVerificationPresentation) -> String {
        let summary = verification.detail ?? verification.summary
        let cleanedParts = summary
            .components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Artifacts: none recorded" }
        return cleanedParts.isEmpty ? verification.summary : cleanedParts.joined(separator: " · ")
    }

    private static func compactEvidenceMeta(
        _ context: Context,
        prefix: String? = nil
    ) -> String? {
        var parts: [String] = []
        if let prefix {
            parts.append(prefix)
        }
        parts.append(contentsOf: compactEvidenceParts(context))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func compactEvidenceParts(_ context: Context) -> [String] {
        var parts: [String] = []
        let artifacts = artifactCount(context)
        if artifacts > 0 {
            parts.append("\(artifacts) \(artifacts == 1 ? "artifact" : "artifacts")")
        }
        if let changedFiles = context.mission?.changedFileCount, changedFiles > 0 {
            parts.append("\(changedFiles) \(changedFiles == 1 ? "file changed" : "files changed")")
        }
        appendIfPresent(compactProofStatus(context), to: &parts)
        return parts
    }

    private static func compactProofStatus(_ context: Context) -> String {
        if let verification = context.verification {
            switch verification.tone {
            case .verified:
                return verificationMentionsSyntax(verification) ? "syntax checked" : "verified"
            case .failed:
                return "verification failed"
            case .attention, .neutral:
                return "not verified"
            }
        }

        guard let mission = context.mission else { return "" }
        let validation = mission.validationSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !validation.isEmpty, validation != "No validation contract" else {
            return "not verified"
        }

        switch mission.tone {
        case .verified:
            return "verified"
        case .failed:
            return "verification failed"
        case .attention, .neutral, .running:
            return humanizedValidationSummary(validation)
        }
    }

    private static func proofSummary(_ context: Context) -> String {
        let artifactSentence = artifactEvidenceSentence(context)
        if let verification = context.verification {
            switch verification.tone {
            case .verified:
                if verificationMentionsSyntax(verification) {
                    let artifacts = artifactCount(context)
                    if artifacts > 0 {
                        return "Syntax checked for \(artifacts) \(artifacts == 1 ? "artifact" : "artifacts")."
                    }
                }
                return firstNonEmpty(verifiedProofSummary(artifactSentence), verificationSummary(verification))
            case .attention, .neutral:
                if context.mission?.validationSummary == "No validation contract" {
                    return firstNonEmpty(
                        ["No validation contract.", artifactSentence].compactMap { $0 }.joined(separator: " "),
                        "No validation contract."
                    )
                }
                return verificationSummary(verification)
            case .failed:
                return verificationSummary(verification)
            }
        }

        if let mission = context.mission {
            let validation = mission.validationSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if validation.isEmpty || validation == "No validation contract" {
                return firstNonEmpty(
                    ["No validation contract.", artifactSentence].compactMap { $0 }.joined(separator: " "),
                    "No validation contract."
                )
            }
            if mission.tone == .verified {
                return firstNonEmpty(verifiedProofSummary(artifactSentence), humanizedValidationSummary(validation))
            }
            return humanizedValidationSummary(validation)
        }

        return artifactSentence ?? "No structured proof is recorded yet."
    }

    private static func proofIcon(_ context: Context) -> String {
        if let verification = context.verification {
            return verification.systemImage
        }
        return context.mission?.tone == .verified ? "checkmark.seal.fill" : "checklist.checked"
    }

    private static func proofTone(_ context: Context) -> TaskDecisionDockTone {
        if let verification = context.verification {
            return tone(from: verification)
        }
        if let mission = context.mission {
            return tone(from: mission.tone)
        }
        return artifactCount(context) > 0 ? .attention : .neutral
    }

    private static func runSummary(_ context: Context) -> String {
        var parts = [taskStatusSummary(context)]
        if let mission = context.mission {
            let missionStatus = "\(mission.statusTitle): \(mission.statusSummary)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !missionStatus.isEmpty, missionStatus != parts[0] {
                parts.append(missionStatus)
            }
            appendIfPresent(mission.nextAction, to: &parts)
        }
        return parts.joined(separator: ". ")
    }

    private static func artifactCount(_ context: Context) -> Int {
        max(context.mission?.artifactCount ?? 0, context.artifactPaths.count)
    }

    private static func artifactEvidenceSentence(_ context: Context) -> String? {
        let count = artifactCount(context)
        guard count > 0 else { return nil }
        return "ASTRA found \(count) \(count == 1 ? "artifact" : "artifacts")."
    }

    private static func verifiedProofSummary(_ artifactSentence: String?) -> String {
        if let artifactSentence {
            return "Verified. \(artifactSentence)"
        }
        return "Verified."
    }

    private static func verificationMentionsSyntax(_ verification: TaskVerificationPresentation) -> Bool {
        let text = [verification.title, verification.summary, verification.detail]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return text.contains("syntax")
    }

    private static func humanizedValidationSummary(_ summary: String) -> String {
        let lowercased = summary.lowercased()
        if lowercased.contains("passed") {
            return "verified"
        }
        if lowercased.contains("failed") {
            return "verification failed"
        }
        return summary.replacingOccurrences(of: "_", with: " ")
    }

    private static func supportAndCloseOverflowActions(
        _ context: Context,
        closeTitle: String?
    ) -> [TaskDecisionDockAction] {
        closeOverflowActions(context, closeTitle: closeTitle)
    }

    private static func taskStatusSummary(_ context: Context) -> String {
        if context.isClosed {
            return "Closed"
        }
        return firstNonEmpty(
            [context.review.runOutcomeLabel, context.review.reviewLabel]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " - "),
            context.status.rawValue
        )
    }

    private static func taskStatusIcon(for status: TaskStatus, isClosed: Bool) -> String {
        if isClosed { return "checkmark.circle.fill" }
        return switch status {
        case .draft: "square.and.pencil"
        case .queued: "play.circle"
        case .running: "dot.radiowaves.left.and.right"
        case .pendingUser: "person.crop.circle.badge.questionmark"
        case .completed: "checkmark.circle"
        case .failed, .budgetExceeded: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private static func taskStatusTone(_ context: Context) -> TaskDecisionDockTone {
        if context.isClosed { return .closed }
        return switch context.status {
        case .running, .queued: .running
        case .pendingUser, .completed, .cancelled: .attention
        case .failed, .budgetExceeded: .failed
        case .draft: .neutral
        }
    }

    private static func missionControlIcon(for tone: MissionControlTone) -> String {
        return switch tone {
        case .verified: "checkmark.seal.fill"
        case .attention: "exclamationmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .neutral: "scope"
        }
    }

    private static func verificationMetricValue(
        mission: MissionControlPresentation,
        verification: TaskVerificationPresentation?
    ) -> String {
        if let verification, verification.summary == "Not automatically verified" {
            return "Not automated"
        }
        return mission.validationSummary
    }

    private static func closeOverflowActions(
        _ context: Context,
        closeTitle: String?
    ) -> [TaskDecisionDockAction] {
        guard context.canToggleDone else { return [] }
        if context.isClosed {
            return [action(.reopenTask, title: TaskPresentationState.reopenTaskActionTitle, systemImage: "arrow.uturn.backward")]
        }
        let title = closeTitle ?? TaskPresentationState.closeTaskActionTitle
        let kind: TaskDecisionDockActionKind = switch title {
        case TaskPresentationState.closeAnywayActionTitle:
            .closeAnyway
        case TaskPresentationState.closeWithoutRunningPlanActionTitle:
            .closeWithoutRunningPlan
        default:
            .closeTask
        }
        return [action(kind, title: title, systemImage: "checkmark.circle")]
    }

    private static func firstArtifactAction(_ context: Context) -> TaskDecisionDockAction? {
        guard !context.visibleThreadAffordances.contains(.artifactOpen) else { return nil }
        guard let path = context.artifactPaths.first else { return nil }
        return action(
            .openArtifact,
            title: "Open artifact",
            systemImage: "doc.text.magnifyingglass",
            payload: path,
            help: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    private static func action(
        _ kind: TaskDecisionDockActionKind,
        title: String,
        systemImage: String,
        payload: String? = nil,
        help: String? = nil,
        isEnabled: Bool = true
    ) -> TaskDecisionDockAction {
        TaskDecisionDockAction(
            kind: kind,
            title: title,
            systemImage: systemImage,
            payload: payload,
            help: help,
            isEnabled: isEnabled
        )
    }

    private static func tone(from tone: MissionControlTone) -> TaskDecisionDockTone {
        switch tone {
        case .verified: .verified
        case .attention: .attention
        case .failed: .failed
        case .running: .running
        case .neutral: .neutral
        }
    }

    private static func tone(from verification: TaskVerificationPresentation) -> TaskDecisionDockTone {
        switch verification.tone {
        case .verified: .verified
        case .attention: .attention
        case .failed: .failed
        case .neutral: .neutral
        }
    }

    private static func appendIfPresent(_ detail: TaskDecisionDockDetail, to output: inout [TaskDecisionDockDetail]) {
        guard !detail.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        output.append(detail)
    }

    private static func appendIfPresent(_ value: String?, to output: inout [String]) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        output.append(trimmed)
    }

    private static func dedupedDetails(_ values: [TaskDecisionDockDetail]) -> [TaskDecisionDockDetail] {
        var seen = Set<String>()
        var result: [TaskDecisionDockDetail] = []
        for value in values {
            let key = "\(value.id):\(value.summary)"
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

private extension TaskDecisionDockActionKind {
    var isDecisionDockUtility: Bool {
        switch self {
        case .openArtifact, .openPlan, .reportProblem:
            true
        case .stop,
             .stopRun,
             .cancelTurnRequest,
             .allowOnce,
             .allowSimilar,
             .reviewGitPublish,
             .approveResult,
             .dismissReview,
             .approveCorrection,
             .createCorrectionTask,
             .dismissCorrection,
             .runApprovedPlan,
             .runTask,
             .retry,
             .resume,
             .closeTask,
             .closeAnyway,
             .closeWithoutRunningPlan,
             .reopenTask,
             .switchRuntime,
             .repairDockerImage:
            false
        }
    }
}
