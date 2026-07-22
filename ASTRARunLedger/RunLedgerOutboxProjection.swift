import ASTRACore
import CryptoKit
import Foundation
import RunBrokerPolicy

/// Versioned semantic truth captured when a journal event commits. Delivery
/// decodes these bytes directly; it never re-runs a newer reducer over an old
/// event after an application update.
package struct RunLedgerPersistedOutboxProjection: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let projection: RunLedgerOutboxProjectionV1

    package init(projection: RunLedgerOutboxProjectionV1) {
        schemaVersion = Self.currentSchemaVersion
        self.projection = projection
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projection
    }

    package init(from decoder: Decoder) throws {
        try RunLedgerStrictCoding.requireExactKeys(
            decoder,
            expected: [CodingKeys.schemaVersion.rawValue, CodingKeys.projection.rawValue],
            typeName: "RunLedgerPersistedOutboxProjection"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported outbox projection schema: \(version)"
            )
        }
        schemaVersion = version
        projection = try container.decode(RunLedgerOutboxProjectionV1.self, forKey: .projection)
        try projection.validate()
    }
}

package enum RunLedgerOutboxExecutionStateV1: String, Codable, Equatable, Sendable {
    case admitted
    case running
    case terminal
    case inDoubt = "in_doubt"
}

package enum RunLedgerOutboxTerminalOutcomeV1: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case cancelled
    case launchFailed = "launch_failed"
    case signaled
    case waitFailed = "wait_failed"
}

package struct RunLedgerOutboxTerminalEvidenceV1: Codable, Equatable, Sendable {
    package let outcome: RunLedgerOutboxTerminalOutcomeV1
    package let exitCode: Int32?
    package let cancellationIntent: ExecutionCancellationIntent?
    package let terminationSignal: Int32?
    package let terminationReason: RunBrokerTerminationReason?
    package let supervisorSequence: UInt64
    package let supervisorEventID: UUID
    package let occurredAt: Date
}

package struct RunLedgerOutboxExecutionV1: Codable, Equatable, Sendable {
    package let executionID: RunBrokerExecutionID
    package let authority: RunBrokerAuthority
    package let state: RunLedgerOutboxExecutionStateV1
    package let lastSupervisorSequence: UInt64
    package let manifestSHA256: ExecutionLaunchArgumentsSHA256
    package let configurationRevision: String
    package let terminalEvidence: RunLedgerOutboxTerminalEvidenceV1?
}

package enum RunLedgerOutboxStreamChannelV1: String, Codable, Equatable, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

package struct RunLedgerOutboxStreamV1: Codable, Equatable, Sendable {
    package let channel: RunLedgerOutboxStreamChannelV1
    package let bytes: Data
    package let startsLogicalLine: Bool
    package let endsLogicalLine: Bool
    /// Total retained bytes in the current logical-line fragment, bounded by
    /// `maximumRetainedFragmentBytes` across arbitrarily many supervisor chunks.
    package let trailingFragmentByteCount: UInt32
    package let fragmentTruncated: Bool

    package static let maximumRetainedFragmentBytes: UInt32 = 131_072
}

package struct RunLedgerOutboxSupervisorV1: Codable, Equatable, Sendable {
    package let observation: RunBrokerSupervisorObservation
    package let stream: RunLedgerOutboxStreamV1?
    package let terminal: RunLedgerOutboxTerminalEvidenceV1?
}

package struct RunLedgerOutboxMonitorV1: Codable, Equatable, Sendable {
    package let operationID: RunBrokerOperationID
    package let authority: RunBrokerAuthority
    package let deadline: RunLedgerMonitorDeadline?
    package let stopped: Bool
}

package enum RunLedgerOutboxRuntimeSwitchProgressV1: String, Codable, Equatable, Sendable {
    case waitingForCheckpoint = "waiting_for_checkpoint"
    case confirmationRequired = "confirmation_required"
    case controlDispatchPending = "control_dispatch_pending"
    case awaitingSourceTerminal = "awaiting_source_terminal"
    case replacementDispatchPending = "replacement_dispatch_pending"
    case awaitingReplacementRunning = "awaiting_replacement_running"
    case completed
    case archived
    case inDoubt = "in_doubt"
}

