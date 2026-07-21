import ASTRACore
import Foundation
import RunBrokerPolicy

public struct RunLedgerEventID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var id: UUID { rawValue }
}

public struct RunLedgerConsumerID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 200,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RunLedgerError.invalidConsumerID
        }
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RunLedgerConfiguration: Sendable, Equatable {
    public static let databaseFileName = "run-ledger.sqlite3"

    /// Dedicated directory owned by the current user and used only for the
    /// canonical ledger and SQLite sidecars. Existing directory permissions
    /// are validated, never silently changed.
    public let ledgerDirectoryURL: URL
    public let installationID: RunBrokerInstallationID
    public let expectedStoreID: RunBrokerStoreID?
    public let busyTimeoutMilliseconds: Int32
    /// Holds a process-lifetime exclusive writer lock for as long as the ledger
    /// is open. The broker daemon must claim this: observation ordering and
    /// output-limit invariants for `.supervisorObservationRecorded` are
    /// serialized by the orchestrator's in-process lock, so a second live
    /// broker process over the same ledger could interleave appends that the
    /// schema accepts but reconcile can never repair. Secondary read/verify
    /// connections (health inspection, tests, in-process fencing checks) do
    /// not claim exclusivity and are unaffected.
    public let exclusiveWriter: Bool

    public init(
        ledgerDirectoryURL: URL,
        installationID: RunBrokerInstallationID,
        expectedStoreID: RunBrokerStoreID? = nil,
        busyTimeoutMilliseconds: Int32 = 5_000,
        exclusiveWriter: Bool = false
    ) {
        self.ledgerDirectoryURL = ledgerDirectoryURL
        self.installationID = installationID
        self.expectedStoreID = expectedStoreID
        self.busyTimeoutMilliseconds = max(1, busyTimeoutMilliseconds)
        self.exclusiveWriter = exclusiveWriter
    }

    public var databaseURL: URL {
        ledgerDirectoryURL.appendingPathComponent(Self.databaseFileName, isDirectory: false)
    }
}

public struct RunLedgerIdentity: Codable, Hashable, Sendable {
    public let storeID: RunBrokerStoreID
    public let installationID: RunBrokerInstallationID
    public let schemaVersion: Int
    public let createdAt: Date

    public init(
        storeID: RunBrokerStoreID,
        installationID: RunBrokerInstallationID,
        schemaVersion: Int,
        createdAt: Date
    ) {
        self.storeID = storeID
        self.installationID = installationID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}

public enum RunLedgerEvent: Equatable, Sendable {
    /// One durable launch-admission fact. The execution row and its primary
    /// effect claim must never be committed independently.
    case executionAdmitted(
        manifest: ExecutionLaunchManifest,
        primaryOperationID: RunBrokerOperationID
    )
    case operationClaimed(
        operationID: RunBrokerOperationID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        effects: [ExecutionEffectClaim]
    )
    case executionAuthorityTransferred(
        executionID: RunBrokerExecutionID,
        expectedAuthority: RunBrokerAuthority,
        newAuthority: RunBrokerAuthority
    )
    case operationTombstoned(
        operationID: RunBrokerOperationID,
        authority: RunBrokerAuthority,
        reason: DurableExecutionClaimTombstoneReason
    )
    case executionControlTransitioned(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        transition: RunLedgerExecutionControlEvent,
        backendCapabilities: ExternalOperationBackendCapabilities
    )
    case supervisorObservationRecorded(RunBrokerSupervisorObservation)
    case monitorDeadlineUpserted(
        deadline: RunLedgerMonitorDeadline,
        replacing: RunLedgerMonitorDeadline?
    )
    case monitorDeadlineRemoved(expected: RunLedgerMonitorDeadline)
    case monitorAttemptRecorded(
        expected: RunLedgerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunLedgerMonitorAttemptDisposition,
        nextDueAt: Date?
    )
    /// Atomically binds one globally unique request, reservation, and target
    /// execution before policy admission. The trusted reservation object is
    /// constructed by the ledger projector from the committed sequence.
    case runtimeSwitchTargetReserved(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        reservationID: RuntimeSwitchEvidenceID
    )
    /// One admission fact atomically verifies source/target digests, reserves
    /// the replacement identity, binds any force challenge, and advances the
    /// policy from its current durable state.
    case runtimeSwitchAdmitted(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        reservationID: RuntimeSwitchEvidenceID,
        forceChallenge: RuntimeForceSwitchChallenge?
    )
    /// Exact compare-and-swap over the canonical runtime-switch policy state.
    /// An effect identifier is present iff this transition records an external
    /// effect intent; dispatch must happen only after this event commits.
    case runtimeSwitchPolicyTransitioned(
        expected: RuntimeSwitchPolicyState,
        next: RuntimeSwitchPolicyState,
        effectID: RuntimeSwitchEffectID?
    )
    /// The projector derives the archived state using the event's actual
    /// inserted sequence, so unrelated ledger writes cannot stale a predicted
    /// rollover sequence.
    case runtimeSwitchCompletionArchived(
        expected: RuntimeSwitchPolicyState,
        archiveEvidenceID: RuntimeSwitchEvidenceID
    )
    case executionForceChallengeRecorded(ExecutionForceChallenge)
    case executionForceChallengeConsumed(
        challengeID: RuntimeForceChallengeID,
        requestDigest: ExecutionForceRequestDigest,
        effectID: RuntimeSwitchEffectID,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        confirmedAt: Date
    )

