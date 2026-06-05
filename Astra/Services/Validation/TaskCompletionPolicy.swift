import Foundation

enum TaskCompletionPolicyGate: String, Sendable, Equatable {
    case validationContract = "validation_contract"
    case deliverableVerification = "deliverable_verification"
    case inferredValidation = "inferred_validation"
    case manualArtifactRequirement = "manual_artifact_requirement"
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
        stopReason: String,
        userVisibleMessage: String,
        auditFields: [String: String] = [:]
    ) -> TaskCompletionPolicyDecision {
        TaskCompletionPolicyDecision(
            gate: gate,
            canComplete: false,
            stopReason: stopReason,
            userVisibleMessage: userVisibleMessage,
            auditFields: auditFields
        )
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
                stopReason: "validation_contract_failed",
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
                stopReason: result.level == .noArtifact ? "no_usable_result" : "deliverable_verification_failed",
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
            decision.stopReason = "inferred_validation_failed"
            decision.userVisibleMessage = "Automatic verification failed: \(evaluation.summary)"
        }
        return decision
    }

    @MainActor
    static func decideManualCompletion(task: AgentTask, run: TaskRun) -> TaskCompletionPolicyDecision {
        let requiresArtifact = TaskDeliverableExpectation.requiresStandaloneArtifact(task)
        let hasArtifact = TaskDeliverableExpectation.hasArtifact(for: task, run: run)
        let fields = [
            "gate": TaskCompletionPolicyGate.manualArtifactRequirement.rawValue,
            "requires_artifact": String(requiresArtifact),
            "has_artifact": String(hasArtifact)
        ]

        guard !requiresArtifact || hasArtifact else {
            return .block(
                gate: .manualArtifactRequirement,
                stopReason: "no_usable_result",
                userVisibleMessage: TaskDeliverableExpectation.missingArtifactMessage(for: task),
                auditFields: fields
            )
        }
        return .allow(gate: .manualArtifactRequirement, auditFields: fields)
    }
}
