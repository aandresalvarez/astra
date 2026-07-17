import ASTRACore
import Foundation

public enum RuntimeSwitchBlockedReason: String, Codable, Equatable, Sendable {
    case unverifiedAdmission = "unverified_admission"
    case requestIDConflict = "request_id_conflict"
    case switchAlreadyPending = "switch_already_pending"
    case executionIdentityMismatch = "execution_identity_mismatch"
    case staleAuthority = "stale_authority"
    case staleManifest = "stale_manifest"
    case targetManifestInvalid = "target_manifest_invalid"
    case executionNotControllable = "execution_not_controllable"
    case concurrentCancellation = "concurrent_cancellation"
    case offline
    case inDoubt = "in_doubt"
    case forceChallengeRequired = "force_challenge_required"
    case forceConfirmationMismatch = "force_confirmation_mismatch"
    case forceCapabilityRequired = "force_capability_required"
    case gracefulCapabilityRequired = "graceful_capability_required"
    case checkpointMismatch = "checkpoint_mismatch"
    case dispatchFenceMismatch = "dispatch_fence_mismatch"
    case effectIDConflict = "effect_id_conflict"
    case terminalEvidenceRequired = "terminal_evidence_required"
    case terminalEvidenceMismatch = "terminal_evidence_mismatch"
    case replacementEvidenceMismatch = "replacement_evidence_mismatch"
    case completionRolloverMismatch = "completion_rollover_mismatch"
    case staleReservation = "stale_reservation"
    case invalidTransition = "invalid_transition"
}

public enum RuntimeSwitchProgress: String, Codable, Equatable, Hashable, Sendable {
    case waitingForCheckpoint = "waiting_for_checkpoint"
    case confirmationRequired = "confirmation_required"
    case controlDispatchPending = "control_dispatch_pending"
    case awaitingSourceTerminal = "awaiting_source_terminal"
    case replacementDispatchPending = "replacement_dispatch_pending"
    case awaitingReplacementRunning = "awaiting_replacement_running"
    case completed
    case inDoubt = "in_doubt"
}

public struct RuntimeSwitchControlEffect: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let effectID: RuntimeSwitchEffectID
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let source: RuntimeSwitchSourceFence
    public let target: RuntimeSwitchResolvedTarget
    public let cancellationIntent: ExecutionCancellationIntent
    public let checkpointFence: RuntimeSwitchCheckpointFence?
    public let confirmationID: RuntimeSwitchEvidenceID?
    public let capabilityID: RuntimeSwitchEvidenceID?

    fileprivate init(
        effectID: RuntimeSwitchEffectID,
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        source: RuntimeSwitchSourceFence,
        target: RuntimeSwitchResolvedTarget,
        cancellationIntent: ExecutionCancellationIntent,
        checkpointFence: RuntimeSwitchCheckpointFence?,
        confirmationID: RuntimeSwitchEvidenceID?,
        capabilityID: RuntimeSwitchEvidenceID?
    ) {
        self.effectID = effectID
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.source = source
        self.target = target
        self.cancellationIntent = cancellationIntent
        self.checkpointFence = checkpointFence
        self.confirmationID = confirmationID
        self.capabilityID = capabilityID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, effectID, requestID, requestDigest, source, target
        case cancellationIntent, checkpointFence, confirmationID, capabilityID
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch control effect"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch control effect"
        )
        let intent = try container.decode(ExecutionCancellationIntent.self, forKey: .cancellationIntent)
        let checkpoint = try container.decodeIfPresent(RuntimeSwitchCheckpointFence.self, forKey: .checkpointFence)
        let confirmation = try container.decodeIfPresent(RuntimeSwitchEvidenceID.self, forKey: .confirmationID)
        let capability = try container.decodeIfPresent(RuntimeSwitchEvidenceID.self, forKey: .capabilityID)
        guard (intent == .graceful && checkpoint != nil && confirmation == nil && capability == nil)
                || (intent == .immediate && checkpoint == nil && confirmation != nil && capability != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cancellationIntent,
                in: container,
                debugDescription: "Control effect evidence must exactly match graceful or immediate intent"
            )
        }
        self.init(
            effectID: try container.decode(RuntimeSwitchEffectID.self, forKey: .effectID),
            requestID: try container.decode(RuntimeSwitchRequestID.self, forKey: .requestID),
            requestDigest: try container.decode(RuntimeSwitchRequestDigest.self, forKey: .requestDigest),
            source: try container.decode(RuntimeSwitchSourceFence.self, forKey: .source),
            target: try container.decode(RuntimeSwitchResolvedTarget.self, forKey: .target),
            cancellationIntent: intent,
            checkpointFence: checkpoint,
            confirmationID: confirmation,
            capabilityID: capability
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(effectID, forKey: .effectID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(source, forKey: .source)
        try container.encode(target, forKey: .target)
        try container.encode(cancellationIntent, forKey: .cancellationIntent)
        try container.encodeIfPresent(checkpointFence, forKey: .checkpointFence)
        try container.encodeIfPresent(confirmationID, forKey: .confirmationID)
        try container.encodeIfPresent(capabilityID, forKey: .capabilityID)
    }
}

public struct RuntimeSwitchReplacementEffect: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let effectID: RuntimeSwitchEffectID
    public let requestID: RuntimeSwitchRequestID
    public let sourceTerminal: RuntimeSwitchTerminalFence
    public let target: RuntimeSwitchResolvedTarget

    fileprivate init(
        effectID: RuntimeSwitchEffectID,
        requestID: RuntimeSwitchRequestID,
        sourceTerminal: RuntimeSwitchTerminalFence,
        target: RuntimeSwitchResolvedTarget
    ) {
        self.effectID = effectID
        self.requestID = requestID
        self.sourceTerminal = sourceTerminal
        self.target = target
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, effectID, requestID, sourceTerminal, target }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch replacement effect"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch replacement effect"
        )
        self.init(
            effectID: try container.decode(RuntimeSwitchEffectID.self, forKey: .effectID),
            requestID: try container.decode(RuntimeSwitchRequestID.self, forKey: .requestID),
            sourceTerminal: try container.decode(RuntimeSwitchTerminalFence.self, forKey: .sourceTerminal),
            target: try container.decode(RuntimeSwitchResolvedTarget.self, forKey: .target)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(effectID, forKey: .effectID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(sourceTerminal, forKey: .sourceTerminal)
        try container.encode(target, forKey: .target)
    }
}

