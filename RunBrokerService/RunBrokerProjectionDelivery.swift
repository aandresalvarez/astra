import ASTRACore
import ASTRARunLedger
import Foundation
import RunBrokerClient
import RunBrokerPolicy

/// Broker-owned typed pull/ack outbox. Opaque ledger payload bytes never cross
/// the client boundary: each message is projected into a strict authority-free
/// DTO and still carries the exact durable sequence/message identity.
public final class RunBrokerProjectionOutbox: @unchecked Sendable {
    private let ledger: RunLedger
    private let afterSnapshotAcknowledgementRead: (@Sendable () -> Void)?
    private let lock = NSRecursiveLock()

    public init(ledger: RunLedger) {
        self.ledger = ledger
        afterSnapshotAcknowledgementRead = nil
    }

    init(
        ledger: RunLedger,
        afterSnapshotAcknowledgementRead: @escaping @Sendable () -> Void
    ) {
        self.ledger = ledger
        self.afterSnapshotAcknowledgementRead = afterSnapshotAcknowledgementRead
    }

    public func next() throws -> RunBrokerApplicationProjectionMessage? {
        try lock.withLock {
            let acknowledged = try ledger.outboxAcknowledgedThrough()
            guard let message = try ledger.outbox(after: acknowledged, limit: 1).first else {
                return nil
            }
            return try projectionMessage(message)
        }
    }

    public func handshake(
        _ cursor: RunBrokerApplicationProjectionCursor
    ) throws -> RunBrokerApplicationProjectionHandshake {
        try lock.withLock {
            let snapshot = try ledger.outboxDeliverySnapshot(
                afterAcknowledgementRead: afterSnapshotAcknowledgementRead
            )
            let acknowledged = snapshot.acknowledgedThrough
            let isOneAhead = acknowledged < Int64.max
                && cursor.acknowledgedThrough == acknowledged + 1
            guard cursor.acknowledgedThrough == acknowledged || isOneAhead else {
                throw RunBrokerApplicationEndpointError.projectionAcknowledgementConflict
            }
            if cursor.acknowledgedThrough > 0 {
                let expectedMessageID = isOneAhead
                    ? snapshot.next?.messageID
                    : snapshot.acknowledgedMessageID
                guard expectedMessageID?.rawValue == cursor.acknowledgedMessageID else {
                    throw RunBrokerApplicationEndpointError.projectionAcknowledgementConflict
                }
            }
            if isOneAhead {
                guard snapshot.next?.sequence == cursor.acknowledgedThrough else {
                    throw RunBrokerApplicationEndpointError.projectionAcknowledgementConflict
                }
            }
            return .init(
                brokerAcknowledgedThrough: acknowledged,
                durableHeadSequence: snapshot.durableHead?.sequence ?? 0,
                durableHeadMessageID: snapshot.durableHead?.messageID.rawValue,
                next: try snapshot.next.map(projectionMessage)
            )
        }
    }

    @discardableResult
    public func acknowledge(
        _ acknowledgement: RunBrokerApplicationProjectionAcknowledgement
    ) throws -> RunLedgerCursorDisposition {
        try lock.withLock {
            try ledger.acknowledgeOutbox(
                sequence: acknowledgement.sequence,
                messageID: .init(rawValue: acknowledgement.messageID)
            )
        }
    }