package struct RunLedgerOutboxRuntimeSwitchV1: Codable, Equatable, Sendable {
    package let requestID: RuntimeSwitchRequestID
    package let requestDigest: RuntimeSwitchRequestDigest
    package let source: RuntimeSwitchSourceFence
    package let targetExecutionID: RunBrokerExecutionID
    package let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    package let progress: RunLedgerOutboxRuntimeSwitchProgressV1
    package let challenge: RuntimeForceSwitchChallenge?
    package let recordedControlEffectID: RuntimeSwitchEffectID?
    package let recordedReplacementEffectID: RuntimeSwitchEffectID?
}

package struct RunLedgerOutboxRuntimeSwitchReservationV1: Codable, Equatable, Sendable {
    package let requestID: RuntimeSwitchRequestID
    package let requestDigest: RuntimeSwitchRequestDigest
    package let reservationID: RuntimeSwitchEvidenceID
    package let targetExecutionID: RunBrokerExecutionID
    package let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    package let ledgerSequence: UInt64
}

package struct RunLedgerOutboxExecutionControlV1: Codable, Equatable, Sendable {
    package let executionID: RunBrokerExecutionID
    package let authority: RunBrokerAuthority
    package let expectedSupervisorSequence: UInt64
    package let acceptedSupervisorSequence: UInt64
    package let cancellationIntent: ExecutionCancellationIntent?
    package let challenge: ExecutionForceChallenge?
    package let acceptedEffectID: RuntimeSwitchEffectID?
}