public struct RuntimeSwitchRecord: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let request: ActiveRuntimeSwitchRequest
    public let requestDigest: RuntimeSwitchRequestDigest
    public let sourceLedgerSequence: UInt64
    public let targetReservation: RuntimeSwitchTargetReservation
    public let progress: RuntimeSwitchProgress
    public let forceChallenge: RuntimeForceSwitchChallenge?
    public let controlEffect: RuntimeSwitchControlEffect?
    public let controlAcceptanceID: RuntimeSwitchEvidenceID?
    public let controlAcceptanceLedgerSequence: UInt64?
    public let replacementEffect: RuntimeSwitchReplacementEffect?
    public let replacementAcceptanceID: RuntimeSwitchEvidenceID?
    public let replacementAcceptanceLedgerSequence: UInt64?
    public let completionEvidenceID: RuntimeSwitchEvidenceID?
    public let completionLedgerSequence: UInt64?

    fileprivate init(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        sourceLedgerSequence: UInt64,
        targetReservation: RuntimeSwitchTargetReservation,
        progress: RuntimeSwitchProgress,
        forceChallenge: RuntimeForceSwitchChallenge? = nil,
        controlEffect: RuntimeSwitchControlEffect? = nil,
        controlAcceptanceID: RuntimeSwitchEvidenceID? = nil,
        controlAcceptanceLedgerSequence: UInt64? = nil,
        replacementEffect: RuntimeSwitchReplacementEffect? = nil,
        replacementAcceptanceID: RuntimeSwitchEvidenceID? = nil,
        replacementAcceptanceLedgerSequence: UInt64? = nil,
        completionEvidenceID: RuntimeSwitchEvidenceID? = nil,
        completionLedgerSequence: UInt64? = nil
    ) {
        self.request = request
        self.requestDigest = requestDigest
        self.sourceLedgerSequence = sourceLedgerSequence
        self.targetReservation = targetReservation
        self.progress = progress
        self.forceChallenge = forceChallenge
        self.controlEffect = controlEffect
        self.controlAcceptanceID = controlAcceptanceID
        self.controlAcceptanceLedgerSequence = controlAcceptanceLedgerSequence
        self.replacementEffect = replacementEffect
        self.replacementAcceptanceID = replacementAcceptanceID
        self.replacementAcceptanceLedgerSequence = replacementAcceptanceLedgerSequence
        self.completionEvidenceID = completionEvidenceID
        self.completionLedgerSequence = completionLedgerSequence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, request, requestDigest, sourceLedgerSequence, targetReservation, progress
        case forceChallenge, controlEffect
        case controlAcceptanceID, controlAcceptanceLedgerSequence, replacementEffect
        case replacementAcceptanceID, replacementAcceptanceLedgerSequence
        case completionEvidenceID, completionLedgerSequence
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch record"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch record"
        )
        let value = Self.init(
            request: try container.decode(ActiveRuntimeSwitchRequest.self, forKey: .request),
            requestDigest: try container.decode(RuntimeSwitchRequestDigest.self, forKey: .requestDigest),
            sourceLedgerSequence: try container.decode(UInt64.self, forKey: .sourceLedgerSequence),
            targetReservation: try container.decode(RuntimeSwitchTargetReservation.self, forKey: .targetReservation),
            progress: try container.decode(RuntimeSwitchProgress.self, forKey: .progress),
            forceChallenge: try container.decodeIfPresent(RuntimeForceSwitchChallenge.self, forKey: .forceChallenge),
            controlEffect: try container.decodeIfPresent(RuntimeSwitchControlEffect.self, forKey: .controlEffect),
            controlAcceptanceID: try container.decodeIfPresent(RuntimeSwitchEvidenceID.self, forKey: .controlAcceptanceID),
            controlAcceptanceLedgerSequence: try container.decodeIfPresent(
                UInt64.self,
                forKey: .controlAcceptanceLedgerSequence
            ),
            replacementEffect: try container.decodeIfPresent(RuntimeSwitchReplacementEffect.self, forKey: .replacementEffect),
            replacementAcceptanceID: try container.decodeIfPresent(RuntimeSwitchEvidenceID.self, forKey: .replacementAcceptanceID),
            replacementAcceptanceLedgerSequence: try container.decodeIfPresent(
                UInt64.self,
                forKey: .replacementAcceptanceLedgerSequence
            ),
            completionEvidenceID: try container.decodeIfPresent(
                RuntimeSwitchEvidenceID.self,
                forKey: .completionEvidenceID
            ),
            completionLedgerSequence: try container.decodeIfPresent(UInt64.self, forKey: .completionLedgerSequence)
        )
        guard value.isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .progress,
                in: container,
                debugDescription: "Runtime switch record fields do not match its durable progress"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(request, forKey: .request)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(sourceLedgerSequence, forKey: .sourceLedgerSequence)
        try container.encode(targetReservation, forKey: .targetReservation)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(forceChallenge, forKey: .forceChallenge)
        try container.encodeIfPresent(controlEffect, forKey: .controlEffect)
        try container.encodeIfPresent(controlAcceptanceID, forKey: .controlAcceptanceID)
        try container.encodeIfPresent(controlAcceptanceLedgerSequence, forKey: .controlAcceptanceLedgerSequence)
        try container.encodeIfPresent(replacementEffect, forKey: .replacementEffect)
        try container.encodeIfPresent(replacementAcceptanceID, forKey: .replacementAcceptanceID)
        try container.encodeIfPresent(
            replacementAcceptanceLedgerSequence,
            forKey: .replacementAcceptanceLedgerSequence
        )
        try container.encodeIfPresent(completionEvidenceID, forKey: .completionEvidenceID)
        try container.encodeIfPresent(completionLedgerSequence, forKey: .completionLedgerSequence)
    }

    private var isValid: Bool {
        let target = request.intent.target
        guard targetReservation.requestID == request.intent.requestID,
              targetReservation.requestDigest == requestDigest,
              targetReservation.installationID == request.intent.expectedSource.installationID,
              targetReservation.storeID == request.intent.expectedSource.storeID,
              targetReservation.taskID == request.intent.expectedSource.taskID,
              targetReservation.targetExecutionID == target.manifest.executionID,
              targetReservation.targetManifestSHA256 == target.manifestSHA256,
              targetReservation.ledgerSequence > sourceLedgerSequence else {
            return false
        }
        guard (controlAcceptanceID == nil) == (controlAcceptanceLedgerSequence == nil),
              (replacementAcceptanceID == nil) == (replacementAcceptanceLedgerSequence == nil),
              (completionEvidenceID == nil) == (completionLedgerSequence == nil) else {
            return false
        }
        switch request.intent.mode {
        case .graceful:
            guard forceChallenge == nil else { return false }
        case .immediate:
            guard let forceChallenge,
                  forceChallenge.requestID == request.intent.requestID,
                  forceChallenge.requestDigest == requestDigest else { return false }
        }
        var controlPredecessorSequence = targetReservation.ledgerSequence
        if let controlEffect {
            guard controlEffect.source == request.intent.expectedSource,
                  controlEffect.target == request.intent.target,
                  controlEffect.requestID == request.intent.requestID,
                  controlEffect.requestDigest == requestDigest,
                  controlEffect.cancellationIntent == request.intent.mode.cancellationIntent else {
                return false
            }
            switch request.intent.mode {
            case .graceful:
                guard let checkpoint = controlEffect.checkpointFence,
                      checkpoint.source == request.intent.expectedSource,
                      checkpoint.targetManifestSHA256 == target.manifestSHA256,
                      checkpoint.supervisor.installationID == checkpoint.source.installationID,
                      checkpoint.supervisor.storeID == checkpoint.source.storeID,
                      checkpoint.supervisor.executionID == checkpoint.source.executionID,
                      checkpoint.supervisor.authority == checkpoint.source.authority,
                      checkpoint.ledgerSequence > targetReservation.ledgerSequence,
                      controlEffect.confirmationID == nil,
                      controlEffect.capabilityID == nil else {
                    return false
                }
                controlPredecessorSequence = checkpoint.ledgerSequence
            case .immediate:
                guard controlEffect.checkpointFence == nil,
                      controlEffect.confirmationID != nil,
                      controlEffect.capabilityID != nil else {
                    return false
                }
            }
        }
        if let controlAcceptanceLedgerSequence {
            guard controlEffect != nil,
                  controlAcceptanceLedgerSequence > controlPredecessorSequence else {
                return false
            }
        }
        if let replacementEffect {
            guard let controlAcceptanceLedgerSequence,
                  replacementEffect.target == request.intent.target,
                  replacementEffect.requestID == request.intent.requestID,
                  replacementEffect.sourceTerminal.source == request.intent.expectedSource,
                  replacementEffect.sourceTerminal.ledgerSequence > controlAcceptanceLedgerSequence else {
                return false
            }
        }
        if let replacementAcceptanceLedgerSequence {
            guard let replacementEffect,
                  replacementAcceptanceLedgerSequence > replacementEffect.sourceTerminal.ledgerSequence else {
                return false
            }
        }
        if let completionLedgerSequence {
            guard let replacementAcceptanceLedgerSequence,
                  completionLedgerSequence > replacementAcceptanceLedgerSequence else {
                return false
            }
        }
        switch progress {
        case .waitingForCheckpoint:
            return request.intent.mode == .graceful
                && controlEffect == nil
                && controlAcceptanceID == nil
                && controlAcceptanceLedgerSequence == nil
                && replacementEffect == nil
                && replacementAcceptanceID == nil
                && replacementAcceptanceLedgerSequence == nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        case .confirmationRequired:
            return request.intent.mode == .immediate
                && controlEffect == nil
                && controlAcceptanceID == nil
                && controlAcceptanceLedgerSequence == nil
                && replacementEffect == nil
                && replacementAcceptanceID == nil
                && replacementAcceptanceLedgerSequence == nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        case .controlDispatchPending:
            return controlEffect != nil
                && controlAcceptanceID == nil
                && controlAcceptanceLedgerSequence == nil
                && replacementEffect == nil
                && replacementAcceptanceID == nil
                && replacementAcceptanceLedgerSequence == nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        case .awaitingSourceTerminal:
            return controlEffect != nil
                && controlAcceptanceID != nil
                && controlAcceptanceLedgerSequence != nil
                && replacementEffect == nil
                && replacementAcceptanceID == nil
                && replacementAcceptanceLedgerSequence == nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        case .replacementDispatchPending:
            return controlEffect != nil
                && controlAcceptanceID != nil
                && controlAcceptanceLedgerSequence != nil
                && replacementEffect != nil
                && replacementAcceptanceID == nil
                && replacementAcceptanceLedgerSequence == nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        case .awaitingReplacementRunning:
            return controlEffect != nil
                && controlAcceptanceID != nil
                && controlAcceptanceLedgerSequence != nil
                && replacementEffect != nil
                && replacementAcceptanceID != nil
                && replacementAcceptanceLedgerSequence != nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        case .completed:
            return controlEffect != nil
                && controlAcceptanceID != nil
                && controlAcceptanceLedgerSequence != nil
                && replacementEffect != nil
                && replacementAcceptanceID != nil
                && replacementAcceptanceLedgerSequence != nil
                && completionEvidenceID != nil
                && completionLedgerSequence != nil
        case .inDoubt:
            return replacementAcceptanceID == nil
                && replacementAcceptanceLedgerSequence == nil
                && completionEvidenceID == nil
                && completionLedgerSequence == nil
        }
    }
}

