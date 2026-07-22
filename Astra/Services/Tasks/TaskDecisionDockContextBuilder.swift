import Foundation
import ASTRACore
import ASTRAModels

struct TaskRuntimePermissionState {
    struct Event: Hashable, Sendable {
        let type: String
        let payload: String
        let timestamp: Date
    }

    let latestRequestPayload: String?
    let hasOpenApprovalRequest: Bool
    let decision: RuntimePermissionDecisionPresentation?
    let taskScopedGrants: [PermissionGrant]

    var canApproveSimilarForTask: Bool {
        hasOpenApprovalRequest && !taskScopedGrants.isEmpty
    }

    static let empty = TaskRuntimePermissionState(
        latestRequestPayload: nil,
        hasOpenApprovalRequest: false,
        decision: nil,
        taskScopedGrants: []
    )

    static func build(task: AgentTask) -> TaskRuntimePermissionState {
        TaskRuntimePermissionOpenRequestStore.state(for: task)
    }

    static func build(events: [Event]) -> TaskRuntimePermissionState {
        let latestRequest = events
            .filter { $0.type == "permission.approval.requested" }
            .max { $0.timestamp < $1.timestamp }
        guard let latestRequest else { return .empty }

        // Correlate live asks by requestID so an out-of-order resolution of one
        // ask never hides another still-pending one (legacy pause-and-relaunch
        // requests fall back to the task.approved timestamp).
        let hasOpenRequest = RuntimePermissionOpenState.hasOpenRequest(
            events: events.map {
                RuntimePermissionOpenState.Event(type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
            }
        )
        let structured = PermissionBroker.structuredApprovalGrants(from: latestRequest.payload)
        let grants = structured.isEmpty ? PermissionBroker.legacyApprovalGrants(from: latestRequest.payload) : structured

        return TaskRuntimePermissionState(
            latestRequestPayload: latestRequest.payload,
            hasOpenApprovalRequest: hasOpenRequest,
            decision: RuntimePermissionDecisionPresentation(payload: latestRequest.payload),
            taskScopedGrants: PermissionBroker.taskScopedApprovalGrants(for: grants)
        )
    }
}

enum TaskDecisionDockContextBuilder {
    struct Input {
        var status: TaskStatus
        var isClosed: Bool
        var review: TaskReviewPresentation
        var mission: MissionControlPresentation?
        var verification: TaskVerificationPresentation?
        var pendingReviewState: PendingTaskReviewState
        var runtimePermission: TaskRuntimePermissionState
        var hasGitPublishRequest: Bool = false
        var executableApprovedPlan: TaskPlanPayload?
        var skipPermissions: Bool
        // Capability-tiered checkpoint mode for the approved plan; nil falls
        // back to the legacy skipPermissions-only derivation.
        var planExecutionMode: TaskPlanExecutionMode? = nil
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
        var extraDetails: [TaskDecisionDockDetail]
    }

    struct ExtraDetailsInput {
        var status: TaskStatus
        var runtimeHealth: TaskRuntimeHealth
        var shouldShowPendingApprovalStatus: Bool
        var hasRuntimePermissionRequest: Bool
        var pendingApprovalStatusDetail: String
        var isCreatingScheduleForCurrentTask: Bool
        var isGeneratingRecap: Bool
        var recapStatusMessage: String?
        var currentScheduleStatusMessage: String?
        var isScheduleStatusError: Bool
    }

    static func build(_ input: Input) -> TaskDecisionDockPresentation? {
        TaskDecisionDockPresentation.build(context(input))
    }

