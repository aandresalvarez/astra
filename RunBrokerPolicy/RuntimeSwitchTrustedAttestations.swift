import ASTRACore
import Foundation

public enum RuntimeSwitchTrustedAttestationError: Error, Equatable, Sendable {
    case requestBindingMismatch
    case sourceBindingMismatch
    case targetBindingMismatch
    case supervisorBindingMismatch
    case checkpointNotSafe
    case invalidCapability
    case challengeExpired
    case challengeNotYetValid
    case confirmationBindingMismatch
    case terminalEvidenceRequired
    case staleReservation
}

/// Durable broker reservation for the exact replacement execution. The
/// non-public constructor is reached only after the ledger atomically reserves
/// a fresh execution ID for this request and target manifest.
public struct RuntimeSwitchTargetReservation: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let reservationID: RuntimeSwitchEvidenceID
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let taskID: UUID
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let ledgerSequence: UInt64

    package init(
        reservationID: RuntimeSwitchEvidenceID,
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        taskID: UUID,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        ledgerSequence: UInt64
    ) {
        self.reservationID = reservationID
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.installationID = installationID
        self.storeID = storeID
        self.taskID = taskID
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.ledgerSequence = ledgerSequence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, reservationID, requestID, requestDigest, installationID, storeID
        case taskID, targetExecutionID, targetManifestSHA256, ledgerSequence
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch target reservation"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch target reservation"
        )
        self.init(
            reservationID: try container.decode(RuntimeSwitchEvidenceID.self, forKey: .reservationID),
            requestID: try container.decode(RuntimeSwitchRequestID.self, forKey: .requestID),
            requestDigest: try container.decode(RuntimeSwitchRequestDigest.self, forKey: .requestDigest),
            installationID: try container.decode(RunBrokerInstallationID.self, forKey: .installationID),
            storeID: try container.decode(RunBrokerStoreID.self, forKey: .storeID),
            taskID: try container.decode(UUID.self, forKey: .taskID),
            targetExecutionID: try container.decode(RunBrokerExecutionID.self, forKey: .targetExecutionID),
            targetManifestSHA256: try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .targetManifestSHA256),
            ledgerSequence: try container.decode(UInt64.self, forKey: .ledgerSequence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(reservationID, forKey: .reservationID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(installationID, forKey: .installationID)
        try container.encode(storeID, forKey: .storeID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(targetExecutionID, forKey: .targetExecutionID)
        try container.encode(targetManifestSHA256, forKey: .targetManifestSHA256)
        try container.encode(ledgerSequence, forKey: .ledgerSequence)
    }
}

/// Canonical ledger snapshot used only to admit a new client request. It is
/// intentionally non-Codable and can be minted only inside this Swift package;
/// architecture fitness further restricts minting to the broker service.
public struct VerifiedRuntimeSwitchAdmission: Equatable, Sendable {
    public let request: ActiveRuntimeSwitchRequest
    public let requestDigest: RuntimeSwitchRequestDigest
    public let source: RuntimeSwitchSourceFence
    public let targetReservation: RuntimeSwitchTargetReservation
    public let sourceLedgerSequence: UInt64
    public let lifecycle: RuntimeSwitchExecutionLifecycle
    public let observedCancellation: ExecutionCancellationObservedState
    public let forceChallenge: RuntimeForceSwitchChallenge?

    package init(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        source: RuntimeSwitchSourceFence,
        targetReservation: RuntimeSwitchTargetReservation,
        sourceLedgerSequence: UInt64,
        lifecycle: RuntimeSwitchExecutionLifecycle,
        observedCancellation: ExecutionCancellationObservedState,
        forceChallenge: RuntimeForceSwitchChallenge? = nil
    ) throws {
        guard request.intent.expectedSource == source else {
            throw RuntimeSwitchTrustedAttestationError.sourceBindingMismatch
        }
        let target = request.intent.target
        guard targetReservation.requestID == request.intent.requestID,
              targetReservation.requestDigest == requestDigest,
              targetReservation.installationID == source.installationID,
              targetReservation.storeID == source.storeID,
              targetReservation.taskID == source.taskID,
              targetReservation.targetExecutionID == target.manifest.executionID,
              targetReservation.targetManifestSHA256 == target.manifestSHA256 else {
            throw RuntimeSwitchTrustedAttestationError.targetBindingMismatch
        }
        guard targetReservation.ledgerSequence > sourceLedgerSequence else {
            throw RuntimeSwitchTrustedAttestationError.staleReservation
        }
        switch request {
        case .gracefulHandoff:
            guard forceChallenge == nil else {
                throw RuntimeSwitchTrustedAttestationError.requestBindingMismatch
            }
        case .forceTermination:
            guard let forceChallenge,
                  forceChallenge.requestID == request.intent.requestID,
                  forceChallenge.requestDigest == requestDigest else {
                throw RuntimeSwitchTrustedAttestationError.requestBindingMismatch
            }
        }
        self.request = request
        self.requestDigest = requestDigest
        self.source = source
        self.targetReservation = targetReservation
        self.sourceLedgerSequence = sourceLedgerSequence
        self.lifecycle = lifecycle
        self.observedCancellation = observedCancellation
        self.forceChallenge = forceChallenge
    }
}

/// Pair-specific provider/supervisor proof for one exact safe checkpoint.
/// The issuer must authenticate the supervisor and verify that both adapters
/// support this exact source-runtime -> target-runtime handoff pair.
public struct VerifiedRuntimeSwitchCheckpointAttestation: Equatable, Sendable {
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let effectID: RuntimeSwitchEffectID
    public let fence: RuntimeSwitchCheckpointFence

    package init(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        effectID: RuntimeSwitchEffectID,
        checkpointID: RuntimeSwitchCheckpointID,
        checkpointGeneration: UInt64,
        ledgerSequence: UInt64,
        effectWatermark: UInt64,
        toolOperationWatermark: UInt64,
        inFlightEffectCount: UInt,
        inFlightToolOperationCount: UInt,
        providerContinuation: RuntimeSwitchProtocolIdentity,
        supervisor: RuntimeSwitchSupervisorFence
    ) throws {
        let source = request.intent.expectedSource
        guard request.intent.mode == .graceful else {
            throw RuntimeSwitchTrustedAttestationError.requestBindingMismatch
        }
        guard inFlightEffectCount == 0, inFlightToolOperationCount == 0 else {
            throw RuntimeSwitchTrustedAttestationError.checkpointNotSafe
        }
        guard supervisor.installationID == source.installationID,
              supervisor.storeID == source.storeID,
              supervisor.executionID == source.executionID,
              supervisor.authority == source.authority else {
            throw RuntimeSwitchTrustedAttestationError.supervisorBindingMismatch
        }
        self.requestID = request.intent.requestID
        self.requestDigest = requestDigest
        self.effectID = effectID
        self.fence = .init(
            checkpointID: checkpointID,
            checkpointGeneration: checkpointGeneration,
            ledgerSequence: ledgerSequence,
            effectWatermark: effectWatermark,
            toolOperationWatermark: toolOperationWatermark,
            source: source,
            targetManifestSHA256: request.intent.target.manifestSHA256,
            providerContinuation: providerContinuation,
            supervisor: supervisor
        )
    }
}

/// Exact backend authority for one cancellation mode. There is no generic
/// `canCancel` bit: immediate and graceful authority are separate attestations.
public struct VerifiedRuntimeSwitchBackendCapability: Equatable, Sendable {
    public let capabilityID: RuntimeSwitchEvidenceID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let source: RuntimeSwitchSourceFence
    public let cancellationIntent: ExecutionCancellationIntent

    package init(
        capabilityID: RuntimeSwitchEvidenceID,
        requestDigest: RuntimeSwitchRequestDigest,
        source: RuntimeSwitchSourceFence,
        cancellationIntent: ExecutionCancellationIntent
    ) throws {
        guard cancellationIntent == .graceful || cancellationIntent == .immediate else {
            throw RuntimeSwitchTrustedAttestationError.invalidCapability
        }
        self.capabilityID = capabilityID
        self.requestDigest = requestDigest
        self.source = source
        self.cancellationIntent = cancellationIntent
    }
}

/// Broker-verified response to a ledger-stored, single-use force challenge.
/// Callers submit a response; only this verified result reaches the policy.
public struct VerifiedRuntimeForceConfirmation: Equatable, Sendable {
    public let confirmationID: RuntimeSwitchEvidenceID
    public let challengeID: RuntimeForceChallengeID
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let actorID: RuntimeSwitchActorID
    public let sessionID: UUID
    public let audit: RuntimeForceSwitchAudit
    public let source: RuntimeSwitchSourceFence
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let confirmedAt: Date
    public let effectID: RuntimeSwitchEffectID

    package init(
        confirmationID: RuntimeSwitchEvidenceID,
        challenge: RuntimeForceSwitchChallenge,
        request: ForceRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        confirmedAt: Date,
        serverNow: Date,
        effectID: RuntimeSwitchEffectID
    ) throws {
        guard confirmedAt.timeIntervalSince1970.isFinite, serverNow.timeIntervalSince1970.isFinite else {
            throw RuntimeSwitchTrustedAttestationError.confirmationBindingMismatch
        }
        guard serverNow >= challenge.issuedAt else {
            throw RuntimeSwitchTrustedAttestationError.challengeNotYetValid
        }
        guard serverNow <= challenge.expiresAt else {
            throw RuntimeSwitchTrustedAttestationError.challengeExpired
        }
        guard challenge.requestID == request.intent.requestID,
              challenge.requestDigest == requestDigest,
              challenge.actorID == actorID,
              challenge.sessionID == sessionID,
              confirmedAt >= challenge.issuedAt,
              confirmedAt <= serverNow else {
            throw RuntimeSwitchTrustedAttestationError.confirmationBindingMismatch
        }
        self.confirmationID = confirmationID
        self.challengeID = challenge.challengeID
        self.requestID = request.intent.requestID
        self.requestDigest = requestDigest
        self.actorID = actorID
        self.sessionID = sessionID
        self.audit = request.audit
        self.source = request.intent.expectedSource
        self.targetManifestSHA256 = request.intent.target.manifestSHA256
        self.confirmedAt = confirmedAt
        self.effectID = effectID
    }
}

/// Fresh canonical dispatch snapshot. For graceful effects it carries the
/// newly authenticated exact checkpoint fence; immediate effects carry nil.
public struct VerifiedRuntimeSwitchDispatchSnapshot: Equatable, Sendable {
    public let effectID: RuntimeSwitchEffectID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let source: RuntimeSwitchSourceFence
    public let lifecycle: RuntimeSwitchExecutionLifecycle
    public let observedCancellation: ExecutionCancellationObservedState
    public let checkpointFence: RuntimeSwitchCheckpointFence?

    package init(
        effectID: RuntimeSwitchEffectID,
        requestDigest: RuntimeSwitchRequestDigest,
        source: RuntimeSwitchSourceFence,
        lifecycle: RuntimeSwitchExecutionLifecycle,
        observedCancellation: ExecutionCancellationObservedState,
        checkpointFence: RuntimeSwitchCheckpointFence?
    ) {
        self.effectID = effectID
        self.requestDigest = requestDigest
        self.source = source
        self.lifecycle = lifecycle
        self.observedCancellation = observedCancellation
        self.checkpointFence = checkpointFence
    }
}

public struct VerifiedRuntimeSwitchControlAcceptance: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let effectID: RuntimeSwitchEffectID
    public let source: RuntimeSwitchSourceFence
    public let ledgerSequence: UInt64

    package init(
        evidenceID: RuntimeSwitchEvidenceID,
        effectID: RuntimeSwitchEffectID,
        source: RuntimeSwitchSourceFence,
        ledgerSequence: UInt64
    ) {
        self.evidenceID = evidenceID
        self.effectID = effectID
        self.source = source
        self.ledgerSequence = ledgerSequence
    }
}