public struct RuntimeSwitchArchivedCompletion: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let archiveEvidenceID: RuntimeSwitchEvidenceID
    public let request: ActiveRuntimeSwitchRequest
    public let requestDigest: RuntimeSwitchRequestDigest
    public let sourceExecutionID: RunBrokerExecutionID
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let targetReservationID: RuntimeSwitchEvidenceID
    public let completionEvidenceID: RuntimeSwitchEvidenceID
    public let completionLedgerSequence: UInt64
    public let ledgerSequence: UInt64

    public var requestID: RuntimeSwitchRequestID { request.intent.requestID }

    fileprivate init(
        archiveEvidenceID: RuntimeSwitchEvidenceID,
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        sourceExecutionID: RunBrokerExecutionID,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        targetReservationID: RuntimeSwitchEvidenceID,
        completionEvidenceID: RuntimeSwitchEvidenceID,
        completionLedgerSequence: UInt64,
        ledgerSequence: UInt64
    ) {
        self.archiveEvidenceID = archiveEvidenceID
        self.request = request
        self.requestDigest = requestDigest
        self.sourceExecutionID = sourceExecutionID
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.targetReservationID = targetReservationID
        self.completionEvidenceID = completionEvidenceID
        self.completionLedgerSequence = completionLedgerSequence
        self.ledgerSequence = ledgerSequence
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, archiveEvidenceID, request, requestDigest, sourceExecutionID, targetExecutionID
        case targetManifestSHA256, targetReservationID, completionEvidenceID
        case completionLedgerSequence, ledgerSequence
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "archived runtime switch completion"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "archived runtime switch completion"
        )
        let value = Self.init(
            archiveEvidenceID: try container.decode(RuntimeSwitchEvidenceID.self, forKey: .archiveEvidenceID),
            request: try container.decode(ActiveRuntimeSwitchRequest.self, forKey: .request),
            requestDigest: try container.decode(RuntimeSwitchRequestDigest.self, forKey: .requestDigest),
            sourceExecutionID: try container.decode(RunBrokerExecutionID.self, forKey: .sourceExecutionID),
            targetExecutionID: try container.decode(RunBrokerExecutionID.self, forKey: .targetExecutionID),
            targetManifestSHA256: try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .targetManifestSHA256),
            targetReservationID: try container.decode(RuntimeSwitchEvidenceID.self, forKey: .targetReservationID),
            completionEvidenceID: try container.decode(RuntimeSwitchEvidenceID.self, forKey: .completionEvidenceID),
            completionLedgerSequence: try container.decode(UInt64.self, forKey: .completionLedgerSequence),
            ledgerSequence: try container.decode(UInt64.self, forKey: .ledgerSequence)
        )
        guard value.ledgerSequence > value.completionLedgerSequence,
              value.request.intent.expectedSource.executionID == value.sourceExecutionID,
              value.request.intent.target.manifest.executionID == value.targetExecutionID,
              value.request.intent.target.manifestSHA256 == value.targetManifestSHA256 else {
            throw DecodingError.dataCorruptedError(
                forKey: .ledgerSequence,
                in: container,
                debugDescription: "Archive evidence must causally follow completion evidence"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(archiveEvidenceID, forKey: .archiveEvidenceID)
        try container.encode(request, forKey: .request)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(sourceExecutionID, forKey: .sourceExecutionID)
        try container.encode(targetExecutionID, forKey: .targetExecutionID)
        try container.encode(targetManifestSHA256, forKey: .targetManifestSHA256)
        try container.encode(targetReservationID, forKey: .targetReservationID)
        try container.encode(completionEvidenceID, forKey: .completionEvidenceID)
        try container.encode(completionLedgerSequence, forKey: .completionLedgerSequence)
        try container.encode(ledgerSequence, forKey: .ledgerSequence)
    }
}

