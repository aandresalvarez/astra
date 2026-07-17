/// Initial-release backend policy. Destructive control is granted only to a
/// typed local supervisor identity with verifier-produced provenance.
public enum ExternalOperationControlPolicy {
    public static func assess(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        cancellationIntent: ExecutionCancellationIntent,
        verifiedEvidence: ExternalOperationVerifiedEvidence? = nil
    ) -> ExternalOperationControlAssessment {
        if target.executionID != binding.executionID {
            return blockedAssessment(intent: cancellationIntent, reason: .staleExecution)
        }
        if target.authority != binding.authority {
            return blockedAssessment(intent: cancellationIntent, reason: .staleAuthority)
        }
        if target.backendIdentity != binding.backendIdentity {
            return blockedAssessment(intent: cancellationIntent, reason: .staleBackendIdentity)
        }
        guard binding.declaredCapabilities.rawValue & ~supportedCapabilitiesRawValue == 0 else {
            return blockedAssessment(
                intent: cancellationIntent,
                reason: .unsupportedCapabilityDeclaration
            )
        }

        let observation = observationDecision(capabilities: binding.declaredCapabilities)
        let cancellation = cancellationDecision(
            target: target,
            binding: binding,
            intent: cancellationIntent,
            verifiedEvidence: verifiedEvidence
        )
        return .init(
            cancellationIntent: cancellationIntent,
            observation: observation,
            cancellation: cancellation
        )
    }

    private static var supportedCapabilitiesRawValue: UInt8 {
        ExternalOperationControlCapabilities.observe.rawValue
            | ExternalOperationControlCapabilities.gracefulCancellation.rawValue
            | ExternalOperationControlCapabilities.immediateTermination.rawValue
    }

    private static func observationDecision(
        capabilities: ExternalOperationControlCapabilities
    ) -> ExternalOperationControlDecision {
        if capabilities.canObserve {
            return .init(kind: .allowed, reason: .observationCapabilityVerified)
        }
        return .init(kind: .blocked, reason: .observationCapabilityMissing)
    }

    private static func cancellationDecision(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        intent: ExecutionCancellationIntent,
        verifiedEvidence: ExternalOperationVerifiedEvidence?
    ) -> ExternalOperationControlDecision {
        guard intent != .none else {
            return .init(kind: .blocked, reason: .cancellationIntentMissing)
        }

        switch binding.backendIdentity.kind {
        case .localRunSupervisor:
            return supervisorCancellationDecision(
                target: target,
                binding: binding,
                intent: intent,
                verifiedEvidence: verifiedEvidence
            )

        case .managedDockerJob:
            return monitoringOnlyDecision(
                binding: binding,
                reason: .managedDockerPendingAuthenticatedControl
            )

        case .sshRemoteOperation:
            return monitoringOnlyDecision(
                binding: binding,
                reason: .sshRequiresReviewedRemoteHelper
            )

        case .importedOperation:
            return monitoringOnlyDecision(
                binding: binding,
                reason: .importedOperationIsMonitoringOnly
            )

        case .opaqueOperation:
            return monitoringOnlyDecision(
                binding: binding,
                reason: .opaqueOperationIsMonitoringOnly
            )

        default:
            return .init(kind: .blocked, reason: .unsupportedBackend)
        }
    }

    private static func supervisorCancellationDecision(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        intent: ExecutionCancellationIntent,
        verifiedEvidence: ExternalOperationVerifiedEvidence?
    ) -> ExternalOperationControlDecision {
        guard let supervisorIdentity = binding.backendIdentity.supervisorIdentity,
              supervisorIdentity.executionID == binding.executionID,
              supervisorIdentity.authority == binding.authority else {
            return .init(kind: .blocked, reason: .staleSupervisorIdentity)
        }
        guard let verifiedEvidence,
              verifiedEvidence.target == target,
              verifiedEvidence.binding == binding else {
            return .init(kind: .blocked, reason: .unverifiedProvenance)
        }

        switch intent {
        case .none:
            return .init(kind: .blocked, reason: .cancellationIntentMissing)
        case .graceful:
            guard binding.declaredCapabilities.canGracefullyCancel else {
                return .init(kind: .blocked, reason: .gracefulCancellationCapabilityMissing)
            }
            return .init(kind: .allowed, reason: .verifiedGracefulCancellation)
        case .immediate:
            guard binding.declaredCapabilities.canImmediatelyTerminate else {
                return .init(kind: .blocked, reason: .immediateTerminationCapabilityMissing)
            }
            return .init(
                kind: .allowed,
                reason: .verifiedImmediateTermination,
                auditRequirement: .immediateTermination
            )
        }
    }

    private static func monitoringOnlyDecision(
        binding: ExternalOperationControlBinding,
        reason: ExternalOperationControlDecisionReason
    ) -> ExternalOperationControlDecision {
        guard !binding.declaredCapabilities.declaresDestructiveControl else {
            return .init(kind: .blocked, reason: .cancellationCapabilityOverclaim)
        }
        return .init(kind: .monitoringOnly, reason: reason)
    }

    private static func blockedAssessment(
        intent: ExecutionCancellationIntent,
        reason: ExternalOperationControlDecisionReason
    ) -> ExternalOperationControlAssessment {
        let decision = ExternalOperationControlDecision(kind: .blocked, reason: reason)
        return .init(
            cancellationIntent: intent,
            observation: decision,
            cancellation: decision
        )
    }
}