    private func typedEvent(
        _ stored: RunLedgerOutboxProjectionV1
    ) throws -> RunBrokerApplicationProjectionEvent {
        switch stored {
        case .execution(let value):
            return .execution(.init(
                executionID: value.executionID,
                authority: value.authority,
                state: Self.executionState(value.state),
                lastSupervisorSequence: value.lastSupervisorSequence,
                manifestSHA256: value.manifestSHA256,
                configurationRevision: value.configurationRevision,
                terminalEvidence: value.terminalEvidence.map(Self.terminalEvidence)
            ))
        case .supervisor(let value):
            return .supervisor(.init(
                observation: Self.deliveredObservation(value),
                stream: value.stream.map(Self.stream),
                normalizedEvent: nil,
                terminal: value.terminal.map(Self.terminalEvidence)
            ))
        case .operation(let record):
            return .operation(record)
        case .monitor(let value):
            return .monitor(.init(
                operationID: value.operationID,
                authority: value.authority,
                deadline: value.deadline.map(Self.deadline),
                stopped: value.stopped
            ))
        case .runtimeSwitch(let value):
            return .runtimeSwitch(.init(
                requestID: value.requestID,
                requestDigest: value.requestDigest,
                source: value.source,
                targetExecutionID: value.targetExecutionID,
                targetManifestSHA256: value.targetManifestSHA256,
                progress: Self.runtimeSwitchProgress(value.progress),
                challenge: value.challenge,
                recordedControlEffectID: value.recordedControlEffectID,
                recordedReplacementEffectID: value.recordedReplacementEffectID
            ))
        case .runtimeSwitchReservation(let value):
            return .runtimeSwitchReservation(.init(
                requestID: value.requestID,
                requestDigest: value.requestDigest,
                reservationID: value.reservationID,
                targetExecutionID: value.targetExecutionID,
                targetManifestSHA256: value.targetManifestSHA256,
                ledgerSequence: value.ledgerSequence
            ))
        case .executionControl(let value):
            return .executionControl(.init(
                fence: .init(
                    executionID: value.executionID,
                    authority: value.authority,
                    expectedSupervisorSequence: value.expectedSupervisorSequence
                ),
                acceptedSupervisorSequence: value.acceptedSupervisorSequence,
                cancellationIntent: value.cancellationIntent,
                challenge: value.challenge,
                acceptedEffectID: value.acceptedEffectID
            ))
        }
    }

    /// Stored stream projections keep the chunk exactly once. Reconstruct the
    /// public observation at the delivery boundary so the wire contract stays
    /// unchanged without duplicating bytes in durable projection payloads.
    private static func deliveredObservation(
        _ value: RunLedgerOutboxSupervisorV1
    ) -> RunBrokerSupervisorObservation {
        let observation = value.observation
        return .init(
            executionID: observation.executionID,
            authority: observation.authority,
            supervisorSequence: observation.supervisorSequence,
            supervisorEventID: observation.supervisorEventID,
            occurredAt: observation.occurredAt,
            kind: observation.kind,
            output: value.stream?.bytes,
            exitCode: observation.exitCode,
            terminationSignal: observation.terminationSignal,
            terminationReason: observation.terminationReason,
            cancellationIntent: observation.cancellationIntent,
            quarantinedByteCount: observation.quarantinedByteCount
        )
    }

    private func projectionMessage(
        _ message: RunLedgerOutboxMessage
    ) throws -> RunBrokerApplicationProjectionMessage {
        try .init(
            sequence: message.sequence,
            messageID: message.messageID.rawValue,
            eventKind: message.eventKind,
            event: typedEvent(message.projection),
            occurredAt: message.occurredAt
        )
    }

    func executionStatus(
        _ executionID: RunBrokerExecutionID,
        projection: RunLedgerProjection,
        through maximumLedgerSequence: Int64? = nil
    ) throws -> RunBrokerApplicationExecutionStatus {
        guard let execution = projection.executions[executionID] else {
            throw RunLedgerError.projectionDrift("Typed execution projection is missing")
        }
        let observations = try observations(
            for: executionID,
            through: maximumLedgerSequence
        )
        return .init(
            executionID: executionID,
            authority: execution.authority,
            state: Self.state(execution.control.observedExecution),
            lastSupervisorSequence: observations.last?.supervisorSequence ?? 0,
            manifestSHA256: try RuntimeSwitchDigests.manifest(execution.manifest),
            configurationRevision: execution.manifest.configuration.configurationRevision,
            terminalEvidence: Self.terminalEvidence(
                observations: observations,
                observed: execution.control.observedExecution
            )
        )
    }