public struct RuntimeSwitchPolicyState: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = RuntimeSwitchPolicyState(record: nil, lastArchivedCompletion: nil)

    public let record: RuntimeSwitchRecord?
    public let lastArchivedCompletion: RuntimeSwitchArchivedCompletion?

    fileprivate init(
        record: RuntimeSwitchRecord?,
        lastArchivedCompletion: RuntimeSwitchArchivedCompletion? = nil
    ) {
        self.record = record
        self.lastArchivedCompletion = lastArchivedCompletion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, record, lastArchivedCompletion }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch policy state"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch policy state"
        )
        let record = try container.decodeIfPresent(RuntimeSwitchRecord.self, forKey: .record)
        let archived = try container.decodeIfPresent(
            RuntimeSwitchArchivedCompletion.self,
            forKey: .lastArchivedCompletion
        )
        if let record, let archived,
           record.targetReservation.ledgerSequence <= archived.ledgerSequence {
            throw DecodingError.dataCorruptedError(
                forKey: .record,
                in: container,
                debugDescription: "An active switch reservation must causally follow the archived switch"
            )
        }
        self.init(record: record, lastArchivedCompletion: archived)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(record, forKey: .record)
        try container.encodeIfPresent(lastArchivedCompletion, forKey: .lastArchivedCompletion)
    }
}

public enum RuntimeSwitchPolicyDisposition: String, Codable, Equatable, Sendable {
    case admitted
    case effectRecorded = "effect_recorded"
    case idempotent
    case awaitingTerminal = "awaiting_terminal"
    case awaitingReplacementRunning = "awaiting_replacement_running"
    case completed
    case archived
    case inDoubt = "in_doubt"
    case blocked
}

