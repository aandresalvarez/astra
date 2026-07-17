import ASTRACore
import Foundation

struct RunLedgerPersistedEventPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let occurredAt: Date
    let event: RunLedgerEvent

    init(occurredAt: Date, event: RunLedgerEvent) {
        schemaVersion = Self.currentSchemaVersion
        self.occurredAt = occurredAt
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case occurredAt
        case event
    }

    init(from decoder: Decoder) throws {
        try RunLedgerStrictCoding.requireExactKeys(
            decoder,
            expected: [
                CodingKeys.schemaVersion.rawValue,
                CodingKeys.occurredAt.rawValue,
                CodingKeys.event.rawValue,
            ],
            typeName: "RunLedgerPersistedEventPayload"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported persisted event payload schema: \(version)"
            )
        }
        schemaVersion = version
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        event = try container.decode(RunLedgerEvent.self, forKey: .event)
    }
}

enum RunLedgerCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = date.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite,
                  milliseconds >= Double(Int64.min),
                  milliseconds <= Double(Int64.max) else {
                throw RunLedgerError.invalidEvent("Date is outside canonical millisecond bounds")
            }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(milliseconds.rounded(.towardZero)))
        }
        do {
            return try encoder.encode(value)
        } catch {
            throw RunLedgerError.invalidEvent("Canonical JSON encoding failed: \(error)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let milliseconds = try container.decode(Int64.self)
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RunLedgerError.corrupt("Canonical JSON decoding failed: \(error)")
        }
    }

    /// Encoding then decoding makes the event accepted by the live projector
    /// byte-for-byte equivalent to the event a recovery replay will observe.
    static func canonicalize(
        _ envelope: RunLedgerEventEnvelope
    ) throws -> (RunLedgerEventEnvelope, Data) {
        let payload = RunLedgerPersistedEventPayload(
            occurredAt: envelope.occurredAt,
            event: envelope.event
        )
        let data = try encode(payload)
        let canonical = try decode(RunLedgerPersistedEventPayload.self, from: data)
        return (
            .init(
                eventID: envelope.eventID,
                occurredAt: canonical.occurredAt,
                event: canonical.event
            ),
            data
        )
    }

    static func envelope(eventID: RunLedgerEventID, from data: Data) throws -> RunLedgerEventEnvelope {
        let payload = try decode(RunLedgerPersistedEventPayload.self, from: data)
        let canonical: Data
        do {
            canonical = try encode(payload)
        } catch {
            throw RunLedgerError.corrupt(
                "Persisted event cannot be re-encoded canonically: \(error)"
            )
        }
        guard canonical == data else {
            throw RunLedgerError.corrupt("Persisted event payload is not canonical JSON")
        }
        return .init(eventID: eventID, occurredAt: payload.occurredAt, event: payload.event)
    }
}

