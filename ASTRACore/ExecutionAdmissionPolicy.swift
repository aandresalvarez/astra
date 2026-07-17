import Foundation

public struct ExecutionAdmissionRequest: Equatable, Sendable {
    public let storeID: RunBrokerStoreID
    public let operationID: RunBrokerOperationID
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let effects: [ExecutionEffectClaim]

    public init(
        storeID: RunBrokerStoreID,
        operationID: RunBrokerOperationID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        effects: [ExecutionEffectClaim]
    ) {
        self.storeID = storeID
        self.operationID = operationID
        self.executionID = executionID
        self.authority = authority
        self.effects = effects
    }
}

public struct ExecutionEffectConflict: Equatable, Sendable {
    public let existingOperationID: RunBrokerOperationID
    public let existingExecutionID: RunBrokerExecutionID
    public let existingEffect: ExecutionEffectClaim
    public let requestedEffect: ExecutionEffectClaim

    public init(
        existingOperationID: RunBrokerOperationID,
        existingExecutionID: RunBrokerExecutionID,
        existingEffect: ExecutionEffectClaim,
        requestedEffect: ExecutionEffectClaim
    ) {
        self.existingOperationID = existingOperationID
        self.existingExecutionID = existingExecutionID
        self.existingEffect = existingEffect
        self.requestedEffect = requestedEffect
    }
}

public enum ExecutionAdmissionDenial: Equatable, Sendable {
    case effectsUndeclared
    case unknownOrMalformedEffect(index: Int)
    case computeOnlyMustBeShared(index: Int)
    case operationTombstoned(RunBrokerOperationID)
    case operationIdentityConflict(RunBrokerOperationID)
    case duplicateOperationRecords(RunBrokerOperationID)
    case staleAuthorityEpoch(
        executionID: RunBrokerExecutionID,
        current: RunBrokerAuthorityEpoch,
        requested: RunBrokerAuthorityEpoch
    )
    case authorityConflict(executionID: RunBrokerExecutionID)
    case authorityTransferRequired(executionID: RunBrokerExecutionID)
    case effectConflict(ExecutionEffectConflict)
}

public enum ExecutionAdmissionDecision: Equatable, Sendable {
    case admitted
    case alreadyAdmitted
    case denied([ExecutionAdmissionDenial])
}

/// Pure fail-closed admission policy. A new execution can start only when all
/// effect scopes are known and every overlapping active claim is compatible.
/// Shared/shared overlap is allowed; any exclusive overlap is rejected.
public enum ExecutionAdmissionPolicy {
    public static func decide(
        request: ExecutionAdmissionRequest,
        existingRecords: [DurableExecutionClaimRecord]
    ) -> ExecutionAdmissionDecision {
        var denials = requestDenials(request)
        var exactActiveRecordFound = false

        let operationRecords = existingRecords.filter { $0.operationID == request.operationID }
        if operationRecords.count > 1 {
            denials.append(.duplicateOperationRecords(request.operationID))
        } else if let operationRecord = operationRecords.first {
            if !operationRecord.holdsEffects {
                denials.append(.operationTombstoned(operationRecord.operationID))
            } else if operationRecord.storeID == request.storeID,
                      operationRecord.executionID == request.executionID,
                      operationRecord.effects == request.effects {
                switch compareAuthority(
                    request.authority,
                    with: operationRecord.authority,
                    executionID: operationRecord.executionID
                ) {
                case .compatible:
                    exactActiveRecordFound = true
                case .denied(let denial):
                    denials.append(denial)
                }
            } else {
                denials.append(.operationIdentityConflict(operationRecord.operationID))
            }
        }

        for record in existingRecords {
            // Operation identity is immutable and was handled above. Never
            // reinterpret a same-ID record as a new, disjoint operation.
            if record.operationID == request.operationID { continue }
            guard record.holdsEffects else { continue }

            if record.executionID == request.executionID {
                switch compareAuthority(request.authority, with: record.authority, executionID: record.executionID) {
                case .compatible:
                    break
                case .denied(let denial):
                    denials.append(denial)
                }
                // Multiple operations under the same fenced execution may
                // overlap; they still have exactly one write-capable executor.
                continue
            }

            for existingEffect in record.effects {
                for requestedEffect in request.effects where effectsConflict(
                    existingEffect,
                    requestedEffect
                ) {
                    denials.append(.effectConflict(.init(
                        existingOperationID: record.operationID,
                        existingExecutionID: record.executionID,
                        existingEffect: existingEffect,
                        requestedEffect: requestedEffect
                    )))
                }
            }
        }

        guard denials.isEmpty else { return .denied(denials) }
        return exactActiveRecordFound ? .alreadyAdmitted : .admitted
    }

    private enum AuthorityComparison {
        case compatible
        case denied(ExecutionAdmissionDenial)
    }

    private static func compareAuthority(
        _ requested: RunBrokerAuthority,
        with current: RunBrokerAuthority,
        executionID: RunBrokerExecutionID
    ) -> AuthorityComparison {
        if requested.epoch < current.epoch {
            return .denied(.staleAuthorityEpoch(
                executionID: executionID,
                current: current.epoch,
                requested: requested.epoch
            ))
        }
        if requested.epoch == current.epoch {
            return requested.id == current.id
                ? .compatible
                : .denied(.authorityConflict(executionID: executionID))
        }
        return .denied(.authorityTransferRequired(executionID: executionID))
    }

    private static func requestDenials(_ request: ExecutionAdmissionRequest) -> [ExecutionAdmissionDenial] {
        guard !request.effects.isEmpty else { return [.effectsUndeclared] }
        return request.effects.enumerated().compactMap { index, effect in
            if !effect.isKnownAndWellFormed {
                return .unknownOrMalformedEffect(index: index)
            }
            if effect.scope.isComputeOnly && effect.access != .shared {
                return .computeOnlyMustBeShared(index: index)
            }
            return nil
        }
    }

    private static func effectsConflict(
        _ existing: ExecutionEffectClaim,
        _ requested: ExecutionEffectClaim
    ) -> Bool {
        guard existing.scope.overlaps(requested.scope) else { return false }
        if !existing.isKnownAndWellFormed || !requested.isKnownAndWellFormed {
            return true
        }
        return existing.access == .exclusive || requested.access == .exclusive
    }
}