/// Policy transitions never return executable process commands. A newly
/// recorded effect is dispatched only by the durable outbox through one of the
/// separately re-fenced `prepare*Dispatch` methods below.
public struct RuntimeSwitchPolicyReduction: Equatable, Sendable {
    public let state: RuntimeSwitchPolicyState
    public let disposition: RuntimeSwitchPolicyDisposition
    public let recordedEffectID: RuntimeSwitchEffectID?
    public let blockedReason: RuntimeSwitchBlockedReason?

    fileprivate static func result(
        _ state: RuntimeSwitchPolicyState,
        _ disposition: RuntimeSwitchPolicyDisposition,
        effectID: RuntimeSwitchEffectID? = nil
    ) -> Self {
        .init(state: state, disposition: disposition, recordedEffectID: effectID, blockedReason: nil)
    }

    fileprivate static func blocked(_ state: RuntimeSwitchPolicyState, _ reason: RuntimeSwitchBlockedReason) -> Self {
        .init(state: state, disposition: .blocked, recordedEffectID: nil, blockedReason: reason)
    }
}

public struct RuntimeSwitchControlDirective: Equatable, Sendable {
    public let effectID: RuntimeSwitchEffectID
    public let requestID: RuntimeSwitchRequestID
    public let source: RuntimeSwitchSourceFence
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let cancellationIntent: ExecutionCancellationIntent
    public let checkpointFence: RuntimeSwitchCheckpointFence?
}

public struct RuntimeSwitchReplacementDirective: Equatable, Sendable {
    public let effectID: RuntimeSwitchEffectID
    public let requestID: RuntimeSwitchRequestID
    public let sourceTerminal: RuntimeSwitchTerminalFence
    public let targetReservation: RuntimeSwitchTargetReservation
    public let target: RuntimeSwitchResolvedTarget
}

public struct RuntimeSwitchDispatchDecision<Directive: Equatable & Sendable>: Equatable, Sendable {
    public let directive: Directive?
    public let blockedReason: RuntimeSwitchBlockedReason?

    fileprivate static func emit(_ directive: Directive) -> Self { .init(directive: directive, blockedReason: nil) }
    fileprivate static func blocked(_ reason: RuntimeSwitchBlockedReason) -> Self { .init(directive: nil, blockedReason: reason) }
}

public enum RuntimeSwitchPolicy {
    public static func admit(
        _ state: RuntimeSwitchPolicyState,
        request: ActiveRuntimeSwitchRequest,
        verified admission: VerifiedRuntimeSwitchAdmission?
    ) -> RuntimeSwitchPolicyReduction {
        if let record = state.record {
            if record.request.intent.requestID == request.intent.requestID {
                guard record.request == request else { return .blocked(state, .requestIDConflict) }
                // Client replay is observation-only. It never re-emits an effect.
                return .result(state, .idempotent)
            }
            return .blocked(state, .switchAlreadyPending)
        }
        if let archived = state.lastArchivedCompletion,
           archived.requestID == request.intent.requestID {
            guard archived.request == request else { return .blocked(state, .requestIDConflict) }
            return .result(state, .idempotent)
        }
        guard let admission, admission.request == request else { return .blocked(state, .unverifiedAdmission) }
        guard admission.source.executionID == request.intent.expectedSource.executionID else {
            return .blocked(state, .executionIdentityMismatch)
        }
        guard admission.source.authority == request.intent.expectedSource.authority else {
            return .blocked(state, .staleAuthority)
        }
        guard admission.source == request.intent.expectedSource else { return .blocked(state, .staleManifest) }
        guard admission.lifecycle.acceptsNewControlIntent else {
            return .blocked(state, lifecycleReason(admission.lifecycle))
        }
        guard admission.observedCancellation == .notRequested else {
            return .blocked(state, .concurrentCancellation)
        }
        if let archived = state.lastArchivedCompletion,
           archived.targetReservationID == admission.targetReservation.reservationID
            || admission.targetReservation.ledgerSequence <= archived.ledgerSequence {
            return .blocked(state, .staleReservation)
        }
        guard validTarget(request.intent.target, for: admission.source) else {
            return .blocked(state, .targetManifestInvalid)
        }

        let progress: RuntimeSwitchProgress
        switch request {
        case .gracefulHandoff:
            guard admission.forceChallenge == nil else { return .blocked(state, .unverifiedAdmission) }
            progress = .waitingForCheckpoint
        case .forceTermination:
            guard admission.forceChallenge != nil else { return .blocked(state, .forceChallengeRequired) }
            progress = .confirmationRequired
        }
        return .result(
            .init(
                record: .init(
                    request: request,
                    requestDigest: admission.requestDigest,
                    sourceLedgerSequence: admission.sourceLedgerSequence,
                    targetReservation: admission.targetReservation,
                    progress: progress,
                    forceChallenge: admission.forceChallenge
                ),
                lastArchivedCompletion: state.lastArchivedCompletion
            ),
            .admitted
        )
    }

