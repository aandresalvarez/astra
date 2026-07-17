import ASTRACore
import Foundation

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

    public init(
        ledgerDirectoryURL: URL,
        installationID: RunBrokerInstallationID,
        expectedStoreID: RunBrokerStoreID? = nil,
        busyTimeoutMilliseconds: Int32 = 5_000
    ) {
        self.ledgerDirectoryURL = ledgerDirectoryURL
        self.installationID = installationID
        self.expectedStoreID = expectedStoreID
        self.busyTimeoutMilliseconds = max(1, busyTimeoutMilliseconds)
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

    public var kind: String {
        switch self {
        case .executionAdmitted: "execution.admitted"
        case .operationClaimed: "operation.claimed"
        case .executionAuthorityTransferred: "execution.authority_transferred"
        case .operationTombstoned: "operation.tombstoned"
        case .executionControlTransitioned: "execution.control_transitioned"
        case .monitorDeadlineUpserted: "monitor.deadline_upserted"
        case .monitorDeadlineRemoved: "monitor.deadline_removed"
        case .monitorAttemptRecorded: "monitor.attempt_recorded"
        }
    }

    public var aggregateKind: String {
        switch self {
        case .executionAdmitted, .executionAuthorityTransferred,
             .executionControlTransitioned:
            "execution"
        case .operationClaimed, .operationTombstoned,
             .monitorDeadlineUpserted, .monitorDeadlineRemoved, .monitorAttemptRecorded:
            "operation"
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
        case .monitorDeadlineUpserted(let deadline, _),
             .monitorAttemptRecorded(let deadline, _, _, _):
            deadline.operationID.rawValue.uuidString.lowercased()
        case .monitorDeadlineRemoved(let expected):
            expected.operationID.rawValue.uuidString.lowercased()
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
        case deadline
        case expected
        case attemptedAt
        case disposition
        case nextDueAt
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