public struct RuntimeSwitchTerminalFence: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let evidenceID: RuntimeSwitchEvidenceID
    public let source: RuntimeSwitchSourceFence
    public let observedState: ExecutionObservedState
    public let ledgerSequence: UInt64

    package init(
        evidenceID: RuntimeSwitchEvidenceID,
        source: RuntimeSwitchSourceFence,
        observedState: ExecutionObservedState,
        ledgerSequence: UInt64
    ) throws {
        guard observedState.isAuthoritativelyTerminal else {
            throw RuntimeSwitchTrustedAttestationError.terminalEvidenceRequired
        }
        self.evidenceID = evidenceID
        self.source = source
        self.observedState = observedState
        self.ledgerSequence = ledgerSequence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, evidenceID, source, observedState, ledgerSequence }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch terminal fence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch terminal fence"
        )
        try self.init(
            evidenceID: container.decode(RuntimeSwitchEvidenceID.self, forKey: .evidenceID),
            source: container.decode(RuntimeSwitchSourceFence.self, forKey: .source),
            observedState: container.decode(ExecutionObservedState.self, forKey: .observedState),
            ledgerSequence: container.decode(UInt64.self, forKey: .ledgerSequence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(evidenceID, forKey: .evidenceID)
        try container.encode(source, forKey: .source)
        try container.encode(observedState, forKey: .observedState)
        try container.encode(ledgerSequence, forKey: .ledgerSequence)
    }
}