package enum RunLedgerOutboxProjectionV1: Equatable, Sendable {
    case execution(RunLedgerOutboxExecutionV1)
    case supervisor(RunLedgerOutboxSupervisorV1)
    case operation(DurableExecutionClaimRecord)
    case monitor(RunLedgerOutboxMonitorV1)
    case runtimeSwitch(RunLedgerOutboxRuntimeSwitchV1)
    case runtimeSwitchReservation(RunLedgerOutboxRuntimeSwitchReservationV1)
    case executionControl(RunLedgerOutboxExecutionControlV1)

    package var executionID: RunBrokerExecutionID? {
        switch self {
        case .execution(let value): value.executionID
        case .supervisor(let value): value.observation.executionID
        case .executionControl(let value): value.executionID
        case .operation, .monitor, .runtimeSwitch, .runtimeSwitchReservation: nil
        }
    }

    package var supervisorSequence: UInt64? {
        guard case .supervisor(let value) = self else { return nil }
        return value.observation.supervisorSequence
    }

    package var stream: RunLedgerOutboxStreamV1? {
        guard case .supervisor(let value) = self else { return nil }
        return value.stream
    }

    package var hasTerminalEvidence: Bool {
        guard case .supervisor(let value) = self else { return false }
        return value.terminal != nil
    }

    package func matches(eventKind: String) -> Bool {
        switch self {
        case .execution:
            eventKind == "execution.admitted"
                || eventKind == "execution.authority_transferred"
                || eventKind == "execution.control_transitioned"
        case .supervisor:
            eventKind == "execution.supervisor_observation_recorded"
        case .operation:
            eventKind == "operation.claimed" || eventKind == "operation.tombstoned"
        case .monitor:
            eventKind == "monitor.deadline_upserted"
                || eventKind == "monitor.deadline_removed"
                || eventKind == "monitor.attempt_recorded"
        case .runtimeSwitch:
            eventKind == "runtime_switch.admitted"
                || eventKind == "runtime_switch.policy_transitioned"
                || eventKind == "runtime_switch.completion_archived"
        case .runtimeSwitchReservation:
            eventKind == "runtime_switch.target_reserved"
        case .executionControl:
            eventKind == "execution.force_challenge_recorded"
                || eventKind == "execution.force_challenge_consumed"
        }
    }

    package func validate() throws {
        switch self {
        case .execution(let value):
            guard value.authority.epoch.rawValue > 0,
                  (value.state == .terminal) == (value.terminalEvidence != nil) else {
                throw RunLedgerError.corrupt("Invalid stored execution projection")
            }
            try Self.validate(value.terminalEvidence)
        case .supervisor(let value):
            let isStream = value.observation.kind == .standardOutput
                || value.observation.kind == .standardError
            guard isStream == (value.stream != nil),
                  value.observation.output == nil,
                  value.terminal.map({
                      $0.supervisorSequence == value.observation.supervisorSequence
                          && $0.supervisorEventID == value.observation.supervisorEventID
                          && $0.occurredAt == value.observation.occurredAt
                  }) ?? true else {
                throw RunLedgerError.corrupt("Invalid stored supervisor projection")
            }
            if let stream = value.stream {
                guard !stream.bytes.isEmpty,
                      stream.trailingFragmentByteCount <= RunLedgerOutboxStreamV1.maximumRetainedFragmentBytes,
                      stream.endsLogicalLine == (stream.trailingFragmentByteCount == 0),
                      !stream.endsLogicalLine || !stream.fragmentTruncated else {
                    throw RunLedgerError.corrupt("Invalid stored stream continuation")
                }
            }
            try Self.validate(value.terminal)
        case .operation(let record):
            guard record.authority.epoch.rawValue > 0 else {
                throw RunLedgerError.corrupt("Invalid stored operation projection")
            }
        case .monitor(let value):
            guard value.authority.epoch.rawValue > 0,
                  value.stopped == (value.deadline == nil) else {
                throw RunLedgerError.corrupt("Invalid stored monitor projection")
            }
        case .runtimeSwitch(let value):
            guard value.source.executionID != value.targetExecutionID,
                  (value.progress == .confirmationRequired) == (value.challenge != nil),
                  value.recordedReplacementEffectID == nil || value.recordedControlEffectID != nil else {
                throw RunLedgerError.corrupt("Invalid stored runtime-switch projection")
            }
        case .runtimeSwitchReservation(let value):
            guard value.ledgerSequence > 0 else {
                throw RunLedgerError.corrupt("Invalid stored runtime-switch reservation")
            }
        case .executionControl(let value):
            guard value.authority.epoch.rawValue > 0,
                  value.acceptedSupervisorSequence >= value.expectedSupervisorSequence,
                  value.acceptedEffectID == nil || value.cancellationIntent == .immediate else {
                throw RunLedgerError.corrupt("Invalid stored execution-control projection")
            }
        }
    }

    private static func validate(_ value: RunLedgerOutboxTerminalEvidenceV1?) throws {
        guard let value else { return }
        let valid: Bool
        switch value.outcome {
        case .completed:
            valid = value.exitCode == 0 && value.cancellationIntent == nil
                && value.terminationReason == .exited && value.terminationSignal == nil
        case .failed:
            valid = value.exitCode.map({ $0 > 0 }) == true && value.cancellationIntent == nil
                && value.terminationReason == .exited && value.terminationSignal == nil
        case .cancelled:
            valid = value.cancellationIntent == .graceful || value.cancellationIntent == .immediate
        case .launchFailed:
            valid = value.exitCode == nil && value.cancellationIntent == nil
                && value.terminationReason == nil && value.terminationSignal == nil
        case .signaled:
            valid = value.exitCode != nil && value.cancellationIntent == nil
                && value.terminationReason == .signaled
                && value.terminationSignal.map({ $0 > 0 }) == true
        case .waitFailed:
            valid = value.exitCode.map({ $0 < 0 }) == true && value.cancellationIntent == nil
                && value.terminationReason == .waitFailed && value.terminationSignal == nil
        }
        guard valid, value.supervisorSequence > 0 else {
            throw RunLedgerError.corrupt("Invalid stored terminal evidence")
        }
    }
}