    private func observations(
        for executionID: RunBrokerExecutionID,
        through maximumSequence: Int64?
    ) throws -> [RunBrokerSupervisorObservation] {
        var result: [RunBrokerSupervisorObservation] = []
        var cursor: Int64 = 0
        while true {
            let page = try ledger.events(after: cursor, limit: 1_000)
            guard !page.isEmpty else { return result.sorted { $0.supervisorSequence < $1.supervisorSequence } }
            for stored in page {
                if let maximumSequence, stored.sequence > maximumSequence {
                    return result.sorted { $0.supervisorSequence < $1.supervisorSequence }
                }
                cursor = stored.sequence
                guard case .supervisorObservationRecorded(let value) = stored.envelope.event,
                      value.executionID == executionID else { continue }
                result.append(value)
            }
        }
    }

    private static func terminalEvidence(
        observations: [RunBrokerSupervisorObservation],
        observed: ExecutionObservedState
    ) -> RunBrokerApplicationTerminalEvidence? {
        guard observed.isAuthoritativelyTerminal else { return nil }
        // An immediate cancellation emits cancellationConfirmed and then a
        // signaled providerExited; when the durable state is .cancelled the
        // confirmation is the authoritative outcome, or a successful user
        // cancellation would be reported as a signal failure.
        let candidate: RunBrokerSupervisorObservation?
        if observed == .cancelled,
           let confirmed = observations.last(where: { $0.kind == .cancellationConfirmed }) {
            candidate = confirmed
        } else {
            candidate = observations.last(where: {
                $0.kind == .providerExited || $0.kind == .providerLaunchFailed
                    || $0.kind == .cancellationConfirmed
            })
        }
        guard let evidence = candidate else { return nil }
        let outcome: RunBrokerApplicationTerminalOutcome
        switch evidence.kind {
        case .providerLaunchFailed: outcome = .launchFailed
        case .cancellationConfirmed: outcome = .cancelled
        default:
            switch evidence.terminationReason {
            case .signaled: outcome = .signaled
            case .waitFailed: outcome = .waitFailed
            case .exited: outcome = evidence.exitCode == 0 ? .completed : .failed
            case nil: return nil
            }
        }
        return .init(
            outcome: outcome,
            exitCode: evidence.exitCode,
            cancellationIntent: outcome == .cancelled ? evidence.cancellationIntent : nil,
            terminationSignal: evidence.terminationSignal,
            terminationReason: evidence.terminationReason,
            supervisorSequence: evidence.supervisorSequence,
            supervisorEventID: evidence.supervisorEventID,
            occurredAt: evidence.occurredAt
        )
    }

    private static func terminalEvidence(
        _ value: RunLedgerOutboxTerminalEvidenceV1
    ) -> RunBrokerApplicationTerminalEvidence {
        let outcome: RunBrokerApplicationTerminalOutcome
        switch value.outcome {
        case .completed: outcome = .completed
        case .failed: outcome = .failed
        case .cancelled: outcome = .cancelled
        case .launchFailed: outcome = .launchFailed
        case .signaled: outcome = .signaled
        case .waitFailed: outcome = .waitFailed
        }
        return .init(
            outcome: outcome,
            exitCode: value.exitCode,
            cancellationIntent: value.cancellationIntent,
            terminationSignal: value.terminationSignal,
            terminationReason: value.terminationReason,
            supervisorSequence: value.supervisorSequence,
            supervisorEventID: value.supervisorEventID,
            occurredAt: value.occurredAt
        )
    }

    private static func stream(
        _ value: RunLedgerOutboxStreamV1
    ) -> RunBrokerApplicationStreamRecord {
        .init(
            channel: value.channel == .standardOutput ? .standardOutput : .standardError,
            bytes: value.bytes,
            startsLogicalLine: value.startsLogicalLine,
            endsLogicalLine: value.endsLogicalLine,
            trailingFragmentByteCount: value.trailingFragmentByteCount,
            fragmentTruncated: value.fragmentTruncated
        )
    }

    private static func executionState(
        _ value: RunLedgerOutboxExecutionStateV1
    ) -> RunBrokerApplicationExecutionState {
        switch value {
        case .admitted: .admitted
        case .running: .running
        case .terminal: .terminal
        case .inDoubt: .inDoubt
        }
    }