    public static func observeSafeCheckpoint(
        _ state: RuntimeSwitchPolicyState,
        attestation: VerifiedRuntimeSwitchCheckpointAttestation
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record else { return .blocked(state, .invalidTransition) }
        if let effect = record.controlEffect, effect.effectID == attestation.effectID {
            guard effect.requestID == attestation.requestID,
                  effect.requestDigest == attestation.requestDigest,
                  effect.source == attestation.fence.source,
                  effect.target.manifestSHA256 == attestation.fence.targetManifestSHA256,
                  effect.cancellationIntent == .graceful,
                  effect.checkpointFence == attestation.fence,
                  effect.confirmationID == nil else {
                return .blocked(state, .effectIDConflict)
            }
            return .result(state, .idempotent)
        }
        guard record.progress == .waitingForCheckpoint else { return .blocked(state, .invalidTransition) }
        guard record.request.intent.requestID == attestation.requestID,
              record.requestDigest == attestation.requestDigest,
              attestation.fence.source == record.request.intent.expectedSource,
              attestation.fence.targetManifestSHA256 == record.request.intent.target.manifestSHA256,
              attestation.fence.ledgerSequence > record.targetReservation.ledgerSequence else {
            return .blocked(state, .checkpointMismatch)
        }
        let effect = RuntimeSwitchControlEffect(
            effectID: attestation.effectID,
            requestID: attestation.requestID,
            requestDigest: record.requestDigest,
            source: record.request.intent.expectedSource,
            target: record.request.intent.target,
            cancellationIntent: .graceful,
            checkpointFence: attestation.fence,
            confirmationID: nil,
            capabilityID: nil
        )
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .controlDispatchPending,
            controlEffect: effect
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .effectRecorded,
            effectID: effect.effectID
        )
    }

    public static func confirmImmediate(
        _ state: RuntimeSwitchPolicyState,
        confirmation: VerifiedRuntimeForceConfirmation,
        capability: VerifiedRuntimeSwitchBackendCapability
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record,
              case .forceTermination(let force) = record.request,
              let challenge = record.forceChallenge else {
            return .blocked(state, .invalidTransition)
        }
        if let effect = record.controlEffect, effect.effectID == confirmation.effectID {
            guard effect.confirmationID == confirmation.confirmationID,
                  confirmation.challengeID == challenge.challengeID,
                  confirmation.requestID == force.intent.requestID,
                  confirmation.requestDigest == record.requestDigest,
                  confirmation.actorID == challenge.actorID,
                  confirmation.sessionID == challenge.sessionID,
                  confirmation.audit == force.audit,
                  confirmation.source == force.intent.expectedSource,
                  confirmation.targetManifestSHA256 == force.intent.target.manifestSHA256,
                  effect.capabilityID == capability.capabilityID,
                  capability.cancellationIntent == .immediate,
                  capability.requestDigest == record.requestDigest,
                  capability.source == force.intent.expectedSource else {
                return .blocked(state, .effectIDConflict)
            }
            return .result(state, .idempotent)
        }
        guard record.progress == .confirmationRequired,
              confirmation.challengeID == challenge.challengeID,
              confirmation.requestID == force.intent.requestID,
              confirmation.requestDigest == record.requestDigest,
              confirmation.actorID == challenge.actorID,
              confirmation.sessionID == challenge.sessionID,
              confirmation.audit == force.audit,
              confirmation.source == force.intent.expectedSource,
              confirmation.targetManifestSHA256 == force.intent.target.manifestSHA256 else {
            return .blocked(state, .forceConfirmationMismatch)
        }
        guard capability.cancellationIntent == .immediate,
              capability.requestDigest == record.requestDigest,
              capability.source == force.intent.expectedSource else {
            return .blocked(state, .forceCapabilityRequired)
        }
        let effect = RuntimeSwitchControlEffect(
            effectID: confirmation.effectID,
            requestID: force.intent.requestID,
            requestDigest: record.requestDigest,
            source: force.intent.expectedSource,
            target: force.intent.target,
            cancellationIntent: .immediate,
            checkpointFence: nil,
            confirmationID: confirmation.confirmationID,
            capabilityID: capability.capabilityID
        )
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .controlDispatchPending,
            forceChallenge: challenge,
            controlEffect: effect
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .effectRecorded,
            effectID: effect.effectID
        )
    }

    /// Called only by the durable outbox. Repeated calls before authenticated
    /// acceptance deliberately return the same directive/effect ID, allowing
    /// the supervisor's `handoffIf(fence,effectID)` dedupe to close send crashes.
    public static func prepareControlDispatch(
        _ state: RuntimeSwitchPolicyState,
        effectID: RuntimeSwitchEffectID,
        snapshot: VerifiedRuntimeSwitchDispatchSnapshot,
        capability: VerifiedRuntimeSwitchBackendCapability
    ) -> RuntimeSwitchDispatchDecision<RuntimeSwitchControlDirective> {
        guard let record = state.record,
              record.progress == .controlDispatchPending,
              let effect = record.controlEffect,
              effect.effectID == effectID else {
            return .blocked(.invalidTransition)
        }
        guard snapshot.effectID == effectID,
              snapshot.requestDigest == effect.requestDigest,
              snapshot.source == effect.source else {
            return .blocked(.dispatchFenceMismatch)
        }
        guard snapshot.lifecycle.acceptsNewControlIntent else {
            return .blocked(lifecycleReason(snapshot.lifecycle))
        }
        guard snapshot.observedCancellation == .notRequested else {
            return .blocked(.concurrentCancellation)
        }
        guard capability.requestDigest == effect.requestDigest,
              capability.source == effect.source,
              capability.cancellationIntent == effect.cancellationIntent,
              effect.cancellationIntent != .immediate || capability.capabilityID == effect.capabilityID else {
            return .blocked(effect.cancellationIntent == .immediate ? .forceCapabilityRequired : .gracefulCapabilityRequired)
        }
        if effect.cancellationIntent == .graceful {
            guard snapshot.lifecycle == .running,
                  snapshot.checkpointFence == effect.checkpointFence else {
                return .blocked(.checkpointMismatch)
            }
        } else if snapshot.checkpointFence != nil {
            return .blocked(.dispatchFenceMismatch)
        }
        return .emit(.init(
            effectID: effect.effectID,
            requestID: effect.requestID,
            source: effect.source,
            targetManifestSHA256: effect.target.manifestSHA256,
            cancellationIntent: effect.cancellationIntent,
            checkpointFence: effect.checkpointFence
        ))
    }

    public static func acknowledgeControl(
        _ state: RuntimeSwitchPolicyState,
        acceptance: VerifiedRuntimeSwitchControlAcceptance
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record, let effect = record.controlEffect else {
            return .blocked(state, .invalidTransition)
        }
        if record.progress == .awaitingSourceTerminal,
           record.controlAcceptanceID == acceptance.evidenceID,
           record.controlAcceptanceLedgerSequence == acceptance.ledgerSequence,
           effect.effectID == acceptance.effectID,
           effect.source == acceptance.source {
            return .result(state, .idempotent)
        }
        guard record.progress == .controlDispatchPending,
              effect.effectID == acceptance.effectID,
              effect.source == acceptance.source,
              acceptance.ledgerSequence
                > (effect.checkpointFence?.ledgerSequence ?? record.targetReservation.ledgerSequence) else {
            return .blocked(state, .dispatchFenceMismatch)
        }
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .awaitingSourceTerminal,
            forceChallenge: record.forceChallenge,
            controlEffect: effect,
            controlAcceptanceID: acceptance.evidenceID,
            controlAcceptanceLedgerSequence: acceptance.ledgerSequence
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .awaitingTerminal
        )
    }

    public static func observeSourceTerminal(
        _ state: RuntimeSwitchPolicyState,
        attestation: VerifiedRuntimeSwitchTerminalAttestation
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record else { return .blocked(state, .invalidTransition) }
        if let effect = record.replacementEffect,
           effect.effectID == attestation.replacementEffectID,
           effect.sourceTerminal == attestation.terminalFence {
            return .result(state, .idempotent)
        }
        guard record.progress == .awaitingSourceTerminal,
              let controlAcceptanceLedgerSequence = record.controlAcceptanceLedgerSequence else {
            return .blocked(state, .terminalEvidenceRequired)
        }
        guard attestation.terminalFence.source == record.request.intent.expectedSource else {
            return .blocked(state, .terminalEvidenceMismatch)
        }
        guard attestation.terminalFence.ledgerSequence > controlAcceptanceLedgerSequence else {
            return .blocked(state, .terminalEvidenceMismatch)
        }
        guard record.controlEffect?.effectID != attestation.replacementEffectID else {
            return .blocked(state, .effectIDConflict)
        }
        let effect = RuntimeSwitchReplacementEffect(
            effectID: attestation.replacementEffectID,
            requestID: record.request.intent.requestID,
            sourceTerminal: attestation.terminalFence,
            target: record.request.intent.target
        )
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .replacementDispatchPending,
            forceChallenge: record.forceChallenge,
            controlEffect: record.controlEffect,
            controlAcceptanceID: record.controlAcceptanceID,
            controlAcceptanceLedgerSequence: record.controlAcceptanceLedgerSequence,
            replacementEffect: effect
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .effectRecorded,
            effectID: effect.effectID
        )
    }

    public static func prepareReplacementDispatch(
        _ state: RuntimeSwitchPolicyState,
        effectID: RuntimeSwitchEffectID,
        snapshot: VerifiedRuntimeSwitchReplacementDispatchSnapshot
    ) -> RuntimeSwitchDispatchDecision<RuntimeSwitchReplacementDirective> {
        guard let record = state.record,
              record.progress == .replacementDispatchPending,
              let effect = record.replacementEffect,
              effect.effectID == effectID else {
            return .blocked(.invalidTransition)
        }
        guard snapshot.effectID == effectID,
              snapshot.sourceTerminal == effect.sourceTerminal else {
            return .blocked(.terminalEvidenceMismatch)
        }
        guard snapshot.targetReservation == record.targetReservation,
              snapshot.targetManifestSHA256 == effect.target.manifestSHA256 else {
            return .blocked(.replacementEvidenceMismatch)
        }
        return .emit(.init(
            effectID: effect.effectID,
            requestID: effect.requestID,
            sourceTerminal: effect.sourceTerminal,
            targetReservation: record.targetReservation,
            target: effect.target
        ))
    }

    public static func acknowledgeReplacement(
        _ state: RuntimeSwitchPolicyState,
        acceptance: VerifiedRuntimeSwitchReplacementAcceptance
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record, let effect = record.replacementEffect else {
            return .blocked(state, .invalidTransition)
        }
        if record.progress == .awaitingReplacementRunning,
           record.replacementAcceptanceID == acceptance.evidenceID,
           record.replacementAcceptanceLedgerSequence == acceptance.ledgerSequence,
           effect.effectID == acceptance.effectID,
           record.targetReservation.reservationID == acceptance.targetReservationID,
           effect.target.manifest.executionID == acceptance.targetExecutionID,
           effect.target.manifestSHA256 == acceptance.targetManifestSHA256 {
            return .result(state, .idempotent)
        }
        guard record.progress == .replacementDispatchPending,
              effect.effectID == acceptance.effectID,
              record.targetReservation.reservationID == acceptance.targetReservationID,
              effect.target.manifest.executionID == acceptance.targetExecutionID,
              effect.target.manifestSHA256 == acceptance.targetManifestSHA256,
              acceptance.ledgerSequence > effect.sourceTerminal.ledgerSequence,
              acceptance.ledgerSequence > record.targetReservation.ledgerSequence,
              acceptance.ledgerSequence > (record.controlAcceptanceLedgerSequence ?? 0) else {
            return .blocked(state, .replacementEvidenceMismatch)
        }
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .awaitingReplacementRunning,
            forceChallenge: record.forceChallenge,
            controlEffect: record.controlEffect,
            controlAcceptanceID: record.controlAcceptanceID,
            controlAcceptanceLedgerSequence: record.controlAcceptanceLedgerSequence,
            replacementEffect: effect,
            replacementAcceptanceID: acceptance.evidenceID,
            replacementAcceptanceLedgerSequence: acceptance.ledgerSequence
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .awaitingReplacementRunning
        )
    }

    public static func observeReplacementRunning(
        _ state: RuntimeSwitchPolicyState,
        attestation: VerifiedRuntimeSwitchReplacementRunningAttestation
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record, let effect = record.replacementEffect else {
            return .blocked(state, .invalidTransition)
        }
        if record.progress == .completed,
           record.completionEvidenceID == attestation.evidenceID,
           record.completionLedgerSequence == attestation.ledgerSequence,
           record.targetReservation.reservationID == attestation.targetReservationID,
           effect.target.manifest.executionID == attestation.targetExecutionID,
           effect.target.manifestSHA256 == attestation.targetManifestSHA256 {
            return .result(state, .idempotent)
        }
        guard record.progress == .awaitingReplacementRunning,
              record.targetReservation.reservationID == attestation.targetReservationID,
              effect.target.manifest.executionID == attestation.targetExecutionID,
              effect.target.manifestSHA256 == attestation.targetManifestSHA256,
              attestation.ledgerSequence > (record.replacementAcceptanceLedgerSequence ?? 0) else {
            return .blocked(state, .replacementEvidenceMismatch)
        }
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .completed,
            forceChallenge: record.forceChallenge,
            controlEffect: record.controlEffect,
            controlAcceptanceID: record.controlAcceptanceID,
            controlAcceptanceLedgerSequence: record.controlAcceptanceLedgerSequence,
            replacementEffect: effect,
            replacementAcceptanceID: record.replacementAcceptanceID,
            replacementAcceptanceLedgerSequence: record.replacementAcceptanceLedgerSequence,
            completionEvidenceID: attestation.evidenceID,
            completionLedgerSequence: attestation.ledgerSequence
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .completed
        )
    }

    /// Frees the single active-switch slot only after the broker durably
    /// archives an exact completed record under CAS. Pending and in-doubt
    /// records intentionally have no rollover path.
    public static func archiveCompleted(
        _ state: RuntimeSwitchPolicyState,
        rollover: VerifiedRuntimeSwitchCompletionRollover
    ) -> RuntimeSwitchPolicyReduction {
        if state.record == nil,
           let archived = state.lastArchivedCompletion,
           archived.archiveEvidenceID == rollover.archiveEvidenceID,
           archived.requestID == rollover.requestID,
           archived.completionEvidenceID == rollover.completionEvidenceID,
           archived.targetReservationID == rollover.targetReservationID,
           archived.targetExecutionID == rollover.targetExecutionID,
           archived.targetManifestSHA256 == rollover.targetManifestSHA256,
           archived.ledgerSequence == rollover.ledgerSequence {
            return .result(state, .idempotent)
        }
        guard let record = state.record,
              record.progress == .completed,
              let replacement = record.replacementEffect,
              let completionEvidenceID = record.completionEvidenceID,
              let completionLedgerSequence = record.completionLedgerSequence,
              rollover.requestID == record.request.intent.requestID,
              rollover.completionEvidenceID == completionEvidenceID,
              rollover.targetReservationID == record.targetReservation.reservationID,
              rollover.targetExecutionID == replacement.target.manifest.executionID,
              rollover.targetManifestSHA256 == replacement.target.manifestSHA256,
              rollover.ledgerSequence > completionLedgerSequence else {
            return .blocked(state, .completionRolloverMismatch)
        }
        let archived = RuntimeSwitchArchivedCompletion(
            archiveEvidenceID: rollover.archiveEvidenceID,
            request: record.request,
            requestDigest: record.requestDigest,
            sourceExecutionID: record.request.intent.expectedSource.executionID,
            targetExecutionID: rollover.targetExecutionID,
            targetManifestSHA256: rollover.targetManifestSHA256,
            targetReservationID: rollover.targetReservationID,
            completionEvidenceID: rollover.completionEvidenceID,
            completionLedgerSequence: completionLedgerSequence,
            ledgerSequence: rollover.ledgerSequence
        )
        return .result(
            .init(record: nil, lastArchivedCompletion: archived),
            .archived
        )
    }

    public static func markSourceInDoubt(
        _ state: RuntimeSwitchPolicyState,
        source: RuntimeSwitchSourceFence
    ) -> RuntimeSwitchPolicyReduction {
        guard let record = state.record,
              record.request.intent.expectedSource == source,
              record.progress != .completed else {
            return .blocked(state, .invalidTransition)
        }
        if record.progress == .inDoubt { return .result(state, .idempotent) }
        let next = RuntimeSwitchRecord(
            request: record.request,
            requestDigest: record.requestDigest,
            sourceLedgerSequence: record.sourceLedgerSequence,
            targetReservation: record.targetReservation,
            progress: .inDoubt,
            forceChallenge: record.forceChallenge,
            controlEffect: record.controlEffect,
            controlAcceptanceID: record.controlAcceptanceID,
            controlAcceptanceLedgerSequence: record.controlAcceptanceLedgerSequence,
            replacementEffect: record.replacementEffect,
            replacementAcceptanceID: record.replacementAcceptanceID
        )
        return .result(
            .init(record: next, lastArchivedCompletion: state.lastArchivedCompletion),
            .inDoubt
        )
    }

    private static func validTarget(_ target: RuntimeSwitchResolvedTarget, for source: RuntimeSwitchSourceFence) -> Bool {
        let manifest = target.manifest
        return manifest.installationID == source.installationID
            && manifest.storeID == source.storeID
            && manifest.taskID == source.taskID
            && manifest.executionID != source.executionID
            && target.manifestSHA256 != source.manifestSHA256
    }

    private static func lifecycleReason(_ lifecycle: RuntimeSwitchExecutionLifecycle) -> RuntimeSwitchBlockedReason {
        switch lifecycle {
        case .offline: .offline
        case .inDoubt: .inDoubt
        case .cancellationPending, .terminating: .concurrentCancellation
        case .terminal: .executionNotControllable
        case .registered, .starting, .running: .executionNotControllable
        }
    }
}