public struct VerifiedRuntimeSwitchTerminalAttestation: Equatable, Sendable {
    public let terminalFence: RuntimeSwitchTerminalFence
    public let replacementEffectID: RuntimeSwitchEffectID

    package init(
        evidenceID: RuntimeSwitchEvidenceID,
        source: RuntimeSwitchSourceFence,
        observedState: ExecutionObservedState,
        ledgerSequence: UInt64,
        replacementEffectID: RuntimeSwitchEffectID
    ) throws {
        self.terminalFence = try .init(
            evidenceID: evidenceID,
            source: source,
            observedState: observedState,
            ledgerSequence: ledgerSequence
        )
        self.replacementEffectID = replacementEffectID
    }
}

public struct VerifiedRuntimeSwitchReplacementDispatchSnapshot: Equatable, Sendable {
    public let effectID: RuntimeSwitchEffectID
    public let sourceTerminal: RuntimeSwitchTerminalFence
    public let targetReservation: RuntimeSwitchTargetReservation
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256

    package init(
        effectID: RuntimeSwitchEffectID,
        sourceTerminal: RuntimeSwitchTerminalFence,
        targetReservation: RuntimeSwitchTargetReservation,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    ) {
        self.effectID = effectID
        self.sourceTerminal = sourceTerminal
        self.targetReservation = targetReservation
        self.targetManifestSHA256 = targetManifestSHA256
    }
}