    public var kind: String {
        switch self {
        case .executionAdmitted: "execution.admitted"
        case .operationClaimed: "operation.claimed"
        case .executionAuthorityTransferred: "execution.authority_transferred"
        case .operationTombstoned: "operation.tombstoned"
        case .executionControlTransitioned: "execution.control_transitioned"
        case .supervisorObservationRecorded: "execution.supervisor_observation_recorded"
        case .monitorDeadlineUpserted: "monitor.deadline_upserted"
        case .monitorDeadlineRemoved: "monitor.deadline_removed"
        case .monitorAttemptRecorded: "monitor.attempt_recorded"
        case .runtimeSwitchTargetReserved: "runtime_switch.target_reserved"
        case .runtimeSwitchAdmitted: "runtime_switch.admitted"
        case .runtimeSwitchPolicyTransitioned: "runtime_switch.policy_transitioned"
        case .runtimeSwitchCompletionArchived: "runtime_switch.completion_archived"
        case .executionForceChallengeRecorded: "execution.force_challenge_recorded"
        case .executionForceChallengeConsumed: "execution.force_challenge_consumed"
        }
    }

    public var aggregateKind: String {
        switch self {
        case .executionAdmitted, .executionAuthorityTransferred,
             .executionControlTransitioned, .supervisorObservationRecorded:
            "execution"
        case .operationClaimed, .operationTombstoned,
             .monitorDeadlineUpserted, .monitorDeadlineRemoved, .monitorAttemptRecorded:
            "operation"
        case .runtimeSwitchTargetReserved, .runtimeSwitchAdmitted,
             .runtimeSwitchPolicyTransitioned,
             .runtimeSwitchCompletionArchived:
            // Runtime switching is a lifecycle transition of the exact
            // source execution. Keep the stable v1 aggregate taxonomy; the
            // event kind carries the narrower domain classification.
            "execution"
        case .executionForceChallengeRecorded, .executionForceChallengeConsumed:
            "execution"
        }
    }

