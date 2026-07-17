/// Initial-release backend policy. Destructive control is granted only to a
/// known ASTRA-owned backend with an authenticated execution-scoped handle.
public enum ExternalOperationControlPolicy {
    public static func assess(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding
    ) -> ExternalOperationControlAssessment {
        if target.executionID != binding.executionID {
            return blockedAssessment(reason: .staleExecution)
        }
        if target.authority != binding.authority {
            return blockedAssessment(reason: .staleAuthority)
        }
        if target.backendIdentity != binding.backendIdentity {
            return blockedAssessment(reason: .staleBackendIdentity)
        }
        guard binding.declaredCapabilities.rawValue & ~supportedCapabilitiesRawValue == 0 else {
            return blockedAssessment(reason: .unsupportedCapabilityDeclaration)
        }

        return .init(
            observation: observationDecision(capabilities: binding.declaredCapabilities),
            cancellation: cancellationDecision(binding: binding)
        )
    }

    private static var supportedCapabilitiesRawValue: UInt8 {
        ExternalOperationBackendCapabilities.observe.rawValue
            | ExternalOperationBackendCapabilities.cancel.rawValue
    }

    private static func observationDecision(
        capabilities: ExternalOperationBackendCapabilities
    ) -> ExternalOperationControlDecision {
        if capabilities.canObserve {
            return .init(kind: .allowed, reason: .observationCapabilityVerified)
        }
        return .init(kind: .blocked, reason: .observationCapabilityMissing)
    }

    private static func cancellationDecision(
        binding: ExternalOperationControlBinding
    ) -> ExternalOperationControlDecision {
        switch binding.backendIdentity.kind {
        case .localRunSupervisor, .managedDockerJob:
            guard binding.ownership == .authenticatedExecutionScoped else {
                return .init(kind: .blocked, reason: .authenticatedOwnershipMissing)
            }
            guard binding.declaredCapabilities.canCancel else {
                return .init(kind: .blocked, reason: .cancellationCapabilityMissing)
            }
            return .init(kind: .allowed, reason: .authenticatedCancellationHandleVerified)

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

    private static func monitoringOnlyDecision(
        binding: ExternalOperationControlBinding,
        reason: ExternalOperationControlDecisionReason
    ) -> ExternalOperationControlDecision {
        guard !binding.declaredCapabilities.canCancel else {
            return .init(kind: .blocked, reason: .cancellationCapabilityOverclaim)
        }
        return .init(kind: .monitoringOnly, reason: reason)
    }

    private static func blockedAssessment(
        reason: ExternalOperationControlDecisionReason
    ) -> ExternalOperationControlAssessment {
        let decision = ExternalOperationControlDecision(kind: .blocked, reason: reason)
        return .init(observation: decision, cancellation: decision)
    }
}
