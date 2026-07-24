import ASTRACore

/// Broker-module-only authentication seam. Because this protocol and the
/// verifier are internal to RunBrokerService, ASTRA and other package targets
/// cannot mint verified control truth even though they share a Swift package.
protocol RunBrokerExternalOperationProvenanceAuthenticating: Sendable {
    func authenticate(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding
    ) throws
}

enum RunBrokerExternalOperationVerificationError: Error, Equatable, Sendable {
    case descriptorMismatch
    case unsupportedBackend
}

enum RunBrokerVerifiedExternalOperationControl {
    static func assess(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        cancellationIntent: ExecutionCancellationIntent,
        authenticator: some RunBrokerExternalOperationProvenanceAuthenticating
    ) throws -> ExternalOperationControlAssessment {
        guard target.executionID == binding.executionID,
              target.authority == binding.authority,
              target.backendIdentity == binding.backendIdentity else {
            throw RunBrokerExternalOperationVerificationError.descriptorMismatch
        }
        guard binding.backendIdentity.kind == .localRunSupervisor,
              let supervisorIdentity = binding.backendIdentity.supervisorIdentity,
              supervisorIdentity.executionID == binding.executionID,
              supervisorIdentity.authority == binding.authority else {
            throw RunBrokerExternalOperationVerificationError.unsupportedBackend
        }
        let supported = ExternalOperationControlCapabilities.observe.rawValue
            | ExternalOperationControlCapabilities.gracefulCancellation.rawValue
            | ExternalOperationControlCapabilities.immediateTermination.rawValue
        guard binding.declaredCapabilities.rawValue & ~supported == 0 else {
            return blocked(
                intent: cancellationIntent,
                reason: .unsupportedCapabilityDeclaration
            )
        }

        try authenticator.authenticate(target: target, binding: binding)

        let observation: ExternalOperationControlDecision = binding.declaredCapabilities.canObserve
            ? .init(kind: .allowed, reason: .observationCapabilityVerified)
            : .init(kind: .blocked, reason: .observationCapabilityMissing)
        let cancellation: ExternalOperationControlDecision
        switch cancellationIntent {
        case .none:
            cancellation = .init(kind: .blocked, reason: .cancellationIntentMissing)
        case .graceful:
            cancellation = binding.declaredCapabilities.canGracefullyCancel
                ? .init(kind: .allowed, reason: .verifiedGracefulCancellation)
                : .init(kind: .blocked, reason: .gracefulCancellationCapabilityMissing)
        case .immediate:
            cancellation = binding.declaredCapabilities.canImmediatelyTerminate
                ? .init(
                    kind: .allowed,
                    reason: .verifiedImmediateTermination,
                    auditRequirement: .immediateTermination
                )
                : .init(kind: .blocked, reason: .immediateTerminationCapabilityMissing)
        }
        return .init(
            cancellationIntent: cancellationIntent,
            observation: observation,
            cancellation: cancellation
        )
    }

    private static func blocked(
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