    public var aggregateID: String {
        switch self {
        case .executionAdmitted(let manifest, _):
            manifest.executionID.rawValue.uuidString.lowercased()
        case .operationClaimed(let operationID, _, _, _),
             .operationTombstoned(let operationID, _, _):
            operationID.rawValue.uuidString.lowercased()
        case .executionAuthorityTransferred(let executionID, _, _),
             .executionControlTransitioned(let executionID, _, _, _):
            executionID.rawValue.uuidString.lowercased()
        case .supervisorObservationRecorded(let observation):
            observation.executionID.rawValue.uuidString.lowercased()
        case .monitorDeadlineUpserted(let deadline, _),
             .monitorAttemptRecorded(let deadline, _, _, _):
            deadline.operationID.rawValue.uuidString.lowercased()
        case .monitorDeadlineRemoved(let expected):
            expected.operationID.rawValue.uuidString.lowercased()
        case .runtimeSwitchTargetReserved(let request, _, _):
            request.intent.requestID.rawValue.uuidString.lowercased()
        case .runtimeSwitchAdmitted(let request, _, _, _):
            request.intent.requestID.rawValue.uuidString.lowercased()
        case .runtimeSwitchPolicyTransitioned(_, let next, _):
            next.record?.request.intent.requestID.rawValue.uuidString.lowercased()
                ?? next.lastArchivedCompletion?.requestID.rawValue.uuidString.lowercased()
                ?? "runtime-switch-policy"
        case .runtimeSwitchCompletionArchived(let expected, _):
            expected.record?.request.intent.requestID.rawValue.uuidString.lowercased()
                ?? "runtime-switch-policy"
        case .executionForceChallengeRecorded(let challenge):
            challenge.executionID.rawValue.uuidString.lowercased()
        case .executionForceChallengeConsumed(let challengeID, _, _, _, _, _):
            challengeID.rawValue.uuidString.lowercased()
        }
    }
}

extension RunLedgerEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case manifest
        case primaryOperationID
        case operationID
        case executionID
        case authority
        case expectedAuthority
        case newAuthority
        case effects
        case reason
        case transition
        case backendCapabilities
        case supervisorObservation
        case deadline
        case expected
        case attemptedAt
        case disposition
        case nextDueAt
        case request
        case requestDigest
        case reservationID
        case next
        case effectID
        case challenge
        case forceChallenge
        case challengeID
        case actorID
        case sessionID
        case confirmedAt
        case archiveEvidenceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let expectedKeys: Set<String>
        switch kind {
        case "execution.admitted":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.manifest.rawValue,
                CodingKeys.primaryOperationID.rawValue,
            ]
        case "operation.claimed":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.operationID.rawValue,
                CodingKeys.executionID.rawValue,
                CodingKeys.authority.rawValue,
                CodingKeys.effects.rawValue,
            ]
        case "execution.authority_transferred":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.executionID.rawValue,
                CodingKeys.expectedAuthority.rawValue,
                CodingKeys.newAuthority.rawValue,
            ]
        case "operation.tombstoned":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.operationID.rawValue,
                CodingKeys.authority.rawValue,
                CodingKeys.reason.rawValue,
            ]
        case "execution.control_transitioned":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.executionID.rawValue,
                CodingKeys.authority.rawValue,
                CodingKeys.transition.rawValue,
                CodingKeys.backendCapabilities.rawValue,
            ]
        case "execution.supervisor_observation_recorded":
            expectedKeys = [CodingKeys.kind.rawValue, CodingKeys.supervisorObservation.rawValue]
        case "monitor.deadline_upserted":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.deadline.rawValue,
                CodingKeys.expected.rawValue,
            ]
        case "monitor.deadline_removed":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.expected.rawValue,
            ]
        case "monitor.attempt_recorded":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.expected.rawValue,
                CodingKeys.attemptedAt.rawValue,
                CodingKeys.disposition.rawValue,
                CodingKeys.nextDueAt.rawValue,
            ]
        case "runtime_switch.target_reserved":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.request.rawValue,
                CodingKeys.requestDigest.rawValue,
                CodingKeys.reservationID.rawValue,
            ]
        case "runtime_switch.admitted":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.request.rawValue,
                CodingKeys.requestDigest.rawValue,
                CodingKeys.reservationID.rawValue,
                CodingKeys.forceChallenge.rawValue,
            ]
        case "runtime_switch.policy_transitioned":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.expected.rawValue,
                CodingKeys.next.rawValue,
                CodingKeys.effectID.rawValue,
            ]
        case "runtime_switch.completion_archived":
            expectedKeys = [
                CodingKeys.kind.rawValue,
                CodingKeys.expected.rawValue,
                CodingKeys.archiveEvidenceID.rawValue,
            ]
        case "execution.force_challenge_recorded":
            expectedKeys = [CodingKeys.kind.rawValue, CodingKeys.challenge.rawValue]
        case "execution.force_challenge_consumed":
            expectedKeys = [
                CodingKeys.kind.rawValue, CodingKeys.challengeID.rawValue,
                CodingKeys.requestDigest.rawValue, CodingKeys.effectID.rawValue,
                CodingKeys.actorID.rawValue, CodingKeys.sessionID.rawValue,
                CodingKeys.confirmedAt.rawValue,
            ]
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported RunLedger event kind: \(kind)"
            )
        }
        try RunLedgerStrictCoding.requireExactKeys(
            decoder,
            expected: expectedKeys,
            typeName: "RunLedgerEvent.\(kind)"
        )
        switch kind {
        case "execution.admitted":
            self = .executionAdmitted(
                manifest: try container.decode(ExecutionLaunchManifest.self, forKey: .manifest),
                primaryOperationID: try container.decode(
                    RunBrokerOperationID.self,
                    forKey: .primaryOperationID
                )
            )
        case "operation.claimed":
            self = .operationClaimed(
                operationID: try container.decode(RunBrokerOperationID.self, forKey: .operationID),
                executionID: try container.decode(RunBrokerExecutionID.self, forKey: .executionID),
                authority: try container.decode(RunBrokerAuthority.self, forKey: .authority),
                effects: try container.decode([ExecutionEffectClaim].self, forKey: .effects)
            )
        case "execution.authority_transferred":
            self = .executionAuthorityTransferred(
                executionID: try container.decode(RunBrokerExecutionID.self, forKey: .executionID),
                expectedAuthority: try container.decode(
                    RunBrokerAuthority.self,
                    forKey: .expectedAuthority
                ),
                newAuthority: try container.decode(
                    RunBrokerAuthority.self,
                    forKey: .newAuthority
                )
            )
        case "operation.tombstoned":
            self = .operationTombstoned(
                operationID: try container.decode(RunBrokerOperationID.self, forKey: .operationID),
                authority: try container.decode(RunBrokerAuthority.self, forKey: .authority),
                reason: try container.decode(
                    DurableExecutionClaimTombstoneReason.self,
                    forKey: .reason
                )
            )
        case "execution.control_transitioned":
            self = .executionControlTransitioned(
                executionID: try container.decode(RunBrokerExecutionID.self, forKey: .executionID),
                authority: try container.decode(RunBrokerAuthority.self, forKey: .authority),
                transition: try container.decode(
                    RunLedgerExecutionControlEvent.self,
                    forKey: .transition
                ),
                backendCapabilities: try container.decode(
                    ExternalOperationBackendCapabilities.self,
                    forKey: .backendCapabilities
                )
            )
        case "execution.supervisor_observation_recorded":
            self = .supervisorObservationRecorded(
                try container.decode(
                    RunBrokerSupervisorObservation.self,
                    forKey: .supervisorObservation
                )
            )
        case "monitor.deadline_upserted":
            self = .monitorDeadlineUpserted(
                deadline: try container.decode(RunLedgerMonitorDeadline.self, forKey: .deadline),
                replacing: try container.decodeIfPresent(
                    RunLedgerMonitorDeadline.self,
                    forKey: .expected
                )
            )
        case "monitor.deadline_removed":
            self = .monitorDeadlineRemoved(
                expected: try container.decode(RunLedgerMonitorDeadline.self, forKey: .expected)
            )
        case "monitor.attempt_recorded":
            self = .monitorAttemptRecorded(
                expected: try container.decode(RunLedgerMonitorDeadline.self, forKey: .expected),
                attemptedAt: try container.decode(Date.self, forKey: .attemptedAt),
                disposition: try container.decode(
                    RunLedgerMonitorAttemptDisposition.self,
                    forKey: .disposition
                ),
                nextDueAt: try container.decodeIfPresent(Date.self, forKey: .nextDueAt)
            )
        case "runtime_switch.target_reserved":
            self = .runtimeSwitchTargetReserved(
                request: try container.decode(ActiveRuntimeSwitchRequest.self, forKey: .request),
                requestDigest: try container.decode(
                    RuntimeSwitchRequestDigest.self,
                    forKey: .requestDigest
                ),
                reservationID: try container.decode(
                    RuntimeSwitchEvidenceID.self,
                    forKey: .reservationID
                )
            )
        case "runtime_switch.admitted":
            self = .runtimeSwitchAdmitted(
                request: try container.decode(ActiveRuntimeSwitchRequest.self, forKey: .request),
                requestDigest: try container.decode(
                    RuntimeSwitchRequestDigest.self,
                    forKey: .requestDigest
                ),
                reservationID: try container.decode(
                    RuntimeSwitchEvidenceID.self,
                    forKey: .reservationID
                ),
                forceChallenge: try container.decodeIfPresent(
                    RuntimeForceSwitchChallenge.self,
                    forKey: .forceChallenge
                )
            )
        case "runtime_switch.policy_transitioned":
            self = .runtimeSwitchPolicyTransitioned(
                expected: try container.decode(RuntimeSwitchPolicyState.self, forKey: .expected),
                next: try container.decode(RuntimeSwitchPolicyState.self, forKey: .next),
                effectID: try container.decodeIfPresent(RuntimeSwitchEffectID.self, forKey: .effectID)
            )
        case "runtime_switch.completion_archived":
            self = .runtimeSwitchCompletionArchived(
                expected: try container.decode(RuntimeSwitchPolicyState.self, forKey: .expected),
                archiveEvidenceID: try container.decode(
                    RuntimeSwitchEvidenceID.self,
                    forKey: .archiveEvidenceID
                )
            )
        case "execution.force_challenge_recorded":
            self = .executionForceChallengeRecorded(
                try container.decode(ExecutionForceChallenge.self, forKey: .challenge)
            )
        case "execution.force_challenge_consumed":
            self = .executionForceChallengeConsumed(
                challengeID: try container.decode(RuntimeForceChallengeID.self, forKey: .challengeID),
                requestDigest: try container.decode(ExecutionForceRequestDigest.self, forKey: .requestDigest),
                effectID: try container.decode(RuntimeSwitchEffectID.self, forKey: .effectID),
                actorID: try container.decode(RuntimeSwitchActorID.self, forKey: .actorID),
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                confirmedAt: try container.decode(Date.self, forKey: .confirmedAt)
            )
        default:
            preconditionFailure("Event kind was validated before decoding")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .executionAdmitted(let manifest, let primaryOperationID):
            try container.encode(manifest, forKey: .manifest)
            try container.encode(primaryOperationID, forKey: .primaryOperationID)
        case .operationClaimed(let operationID, let executionID, let authority, let effects):
            try container.encode(operationID, forKey: .operationID)
            try container.encode(executionID, forKey: .executionID)
            try container.encode(authority, forKey: .authority)
            try container.encode(effects, forKey: .effects)
        case .executionAuthorityTransferred(
            let executionID,
            let expectedAuthority,
            let newAuthority
        ):
            try container.encode(executionID, forKey: .executionID)
            try container.encode(expectedAuthority, forKey: .expectedAuthority)
            try container.encode(newAuthority, forKey: .newAuthority)
        case .operationTombstoned(let operationID, let authority, let reason):
            try container.encode(operationID, forKey: .operationID)
            try container.encode(authority, forKey: .authority)
            try container.encode(reason, forKey: .reason)
        case .executionControlTransitioned(
            let executionID,
            let authority,
            let transition,
            let capabilities
        ):
            try container.encode(executionID, forKey: .executionID)
            try container.encode(authority, forKey: .authority)
            try container.encode(transition, forKey: .transition)
            try container.encode(capabilities, forKey: .backendCapabilities)
        case .supervisorObservationRecorded(let observation):
            try container.encode(observation, forKey: .supervisorObservation)
        case .monitorDeadlineUpserted(let deadline, let replacing):
            try container.encode(deadline, forKey: .deadline)
            try container.encode(replacing, forKey: .expected)
        case .monitorDeadlineRemoved(let expected):
            try container.encode(expected, forKey: .expected)
        case .monitorAttemptRecorded(let expected, let attemptedAt, let disposition, let nextDueAt):
            try container.encode(expected, forKey: .expected)
            try container.encode(attemptedAt, forKey: .attemptedAt)
            try container.encode(disposition, forKey: .disposition)
            try container.encode(nextDueAt, forKey: .nextDueAt)
        case .runtimeSwitchTargetReserved(let request, let requestDigest, let reservationID):
            try container.encode(request, forKey: .request)
            try container.encode(requestDigest, forKey: .requestDigest)
            try container.encode(reservationID, forKey: .reservationID)
        case .runtimeSwitchAdmitted(
            let request, let requestDigest, let reservationID, let forceChallenge
        ):
            try container.encode(request, forKey: .request)
            try container.encode(requestDigest, forKey: .requestDigest)
            try container.encode(reservationID, forKey: .reservationID)
            try container.encode(forceChallenge, forKey: .forceChallenge)
        case .runtimeSwitchPolicyTransitioned(let expected, let next, let effectID):
            try container.encode(expected, forKey: .expected)
            try container.encode(next, forKey: .next)
            try container.encode(effectID, forKey: .effectID)
        case .runtimeSwitchCompletionArchived(let expected, let archiveEvidenceID):
            try container.encode(expected, forKey: .expected)
            try container.encode(archiveEvidenceID, forKey: .archiveEvidenceID)
        case .executionForceChallengeRecorded(let challenge):
            try container.encode(challenge, forKey: .challenge)
        case .executionForceChallengeConsumed(
            let challengeID, let requestDigest, let effectID,
            let actorID, let sessionID, let confirmedAt
        ):
            try container.encode(challengeID, forKey: .challengeID)
            try container.encode(requestDigest, forKey: .requestDigest)
            try container.encode(effectID, forKey: .effectID)
            try container.encode(actorID, forKey: .actorID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(confirmedAt, forKey: .confirmedAt)
        }
    }
}

public struct RunLedgerEventEnvelope: Codable, Equatable, Sendable {
    public let eventID: RunLedgerEventID
    public let occurredAt: Date
    public let event: RunLedgerEvent

    public init(
        eventID: RunLedgerEventID = .init(),
        occurredAt: Date,
        event: RunLedgerEvent
    ) {
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.event = event
    }
}

public struct StoredRunLedgerEvent: Equatable, Sendable {
    public let sequence: Int64
    public let envelope: RunLedgerEventEnvelope

    public init(sequence: Int64, envelope: RunLedgerEventEnvelope) {
        self.sequence = sequence
        self.envelope = envelope
    }
}

public enum RunLedgerAppendDisposition: String, Codable, Equatable, Sendable {
    case appended
    case exactReplay = "exact_replay"
}

public struct RunLedgerAppendResult: Equatable, Sendable {
    public let sequence: Int64
    public let disposition: RunLedgerAppendDisposition

    public init(sequence: Int64, disposition: RunLedgerAppendDisposition) {
        self.sequence = sequence
        self.disposition = disposition
    }
}
