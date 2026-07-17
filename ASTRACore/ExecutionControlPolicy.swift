import Foundation

public enum ExecutionDesiredState: String, Codable, Hashable, Sendable {
    case running
    case cancelled
}

public enum ExecutionObservedState: String, Codable, Hashable, Sendable {
    case registered
    case starting
    case running
    case completed
    case failed
    case cancelled
    case inDoubt = "in_doubt"

    public var isAuthoritativelyTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .registered, .starting, .running, .inDoubt:
            false
        }
    }
}

public enum ExecutionCancellationIntent: String, Codable, Hashable, Sendable {
    case none
    case graceful
    case immediate
}

public enum ExecutionCancellationObservedState: String, Codable, Hashable, Sendable {
    case notRequested = "not_requested"
    case requestPending = "request_pending"
    case accepted
    case terminating
    case cancelled
    case completedBeforeCancel = "completed_before_cancel"
    case rejected
    case unsupported
    case inDoubt = "in_doubt"
}

/// Desired state records user/control-plane intent. Observed state records only
/// backend evidence; requesting cancellation never manufactures termination.
public struct ExecutionControlState: Codable, Equatable, Hashable, Sendable {
    public let desiredExecution: ExecutionDesiredState
    public let observedExecution: ExecutionObservedState
    public let desiredCancellation: ExecutionCancellationIntent
    public let observedCancellation: ExecutionCancellationObservedState

    public init(
        desiredExecution: ExecutionDesiredState = .running,
        observedExecution: ExecutionObservedState = .registered,
        desiredCancellation: ExecutionCancellationIntent = .none,
        observedCancellation: ExecutionCancellationObservedState = .notRequested
    ) {
        self.desiredExecution = desiredExecution
        self.observedExecution = observedExecution
        self.desiredCancellation = desiredCancellation
        self.observedCancellation = observedCancellation
    }
}

public enum ExecutionControlEvent: Equatable, Sendable {
    case executionStarted
    case executionCompleted
    case executionFailed
    case requestCancellation(ExecutionCancellationIntent)
    case backendAcceptedCancellation
    case terminationStarted
    case cancellationConfirmed
    case backendRejectedCancellation
    case observationBecameIndeterminate
}

public enum ExecutionControlDisposition: String, Codable, Equatable, Sendable {
    case applied
    case idempotent
    case weakerCancellationIgnored = "weaker_cancellation_ignored"
    case invalidTransition = "invalid_transition"
}

public struct ExecutionControlReduction: Equatable, Sendable {
    public let state: ExecutionControlState
    public let disposition: ExecutionControlDisposition

    public init(state: ExecutionControlState, disposition: ExecutionControlDisposition) {
        self.state = state
        self.disposition = disposition
    }
}

/// Deterministic reducer for execution and cancellation observations.
public enum ExecutionControlReducer {
    public static func reduce(
        _ state: ExecutionControlState,
        event: ExecutionControlEvent,
        backendCapabilities: ExternalOperationBackendCapabilities
    ) -> ExecutionControlReduction {
        switch event {
        case .executionStarted:
            guard !state.observedExecution.isAuthoritativelyTerminal else {
                return invalid(state)
            }
            guard state.observedExecution != .running else { return idempotent(state) }
            return applied(state, observedExecution: .running)

        case .executionCompleted:
            return finish(state, as: .completed)

        case .executionFailed:
            return finish(state, as: .failed)

        case .requestCancellation(let intent):
            return requestCancellation(
                state,
                intent: intent,
                backendCapabilities: backendCapabilities
            )

        case .backendAcceptedCancellation:
            guard state.desiredCancellation != .none else { return invalid(state) }
            if state.observedCancellation == .accepted { return idempotent(state) }
            guard state.observedCancellation == .requestPending else { return invalid(state) }
            return applied(state, observedCancellation: .accepted)

        case .terminationStarted:
            guard state.desiredCancellation != .none else { return invalid(state) }
            if state.observedCancellation == .terminating { return idempotent(state) }
            guard state.observedCancellation == .requestPending
                    || state.observedCancellation == .accepted else {
                return invalid(state)
            }
            return applied(state, observedCancellation: .terminating)

        case .cancellationConfirmed:
            if state.observedExecution == .cancelled,
               state.observedCancellation == .cancelled {
                return idempotent(state)
            }
            guard state.desiredCancellation != .none,
                  !state.observedExecution.isAuthoritativelyTerminal else {
                return invalid(state)
            }
            return applied(
                state,
                observedExecution: .cancelled,
                observedCancellation: .cancelled
            )

        case .backendRejectedCancellation:
            guard state.desiredCancellation != .none else { return invalid(state) }
            if state.observedCancellation == .rejected { return idempotent(state) }
            guard state.observedCancellation == .requestPending
                    || state.observedCancellation == .accepted else {
                return invalid(state)
            }
            return applied(state, observedCancellation: .rejected)

        case .observationBecameIndeterminate:
            guard !state.observedExecution.isAuthoritativelyTerminal else { return invalid(state) }
            let cancellation: ExecutionCancellationObservedState = state.desiredCancellation == .none
                ? state.observedCancellation
                : .inDoubt
            if state.observedExecution == .inDoubt,
               state.observedCancellation == cancellation {
                return idempotent(state)
            }
            return applied(
                state,
                observedExecution: .inDoubt,
                observedCancellation: cancellation
            )
        }
    }

