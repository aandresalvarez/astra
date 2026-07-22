import ASTRACore
import Foundation
import RunBrokerPolicy

public struct RunLedgerExecutionProjection: Equatable, Sendable {
    public let manifest: ExecutionLaunchManifest
    public let authority: RunBrokerAuthority
    public let control: ExecutionControlState
    public let updatedAt: Date
    public let createdSequence: Int64
    public let updatedSequence: Int64

    public init(
        manifest: ExecutionLaunchManifest,
        authority: RunBrokerAuthority,
        control: ExecutionControlState,
        updatedAt: Date,
        createdSequence: Int64,
        updatedSequence: Int64
    ) {
        self.manifest = manifest
        self.authority = authority
        self.control = control
        self.updatedAt = updatedAt
        self.createdSequence = createdSequence
        self.updatedSequence = updatedSequence
    }
}

public struct RunLedgerOperationProjection: Equatable, Sendable {
    public let record: DurableExecutionClaimRecord
    public let createdSequence: Int64
    public let updatedSequence: Int64

    public init(
        record: DurableExecutionClaimRecord,
        createdSequence: Int64,
        updatedSequence: Int64
    ) {
        self.record = record
        self.createdSequence = createdSequence
        self.updatedSequence = updatedSequence
    }
}

public struct RunLedgerProjection: Equatable, Sendable {
    public let executions: [RunBrokerExecutionID: RunLedgerExecutionProjection]
    public let operations: [RunBrokerOperationID: RunLedgerOperationProjection]
    public let monitorDeadlines: [RunBrokerOperationID: RunLedgerMonitorDeadline]
    /// Runtime-switch policy is reduced from the append-only journal on every
    /// projection load. This deliberately avoids a second mutable policy owner:
    /// restart recovery and live admission observe the same canonical facts.
    public let runtimeSwitchPolicyState: RuntimeSwitchPolicyState
    public let runtimeSwitchReservations: [RuntimeSwitchEvidenceID: RuntimeSwitchTargetReservation]
    public let runtimeSwitchRequestBindings: [RuntimeSwitchRequestID: RunLedgerRuntimeSwitchRequestBinding]
    public let runtimeSwitchTargetReservations: [RunBrokerExecutionID: RuntimeSwitchEvidenceID]
    public let runtimeSwitchEffectBindings: [RuntimeSwitchEffectID: RuntimeSwitchRequestDigest]
    /// Retained across completion archive so a broker-issued force challenge
    /// can never collide with direct execution-control challenge authority.
    public let runtimeSwitchForceChallenges: [RuntimeForceChallengeID: RuntimeForceSwitchChallenge]
    public let runtimeSwitchArchivedRecords: [RuntimeSwitchRequestID: RuntimeSwitchRecord]
    public let executionForceChallenges: [RuntimeForceChallengeID: ExecutionForceChallenge]
    public let executionForceConsumptions: [RuntimeForceChallengeID: ExecutionForceChallengeConsumption]
    public let executionForceRequestBindings: [ExecutionForceRequestDigest: RuntimeForceChallengeID]
    public let executionForceEffectBindings: [RuntimeSwitchEffectID: ExecutionForceRequestDigest]

    public init(
        executions: [RunBrokerExecutionID: RunLedgerExecutionProjection] = [:],
        operations: [RunBrokerOperationID: RunLedgerOperationProjection] = [:],
        monitorDeadlines: [RunBrokerOperationID: RunLedgerMonitorDeadline] = [:],
        runtimeSwitchPolicyState: RuntimeSwitchPolicyState = .empty,
        runtimeSwitchReservations: [RuntimeSwitchEvidenceID: RuntimeSwitchTargetReservation] = [:],
        runtimeSwitchRequestBindings: [RuntimeSwitchRequestID: RunLedgerRuntimeSwitchRequestBinding] = [:],
        runtimeSwitchTargetReservations: [RunBrokerExecutionID: RuntimeSwitchEvidenceID] = [:],
        runtimeSwitchEffectBindings: [RuntimeSwitchEffectID: RuntimeSwitchRequestDigest] = [:],
        runtimeSwitchForceChallenges: [RuntimeForceChallengeID: RuntimeForceSwitchChallenge] = [:],
        runtimeSwitchArchivedRecords: [RuntimeSwitchRequestID: RuntimeSwitchRecord] = [:],
        executionForceChallenges: [RuntimeForceChallengeID: ExecutionForceChallenge] = [:],
        executionForceConsumptions: [RuntimeForceChallengeID: ExecutionForceChallengeConsumption] = [:],
        executionForceRequestBindings: [ExecutionForceRequestDigest: RuntimeForceChallengeID] = [:],
        executionForceEffectBindings: [RuntimeSwitchEffectID: ExecutionForceRequestDigest] = [:]
    ) {
        self.executions = executions
        self.operations = operations
        self.monitorDeadlines = monitorDeadlines
        self.runtimeSwitchPolicyState = runtimeSwitchPolicyState
        self.runtimeSwitchReservations = runtimeSwitchReservations
        self.runtimeSwitchRequestBindings = runtimeSwitchRequestBindings
        self.runtimeSwitchTargetReservations = runtimeSwitchTargetReservations
        self.runtimeSwitchEffectBindings = runtimeSwitchEffectBindings
        self.runtimeSwitchForceChallenges = runtimeSwitchForceChallenges
        self.runtimeSwitchArchivedRecords = runtimeSwitchArchivedRecords
        self.executionForceChallenges = executionForceChallenges
        self.executionForceConsumptions = executionForceConsumptions
        self.executionForceRequestBindings = executionForceRequestBindings
        self.executionForceEffectBindings = executionForceEffectBindings
    }
}

