import ASTRACore
import Foundation

/// Pure admission projection. Compound launch admission reuses the same
/// registration and claim policies but publishes both rows at one sequence.
enum RunLedgerAdmissionProjector {
    static func admit(
        manifest: ExecutionLaunchManifest,
        primaryOperationID: RunBrokerOperationID,
        projection: RunLedgerProjection,
        storedEvent: StoredRunLedgerEvent,
        storeID: RunBrokerStoreID
    ) throws -> RunLedgerProjection {
        let registered = try register(
            manifest: manifest,
            projection: projection,
            storedEvent: storedEvent,
            storeID: storeID
        )
        return try claim(
            operationID: primaryOperationID,
            executionID: manifest.executionID,
            authority: manifest.authority,
            effects: manifest.declaredEffects,
            projection: registered,
            storedEvent: storedEvent,
            storeID: storeID
        )
    }

    /// Registration without the primary effect claim. Besides atomic
    /// admission above, the projection store's runtime-switch replay uses
    /// this to rebuild the exact as-of `executions` history: replaying
    /// cross-execution effect admission there against a partial operations
    /// view could reject a legal journal, and the runtime-switch projector
    /// never consults `operations`.
    static func register(
        manifest: ExecutionLaunchManifest,
        projection: RunLedgerProjection,
        storedEvent: StoredRunLedgerEvent,
        storeID: RunBrokerStoreID
    ) throws -> RunLedgerProjection {
        guard manifest.storeID == storeID else {
            throw RunLedgerError.storeIdentityMismatch(expected: storeID, found: manifest.storeID)
        }
        try validateAuthority(manifest.authority)
        try validateEffects(manifest.declaredEffects)
        guard storedEvent.envelope.occurredAt >= manifest.createdAt else {
            throw RunLedgerError.invalidEvent("Execution registration predates its launch manifest")
        }
        guard projection.executions[manifest.executionID] == nil else {
            throw RunLedgerError.aggregateKeyReuse(
                kind: "execution",
                id: RunLedgerSchema.uuid(manifest.executionID.rawValue)
            )
        }
        var executions = projection.executions
        executions[manifest.executionID] = .init(
            manifest: manifest,
            authority: manifest.authority,
            control: .init(),
            updatedAt: storedEvent.envelope.occurredAt,
            createdSequence: storedEvent.sequence,
            updatedSequence: storedEvent.sequence
        )
        return .init(
            executions: executions,
            operations: projection.operations,
            monitorDeadlines: projection.monitorDeadlines
        )
    }

    static func claim(
        operationID: RunBrokerOperationID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        effects: [ExecutionEffectClaim],
        projection: RunLedgerProjection,
        storedEvent: StoredRunLedgerEvent,
        storeID: RunBrokerStoreID
    ) throws -> RunLedgerProjection {
        guard let execution = projection.executions[executionID] else {
            throw RunLedgerError.missingExecution(executionID)
        }
        try validateAuthority(authority)
        try validateEffects(effects)
        try requireCurrentAuthority(authority, execution: execution)
        guard storedEvent.envelope.occurredAt >= execution.updatedAt else {
            throw RunLedgerError.invalidEvent("Operation claim predates the current execution state")
        }
        let declared = Set(execution.manifest.declaredEffects)
        guard effects.allSatisfy(declared.contains) else {
            throw RunLedgerError.invalidEvent(
                "Operation effects exceed the immutable launch manifest declaration"
            )
        }
        let request = ExecutionAdmissionRequest(
            storeID: storeID,
            operationID: operationID,
            executionID: executionID,
            authority: authority,
            effects: effects
        )
        let records = projection.operations.values.map(\.record)
        switch ExecutionAdmissionPolicy.decide(request: request, existingRecords: records) {
        case .admitted:
            break
        case .alreadyAdmitted:
            throw RunLedgerError.aggregateKeyReuse(
                kind: "operation",
                id: RunLedgerSchema.uuid(operationID.rawValue)
            )
        case .denied(let denials):
            throw RunLedgerError.admissionDenied(denials)
        }
        var operations = projection.operations
        operations[operationID] = .init(
            record: .init(
                storeID: storeID,
                operationID: operationID,
                executionID: executionID,
                authority: authority,
                effects: effects,
                createdAt: storedEvent.envelope.occurredAt
            ),
            createdSequence: storedEvent.sequence,
            updatedSequence: storedEvent.sequence
        )
        return .init(
            executions: projection.executions,
            operations: operations,
            monitorDeadlines: projection.monitorDeadlines
        )
    }

    static func validateAuthority(_ authority: RunBrokerAuthority) throws {
        guard authority.epoch.rawValue >= 1,
              authority.epoch.rawValue <= UInt64(Int64.max) else {
            throw RunLedgerError.invalidEvent("Authority epoch is outside SQLite's positive Int64 range")
        }
    }

    static func requireCurrentAuthority(
        _ authority: RunBrokerAuthority,
        execution: RunLedgerExecutionProjection
    ) throws {
        if authority.epoch < execution.authority.epoch {
            throw RunLedgerError.claimTransitionRejected(.staleEpochRejected)
        }
        if authority.epoch == execution.authority.epoch,
           authority.id != execution.authority.id {
            throw RunLedgerError.claimTransitionRejected(.authorityConflict)
        }
        guard authority == execution.authority else {
            throw RunLedgerError.invalidEvent("Authority transfer must be journaled before use")
        }
    }

    static func requireNextAuthority(
        _ incoming: RunBrokerAuthority,
        after current: RunBrokerAuthority
    ) throws {
        guard current.epoch.rawValue < UInt64(Int64.max),
              incoming.epoch.rawValue == current.epoch.rawValue + 1 else {
            throw RunLedgerError.invalidEvent(
                "Authority transfer must advance exactly one epoch"
            )
        }
    }

    private static func validateEffects(_ effects: [ExecutionEffectClaim]) throws {
        guard !effects.isEmpty else {
            throw RunLedgerError.invalidEvent("Effects must be declared explicitly")
        }
        guard Set(effects).count == effects.count else {
            throw RunLedgerError.invalidEvent("Duplicate effect declarations are not canonical")
        }
        for effect in effects {
            guard effect.isKnownAndWellFormed else {
                throw RunLedgerError.invalidEvent("Unknown or malformed effects cannot enter the ledger")
            }
            guard !effect.scope.isComputeOnly || effect.access == .shared else {
                throw RunLedgerError.invalidEvent("Compute-only effects cannot be exclusive")
            }
        }
    }
}
