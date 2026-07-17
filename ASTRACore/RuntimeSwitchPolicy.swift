import Foundation

public enum RuntimeSwitchBlockedReason: String, Codable, Equatable, Sendable {
    case executionNotActive = "execution_not_active"
    case executionIdentityMismatch = "execution_identity_mismatch"
    case staleAuthority = "stale_authority"
    case staleConfigurationRevision = "stale_configuration_revision"
    case activeConfigurationMismatch = "active_configuration_mismatch"
    case targetMatchesActiveConfiguration = "target_matches_active_configuration"
    case inFlightEffects = "in_flight_effects"
    case inFlightToolOperations = "in_flight_tool_operations"
    case safeCheckpointUnavailable = "safe_checkpoint_unavailable"
    case providerContinuationNotDeclared = "provider_continuation_not_declared"
    case providerContinuationUnsupported = "provider_continuation_unsupported"
    case supervisorContinuationNotDeclared = "supervisor_continuation_not_declared"
    case supervisorContinuationUnsupported = "supervisor_continuation_unsupported"
    case forceConfirmationRequired = "force_confirmation_required"
    case forceConfirmationRequestMismatch = "force_confirmation_request_mismatch"
    case forceConfirmationExecutionMismatch = "force_confirmation_execution_mismatch"
    case forceConfirmationTargetMismatch = "force_confirmation_target_mismatch"
    case forceConfirmationPredatesRequest = "force_confirmation_predates_request"
    case requestIDConflict = "request_id_conflict"
    case switchAlreadyPending = "switch_already_pending"
}

/// The only business-layer commands the later RunBroker adapter may execute.
/// Neither case permits choosing a substitute runtime or controlling by PID.
public enum RuntimeSwitchDirective: Equatable, Sendable {
    case gracefulHandoff(
        request: GracefulRuntimeHandoffRequest,
        checkpointID: RuntimeSwitchCheckpointID
    )
    case forceTermination(request: ForceRuntimeSwitchRequest)
}

/// Durable accepted intent. A graceful acceptance pins the exact checkpoint;
/// force acceptance instead pins the separately confirmed force request.
public struct AcceptedRuntimeSwitch: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let request: ActiveRuntimeSwitchRequest
    public let acceptedCheckpointID: RuntimeSwitchCheckpointID?

    fileprivate init(
        request: ActiveRuntimeSwitchRequest,
        acceptedCheckpointID: RuntimeSwitchCheckpointID?
    ) {
        self.request = request
        self.acceptedCheckpointID = acceptedCheckpointID
    }

    public var directive: RuntimeSwitchDirective {
        switch request {
        case .gracefulHandoff(let request):
            // Accepted state decoding and the policy both enforce this pairing.
            return .gracefulHandoff(request: request, checkpointID: acceptedCheckpointID!)
        case .forceTermination(let request):
            return .forceTermination(request: request)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case request
        case acceptedCheckpointID
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "accepted runtime switch"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "accepted runtime switch"
        )
        let request = try container.decode(ActiveRuntimeSwitchRequest.self, forKey: .request)
        let checkpointID = try container.decodeIfPresent(
            RuntimeSwitchCheckpointID.self,
            forKey: .acceptedCheckpointID
        )
        switch request {
        case .gracefulHandoff:
            guard checkpointID != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .acceptedCheckpointID,
                    in: container,
                    debugDescription: "Accepted graceful handoff requires a checkpoint"
                )
            }
        case .forceTermination(let force):
            guard checkpointID == nil, force.confirmationBlockReason == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .acceptedCheckpointID,
                    in: container,
                    debugDescription: "Accepted force switch requires an exact valid confirmation and no checkpoint"
                )
            }
        }
        self.init(request: request, acceptedCheckpointID: checkpointID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(acceptedCheckpointID, forKey: .acceptedCheckpointID)
    }
}

public struct RuntimeSwitchPolicyState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = RuntimeSwitchPolicyState(accepted: nil)

    public let accepted: AcceptedRuntimeSwitch?

    public init(accepted: AcceptedRuntimeSwitch?) {
        self.accepted = accepted
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case accepted
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch policy state"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch policy state"
        )
        self.init(accepted: try container.decodeIfPresent(AcceptedRuntimeSwitch.self, forKey: .accepted))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(accepted, forKey: .accepted)
    }
}

public enum RuntimeSwitchPolicyDisposition: String, Codable, Equatable, Sendable {
    case applied
    case idempotent
    case blocked
}

public struct RuntimeSwitchPolicyReduction: Equatable, Sendable {
    public let state: RuntimeSwitchPolicyState
    public let disposition: RuntimeSwitchPolicyDisposition
    public let directive: RuntimeSwitchDirective?
    public let blockedReason: RuntimeSwitchBlockedReason?

    private init(
        state: RuntimeSwitchPolicyState,
        disposition: RuntimeSwitchPolicyDisposition,
        directive: RuntimeSwitchDirective?,
        blockedReason: RuntimeSwitchBlockedReason?
    ) {
        self.state = state
        self.disposition = disposition
        self.directive = directive
        self.blockedReason = blockedReason
    }