    static func context(_ input: Input) -> TaskDecisionDockPresentation.Context {
        let plan = input.executableApprovedPlan
        let nextStep = plan.flatMap { TaskPlanService.nextExecutableStep(in: $0) }
        let planMode = input.planExecutionMode ?? (input.skipPermissions ? .fullPlan : .nextStep)
        let planActionTitle = plan == nil
            ? nil
            : PlanCheckpointPolicy.approveActionTitle(mode: planMode, skipPermissions: input.skipPermissions)
        let planActionDetail = plan.map { nextStep.map { "Next: \($0.title)" } ?? $0.title }
        let planModeLabel = plan == nil
            ? nil
            : PlanCheckpointPolicy.modeLabel(mode: planMode, skipPermissions: input.skipPermissions)

        return TaskDecisionDockPresentation.Context(
            status: input.status,
            isClosed: input.isClosed,
            review: input.review,
            mission: input.mission,
            verification: input.verification,
            pendingReviewState: input.pendingReviewState,
            hasRuntimePermissionRequest: input.runtimePermission.hasOpenApprovalRequest,
            runtimePermissionTitle: input.runtimePermission.decision?.title,
            runtimePermissionSummary: input.runtimePermission.decision?.summary,
            runtimePermissionScope: input.runtimePermission.decision?.scope,
            runtimePermissionCommandPreview: input.runtimePermission.decision?.commandPreview,
            runtimePermissionAllowSimilarLabel: input.runtimePermission.decision?.allowSimilarLabel,
            canApproveSimilarRuntimePermission: input.runtimePermission.canApproveSimilarForTask,
            hasGitPublishRequest: input.hasGitPublishRequest,
            hasExecutableApprovedPlan: plan != nil,
            planActionTitle: planActionTitle,
            planActionDetail: planActionDetail,
            planModeLabel: planModeLabel,
            canOpenPlan: input.canOpenPlan,
            isPlanCanvasVisible: input.isPlanCanvasVisible,
            canRunApprovedPlan: input.canRunApprovedPlan,
            latestRunHasNoUsableResult: input.latestRunHasNoUsableResult,
            completedTaskNeedsArtifactAttention: input.completedTaskNeedsArtifactAttention,
            canCancel: input.canCancel,
            canRun: input.canRun,
            canApprove: input.canApprove,
            canRetry: input.canRetry,
            canResume: input.canResume,
            canReportProblem: input.canReportProblem,
            canToggleDone: input.canToggleDone,
            hasProviderSession: input.hasProviderSession,
            failureReason: input.failureReason,
            launchBlock: input.launchBlock,
            dockerRecoveryImage: input.dockerRecoveryImage,
            isDockerRecoveryBusy: input.isDockerRecoveryBusy,
            artifactPaths: input.artifactPaths,
            extraDetails: input.extraDetails,
            visibleThreadAffordances: visibleThreadAffordances(
                artifactPaths: input.artifactPaths,
                mission: input.mission,
                isPlanCanvasVisible: input.isPlanCanvasVisible
            )
        )
    }

    static func artifactPaths(generatedFilePaths: [String], storedArtifactPaths: [String]) -> [String] {
        dedupePaths(generatedFilePaths + storedArtifactPaths)
    }

    static func visibleThreadAffordances(
        artifactPaths: [String],
        mission: MissionControlPresentation?,
        isPlanCanvasVisible: Bool
    ) -> Set<TaskThreadAffordance> {
        var affordances: Set<TaskThreadAffordance> = [.runDetails]
        if !artifactPaths.isEmpty {
            affordances.insert(.artifactOpen)
        }
        if mission != nil {
            affordances.insert(.missionControlDetails)
        }
        if isPlanCanvasVisible {
            affordances.insert(.planDetails)
        }
        return affordances
    }

    static func extraDetails(_ input: ExtraDetailsInput) -> [TaskDecisionDockDetail] {
        var details: [TaskDecisionDockDetail] = []
        if input.status == .running {
            details.append(TaskDecisionDockDetail(
                id: "runtime-health",
                title: input.runtimeHealth.message,
                summary: input.runtimeHealth.detail ?? input.runtimeHealth.message,
                systemImage: input.runtimeHealth.isAttentionState ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath",
                tone: input.runtimeHealth.isAttentionState ? .attention : .running
            ))
        }

        if input.shouldShowPendingApprovalStatus && !input.hasRuntimePermissionRequest {
            details.append(TaskDecisionDockDetail(
                id: "pending-approval",
                title: "Waiting for your approval",
                summary: input.pendingApprovalStatusDetail,
                systemImage: "person.crop.circle.badge.questionmark",
                tone: .attention
            ))
        }

        if input.isCreatingScheduleForCurrentTask {
            details.append(TaskDecisionDockDetail(
                id: "routine-creating",
                title: "Creating routine",
                summary: "ASTRA is creating the routine for this task.",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .running
            ))
        }

        if input.isGeneratingRecap {
            details.append(TaskDecisionDockDetail(
                id: "recap-generating",
                title: "Generating recap",
                summary: "ASTRA is summarizing the task conversation.",
                systemImage: "doc.text.magnifyingglass",
                tone: .running
            ))
        }

        if let msg = input.recapStatusMessage {
            details.append(TaskDecisionDockDetail(
                id: "recap-message",
                title: "Recap needs attention",
                summary: msg,
                systemImage: "exclamationmark.triangle",
                tone: .attention
            ))
        }

        if let statusMsg = input.currentScheduleStatusMessage {
            details.append(TaskDecisionDockDetail(
                id: "routine-status",
                title: input.isScheduleStatusError ? "Routine needs attention" : "Routine created",
                summary: statusMsg,
                systemImage: input.isScheduleStatusError ? "exclamationmark.triangle" : "checkmark.circle",
                tone: input.isScheduleStatusError ? .attention : .verified
            ))
        }

        return details
    }

    private static func dedupePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }
}
