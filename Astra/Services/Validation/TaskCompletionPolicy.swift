import Foundation
import ASTRAModels

enum TaskCompletionPolicyGate: String, Sendable, Equatable {
    case validationContract = "validation_contract"
    case deliverableVerification = "deliverable_verification"
    case inferredValidation = "inferred_validation"
    case manualArtifactRequirement = "manual_artifact_requirement"
    case requiredExternalOutcome = "required_external_outcome"
}

struct TaskCompletionPolicyDecision: Sendable, Equatable {
    var gate: TaskCompletionPolicyGate
    var canComplete: Bool
    var stopReason: String?
    var userVisibleMessage: String?
    var auditFields: [String: String]

    var shouldBlockCompletion: Bool {
        !canComplete
    }

    static func allow(
        gate: TaskCompletionPolicyGate,
        auditFields: [String: String] = [:]
    ) -> TaskCompletionPolicyDecision {
        TaskCompletionPolicyDecision(
            gate: gate,
            canComplete: true,
            stopReason: nil,
            userVisibleMessage: nil,
            auditFields: auditFields
        )
    }

    static func block(
        gate: TaskCompletionPolicyGate,
        stopReason: TaskRunStopReason,
        userVisibleMessage: String,
        auditFields: [String: String] = [:]
    ) -> TaskCompletionPolicyDecision {
        TaskCompletionPolicyDecision(
            gate: gate,
            canComplete: false,
            stopReason: stopReason.rawValue,
            userVisibleMessage: userVisibleMessage,
            auditFields: auditFields
        )
    }

    var typedStopReason: TaskRunStopReason? {
        get { stopReason.flatMap(TaskRunStopReason.init(rawValue:)) }
        set { stopReason = newValue?.rawValue }
    }
}

struct TaskCompletionBlockedEventPayload: Codable, Sendable, Equatable {
    let gate: String
    let stopReason: String
    let message: String
    let auditFields: [String: String]

    init(decision: TaskCompletionPolicyDecision) {
        gate = decision.gate.rawValue
        stopReason = decision.stopReason ?? ""
        message = decision.userVisibleMessage ?? "Task completion blocked by \(decision.gate.rawValue)."
        auditFields = decision.auditFields
    }
}

enum TaskCompletionPolicy {
    static func decide(validationContract evaluation: TaskValidationContractEvaluation) -> TaskCompletionPolicyDecision {
        var fields = [
            "gate": TaskCompletionPolicyGate.validationContract.rawValue,
            "did_run": String(evaluation.didRun),
            "outcome": evaluation.outcome.rawValue,
            "failed_required_assertion_count": String(evaluation.failedRequiredAssertionIDs.count)
        ]
        fields["failed_required_assertions"] = evaluation.failedRequiredAssertionIDs.joined(separator: ",")

        guard evaluation.outcome.canComplete, evaluation.canComplete else {
            return .block(
                gate: .validationContract,
                stopReason: .validationContractFailed,
                userVisibleMessage: evaluation.summary,
                auditFields: fields
            )
        }
        return .allow(gate: .validationContract, auditFields: fields)
    }

    static func decide(deliverableVerification result: TaskDeliverableVerificationResult) -> TaskCompletionPolicyDecision {
        let fields = [
            "gate": TaskCompletionPolicyGate.deliverableVerification.rawValue,
            "profile": result.profile.rawValue,
            "level": result.level.rawValue,
            "status": result.status,
            "can_complete": String(result.canComplete),
            "requires_human_review": String(result.requiresHumanReview),
            "check_count": String(result.checks.count),
            "evidence_count": String(result.evidencePaths.count)
        ]

        guard result.canComplete else {
            return .block(
                gate: .deliverableVerification,
                stopReason: result.level == .noArtifact ? .noUsableResult : .deliverableVerificationFailed,
                userVisibleMessage: result.userVisibleFailureMessage,
                auditFields: fields
            )
        }
        return .allow(gate: .deliverableVerification, auditFields: fields)
    }

    static func decide(inferredValidation evaluation: TaskValidationContractEvaluation) -> TaskCompletionPolicyDecision {
        var decision = decide(validationContract: evaluation)
        decision.gate = .inferredValidation
        decision.auditFields["gate"] = TaskCompletionPolicyGate.inferredValidation.rawValue
        if decision.shouldBlockCompletion {
            decision.typedStopReason = .inferredValidationFailed
            decision.userVisibleMessage = "Automatic verification failed: \(evaluation.summary)"
        }
        return decision
    }

    @MainActor
    static func decideSuccessfulCompletion(
        task: AgentTask,
        run: TaskRun,
        permissionPolicy: PermissionPolicy = .autonomous
    ) -> TaskCompletionPolicyDecision {
        let pendingPublication = TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
            task: task,
            run: run
        ) ?? (permissionPolicy == .autonomous
            ? nil
            : TaskExternalOutcomeRequirementResolver.makeGitHubPullRequest(task: task, run: run))
        if let pendingPublication {
            return .block(
                gate: .requiredExternalOutcome,
                stopReason: .externalOutcomePending,
                userVisibleMessage: "The local work finished. Review the exact ASTRA draft pull request proposal to finish the task.",
                auditFields: [
                    "outcome_kind": pendingPublication.kind.rawValue,
                    "run_id": pendingPublication.runID.uuidString,
                    "source_event_id": pendingPublication.sourceEventID?.uuidString ?? "none",
                    "publication_owner": "astra"
                ]
            )
        }

        let requiresArtifact = TaskDeliverableExpectation.requiresDeliverableArtifact(task)
        let hasArtifact = TaskDeliverableExpectation.hasArtifact(for: task, run: run)
        let fields = [
            "gate": TaskCompletionPolicyGate.manualArtifactRequirement.rawValue,
            "requires_artifact": String(requiresArtifact),
            "has_artifact": String(hasArtifact)
        ]

        guard !requiresArtifact || hasArtifact else {
            return .block(
                gate: .manualArtifactRequirement,
                stopReason: .noUsableResult,
                userVisibleMessage: TaskDeliverableExpectation.missingDeliverableMessage(for: task),
                auditFields: fields
            )
        }
        return .allow(gate: .manualArtifactRequirement, auditFields: fields)
    }
}
