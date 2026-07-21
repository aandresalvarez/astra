import ASTRACore
import Foundation

enum RunLedgerProjectionStore {
    static func load(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerProjection {
        var executions: [RunBrokerExecutionID: RunLedgerExecutionProjection] = [:]
        let executionStatement = try connection.statement(
            """
            SELECT execution_id, manifest, authority_id, authority_epoch,
                   desired_execution, observed_execution,
                   desired_cancellation, observed_cancellation,
                   updated_at, created_sequence, updated_sequence
            FROM executions ORDER BY execution_id
            """,
            database: database
        )
        defer { executionStatement.finalize() }
        while try executionStatement.step() == .row {
            let executionID = RunBrokerExecutionID(
                rawValue: try uuid(executionStatement.text(at: 0), field: "execution_id")
            )
            let manifest = try RunLedgerCodec.decode(
                ExecutionLaunchManifest.self,
                from: executionStatement.blob(at: 1)
            )
            guard manifest.executionID == executionID else {
                throw RunLedgerError.projectionDrift("Execution manifest key does not match its row")
            }
            let authority = try authority(
                id: executionStatement.text(at: 2),
                epoch: executionStatement.int64(at: 3)
            )
            let control = try controlState(
                desiredExecution: executionStatement.text(at: 4),
                observedExecution: executionStatement.text(at: 5),
                desiredCancellation: executionStatement.text(at: 6),
                observedCancellation: executionStatement.text(at: 7)
            )
            guard executions[executionID] == nil else {
                throw RunLedgerError.projectionDrift("Duplicate execution projection key")
            }
            executions[executionID] = .init(
                manifest: manifest,
                authority: authority,
                control: control,
                updatedAt: Date(timeIntervalSince1970: executionStatement.double(at: 8)),
                createdSequence: executionStatement.int64(at: 9),
                updatedSequence: executionStatement.int64(at: 10)
            )
        }

        var operations: [RunBrokerOperationID: RunLedgerOperationProjection] = [:]
        let operationStatement = try connection.statement(
            """
            SELECT operation_id, store_id, execution_id, authority_id, authority_epoch,
                   effects, claim_state, tombstone_reason, tombstone_recorded_at,
                   created_at, updated_at, created_sequence, updated_sequence
            FROM operation_claims ORDER BY operation_id
            """,
            database: database
        )
        defer { operationStatement.finalize() }
        while try operationStatement.step() == .row {
            let operationID = RunBrokerOperationID(
                rawValue: try uuid(operationStatement.text(at: 0), field: "operation_id")
            )
            let storeID = RunBrokerStoreID(
                rawValue: try uuid(operationStatement.text(at: 1), field: "store_id")
            )
            let executionID = RunBrokerExecutionID(
                rawValue: try uuid(operationStatement.text(at: 2), field: "execution_id")
            )
            let claimAuthority = try authority(
                id: operationStatement.text(at: 3),
                epoch: operationStatement.int64(at: 4)
            )
            let effectsData = try operationStatement.blob(at: 5)
            let effects = try RunLedgerCodec.decode([ExecutionEffectClaim].self, from: effectsData)
            let normalizedEffects = try loadNormalizedEffects(
                operationID: operationID,
                connection: connection,
                database: database
            )
            guard effects == normalizedEffects else {
                throw RunLedgerError.projectionDrift(
                    "Normalized effect rows do not match the immutable claim payload"
                )
            }
            let state = try claimState(
                rawState: operationStatement.text(at: 6),
                reason: operationStatement.optionalText(at: 7),
                recordedAt: operationStatement.isNull(at: 8)
                    ? nil
                    : operationStatement.double(at: 8)
            )
            let record = DurableExecutionClaimRecord(
                storeID: storeID,
                operationID: operationID,
                executionID: executionID,
                authority: claimAuthority,
                effects: effects,
                state: state,
                createdAt: Date(timeIntervalSince1970: operationStatement.double(at: 9)),
                updatedAt: Date(timeIntervalSince1970: operationStatement.double(at: 10))
            )
            guard operations[operationID] == nil else {
                throw RunLedgerError.projectionDrift("Duplicate operation projection key")
            }
            operations[operationID] = .init(
                record: record,
                createdSequence: operationStatement.int64(at: 11),
                updatedSequence: operationStatement.int64(at: 12)
            )
        }

        let monitorDeadlines = try RunLedgerMonitorProjectionStore.load(
            connection: connection,
            database: database
        )
        let durable = RunLedgerProjection(
            executions: executions,
            operations: operations,
            monitorDeadlines: monitorDeadlines
        )
        return try loadRuntimeSwitchProjection(
            over: durable,
            connection: connection,
            database: database
        )
    }

    /// Runtime-switch policy intentionally has no mutable snapshot table. The
    /// journal is small at this boundary and remains the sole canonical owner;
    /// loading replays just the typed runtime-switch events under the same
    /// SQLite lock used by append CAS.
    ///
    /// Each historical event must be replayed against the execution state AS
    /// OF its journal position, never against the final durable state: legal
    /// later facts (an authority transfer, admission of the reserved
    /// replacement, a control transition) would otherwise retroactively
    /// invalidate recorded runtime-switch events and permanently brick every
    /// `projection()` load. The replay therefore interleaves, in full journal
    /// order, the only event kinds that mutate `executions` — registration,
    /// authority transfer, and control transitions — which is the only
    /// durable state the runtime-switch projector consults. Operation claims,
    /// monitor events, and supervisor observations never change `executions`,
    /// so excluding them keeps this load bounded by control-plane events
    /// while reproducing exactly the state the append-time projector saw;
    /// `assertIntegrity` cross-checks the result against a full journal
    /// replay on every open.
    private static func loadRuntimeSwitchProjection(
        over durable: RunLedgerProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerProjection {
        let statement = try connection.statement(
            """
            SELECT sequence, event_id, event_kind, aggregate_kind, aggregate_id, payload
            FROM events
            WHERE event_kind IN (
                'execution.admitted', 'execution.authority_transferred',
                'execution.control_transitioned',
                'runtime_switch.target_reserved', 'runtime_switch.admitted',
                'runtime_switch.policy_transitioned',
                'runtime_switch.completion_archived',
                'execution.force_challenge_recorded', 'execution.force_challenge_consumed'
            )
            ORDER BY sequence
            """,
            database: database
        )
        defer { statement.finalize() }
        var replayed = RunLedgerProjection()
        while try statement.step() == .row {
            guard let eventUUID = UUID(uuidString: try statement.text(at: 1)) else {
                throw RunLedgerError.projectionDrift("Runtime-switch event ID is invalid")
            }
            let eventID = RunLedgerEventID(rawValue: eventUUID)
            let envelope = try RunLedgerCodec.envelope(
                eventID: eventID,
                from: statement.blob(at: 5)
            )
            guard try statement.text(at: 2) == envelope.event.kind,
                  try statement.text(at: 3) == envelope.event.aggregateKind,
                  try statement.text(at: 4) == envelope.event.aggregateID else {
                throw RunLedgerError.projectionDrift("Runtime-switch event index differs from payload")
            }
            let storedEvent = StoredRunLedgerEvent(
                sequence: statement.int64(at: 0),
                envelope: envelope
            )
            let storeID = try durable.executions.values.first?.manifest.storeID
                ?? runtimeSwitchStoreID(from: envelope)
            switch envelope.event {
            case .executionAdmitted(let manifest, _):
                replayed = try RunLedgerAdmissionProjector.register(
                    manifest: manifest,
                    projection: replayed,
                    storedEvent: storedEvent,
                    storeID: storeID
                ).preservingRuntimeSwitch(from: replayed)
            case .executionAuthorityTransferred, .executionControlTransitioned:
                replayed = try RunLedgerProjector.reduce(
                    replayed,
                    storedEvent: storedEvent,
                    storeID: storeID
                ).preservingRuntimeSwitch(from: replayed)
            default:
                replayed = try RunLedgerProjector.reduceRuntimeSwitch(
                    replayed,
                    storedEvent: storedEvent,
                    storeID: storeID
                )
            }
        }
        return durable.preservingRuntimeSwitch(from: replayed)
    }

    private static func runtimeSwitchStoreID(
        from envelope: RunLedgerEventEnvelope
    ) throws -> RunBrokerStoreID {
        switch envelope.event {
        case .runtimeSwitchTargetReserved(let request, _, _):
            return request.intent.expectedSource.storeID
        case .runtimeSwitchAdmitted(let request, _, _, _):
            return request.intent.expectedSource.storeID
        case .runtimeSwitchPolicyTransitioned(let expected, let next, _):
            if let storeID = next.record?.request.intent.expectedSource.storeID
                ?? expected.record?.request.intent.expectedSource.storeID {
                return storeID
            }
            throw RunLedgerError.projectionDrift("Runtime-switch policy event has no store binding")
        case .runtimeSwitchCompletionArchived(let expected, _):
            guard let storeID = expected.record?.request.intent.expectedSource.storeID else {
                throw RunLedgerError.projectionDrift(
                    "Runtime-switch archive event has no store binding"
                )
            }
            return storeID
        case .executionForceChallengeRecorded, .executionForceChallengeConsumed:
            throw RunLedgerError.projectionDrift(
                "Execution-force event has no admitted execution store binding"
            )
        default:
            throw RunLedgerError.projectionDrift("Unexpected event in runtime-switch projection")
        }
    }

    private static func loadNormalizedEffects(
        operationID: RunBrokerOperationID,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> [ExecutionEffectClaim] {
        let statement = try connection.statement(
            """
            SELECT effect_index, scope, access FROM effect_claims
            WHERE operation_id = ? ORDER BY effect_index
            """,
            bindings: [.text(RunLedgerSchema.uuid(operationID.rawValue))],
            database: database
        )
        defer { statement.finalize() }
        var effects: [ExecutionEffectClaim] = []
        while try statement.step() == .row {
            guard statement.int64(at: 0) == Int64(effects.count) else {
                throw RunLedgerError.projectionDrift("Effect indexes are not contiguous")
            }
            let scope = try RunLedgerCodec.decode(
                ExecutionEffectScope.self,
                from: statement.blob(at: 1)
            )
            guard let access = ExecutionEffectAccess(rawValue: try statement.text(at: 2)) else {
                throw RunLedgerError.projectionDrift("Effect access value is invalid")
            }
            effects.append(.init(scope: scope, access: access))
        }
        return effects
    }

    private static func authority(id: String, epoch: Int64) throws -> RunBrokerAuthority {
        guard epoch >= 1 else {
            throw RunLedgerError.projectionDrift("Authority epoch is not positive")
        }
        return .init(
            id: .init(rawValue: try uuid(id, field: "authority_id")),
            epoch: .init(rawValue: UInt64(epoch))
        )
    }

    private static func controlState(
        desiredExecution: String,
        observedExecution: String,
        desiredCancellation: String,
        observedCancellation: String
    ) throws -> ExecutionControlState {
        guard let desiredExecution = ExecutionDesiredState(rawValue: desiredExecution),
              let observedExecution = ExecutionObservedState(rawValue: observedExecution),
              let desiredCancellation = ExecutionCancellationIntent(rawValue: desiredCancellation),
              let observedCancellation = ExecutionCancellationObservedState(rawValue: observedCancellation) else {
            throw RunLedgerError.projectionDrift("Execution control projection contains an invalid state")
        }
        return .init(
            desiredExecution: desiredExecution,
            observedExecution: observedExecution,
            desiredCancellation: desiredCancellation,
            observedCancellation: observedCancellation
        )
    }

    private static func claimState(
        rawState: String,
        reason: String?,
        recordedAt: Double?
    ) throws -> DurableExecutionClaimState {
        switch (rawState, reason, recordedAt) {
        case ("active", nil, nil):
            return .active
        case ("tombstoned", let reason?, let recordedAt?):
            guard let reason = DurableExecutionClaimTombstoneReason(rawValue: reason) else {
                throw RunLedgerError.projectionDrift("Tombstone reason is invalid")
            }
            return .tombstoned(.init(
                reason: reason,
                recordedAt: Date(timeIntervalSince1970: recordedAt)
            ))
        default:
            throw RunLedgerError.projectionDrift("Claim state and tombstone fields disagree")
        }
    }

    private static func uuid(_ value: String, field: String) throws -> UUID {
        guard let value = UUID(uuidString: value) else {
            throw RunLedgerError.projectionDrift("Projection field \(field) is not a UUID")
        }
        return value
    }

}