    static func applied(accepted: AcceptedRuntimeSwitch) -> Self {
        .init(
            state: .init(accepted: accepted),
            disposition: .applied,
            directive: accepted.directive,
            blockedReason: nil
        )
    }

    static func idempotent(state: RuntimeSwitchPolicyState, accepted: AcceptedRuntimeSwitch) -> Self {
        .init(
            state: state,
            disposition: .idempotent,
            directive: accepted.directive,
            blockedReason: nil
        )
    }

    static func blocked(
        state: RuntimeSwitchPolicyState,
        reason: RuntimeSwitchBlockedReason
    ) -> Self {
        .init(
            state: state,
            disposition: .blocked,
            directive: nil,
            blockedReason: reason
        )
    }
}

/// Pure compare-and-swap policy for explicit active-run switching.
///
/// Evaluation order is deterministic: idempotency, pending ownership,
/// execution identity, authority, configuration revision, lifecycle, then
/// action-specific safety. A blocked request never manufactures cancellation
/// and never falls back to another provider or local process.
public enum RuntimeSwitchPolicy {
    public static func reduce(
        _ state: RuntimeSwitchPolicyState,
        request: ActiveRuntimeSwitchRequest,
        context: ActiveRuntimeSwitchContext
    ) -> RuntimeSwitchPolicyReduction {
        if let accepted = state.accepted {
            if accepted.request.intent.requestID == request.intent.requestID {
                guard accepted.request == request else {
                    return .blocked(state: state, reason: .requestIDConflict)
                }
                return .idempotent(state: state, accepted: accepted)
            }
            return .blocked(state: state, reason: .switchAlreadyPending)
        }

        let expected = request.intent.expectedActive
        let current = context.identity
        guard expected.executionID == current.executionID else {
            return .blocked(state: state, reason: .executionIdentityMismatch)
        }
        guard expected.authority == current.authority else {
            return .blocked(state: state, reason: .staleAuthority)
        }
        guard expected.configuration.revision == current.configuration.revision else {
            return .blocked(state: state, reason: .staleConfigurationRevision)
        }
        guard expected.configuration == current.configuration else {
            return .blocked(state: state, reason: .activeConfigurationMismatch)
        }
        guard context.lifecycle == .active else {
            return .blocked(state: state, reason: .executionNotActive)
        }
        guard request.intent.target != current.configuration else {
            return .blocked(state: state, reason: .targetMatchesActiveConfiguration)
        }

        switch request {
        case .gracefulHandoff:
            return reduceGraceful(state, request: request, context: context)
        case .forceTermination(let force):
            return reduceForce(state, request: request, force: force)
        }
    }

    private static func reduceGraceful(
        _ state: RuntimeSwitchPolicyState,
        request: ActiveRuntimeSwitchRequest,
        context: ActiveRuntimeSwitchContext
    ) -> RuntimeSwitchPolicyReduction {
        let checkpoint = context.checkpoint
        guard checkpoint.inFlightEffectCount == 0 else {
            return .blocked(state: state, reason: .inFlightEffects)
        }
        guard checkpoint.inFlightToolOperationCount == 0 else {
            return .blocked(state: state, reason: .inFlightToolOperations)
        }
        guard let checkpointID = checkpoint.checkpointID else {
            return .blocked(state: state, reason: .safeCheckpointUnavailable)
        }
        switch checkpoint.providerContinuation {
        case .notDeclared:
            return .blocked(state: state, reason: .providerContinuationNotDeclared)
        case .unsupported:
            return .blocked(state: state, reason: .providerContinuationUnsupported)
        case .supported:
            break
        }
        switch checkpoint.supervisorContinuation {
        case .notDeclared:
            return .blocked(state: state, reason: .supervisorContinuationNotDeclared)
        case .unsupported:
            return .blocked(state: state, reason: .supervisorContinuationUnsupported)
        case .supported:
            break
        }

        return .applied(accepted: .init(
            request: request,
            acceptedCheckpointID: checkpointID
        ))
    }

    private static func reduceForce(
        _ state: RuntimeSwitchPolicyState,
        request: ActiveRuntimeSwitchRequest,
        force: ForceRuntimeSwitchRequest
    ) -> RuntimeSwitchPolicyReduction {
        if let blockedReason = force.confirmationBlockReason {
            return .blocked(state: state, reason: blockedReason)
        }

        return .applied(accepted: .init(
            request: request,
            acceptedCheckpointID: nil
        ))
    }
}

private extension ForceRuntimeSwitchRequest {
    var confirmationBlockReason: RuntimeSwitchBlockedReason? {
        guard let confirmation else { return .forceConfirmationRequired }
        guard confirmation.affirmedRequestID == intent.requestID else {
            return .forceConfirmationRequestMismatch
        }
        guard confirmation.affirmedExecutionID == intent.expectedActive.executionID else {
            return .forceConfirmationExecutionMismatch
        }
        guard confirmation.affirmedTarget == intent.target else {
            return .forceConfirmationTargetMismatch
        }
        guard confirmation.confirmedAt >= intent.requestedAt else {
            return .forceConfirmationPredatesRequest
        }
        return nil
    }
}
