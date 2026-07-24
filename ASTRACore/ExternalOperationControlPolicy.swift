/// Initial-release policy for untrusted descriptors. This module can classify
/// monitoring-only backends but cannot mint verified observation or control;
/// those decisions require a broker-owned provenance boundary.
public enum ExternalOperationControlPolicy {
    public static func assess(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        cancellationIntent: ExecutionCancellationIntent
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
            binding: binding,
            intent: cancellationIntent
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
            // A wire/durable declaration is not provenance. The broker-owned
            // verifier may promote this decision after authenticating its own
            // local capability or a future durable backend receipt.
            return .init(kind: .blocked, reason: .unverifiedProvenance)
        }
        return .init(kind: .blocked, reason: .observationCapabilityMissing)
    }

    private static func cancellationDecision(
        binding: ExternalOperationControlBinding,
        intent: ExecutionCancellationIntent
    ) -> ExternalOperationControlDecision {
        guard intent != .none else {
            return .init(kind: .blocked, reason: .cancellationIntentMissing)
        }

        switch binding.backendIdentity.kind {
        case .localRunSupervisor:
            return supervisorCancellationDecision(binding: binding)

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
        binding: ExternalOperationControlBinding
    ) -> ExternalOperationControlDecision {
        guard let supervisorIdentity = binding.backendIdentity.supervisorIdentity,
              supervisorIdentity.executionID == binding.executionID,
              supervisorIdentity.authority == binding.authority else {
            return .init(kind: .blocked, reason: .staleSupervisorIdentity)
        }
        return .init(kind: .blocked, reason: .unverifiedProvenance)
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