public struct RunLedgerRuntimeSwitchRequestBinding: Codable, Equatable, Hashable, Sendable {
    public let request: ActiveRuntimeSwitchRequest
    public let requestDigest: RuntimeSwitchRequestDigest
    public let reservationID: RuntimeSwitchEvidenceID

    public init(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        reservationID: RuntimeSwitchEvidenceID
    ) {
        self.request = request
        self.requestDigest = requestDigest
        self.reservationID = reservationID
    }
}

extension RunLedgerProjection {
    func preservingRuntimeSwitch(from source: RunLedgerProjection) -> Self {
        .init(
            executions: executions,
            operations: operations,
            monitorDeadlines: monitorDeadlines,
            runtimeSwitchPolicyState: source.runtimeSwitchPolicyState,
            runtimeSwitchReservations: source.runtimeSwitchReservations,
            runtimeSwitchRequestBindings: source.runtimeSwitchRequestBindings,
            runtimeSwitchTargetReservations: source.runtimeSwitchTargetReservations,
            runtimeSwitchEffectBindings: source.runtimeSwitchEffectBindings,
            runtimeSwitchForceChallenges: source.runtimeSwitchForceChallenges,
            runtimeSwitchArchivedRecords: source.runtimeSwitchArchivedRecords,
            executionForceChallenges: source.executionForceChallenges,
            executionForceConsumptions: source.executionForceConsumptions,
            executionForceRequestBindings: source.executionForceRequestBindings,
            executionForceEffectBindings: source.executionForceEffectBindings
        )
    }

    func replacingRuntimeSwitch(
        policyState: RuntimeSwitchPolicyState? = nil,
        reservations: [RuntimeSwitchEvidenceID: RuntimeSwitchTargetReservation]? = nil,
        requestBindings: [RuntimeSwitchRequestID: RunLedgerRuntimeSwitchRequestBinding]? = nil,
        targetReservations: [RunBrokerExecutionID: RuntimeSwitchEvidenceID]? = nil,
        effectBindings: [RuntimeSwitchEffectID: RuntimeSwitchRequestDigest]? = nil,
        forceChallenges: [RuntimeForceChallengeID: RuntimeForceSwitchChallenge]? = nil,
        archivedRecords: [RuntimeSwitchRequestID: RuntimeSwitchRecord]? = nil
    ) -> Self {
        .init(
            executions: executions,
            operations: operations,
            monitorDeadlines: monitorDeadlines,
            runtimeSwitchPolicyState: policyState ?? runtimeSwitchPolicyState,
            runtimeSwitchReservations: reservations ?? runtimeSwitchReservations,
            runtimeSwitchRequestBindings: requestBindings ?? runtimeSwitchRequestBindings,
            runtimeSwitchTargetReservations: targetReservations ?? runtimeSwitchTargetReservations,
            runtimeSwitchEffectBindings: effectBindings ?? runtimeSwitchEffectBindings,
            runtimeSwitchForceChallenges: forceChallenges ?? runtimeSwitchForceChallenges,
            runtimeSwitchArchivedRecords: archivedRecords ?? runtimeSwitchArchivedRecords,
            executionForceChallenges: executionForceChallenges,
            executionForceConsumptions: executionForceConsumptions,
            executionForceRequestBindings: executionForceRequestBindings,
            executionForceEffectBindings: executionForceEffectBindings
        )
    }

    func replacingExecutionForce(
        challenges: [RuntimeForceChallengeID: ExecutionForceChallenge]? = nil,
        consumptions: [RuntimeForceChallengeID: ExecutionForceChallengeConsumption]? = nil,
        requests: [ExecutionForceRequestDigest: RuntimeForceChallengeID]? = nil,
        effects: [RuntimeSwitchEffectID: ExecutionForceRequestDigest]? = nil
    ) -> Self {
        .init(
            executions: executions,
            operations: operations,
            monitorDeadlines: monitorDeadlines,
            runtimeSwitchPolicyState: runtimeSwitchPolicyState,
            runtimeSwitchReservations: runtimeSwitchReservations,
            runtimeSwitchRequestBindings: runtimeSwitchRequestBindings,
            runtimeSwitchTargetReservations: runtimeSwitchTargetReservations,
            runtimeSwitchEffectBindings: runtimeSwitchEffectBindings,
            runtimeSwitchForceChallenges: runtimeSwitchForceChallenges,
            runtimeSwitchArchivedRecords: runtimeSwitchArchivedRecords,
            executionForceChallenges: challenges ?? executionForceChallenges,
            executionForceConsumptions: consumptions ?? executionForceConsumptions,
            executionForceRequestBindings: requests ?? executionForceRequestBindings,
            executionForceEffectBindings: effects ?? executionForceEffectBindings
        )
    }
}
