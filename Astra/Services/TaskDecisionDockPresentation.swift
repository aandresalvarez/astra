import Foundation

enum TaskDecisionDockTone: String, Equatable {
    case neutral
    case running
    case attention
    case failed
    case verified
    case closed
}

enum TaskDecisionDockActionKind: String, Equatable {
    case stop
    case allowOnce
    case allowSimilar
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
    case openArtifact
    case closeTask
    case closeAnyway
    case closeWithoutRunningPlan
    case reopenTask
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
        var canToggleDone: Bool
        var hasProviderSession: Bool
        var failureReason: String?
        var artifactPaths: [String]
        var extraDetails: [TaskDecisionDockDetail] = []
    }

    var id: String
    var icon: String
    var tone: TaskDecisionDockTone
    var title: String
    var summary: String
    var metrics: [TaskDecisionDockMetric]
    var details: [TaskDecisionDockDetail]
    var primaryAction: TaskDecisionDockAction?
    var secondaryActions: [TaskDecisionDockAction]
    var overflowActions: [TaskDecisionDockAction]
    var prefersExpandedDetails: Bool

    var hasDetails: Bool { !details.isEmpty }
    var hasActions: Bool { primaryAction != nil || !secondaryActions.isEmpty || !overflowActions.isEmpty }

    static func build(_ context: Context) -> TaskDecisionDockPresentation? {
        if context.isClosed {
            return closedPresentation(context)
        }

        if context.hasRuntimePermissionRequest {
            return runtimePermissionPresentation(context)
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
        TaskDecisionDockPresentation(
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

    private static func correctionPresentation(
        _ context: Context,
        correction: MissionControlCorrection
    ) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "correction-\(correction.correctiveStepID)",
            icon: "wrench.and.screwdriver.fill",
            tone: .failed,
            title: "Correction needed",
            summary: "Assertion \(correction.failedAssertionID): \(correction.suggestedRepair)",
            metrics: metrics(context),
            details: details(context),
            primaryAction: action(
                .approveCorrection,
                title: correction.status == "approved" ? "Approved" : "Approve",
                systemImage: "checkmark",
                payload: correction.correctiveStepID,
                isEnabled: correction.status != "approved"
            ),
            secondaryActions: [
                action(.createCorrectionTask, title: "Create task", systemImage: "plus.square", payload: correction.correctiveStepID),
                action(.dismissCorrection, title: "Dismiss", systemImage: "xmark", payload: correction.correctiveStepID)
            ],
            overflowActions: closeOverflowActions(context, closeTitle: nil),
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
        let title = isMissingArtifact ? "No usable result" : (isBlocked ? "Policy blocked" : "Needs your review")
        let summary: String
        if isBlocked {
            summary = "The run stopped before completion. Retry with broader policy permissions; dismissing will not mark it completed."
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
                context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: isMissingArtifact ? TaskPresentationState.closeAnywayActionTitle : nil),
            prefersExpandedDetails: isBlocked || isMissingArtifact
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
            primaryAction: context.canResume && context.hasProviderSession
                ? action(.resume, title: "Resume", systemImage: "play.fill")
                : (context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil),
            secondaryActions: [
                context.canResume && context.hasProviderSession && context.canRetry
                    ? action(.retry, title: "Retry", systemImage: "arrow.clockwise")
                    : nil,
                firstArtifactAction(context)
            ].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: true
        )
    }

    private static func noUsableResultPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "completed-no-usable-result",
            icon: "doc.badge.exclamationmark",
            tone: .attention,
            title: "No usable result",
            summary: "This finished run did not create the expected artifact. Retry or close it anyway.",
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
            secondaryActions: [firstArtifactAction(context)].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: TaskPresentationState.closeAnywayActionTitle),
            prefersExpandedDetails: true
        )
    }

    private static func completedPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        let artifactCount = context.mission?.artifactCount ?? context.artifactPaths.count
        let verification = context.verification
        let summary: String
        if artifactCount > 0, verification?.tone == .attention {
            summary = "ASTRA found \(artifactCount) \(artifactCount == 1 ? "artifact" : "artifacts"). No automated verification was run."
        } else if let verification {
            summary = verification.detail ?? verification.summary
        } else if artifactCount > 0 {
            summary = "ASTRA found \(artifactCount) \(artifactCount == 1 ? "artifact" : "artifacts"). Review the result before closing."
        } else {
            summary = context.review.decisionDetail
        }

        return TaskDecisionDockPresentation(
            id: "completed",
            icon: "checkmark.circle.fill",
            tone: verification?.tone == .verified ? .verified : .attention,
            title: "Result ready for review",
            summary: summary,
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canToggleDone ? action(.closeTask, title: TaskPresentationState.closeTaskActionTitle, systemImage: "checkmark.circle") : nil,
            secondaryActions: [firstArtifactAction(context)].compactMap { $0 },
            overflowActions: [],
            prefersExpandedDetails: verification?.tone == .failed || verification?.tone == .attention
        )
    }

    private static func cancelledPresentation(_ context: Context) -> TaskDecisionDockPresentation {
        TaskDecisionDockPresentation(
            id: "cancelled",
            icon: "xmark.circle.fill",
            tone: .attention,
            title: "Run cancelled",
            summary: "Review the partial result, then retry or close the task.",
            metrics: metrics(context),
            details: details(context),
            primaryAction: context.canRetry ? action(.retry, title: "Retry", systemImage: "arrow.clockwise") : nil,
            secondaryActions: [firstArtifactAction(context)].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: true
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
            secondaryActions: [firstArtifactAction(context)].compactMap { $0 },
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
            secondaryActions: [firstArtifactAction(context)].compactMap { $0 },
            overflowActions: closeOverflowActions(context, closeTitle: nil),
            prefersExpandedDetails: false
        )
    }

    private static func metrics(_ context: Context) -> [TaskDecisionDockMetric] {
        var output: [TaskDecisionDockMetric] = []
        if let mission = context.mission {
            output.append(TaskDecisionDockMetric(
                id: "validation",
                title: "Verification",
                value: verificationMetricValue(mission: mission, verification: context.verification),
                tone: context.verification.map(tone(from:)) ?? tone(from: mission.tone)
            ))
            output.append(TaskDecisionDockMetric(
                id: "files",
                title: "Files",
                value: "\(mission.changedFileCount) changed",
                tone: mission.changedFileCount > 0 ? .neutral : .neutral
            ))
            output.append(TaskDecisionDockMetric(
                id: "artifacts",
                title: "Artifacts",
                value: "\(mission.artifactCount)",
                tone: mission.artifactCount > 0 ? .verified : .neutral
            ))
            output.append(TaskDecisionDockMetric(
                id: "budget",
                title: "Budget",
                value: mission.budgetSummary,
                tone: .neutral
            ))
            return output
        }

        if let verification = context.verification {
            output.append(TaskDecisionDockMetric(
                id: "verification",
                title: "Verification",
                value: verification.summary,
                tone: tone(from: verification)
            ))
        }
        if !context.artifactPaths.isEmpty {
            output.append(TaskDecisionDockMetric(
                id: "artifacts",
                title: "Artifacts",
                value: "\(context.artifactPaths.count)",
                tone: .verified
            ))
        }
        return output
    }

    private static func details(
        _ context: Context,
        additional: [TaskDecisionDockDetail] = []
    ) -> [TaskDecisionDockDetail] {
        var output = context.extraDetails

        if let mission = context.mission {
            appendIfPresent(TaskDecisionDockDetail(
                id: "mission-control",
                title: "Mission Control",
                summary: "\(mission.statusTitle): \(mission.statusSummary)",
                systemImage: missionControlIcon(for: mission.tone),
                tone: tone(from: mission.tone)
            ), to: &output)

            appendIfPresent(TaskDecisionDockDetail(
                id: "mission-objective",
                title: "Objective",
                summary: mission.objective,
                systemImage: "scope",
                tone: .neutral
            ), to: &output)

            if let activeStep = mission.activeStepTitle {
                appendIfPresent(TaskDecisionDockDetail(
                    id: "mission-active-step",
                    title: "Active step",
                    summary: activeStep,
                    systemImage: "list.bullet.rectangle",
                    tone: .neutral
                ), to: &output)
            }

            appendIfPresent(TaskDecisionDockDetail(
                id: "mission-validation",
                title: "Validation",
                summary: mission.validationSummary,
                systemImage: "checklist.checked",
                tone: tone(from: mission.tone)
            ), to: &output)
        }

        appendIfPresent(TaskDecisionDockDetail(
            id: "task-status",
            title: "Task status",
            summary: taskStatusSummary(context),
            systemImage: taskStatusIcon(for: context.status, isClosed: context.isClosed),
            tone: taskStatusTone(context)
        ), to: &output)

        if let handoff = context.mission?.latestHandoffSummary {
            appendIfPresent(TaskDecisionDockDetail(
                id: "handoff",
                title: "Latest handoff",
                summary: handoff,
                systemImage: "arrowshape.turn.up.right",
                tone: .neutral
            ), to: &output)
        }

        if let nextAction = context.mission?.nextAction {
            appendIfPresent(TaskDecisionDockDetail(
                id: "next-action",
                title: "Next action",
                summary: nextAction,
                systemImage: "arrow.right.circle",
                tone: .neutral
            ), to: &output)
        }

        if let verification = context.verification {
            appendIfPresent(TaskDecisionDockDetail(
                id: "verification",
                title: verification.title,
                summary: verification.detail ?? verification.summary,
                systemImage: verification.systemImage,
                tone: tone(from: verification)
            ), to: &output)
        }

        for detail in additional {
            appendIfPresent(detail, to: &output)
        }

        return dedupedDetails(output)
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
