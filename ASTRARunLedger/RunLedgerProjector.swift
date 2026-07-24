import ASTRACore
import Foundation
import RunBrokerPolicy

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
        do {
            return try ASTRACanonicalJSON.encode(value)
        } catch {
            throw RunLedgerError.invalidEvent("Canonical JSON encoding failed: \(error)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try ASTRACanonicalJSON.decode(type, from: data)
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
            var operations = projection.operations
            var monitorDeadlines = projection.monitorDeadlines
            if let tombstoneReason = terminalClaimTombstoneReason(
                for: reduction.state.observedExecution
            ) {
                // Terminal execution truth and release of every effect claim
                // are one projection transaction. Requiring a later caller to
                // append operationTombstoned leaves claims permanently active
                // after a broker crash between those separate actions.
                for (operationID, operation) in projection.operations
                    where operation.record.executionID == executionID
                        && operation.record.holdsEffects {
                    guard occurredAt >= operation.record.updatedAt else {
                        throw RunLedgerError.invalidEvent(
                            "Terminal execution evidence predates its operation claim"
                        )
                    }
                    let claim = DurableExecutionClaimReducer.reduce(
                        operation.record,
                        event: .tombstone(
                            authority: authority,
                            reason: tombstoneReason,
                            at: occurredAt
                        )
                    )
                    guard claim.disposition == .applied else {
                        throw RunLedgerError.claimTransitionRejected(claim.disposition)
                    }
                    operations[operationID] = .init(
                        record: claim.record,
                        createdSequence: operation.createdSequence,
                        updatedSequence: storedEvent.sequence
                    )
                    monitorDeadlines.removeValue(forKey: operationID)
                }
            }
            return .init(
                executions: executions,
                operations: operations,
                monitorDeadlines: monitorDeadlines
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

        case .runtimeSwitchTargetReserved,
             .runtimeSwitchAdmitted,
             .runtimeSwitchPolicyTransitioned,
             .runtimeSwitchCompletionArchived,
             .executionForceChallengeRecorded,
             .executionForceChallengeConsumed:
            return try reduceRuntimeSwitch(projection, storedEvent: storedEvent, storeID: storeID)
        }
    }

    private static func terminalClaimTombstoneReason(
        for state: ExecutionObservedState
    ) -> DurableExecutionClaimTombstoneReason? {
        switch state {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        default: nil
        }
    }

    static func reduceRuntimeSwitch(
        _ projection: RunLedgerProjection,
        storedEvent: StoredRunLedgerEvent,
        storeID: RunBrokerStoreID
    ) throws -> RunLedgerProjection {
        switch storedEvent.envelope.event {
        case .runtimeSwitchTargetReserved(let request, let digest, let reservationID):
            let source = request.intent.expectedSource
            let target = request.intent.target
            guard source.storeID == storeID,
                  target.manifest.storeID == storeID,
                  source.installationID == target.manifest.installationID,
                  source.taskID == target.manifest.taskID,
                  source.executionID != target.manifest.executionID,
                  storedEvent.sequence > 0 else {
                throw RunLedgerError.invalidEvent("Runtime-switch reservation identity is invalid")
            }
            if let execution = projection.executions[source.executionID] {
                guard execution.authority == source.authority,
                      execution.manifest.installationID == source.installationID,
                      execution.manifest.storeID == source.storeID,
                      execution.manifest.taskID == source.taskID else {
                    throw RunLedgerError.invalidEvent("Runtime-switch source fence is stale")
                }
            }
            let binding = RunLedgerRuntimeSwitchRequestBinding(
                request: request,
                requestDigest: digest,
                reservationID: reservationID
            )
            if let existing = projection.runtimeSwitchRequestBindings[request.intent.requestID] {
                guard existing == binding else {
                    throw RunLedgerError.invalidEvent("Runtime-switch request ID is globally bound to different input")
                }
                guard projection.runtimeSwitchReservations[reservationID] != nil else {
                    throw RunLedgerError.projectionDrift("Runtime-switch request binding lost its reservation")
                }
                return projection
            }
            guard projection.runtimeSwitchReservations[reservationID] == nil else {
                throw RunLedgerError.invalidEvent("Runtime-switch reservation ID is already bound")
            }
            guard projection.runtimeSwitchTargetReservations[target.manifest.executionID] == nil,
                  projection.executions[target.manifest.executionID] == nil else {
                throw RunLedgerError.invalidEvent("Runtime-switch target execution is already reserved or admitted")
            }
            guard let sequence = UInt64(exactly: storedEvent.sequence) else {
                throw RunLedgerError.invalidEvent("Runtime-switch reservation sequence is invalid")
            }
            let reservation = RuntimeSwitchTargetReservation(
                reservationID: reservationID,
                requestID: request.intent.requestID,
                requestDigest: digest,
                installationID: source.installationID,
                storeID: source.storeID,
                taskID: source.taskID,
                targetExecutionID: target.manifest.executionID,
                targetManifestSHA256: target.manifestSHA256,
                ledgerSequence: sequence
            )
            var reservations = projection.runtimeSwitchReservations
            reservations[reservationID] = reservation
            var requests = projection.runtimeSwitchRequestBindings
            requests[request.intent.requestID] = binding
            var targets = projection.runtimeSwitchTargetReservations
            targets[target.manifest.executionID] = reservationID
            return projection.replacingRuntimeSwitch(
                reservations: reservations,
                requestBindings: requests,
                targetReservations: targets
            )

        case .runtimeSwitchAdmitted(
            let request, let digest, let reservationID, let forceChallenge
        ):
            let source = request.intent.expectedSource
            let target = request.intent.target
            guard storedEvent.sequence > 0,
                  source.storeID == storeID,
                  target.manifest.storeID == storeID,
                  source.installationID == target.manifest.installationID,
                  source.taskID == target.manifest.taskID,
                  source.executionID != target.manifest.executionID,
                  try RuntimeSwitchDigests.request(request) == digest,
                  try RuntimeSwitchDigests.manifest(target.manifest) == target.manifestSHA256,
                  let targetPolicy = target.manifest.supervisionPolicy,
                  try RunBrokerAuthorityDerivation.runtimeSwitchTarget(
                    installationID: target.manifest.installationID,
                    storeID: target.manifest.storeID,
                    requestID: request.intent.requestID,
                    executionID: target.manifest.executionID,
                    taskID: target.manifest.taskID,
                    configuration: target.manifest.configuration,
                    declaredEffects: target.manifest.declaredEffects,
                    supervisionPolicy: targetPolicy,
                    createdAt: target.manifest.createdAt
                  ) == target.manifest.authority,
                  let execution = projection.executions[source.executionID],
                  execution.authority == source.authority,
                  execution.manifest.installationID == source.installationID,
                  execution.manifest.storeID == source.storeID,
                  execution.manifest.taskID == source.taskID,
                  execution.manifest.configuration.configurationRevision
                    == source.configurationRevision,
                  try RuntimeSwitchDigests.manifest(execution.manifest)
                    == source.manifestSHA256 else {
                throw RunLedgerError.invalidEvent(
                    "Runtime-switch atomic admission identity or digest is invalid"
                )
            }
            let binding = RunLedgerRuntimeSwitchRequestBinding(
                request: request,
                requestDigest: digest,
                reservationID: reservationID
            )
            guard projection.runtimeSwitchRequestBindings[request.intent.requestID] == nil,
                  projection.runtimeSwitchReservations[reservationID] == nil,
                  projection.runtimeSwitchTargetReservations[target.manifest.executionID] == nil,
                  projection.executions[target.manifest.executionID] == nil else {
                throw RunLedgerError.invalidEvent(
                    "Runtime-switch admission identity is already bound"
                )
            }
            switch (request, forceChallenge) {
            case (.gracefulHandoff, nil):
                break
            case (.forceTermination, let challenge?):
                guard challenge.requestID == request.intent.requestID,
                      challenge.requestDigest == digest,
                      challenge.issuedAt == storedEvent.envelope.occurredAt,
                      projection.runtimeSwitchForceChallenges[challenge.challengeID] == nil,
                      projection.executionForceChallenges[challenge.challengeID] == nil else {
                    throw RunLedgerError.invalidEvent(
                        "Runtime-switch force challenge is stale or globally rebound"
                    )
                }
            default:
                throw RunLedgerError.invalidEvent(
                    "Runtime-switch force challenge does not match request mode"
                )
            }
            guard let sequence = UInt64(exactly: storedEvent.sequence),
                  let sourceSequence = UInt64(exactly: execution.updatedSequence) else {
                throw RunLedgerError.invalidEvent("Runtime-switch admission sequence is invalid")
            }
            let reservation = RuntimeSwitchTargetReservation(
                reservationID: reservationID,
                requestID: request.intent.requestID,
                requestDigest: digest,
                installationID: source.installationID,
                storeID: source.storeID,
                taskID: source.taskID,
                targetExecutionID: target.manifest.executionID,
                targetManifestSHA256: target.manifestSHA256,
                ledgerSequence: sequence
            )
            let verified = try VerifiedRuntimeSwitchAdmission(
                request: request,
                requestDigest: digest,
                source: source,
                targetReservation: reservation,
                sourceLedgerSequence: sourceSequence,
                lifecycle: runtimeSwitchLifecycle(execution.control),
                observedCancellation: execution.control.observedCancellation,
                forceChallenge: forceChallenge
            )
            let reduction = RuntimeSwitchPolicy.admit(
                projection.runtimeSwitchPolicyState,
                request: request,
                verified: verified
            )
            guard reduction.blockedReason == nil,
                  reduction.state != projection.runtimeSwitchPolicyState else {
                throw RunLedgerError.invalidEvent("Runtime-switch policy admission was rejected")
            }
            var reservations = projection.runtimeSwitchReservations
            reservations[reservationID] = reservation
            var requests = projection.runtimeSwitchRequestBindings
            requests[request.intent.requestID] = binding
            var targets = projection.runtimeSwitchTargetReservations
            targets[target.manifest.executionID] = reservationID
            var challenges = projection.runtimeSwitchForceChallenges
            if let forceChallenge {
                challenges[forceChallenge.challengeID] = forceChallenge
            }
            return projection.replacingRuntimeSwitch(
                policyState: reduction.state,
                reservations: reservations,
                requestBindings: requests,
                targetReservations: targets,
                forceChallenges: challenges
            )

        case .runtimeSwitchPolicyTransitioned(let expected, let next, let effectID):
            guard projection.runtimeSwitchPolicyState == expected else {
                throw RunLedgerError.invalidEvent("Runtime-switch policy compare-and-swap failed")
            }
            guard next != expected else {
                throw RunLedgerError.invalidEvent("Runtime-switch policy transition must change state")
            }
            let bindingRecord = next.record ?? expected.record
            guard let bindingRecord,
                  let binding = projection.runtimeSwitchRequestBindings[
                    bindingRecord.request.intent.requestID
                  ],
                  binding.request == bindingRecord.request,
                  binding.requestDigest == bindingRecord.requestDigest,
                  binding.reservationID == bindingRecord.targetReservation.reservationID,
                  projection.runtimeSwitchReservations[binding.reservationID]
                    == bindingRecord.targetReservation else {
                throw RunLedgerError.invalidEvent("Runtime-switch policy state is not bound to a reservation")
            }

            var effects = projection.runtimeSwitchEffectBindings
            var forceChallenges = projection.runtimeSwitchForceChallenges
            if let challenge = next.record?.forceChallenge {
                guard projection.executionForceChallenges[challenge.challengeID] == nil else {
                    throw RunLedgerError.invalidEvent(
                        "Legacy runtime-switch challenge conflicts with execution control"
                    )
                }
                if let existing = forceChallenges[challenge.challengeID] {
                    guard existing == challenge else {
                        throw RunLedgerError.invalidEvent(
                            "Legacy runtime-switch challenge ID is globally rebound"
                        )
                    }
                } else {
                    forceChallenges[challenge.challengeID] = challenge
                }
            }
            if let effectID {
                let recordedEffect = next.record?.controlEffect?.effectID == effectID
                    || next.record?.replacementEffect?.effectID == effectID
                guard recordedEffect else {
                    throw RunLedgerError.invalidEvent("Runtime-switch effect ID is absent from next policy state")
                }
                guard projection.executionForceEffectBindings[effectID] == nil else {
                    throw RunLedgerError.invalidEvent("Runtime-switch effect ID conflicts with execution control")
                }
                if let existing = effects[effectID] {
                    guard existing == bindingRecord.requestDigest else {
                        throw RunLedgerError.invalidEvent("Runtime-switch effect ID is globally bound to another request")
                    }
                } else {
                    effects[effectID] = bindingRecord.requestDigest
                }
            } else {
                let oldControl = expected.record?.controlEffect?.effectID
                let oldReplacement = expected.record?.replacementEffect?.effectID
                guard next.record?.controlEffect?.effectID == oldControl,
                      next.record?.replacementEffect?.effectID == oldReplacement else {
                    throw RunLedgerError.invalidEvent("Runtime-switch effect transition omitted its effect fence")
                }
            }
            return projection.replacingRuntimeSwitch(
                policyState: next,
                effectBindings: effects,
                forceChallenges: forceChallenges
            )

        case .runtimeSwitchCompletionArchived(let expected, let archiveEvidenceID):
            guard projection.runtimeSwitchPolicyState == expected,
                  let record = expected.record,
                  record.progress == .completed,
                  let replacement = record.replacementEffect,
                  let completionEvidenceID = record.completionEvidenceID,
                  storedEvent.sequence > 0 else {
                throw RunLedgerError.invalidEvent(
                    "Runtime-switch completion archive compare-and-swap failed"
                )
            }
            let rollover = VerifiedRuntimeSwitchCompletionRollover(
                archiveEvidenceID: archiveEvidenceID,
                requestID: record.request.intent.requestID,
                completionEvidenceID: completionEvidenceID,
                targetReservationID: record.targetReservation.reservationID,
                targetExecutionID: replacement.target.manifest.executionID,
                targetManifestSHA256: replacement.target.manifestSHA256,
                ledgerSequence: UInt64(storedEvent.sequence)
            )
            let reduction = RuntimeSwitchPolicy.archiveCompleted(expected, rollover: rollover)
            guard reduction.blockedReason == nil,
                  reduction.disposition == .archived,
                  reduction.state != expected else {
                throw RunLedgerError.invalidEvent(
                    "Runtime-switch completion archive evidence is invalid"
                )
            }
            var history = projection.runtimeSwitchArchivedRecords
            let requestID = record.request.intent.requestID
            if let existing = history[requestID] {
                guard existing == record else {
                    throw RunLedgerError.invalidEvent(
                        "Runtime-switch archived request ID is globally rebound"
                    )
                }
            } else {
                history[requestID] = record
            }
            return projection.replacingRuntimeSwitch(
                policyState: reduction.state,
                archivedRecords: history
            )

        case .executionForceChallengeRecorded(let challenge):
            guard let execution = projection.executions[challenge.executionID],
                  execution.authority == challenge.authority else {
                throw RunLedgerError.invalidEvent("Execution-force challenge fence is stale")
            }
            if let existingID = projection.executionForceRequestBindings[challenge.requestDigest] {
                guard existingID == challenge.challengeID,
                      projection.executionForceChallenges[existingID] == challenge else {
                    throw RunLedgerError.invalidEvent("Execution-force request digest is globally rebound")
                }
                return projection
            }
            guard projection.executionForceChallenges[challenge.challengeID] == nil,
                  projection.runtimeSwitchForceChallenges[challenge.challengeID] == nil else {
                throw RunLedgerError.invalidEvent("Execution-force challenge ID is globally rebound")
            }
            var challenges = projection.executionForceChallenges
            challenges[challenge.challengeID] = challenge
            var requests = projection.executionForceRequestBindings
            requests[challenge.requestDigest] = challenge.challengeID
            return projection.replacingExecutionForce(
                challenges: challenges,
                requests: requests
            )

        case .executionForceChallengeConsumed(
            let challengeID, let requestDigest, let effectID,
            let actorID, let sessionID, let confirmedAt
        ):
            guard let challenge = projection.executionForceChallenges[challengeID],
                  challenge.requestDigest == requestDigest,
                  challenge.actorID == actorID,
                  challenge.sessionID == sessionID,
                  confirmedAt >= challenge.issuedAt,
                  confirmedAt <= challenge.expiresAt else {
                throw RunLedgerError.invalidEvent("Execution-force confirmation does not match its challenge")
            }
            let consumption = try ExecutionForceChallengeConsumption(
                challenge: challenge,
                effectID: effectID,
                confirmedAt: confirmedAt
            )
            if let existing = projection.executionForceConsumptions[challengeID] {
                guard existing == consumption else {
                    throw RunLedgerError.invalidEvent("Execution-force challenge was already consumed differently")
                }
                return projection
            }
            guard projection.executionForceEffectBindings[effectID] == nil,
                  projection.runtimeSwitchEffectBindings[effectID] == nil else {
                throw RunLedgerError.invalidEvent("Execution-force effect ID is globally rebound")
            }
            var consumptions = projection.executionForceConsumptions
            consumptions[challengeID] = consumption
            var effects = projection.executionForceEffectBindings
            effects[effectID] = requestDigest
            return projection.replacingExecutionForce(
                consumptions: consumptions,
                effects: effects
            )

        default:
            throw RunLedgerError.invalidEvent("Non runtime-switch event reached runtime-switch projector")
        }
    }

    private static func runtimeSwitchLifecycle(
        _ state: ExecutionControlState
    ) -> RuntimeSwitchExecutionLifecycle {
        if state.observedExecution.isAuthoritativelyTerminal { return .terminal }
        if state.observedExecution == .inDoubt { return .inDoubt }
        if state.desiredCancellation != .none { return .cancellationPending }
        switch state.observedExecution {
        case .registered: return .registered
        case .starting: return .starting
        case .running: return .running
        case .completed, .failed, .cancelled: return .terminal
        case .inDoubt: return .inDoubt
        }
    }

}