public struct VerifiedRuntimeSwitchReplacementAcceptance: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let effectID: RuntimeSwitchEffectID
    public let targetReservationID: RuntimeSwitchEvidenceID
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let ledgerSequence: UInt64

    package init(
        evidenceID: RuntimeSwitchEvidenceID,
        effectID: RuntimeSwitchEffectID,
        targetReservationID: RuntimeSwitchEvidenceID,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        ledgerSequence: UInt64
    ) {
        self.evidenceID = evidenceID
        self.effectID = effectID
        self.targetReservationID = targetReservationID
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.ledgerSequence = ledgerSequence
    }
}

public struct VerifiedRuntimeSwitchReplacementRunningAttestation: Equatable, Sendable {
    public let evidenceID: RuntimeSwitchEvidenceID
    public let targetReservationID: RuntimeSwitchEvidenceID
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let ledgerSequence: UInt64

    package init(
        evidenceID: RuntimeSwitchEvidenceID,
        targetReservationID: RuntimeSwitchEvidenceID,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        ledgerSequence: UInt64
    ) {
        self.evidenceID = evidenceID
        self.targetReservationID = targetReservationID
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.ledgerSequence = ledgerSequence
    }
}

/// Broker CAS witness used to roll a completed switch out of the active slot.
/// In-doubt and pending records have no path to this attestation.
public struct VerifiedRuntimeSwitchCompletionRollover: Equatable, Sendable {
    public let archiveEvidenceID: RuntimeSwitchEvidenceID
    public let requestID: RuntimeSwitchRequestID
    public let completionEvidenceID: RuntimeSwitchEvidenceID
    public let targetReservationID: RuntimeSwitchEvidenceID
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let ledgerSequence: UInt64

    package init(
        archiveEvidenceID: RuntimeSwitchEvidenceID,
        requestID: RuntimeSwitchRequestID,
        completionEvidenceID: RuntimeSwitchEvidenceID,
        targetReservationID: RuntimeSwitchEvidenceID,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        ledgerSequence: UInt64
    ) {
        self.archiveEvidenceID = archiveEvidenceID
        self.requestID = requestID
        self.completionEvidenceID = completionEvidenceID
        self.targetReservationID = targetReservationID
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.ledgerSequence = ledgerSequence
    }
}