    private static func requestCancellation(
        _ state: ExecutionControlState,
        intent: ExecutionCancellationIntent,
        backendCapabilities: ExternalOperationBackendCapabilities
    ) -> ExecutionControlReduction {
        guard intent != .none else { return invalid(state) }

        if cancellationStrength(intent) < cancellationStrength(state.desiredCancellation) {
            return .init(state: state, disposition: .weakerCancellationIgnored)
        }

        if state.observedExecution.isAuthoritativelyTerminal {
            let observedCancellation: ExecutionCancellationObservedState = state.observedExecution == .cancelled
                ? .cancelled
                : .completedBeforeCancel
            if state.desiredCancellation == intent,
               state.observedCancellation == observedCancellation {
                return idempotent(state)
            }
            return applied(
                state,
                desiredExecution: .cancelled,
                desiredCancellation: intent,
                observedCancellation: observedCancellation
            )
        }

        let isEscalation = cancellationStrength(intent) > cancellationStrength(state.desiredCancellation)
        let observedCancellation: ExecutionCancellationObservedState
        if isEscalation {
            // A graceful -> immediate escalation is a distinct backend
            // command. Evidence for the weaker request cannot acknowledge it.
            observedCancellation = backendCapabilities.canCancel ? .requestPending : .unsupported
        } else {
            observedCancellation = observedCancellationAfterSameIntentRetry(
                state,
                backendCapabilities: backendCapabilities
            )
        }
        if state.desiredCancellation == intent,
           state.observedCancellation == observedCancellation {
            return idempotent(state)
        }
        return applied(
            state,
            desiredExecution: .cancelled,
            desiredCancellation: intent,
            observedCancellation: observedCancellation
        )
    }

    private static func cancellationStrength(_ intent: ExecutionCancellationIntent) -> Int {
        switch intent {
        case .none: 0
        case .graceful: 1
        case .immediate: 2
        }
    }

    private static func observedCancellationAfterSameIntentRetry(
        _ state: ExecutionControlState,
        backendCapabilities: ExternalOperationBackendCapabilities
    ) -> ExecutionCancellationObservedState {
        guard backendCapabilities.canCancel else { return .unsupported }

        // Acceptance and termination are authoritative for an in-flight
        // request, so an exact replay remains idempotent. Rejected,
        // unsupported, and indeterminate attempts are retryable: a new durable
        // command returns to pending so the backend actually receives it.
        switch state.observedCancellation {
        case .accepted, .terminating, .cancelled, .completedBeforeCancel:
            return state.observedCancellation
        case .notRequested, .requestPending, .rejected, .unsupported, .inDoubt:
            return .requestPending
        }
    }

    private static func finish(
        _ state: ExecutionControlState,
        as observedExecution: ExecutionObservedState
    ) -> ExecutionControlReduction {
        if state.observedExecution == observedExecution {
            return idempotent(state)
        }
        guard !state.observedExecution.isAuthoritativelyTerminal else { return invalid(state) }
        let cancellation: ExecutionCancellationObservedState = state.desiredCancellation == .none
            ? state.observedCancellation
            : .completedBeforeCancel
        return applied(
            state,
            observedExecution: observedExecution,
            observedCancellation: cancellation
        )
    }

    private static func applied(
        _ state: ExecutionControlState,
        desiredExecution: ExecutionDesiredState? = nil,
        observedExecution: ExecutionObservedState? = nil,
        desiredCancellation: ExecutionCancellationIntent? = nil,
        observedCancellation: ExecutionCancellationObservedState? = nil
    ) -> ExecutionControlReduction {
        .init(
            state: .init(
                desiredExecution: desiredExecution ?? state.desiredExecution,
                observedExecution: observedExecution ?? state.observedExecution,
                desiredCancellation: desiredCancellation ?? state.desiredCancellation,
                observedCancellation: observedCancellation ?? state.observedCancellation
            ),
            disposition: .applied
        )
    }

    private static func idempotent(_ state: ExecutionControlState) -> ExecutionControlReduction {
        .init(state: state, disposition: .idempotent)
    }

    private static func invalid(_ state: ExecutionControlState) -> ExecutionControlReduction {
        .init(state: state, disposition: .invalidTransition)
    }
}