extension RunLedgerOutboxProjectionV1: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case execution
        case supervisor
        case operation
        case monitor
        case runtimeSwitch
        case runtimeSwitchReservation
        case executionControl
    }

    private enum Kind: String, Codable {
        case execution
        case supervisor
        case operation
        case monitor
        case runtimeSwitch = "runtime_switch"
        case runtimeSwitchReservation = "runtime_switch_reservation"
        case executionControl = "execution_control"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let payloadKey: CodingKeys
        switch kind {
        case .execution: payloadKey = .execution
        case .supervisor: payloadKey = .supervisor
        case .operation: payloadKey = .operation
        case .monitor: payloadKey = .monitor
        case .runtimeSwitch: payloadKey = .runtimeSwitch
        case .runtimeSwitchReservation: payloadKey = .runtimeSwitchReservation
        case .executionControl: payloadKey = .executionControl
        }
        try RunLedgerStrictCoding.requireExactKeys(
            decoder,
            expected: [CodingKeys.kind.rawValue, payloadKey.rawValue],
            typeName: "RunLedgerOutboxProjectionV1"
        )
        switch kind {
        case .execution: self = .execution(try container.decode(RunLedgerOutboxExecutionV1.self, forKey: payloadKey))
        case .supervisor: self = .supervisor(try container.decode(RunLedgerOutboxSupervisorV1.self, forKey: payloadKey))
        case .operation: self = .operation(try container.decode(DurableExecutionClaimRecord.self, forKey: payloadKey))
        case .monitor: self = .monitor(try container.decode(RunLedgerOutboxMonitorV1.self, forKey: payloadKey))
        case .runtimeSwitch: self = .runtimeSwitch(try container.decode(RunLedgerOutboxRuntimeSwitchV1.self, forKey: payloadKey))
        case .runtimeSwitchReservation:
            self = .runtimeSwitchReservation(try container.decode(RunLedgerOutboxRuntimeSwitchReservationV1.self, forKey: payloadKey))
        case .executionControl:
            self = .executionControl(try container.decode(RunLedgerOutboxExecutionControlV1.self, forKey: payloadKey))
        }
        try validate()
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .execution(let value):
            try container.encode(Kind.execution, forKey: .kind)
            try container.encode(value, forKey: .execution)
        case .supervisor(let value):
            try container.encode(Kind.supervisor, forKey: .kind)
            try container.encode(value, forKey: .supervisor)
        case .operation(let value):
            try container.encode(Kind.operation, forKey: .kind)
            try container.encode(value, forKey: .operation)
        case .monitor(let value):
            try container.encode(Kind.monitor, forKey: .kind)
            try container.encode(value, forKey: .monitor)
        case .runtimeSwitch(let value):
            try container.encode(Kind.runtimeSwitch, forKey: .kind)
            try container.encode(value, forKey: .runtimeSwitch)
        case .runtimeSwitchReservation(let value):
            try container.encode(Kind.runtimeSwitchReservation, forKey: .kind)
            try container.encode(value, forKey: .runtimeSwitchReservation)
        case .executionControl(let value):
            try container.encode(Kind.executionControl, forKey: .kind)
            try container.encode(value, forKey: .executionControl)
        }
    }
}

package struct RunLedgerOutboxProjectionMaterialization: Equatable, Sendable {
    package let payload: Data
    package let sha256: Data
    package let projection: RunLedgerOutboxProjectionV1
}

