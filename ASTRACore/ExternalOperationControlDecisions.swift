public enum ExternalOperationControlDecisionKind: String, Codable, Equatable, Sendable {
    case allowed
    case monitoringOnly = "monitoring_only"
    case blocked
}

public enum ExternalOperationControlDecisionReason: String, Codable, Equatable, Sendable {
    case observationCapabilityVerified = "observation_capability_verified"
    case verifiedGracefulCancellation = "verified_graceful_cancellation"
    case verifiedImmediateTermination = "verified_immediate_termination"
    case sshRequiresReviewedRemoteHelper = "ssh_requires_reviewed_remote_helper"
    case managedDockerPendingAuthenticatedControl = "managed_docker_pending_authenticated_receipt_immutable_identity_terminal_confirmation"
    case importedOperationIsMonitoringOnly = "imported_operation_is_monitoring_only"
    case opaqueOperationIsMonitoringOnly = "opaque_operation_is_monitoring_only"
    case staleExecution = "stale_execution"
    case staleAuthority = "stale_authority"
    case staleBackendIdentity = "stale_backend_identity"
    case staleSupervisorIdentity = "stale_supervisor_identity"
    case unsupportedCapabilityDeclaration = "unsupported_capability_declaration"
    case observationCapabilityMissing = "observation_capability_missing"
    case cancellationIntentMissing = "cancellation_intent_missing"
    case gracefulCancellationCapabilityMissing = "graceful_cancellation_capability_missing"
    case immediateTerminationCapabilityMissing = "immediate_termination_capability_missing"
    case unverifiedProvenance = "unverified_provenance"
    case cancellationCapabilityOverclaim = "cancellation_capability_overclaim"
    case unsupportedBackend = "unsupported_backend"
}

public enum ExternalOperationControlAuditRequirement: String, Codable, Equatable, Sendable {
    case none
    case immediateTermination = "immediate_termination"
}

public struct ExternalOperationControlDecision: Codable, Equatable, Sendable {
    public let kind: ExternalOperationControlDecisionKind
    public let reason: ExternalOperationControlDecisionReason
    public let auditRequirement: ExternalOperationControlAuditRequirement

    public init(
        kind: ExternalOperationControlDecisionKind,
        reason: ExternalOperationControlDecisionReason,
        auditRequirement: ExternalOperationControlAuditRequirement = .none
    ) {
        self.kind = kind
        self.reason = reason
        self.auditRequirement = auditRequirement
    }
}

/// Observation and cancellation are evaluated separately. The requested
/// cancellation intent remains explicit in the result so callers cannot turn a
/// blocked graceful request into an immediate termination.
public struct ExternalOperationControlAssessment: Codable, Equatable, Sendable {
    public let cancellationIntent: ExecutionCancellationIntent
    public let observation: ExternalOperationControlDecision
    public let cancellation: ExternalOperationControlDecision

    public init(
        cancellationIntent: ExecutionCancellationIntent,
        observation: ExternalOperationControlDecision,
        cancellation: ExternalOperationControlDecision
    ) {
        self.cancellationIntent = cancellationIntent
        self.observation = observation
        self.cancellation = cancellation
    }
}