    private static func runtimeSwitchProgress(
        _ value: RunLedgerOutboxRuntimeSwitchProgressV1
    ) -> RunBrokerApplicationRuntimeSwitchProgress {
        switch value {
        case .waitingForCheckpoint: .waitingForCheckpoint
        case .confirmationRequired: .confirmationRequired
        case .controlDispatchPending: .controlDispatchPending
        case .awaitingSourceTerminal: .awaitingSourceTerminal
        case .replacementDispatchPending: .replacementDispatchPending
        case .awaitingReplacementRunning: .awaitingReplacementRunning
        case .completed: .completed
        case .archived: .archived
        case .inDoubt: .inDoubt
        }
    }

    private static func state(_ state: ExecutionObservedState) -> RunBrokerApplicationExecutionState {
        switch state {
        case .registered, .starting: .admitted
        case .running: .running
        case .completed, .failed, .cancelled: .terminal
        case .inDoubt: .inDoubt
        }
    }

    private static func deadline(_ value: RunLedgerMonitorDeadline) -> RunBrokerMonitorDeadline {
        .init(
            operationID: value.operationID,
            authority: value.authority,
            dueAt: value.dueAt,
            recordedAt: value.recordedAt,
            attempt: value.attempt,
            generation: value.generation
        )
    }
}

enum RunBrokerRuntimeSwitchProjection {
    static func archivedStatus(
        _ record: RuntimeSwitchRecord
    ) -> RunBrokerApplicationRuntimeSwitchStatus {
        .init(
            requestID: record.request.intent.requestID,
            requestDigest: record.requestDigest,
            source: record.request.intent.expectedSource,
            targetExecutionID: record.request.intent.target.manifest.executionID,
            targetManifestSHA256: record.request.intent.target.manifestSHA256,
            progress: .archived,
            // The historical force challenge is consumed state; the status
            // invariant permits a challenge only for confirmationRequired,
            // so surfacing it here would make every archived immediate-switch
            // status fail client-side validation.
            challenge: nil,
            recordedControlEffectID: record.controlEffect?.effectID,
            recordedReplacementEffectID: record.replacementEffect?.effectID
        )
    }

    static func status(
        _ state: RuntimeSwitchPolicyState
    ) throws -> RunBrokerApplicationRuntimeSwitchStatus {
        if let record = state.record {
            return .init(
                requestID: record.request.intent.requestID,
                requestDigest: record.requestDigest,
                source: record.request.intent.expectedSource,
                targetExecutionID: record.request.intent.target.manifest.executionID,
                targetManifestSHA256: record.request.intent.target.manifestSHA256,
                progress: progress(record.progress),
                challenge: record.forceChallenge,
                recordedControlEffectID: record.controlEffect?.effectID,
                recordedReplacementEffectID: record.replacementEffect?.effectID
            )
        }
        guard let archived = state.lastArchivedCompletion else {
            throw RunLedgerError.projectionDrift("Runtime-switch transition has no durable status")
        }
        return .init(
            requestID: archived.requestID,
            requestDigest: archived.requestDigest,
            source: archived.request.intent.expectedSource,
            targetExecutionID: archived.targetExecutionID,
            targetManifestSHA256: archived.targetManifestSHA256,
            progress: .archived,
            challenge: nil,
            recordedControlEffectID: nil,
            recordedReplacementEffectID: nil
        )
    }

    private static func progress(
        _ value: RuntimeSwitchProgress
    ) -> RunBrokerApplicationRuntimeSwitchProgress {
        switch value {
        case .waitingForCheckpoint: .waitingForCheckpoint
        case .confirmationRequired: .confirmationRequired
        case .controlDispatchPending: .controlDispatchPending
        case .awaitingSourceTerminal: .awaitingSourceTerminal
        case .replacementDispatchPending: .replacementDispatchPending
        case .awaitingReplacementRunning: .awaitingReplacementRunning
        case .completed: .completed
        case .inDoubt: .inDoubt
        }
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