package enum RunLedgerOutboxProjectionCodec {
    package static func encode(
        _ projection: RunLedgerOutboxProjectionV1
    ) throws -> RunLedgerOutboxProjectionMaterialization {
        try projection.validate()
        let persisted = RunLedgerPersistedOutboxProjection(projection: projection)
        let payload = try RunLedgerCodec.encode(persisted)
        return .init(
            payload: payload,
            sha256: Data(SHA256.hash(data: payload)),
            projection: projection
        )
    }

    package static func decode(
        payload: Data,
        sha256: Data
    ) throws -> RunLedgerOutboxProjectionV1 {
        guard sha256.count == SHA256.Digest.byteCount,
              Data(SHA256.hash(data: payload)) == sha256 else {
            throw RunLedgerError.projectionDrift("Stored outbox projection digest mismatch")
        }
        let persisted = try RunLedgerCodec.decode(
            RunLedgerPersistedOutboxProjection.self,
            from: payload
        )
        let canonical = try RunLedgerCodec.encode(persisted)
        guard canonical == payload else {
            throw RunLedgerError.projectionDrift("Stored outbox projection is not canonical JSON")
        }
        try persisted.projection.validate()
        return persisted.projection
    }
}

enum RunLedgerOutboxProjectionMaterializer {
    static func materialize(
        storedEvent: StoredRunLedgerEvent,
        projection: RunLedgerProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerOutboxProjectionMaterialization {
        let event = storedEvent.envelope.event
        let projected: RunLedgerOutboxProjectionV1
        switch event {
        case .executionAdmitted(let manifest, _):
            projected = .execution(try execution(
                manifest.executionID,
                projection: projection,
                connection: connection,
                database: database
            ))
        case .executionAuthorityTransferred(let executionID, _, _),
             .executionControlTransitioned(let executionID, _, _, _):
            projected = .execution(try execution(
                executionID,
                projection: projection,
                connection: connection,
                database: database
            ))
        case .supervisorObservationRecorded(let observation):
            projected = .supervisor(try supervisor(
                observation,
                connection: connection,
                database: database
            ))
        case .operationClaimed(let operationID, _, _, _),
             .operationTombstoned(let operationID, _, _):
            guard let record = projection.operations[operationID]?.record else {
                throw RunLedgerError.projectionDrift("Outbox operation projection is missing")
            }
            projected = .operation(record)
        case .monitorDeadlineUpserted(let deadline, _):
            projected = .monitor(.init(
                operationID: deadline.operationID,
                authority: deadline.authority,
                deadline: projection.monitorDeadlines[deadline.operationID],
                stopped: false
            ))
        case .monitorDeadlineRemoved(let expected):
            projected = .monitor(.init(
                operationID: expected.operationID,
                authority: expected.authority,
                deadline: nil,
                stopped: true
            ))
        case .monitorAttemptRecorded(let expected, _, _, _):
            let deadline = projection.monitorDeadlines[expected.operationID]
            projected = .monitor(.init(
                operationID: expected.operationID,
                authority: expected.authority,
                deadline: deadline,
                stopped: deadline == nil
            ))
        case .runtimeSwitchTargetReserved(_, _, let reservationID):
            guard let value = projection.runtimeSwitchReservations[reservationID] else {
                throw RunLedgerError.projectionDrift("Outbox runtime-switch reservation is missing")
            }
            projected = .runtimeSwitchReservation(.init(
                requestID: value.requestID,
                requestDigest: value.requestDigest,
                reservationID: value.reservationID,
                targetExecutionID: value.targetExecutionID,
                targetManifestSHA256: value.targetManifestSHA256,
                ledgerSequence: value.ledgerSequence
            ))
        case .runtimeSwitchAdmitted:
            projected = .runtimeSwitch(try runtimeSwitch(
                projection.runtimeSwitchPolicyState
            ))
        case .runtimeSwitchPolicyTransitioned(_, let next, _):
            projected = .runtimeSwitch(try runtimeSwitch(next))
        case .runtimeSwitchCompletionArchived:
            projected = .runtimeSwitch(try runtimeSwitch(
                projection.runtimeSwitchPolicyState
            ))
        case .executionForceChallengeRecorded(let challenge):
            projected = .executionControl(.init(
                executionID: challenge.executionID,
                authority: challenge.authority,
                expectedSupervisorSequence: challenge.expectedSupervisorSequence,
                acceptedSupervisorSequence: challenge.expectedSupervisorSequence,
                cancellationIntent: nil,
                challenge: challenge,
                acceptedEffectID: nil
            ))
        case .executionForceChallengeConsumed(let challengeID, _, let effectID, _, _, _):
            guard let challenge = projection.executionForceChallenges[challengeID] else {
                throw RunLedgerError.projectionDrift("Outbox force challenge is missing")
            }
            projected = .executionControl(.init(
                executionID: challenge.executionID,
                authority: challenge.authority,
                expectedSupervisorSequence: challenge.expectedSupervisorSequence,
                acceptedSupervisorSequence: challenge.expectedSupervisorSequence,
                cancellationIntent: .immediate,
                challenge: challenge,
                acceptedEffectID: effectID
            ))
        }
        return try RunLedgerOutboxProjectionCodec.encode(projected)
    }

    private static func execution(
        _ executionID: RunBrokerExecutionID,
        projection: RunLedgerProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerOutboxExecutionV1 {
        guard let execution = projection.executions[executionID] else {
            throw RunLedgerError.projectionDrift("Outbox execution projection is missing")
        }
        let lastSequence = try connection.scalarInt64(
            "SELECT MAX(supervisor_sequence) FROM outbox WHERE execution_id = ?",
            bindings: [.text(RunLedgerSchema.uuid(executionID.rawValue))],
            database: database
        ).flatMap(UInt64.init(exactly:)) ?? 0
        let terminal = try latestTerminal(
            executionID: executionID,
            connection: connection,
            database: database
        )
        let state: RunLedgerOutboxExecutionStateV1 = switch execution.control.observedExecution {
        case .registered, .starting: .admitted
        case .running: .running
        case .completed, .failed, .cancelled: .terminal
        case .inDoubt: .inDoubt
        }
        return .init(
            executionID: executionID,
            authority: execution.authority,
            state: state,
            lastSupervisorSequence: lastSequence,
            manifestSHA256: try RuntimeSwitchDigests.manifest(execution.manifest),
            configurationRevision: execution.manifest.configuration.configurationRevision,
            terminalEvidence: state == .terminal ? terminal : nil
        )
    }

    private static func supervisor(
        _ observation: RunBrokerSupervisorObservation,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerOutboxSupervisorV1 {
        let stream: RunLedgerOutboxStreamV1?
        if let bytes = observation.output,
           observation.kind == .standardOutput || observation.kind == .standardError {
            let channel: RunLedgerOutboxStreamChannelV1 = observation.kind == .standardOutput
                ? .standardOutput : .standardError
            let previous = try latestStream(
                executionID: observation.executionID,
                channel: channel,
                connection: connection,
                database: database
            )
            let trailingInChunk = bytes.lastIndex(of: 0x0A).map { bytes.count - $0 - 1 }
            let unbounded = trailingInChunk.map(Int64.init)
                ?? Int64(previous?.trailingFragmentByteCount ?? 0) + Int64(bytes.count)
            let maximum = Int64(RunLedgerOutboxStreamV1.maximumRetainedFragmentBytes)
            let trailing = min(unbounded, maximum)
            stream = .init(
                channel: channel,
                bytes: bytes,
                startsLogicalLine: previous?.endsLogicalLine ?? true,
                endsLogicalLine: unbounded == 0,
                trailingFragmentByteCount: UInt32(trailing),
                fragmentTruncated: unbounded > maximum
                    || (trailingInChunk == nil && previous?.fragmentTruncated == true)
            )
        } else {
            stream = nil
        }
        let storedObservation: RunBrokerSupervisorObservation
        if stream != nil {
            storedObservation = .init(
                executionID: observation.executionID,
                authority: observation.authority,
                supervisorSequence: observation.supervisorSequence,
                supervisorEventID: observation.supervisorEventID,
                occurredAt: observation.occurredAt,
                kind: observation.kind,
                output: nil,
                exitCode: observation.exitCode,
                terminationSignal: observation.terminationSignal,
                terminationReason: observation.terminationReason,
                cancellationIntent: observation.cancellationIntent,
                quarantinedByteCount: observation.quarantinedByteCount
            )
        } else {
            storedObservation = observation
        }
        return .init(
            observation: storedObservation,
            stream: stream,
            terminal: terminal(observation)
        )
    }

    private static func latestStream(
        executionID: RunBrokerExecutionID,
        channel: RunLedgerOutboxStreamChannelV1,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerOutboxStreamV1? {
        let statement = try connection.statement(
            """
            SELECT projection_payload, projection_sha256 FROM outbox
            WHERE execution_id = ? AND stream_channel = ?
            ORDER BY sequence DESC LIMIT 1
            """,
            bindings: [
                .text(RunLedgerSchema.uuid(executionID.rawValue)),
                .text(channel.rawValue),
            ],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row else { return nil }
        let projection = try RunLedgerOutboxProjectionCodec.decode(
            payload: try statement.blob(at: 0),
            sha256: try statement.blob(at: 1)
        )
        guard case .supervisor(let value) = projection,
              value.stream?.channel == channel else {
            throw RunLedgerError.projectionDrift("Stream index points to a different projection")
        }
        return value.stream
    }

    private static func latestTerminal(
        executionID: RunBrokerExecutionID,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerOutboxTerminalEvidenceV1? {
        let statement = try connection.statement(
            """
            SELECT projection_payload, projection_sha256 FROM outbox
            WHERE execution_id = ? AND has_terminal = 1
            ORDER BY sequence DESC LIMIT 1
            """,
            bindings: [.text(RunLedgerSchema.uuid(executionID.rawValue))],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row else { return nil }
        let projection = try RunLedgerOutboxProjectionCodec.decode(
            payload: try statement.blob(at: 0),
            sha256: try statement.blob(at: 1)
        )
        guard case .supervisor(let value) = projection, let terminal = value.terminal else {
            throw RunLedgerError.projectionDrift("Terminal index points to a different projection")
        }
        return terminal
    }

    private static func terminal(
        _ observation: RunBrokerSupervisorObservation
    ) -> RunLedgerOutboxTerminalEvidenceV1? {
        let outcome: RunLedgerOutboxTerminalOutcomeV1
        switch observation.kind {
        case .providerLaunchFailed:
            outcome = .launchFailed
        case .cancellationConfirmed:
            outcome = .cancelled
        case .providerExited:
            switch observation.terminationReason {
            case .exited: outcome = observation.exitCode == 0 ? .completed : .failed
            case .signaled: outcome = .signaled
            case .waitFailed: outcome = .waitFailed
            case nil: return nil
            }
        default:
            return nil
        }
        return .init(
            outcome: outcome,
            exitCode: observation.exitCode,
            cancellationIntent: outcome == .cancelled ? observation.cancellationIntent : nil,
            terminationSignal: observation.terminationSignal,
            terminationReason: observation.terminationReason,
            supervisorSequence: observation.supervisorSequence,
            supervisorEventID: observation.supervisorEventID,
            occurredAt: observation.occurredAt
        )
    }

    private static func runtimeSwitch(
        _ state: RuntimeSwitchPolicyState
    ) throws -> RunLedgerOutboxRuntimeSwitchV1 {
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
            throw RunLedgerError.projectionDrift("Runtime-switch transition has no outbox status")
        }
        return .init(
            requestID: archived.requestID,
            requestDigest: archived.requestDigest,
            source: archived.request.intent.expectedSource,
            targetExecutionID: archived.targetExecutionID,
            targetManifestSHA256: archived.targetManifestSHA256,
            progress: .archived,
            challenge: nil,
            recordedControlEffectID: archived.controlEffectID,
            recordedReplacementEffectID: archived.replacementEffectID
        )
    }

    private static func progress(
        _ value: RuntimeSwitchProgress
    ) -> RunLedgerOutboxRuntimeSwitchProgressV1 {
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