enum RunLedgerProjector {
    static func reduce(
        _ projection: RunLedgerProjection,
        storedEvent: StoredRunLedgerEvent,
        storeID: RunBrokerStoreID
    ) throws -> RunLedgerProjection {
        guard storedEvent.sequence > 0 else {
            throw RunLedgerError.invalidEvent("Event sequence must be positive")
        }
        let event = storedEvent.envelope.event
        let occurredAt = storedEvent.envelope.occurredAt

        switch event {
        case .executionAdmitted(let manifest, let primaryOperationID):
            return try RunLedgerAdmissionProjector.admit(
                manifest: manifest,
                primaryOperationID: primaryOperationID,
                projection: projection,
                storedEvent: storedEvent,
                storeID: storeID
            )

        case .operationClaimed(let operationID, let executionID, let authority, let effects):
            return try RunLedgerAdmissionProjector.claim(
                operationID: operationID,
                executionID: executionID,
                authority: authority,
                effects: effects,
                projection: projection,
                storedEvent: storedEvent,
                storeID: storeID
            )

        case .executionAuthorityTransferred(
            let executionID,
            let expectedAuthority,
            let newAuthority
        ):
            guard let execution = projection.executions[executionID] else {
                throw RunLedgerError.missingExecution(executionID)
            }
            try RunLedgerAdmissionProjector.validateAuthority(expectedAuthority)
            try RunLedgerAdmissionProjector.validateAuthority(newAuthority)
            try RunLedgerAdmissionProjector.requireCurrentAuthority(
                expectedAuthority,
                execution: execution
            )
            try RunLedgerAdmissionProjector.requireNextAuthority(
                newAuthority,
                after: expectedAuthority
            )
            guard occurredAt >= execution.updatedAt else {
                throw RunLedgerError.invalidEvent(
                    "Authority transfer predates the current execution state"
                )
            }

            var operations = projection.operations
            for (operationID, operation) in projection.operations
                where operation.record.executionID == executionID && operation.record.holdsEffects {
                guard occurredAt >= operation.record.updatedAt else {
                    throw RunLedgerError.invalidEvent("Authority transfer predates the current claim state")
                }
                let reduction = DurableExecutionClaimReducer.reduce(
                    operation.record,
                    event: .transferAuthority(newAuthority, at: occurredAt)
                )
                guard reduction.disposition == .applied else {
                    throw RunLedgerError.claimTransitionRejected(reduction.disposition)
                }
                operations[operationID] = .init(
                    record: reduction.record,
                    createdSequence: operation.createdSequence,
                    updatedSequence: storedEvent.sequence
                )
            }
            var executions = projection.executions
            executions[executionID] = .init(
                manifest: execution.manifest,
                authority: newAuthority,
                control: execution.control,
                updatedAt: occurredAt,
                createdSequence: execution.createdSequence,
                updatedSequence: storedEvent.sequence
            )
            var deadlines = projection.monitorDeadlines
            for operation in projection.operations.values
                where operation.record.executionID == executionID && operation.record.holdsEffects {
                guard let deadline = deadlines[operation.record.operationID] else { continue }
                deadlines[operation.record.operationID] = .init(
                    operationID: deadline.operationID,
                    authority: newAuthority,
                    dueAt: deadline.dueAt,
                    recordedAt: deadline.recordedAt,
                    attempt: deadline.attempt,
                    generation: deadline.generation
                )
            }
            return .init(
                executions: executions,
                operations: operations,
                monitorDeadlines: deadlines
            )

        case .operationTombstoned(let operationID, let authority, let reason):
            guard let operation = projection.operations[operationID] else {
                throw RunLedgerError.missingOperation(operationID)
            }
            guard let execution = projection.executions[operation.record.executionID] else {
                throw RunLedgerError.projectionDrift("Operation references a missing execution")
            }
            try RunLedgerAdmissionProjector.validateAuthority(authority)
            try RunLedgerAdmissionProjector.requireCurrentAuthority(
                authority,
                execution: execution
            )
            guard occurredAt >= operation.record.updatedAt else {
                throw RunLedgerError.invalidEvent("Tombstone predates the current claim state")
            }
            let reduction = DurableExecutionClaimReducer.reduce(
                operation.record,
                event: .tombstone(authority: authority, reason: reason, at: occurredAt)
            )
            guard reduction.disposition == .applied else {
                throw RunLedgerError.claimTransitionRejected(reduction.disposition)
            }
            var operations = projection.operations
            operations[operationID] = .init(
                record: reduction.record,
                createdSequence: operation.createdSequence,
                updatedSequence: storedEvent.sequence
            )
            var deadlines = projection.monitorDeadlines
            deadlines.removeValue(forKey: operationID)
            return .init(
                executions: projection.executions,
                operations: operations,
                monitorDeadlines: deadlines
            )

        case .executionControlTransitioned(
            let executionID,
            let authority,
            let transition,
            let backendCapabilities
        ):
            guard let execution = projection.executions[executionID] else {
                throw RunLedgerError.missingExecution(executionID)
            }
            try RunLedgerAdmissionProjector.validateAuthority(authority)
            try RunLedgerAdmissionProjector.requireCurrentAuthority(
                authority,
                execution: execution
            )
            guard occurredAt >= execution.updatedAt else {
                throw RunLedgerError.invalidEvent(
                    "Execution control transition predates the current execution state"
                )
            }
            let reduction = ExecutionControlReducer.reduce(
                execution.control,
                event: transition.coreEvent,
                backendCapabilities: backendCapabilities
            )
            guard reduction.disposition == .applied else {
                throw RunLedgerError.controlTransitionRejected
            }
            var executions = projection.executions
            executions[executionID] = .init(
                manifest: execution.manifest,
                authority: execution.authority,
                control: reduction.state,
                updatedAt: occurredAt,
                createdSequence: execution.createdSequence,
                updatedSequence: storedEvent.sequence
            )
            return .init(
                executions: executions,
                operations: projection.operations,
                monitorDeadlines: projection.monitorDeadlines
            )

        case .supervisorObservationRecorded(let observation):
            guard let execution = projection.executions[observation.executionID] else {
                throw RunLedgerError.missingExecution(observation.executionID)
            }
            try RunLedgerAdmissionProjector.validateAuthority(observation.authority)
            try RunLedgerAdmissionProjector.requireCurrentAuthority(
                observation.authority,
                execution: execution
            )
            guard observation.supervisorSequence > 0,
                  observation.occurredAt >= execution.manifest.createdAt,
                  observation.output.map({ !$0.isEmpty && $0.count <= 32_768 }) ?? true else {
                throw RunLedgerError.invalidEvent("Supervisor observation is outside durable bounds")
            }
            // Observation order and total output limits are checked by the
            // serialized broker service against journal history before append.
            // This event intentionally has no second mutable projection table:
            // the append-only journal/outbox is the canonical replay source.
            return projection

        case .monitorDeadlineUpserted,
             .monitorDeadlineRemoved,
             .monitorAttemptRecorded:
            return try RunLedgerMonitorProjector.reduce(
                projection,
                storedEvent: storedEvent
            )
        }
    }

}
