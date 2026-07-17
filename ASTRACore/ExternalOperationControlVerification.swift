/// Authentication implementation owned by the broker boundary. Conformances
/// are package-scoped so external clients cannot supply a self-approving
/// verifier. The implementation must authenticate the supervisor capability,
/// exact identity, and declared operation capabilities.
package protocol ExternalOperationControlProvenanceAuthenticating: Sendable {
    func authenticate(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding
    ) throws
}

public enum ExternalOperationControlVerificationError: Error, Equatable, Sendable {
    case descriptorMismatch
    case unsupportedBackend
}

/// In-memory proof that a package-trusted verifier authenticated this exact
/// target and descriptor. It is intentionally not Codable and has no public or
/// package initializer.
public struct ExternalOperationVerifiedEvidence: Sendable {
    let target: ExternalOperationControlTarget
    let binding: ExternalOperationControlBinding

    fileprivate init(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding
    ) {
        self.target = target
        self.binding = binding
    }
}

/// Sole constructor boundary for verified evidence.
package enum ExternalOperationControlProvenanceVerifier {
    package static func verify(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        authenticator: some ExternalOperationControlProvenanceAuthenticating
    ) throws -> ExternalOperationVerifiedEvidence {
        guard target.executionID == binding.executionID,
              target.authority == binding.authority,
              target.backendIdentity == binding.backendIdentity else {
            throw ExternalOperationControlVerificationError.descriptorMismatch
        }
        guard binding.backendIdentity.kind == .localRunSupervisor,
              let supervisorIdentity = binding.backendIdentity.supervisorIdentity,
              supervisorIdentity.executionID == binding.executionID,
              supervisorIdentity.authority == binding.authority else {
            throw ExternalOperationControlVerificationError.unsupportedBackend
        }

        try authenticator.authenticate(target: target, binding: binding)
        return ExternalOperationVerifiedEvidence(target: target, binding: binding)
    }
}
