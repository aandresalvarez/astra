import ASTRACore
import Foundation

/// Authenticated broker identity and capability context used to construct an
/// exact manifest. A client must not guess store or installation identity.
public struct RunBrokerApplicationContext: Codable, Equatable, Sendable {
    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let brokerProtocolVersion: RunBrokerProtocolVersion
    public let runtimeFeatures: RunBrokerRuntimeFeatureSet
    public let durableHeadSequence: Int64

    public init(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        brokerProtocolVersion: RunBrokerProtocolVersion,
        runtimeFeatures: RunBrokerRuntimeFeatureSet,
        durableHeadSequence: Int64
    ) {
        self.installationID = installationID
        self.storeID = storeID
        self.brokerProtocolVersion = brokerProtocolVersion
        self.runtimeFeatures = runtimeFeatures
        self.durableHeadSequence = durableHeadSequence
    }

    public func validate() throws {
        guard brokerProtocolVersion == .v2,
              durableHeadSequence >= 0,
              runtimeFeatures.isKnown else {
            throw RunBrokerApplicationContractError.invalidManifestMetadata
        }
    }
}

/// Provider-neutral feature parity advertised before bootstrap or handoff.
/// Unsupported features are denied; they are never silently downgraded.
public struct RunBrokerRuntimeFeatureSet: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let durableTypedStream = Self(rawValue: 1 << 0)
    public static let normalizedEvents = Self(rawValue: 1 << 1)
    public static let standardInput = Self(rawValue: 1 << 2)
    public static let approvalRequests = Self(rawValue: 1 << 3)
    public static let gracefulCancellation = Self(rawValue: 1 << 4)
    public static let immediateTermination = Self(rawValue: 1 << 5)
    public static let safeRuntimeHandoff = Self(rawValue: 1 << 6)
    public static let known: Self = [
        .durableTypedStream, .normalizedEvents, .standardInput, .approvalRequests,
        .gracefulCancellation, .immediateTermination, .safeRuntimeHandoff,
    ]

    public var isKnown: Bool { rawValue & ~Self.known.rawValue == 0 }
}

public struct RunBrokerRuntimeProtocolManifest: Codable, Equatable, Sendable {
    public static let baseline = Self(
        validatedSupervisorProtocolVersion: 2,
        validatedProviderAdapterID: "provider-neutral-v2",
        validatedProviderAdapterProtocolVersion: 2,
        validatedFeatures: [.durableTypedStream]
    )

    private init(
        validatedSupervisorProtocolVersion: UInt32,
        validatedProviderAdapterID: String,
        validatedProviderAdapterProtocolVersion: UInt32,
        validatedFeatures: RunBrokerRuntimeFeatureSet
    ) {
        self.supervisorProtocolVersion = validatedSupervisorProtocolVersion
        self.providerAdapterID = validatedProviderAdapterID
        self.providerAdapterProtocolVersion = validatedProviderAdapterProtocolVersion
        self.features = validatedFeatures
    }

    public let supervisorProtocolVersion: UInt32
    public let providerAdapterID: String
    public let providerAdapterProtocolVersion: UInt32
    public let features: RunBrokerRuntimeFeatureSet

    public init(
        supervisorProtocolVersion: UInt32,
        providerAdapterID: String,
        providerAdapterProtocolVersion: UInt32,
        features: RunBrokerRuntimeFeatureSet
    ) throws {
        let adapter = providerAdapterID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.supervisorProtocolVersion = supervisorProtocolVersion
        self.providerAdapterID = adapter
        self.providerAdapterProtocolVersion = providerAdapterProtocolVersion
        self.features = features
        try validate()
    }

    public func validate() throws {
        guard supervisorProtocolVersion > 0,
              providerAdapterProtocolVersion > 0,
              providerAdapterID == providerAdapterID.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerAdapterID.isEmpty,
              providerAdapterID.utf8.count <= 128,
              !providerAdapterID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              features.isKnown else {
            throw RunBrokerApplicationContractError.invalidManifestMetadata
        }
    }
}

public struct RunBrokerApplicationRuntimeSwitchSubmission: Codable, Equatable, Sendable {
    public let requestID: RuntimeSwitchRequestID
    public let mode: RuntimeSwitchMode
    public let expectedSource: RuntimeSwitchSourceFence
    public let targetDraft: RunBrokerApplicationLaunchDraft
    public let requestedAt: Date
    public let forceAudit: RuntimeForceSwitchAudit?
    public let targetProtocol: RunBrokerRuntimeProtocolManifest
    public let actorID: RuntimeSwitchActorID?
    public let sessionID: UUID?

    public init(
        requestID: RuntimeSwitchRequestID,
        mode: RuntimeSwitchMode,
        expectedSource: RuntimeSwitchSourceFence,
        targetDraft: RunBrokerApplicationLaunchDraft,
        requestedAt: Date,
        forceAudit: RuntimeForceSwitchAudit? = nil,
        targetProtocol: RunBrokerRuntimeProtocolManifest,
        actorID: RuntimeSwitchActorID? = nil,
        sessionID: UUID? = nil
    ) {
        self.requestID = requestID
        self.mode = mode
        self.expectedSource = expectedSource
        self.targetDraft = targetDraft
        self.requestedAt = requestedAt
        self.forceAudit = forceAudit
        self.targetProtocol = targetProtocol
        self.actorID = actorID
        self.sessionID = sessionID
    }

    public func validate() throws {
        try validate(now: nil)
    }

    public func validate(now: Date) throws {
        try validate(now: Optional(now))
    }

    private func validate(now: Date?) throws {
        try targetProtocol.validate()
        try targetDraft.validate(now: now)
        let requestedMilliseconds = requestedAt.timeIntervalSince1970 * 1_000
        guard requestedMilliseconds.isFinite,
              requestedMilliseconds > TimeInterval(Int64.min),
              requestedMilliseconds < TimeInterval(Int64.max) else {
            throw RunBrokerApplicationContractError.invalidRuntimeSwitch
        }
        let canonicalRequestedAt = Date(
            timeIntervalSince1970:
                TimeInterval(Int64(requestedMilliseconds.rounded(.towardZero))) / 1_000
        )
        // Initial v2 handoff supports one broker-owned provider-neutral
        // protocol. Client metadata cannot mint a new capability set.
        guard targetProtocol == .baseline,
              requestedAt == canonicalRequestedAt,
              targetDraft.executionID != expectedSource.executionID,
              targetDraft.taskID == expectedSource.taskID,
              !targetDraft.declaredEffects.isEmpty,
              targetDraft.declaredEffects.count <= 256,
              (try ASTRACanonicalJSON.encode(targetDraft)).count
                <= RunBrokerApplicationBounds.maximumProjectionPayloadBytes,
              mode == .immediate
                ? (actorID != nil && sessionID != nil && forceAudit != nil)
                : (actorID == nil && sessionID == nil && forceAudit == nil) else {
            throw RunBrokerApplicationContractError.invalidRuntimeSwitch
        }
    }
}

public struct RunBrokerApplicationForceConfirmation: Codable, Equatable, Sendable {
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let challengeID: RuntimeForceChallengeID
    public let actorID: RuntimeSwitchActorID
    public let sessionID: UUID
    public let confirmedAt: Date
    public let effectID: RuntimeSwitchEffectID

    public init(
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        challengeID: RuntimeForceChallengeID,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        confirmedAt: Date,
        effectID: RuntimeSwitchEffectID
    ) {
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.challengeID = challengeID
        self.actorID = actorID
        self.sessionID = sessionID
        self.confirmedAt = confirmedAt
        self.effectID = effectID
    }
}

public enum RunBrokerApplicationRuntimeSwitchProgress: String, Codable, Equatable, Sendable {
    case waitingForCheckpoint = "waiting_for_checkpoint"
    case confirmationRequired = "confirmation_required"
    case controlDispatchPending = "control_dispatch_pending"
    case awaitingSourceTerminal = "awaiting_source_terminal"
    case replacementDispatchPending = "replacement_dispatch_pending"
    case awaitingReplacementRunning = "awaiting_replacement_running"
    case completed
    case archived
    case inDoubt = "in_doubt"
}

public struct RunBrokerApplicationRuntimeSwitchStatus: Codable, Equatable, Sendable {
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let source: RuntimeSwitchSourceFence
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let progress: RunBrokerApplicationRuntimeSwitchProgress
    public let challenge: RuntimeForceSwitchChallenge?
    public let recordedControlEffectID: RuntimeSwitchEffectID?
    public let recordedReplacementEffectID: RuntimeSwitchEffectID?

    public init(
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        source: RuntimeSwitchSourceFence,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        progress: RunBrokerApplicationRuntimeSwitchProgress,
        challenge: RuntimeForceSwitchChallenge?,
        recordedControlEffectID: RuntimeSwitchEffectID?,
        recordedReplacementEffectID: RuntimeSwitchEffectID?
    ) {
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.source = source
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.progress = progress
        self.challenge = challenge
        self.recordedControlEffectID = recordedControlEffectID
        self.recordedReplacementEffectID = recordedReplacementEffectID
    }

    public func validate() throws {
        guard source.executionID != targetExecutionID,
              source.authority.epoch.rawValue > 0,
              (progress == .confirmationRequired) == (challenge != nil),
              challenge.map({ $0.requestID == requestID && $0.requestDigest == requestDigest }) ?? true,
              recordedReplacementEffectID == nil || recordedControlEffectID != nil else {
            throw RunBrokerApplicationContractError.invalidRuntimeSwitch
        }
    }
}

public struct RunBrokerApplicationExecutionFence: Codable, Equatable, Sendable {
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let expectedSupervisorSequence: UInt64

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        expectedSupervisorSequence: UInt64
    ) {
        self.executionID = executionID
        self.authority = authority
        self.expectedSupervisorSequence = expectedSupervisorSequence
    }

    public func validate() throws {
        guard authority.epoch.rawValue > 0,
              authority.epoch.rawValue <= UInt64(Int64.max) else {
            throw RunBrokerApplicationContractError.invalidExecutionControl
        }
    }
}

public struct RunBrokerApplicationInputWrite: Codable, Equatable, Sendable {
    public let fence: RunBrokerApplicationExecutionFence
    public let line: String

    public init(fence: RunBrokerApplicationExecutionFence, line: String) throws {
        guard !line.contains("\n"),
              !line.unicodeScalars.contains(where: { $0.value == 0 }),
              line.utf8.count <= 32_768 else {
            throw RunBrokerApplicationContractError.invalidLaunchArguments
        }
        self.fence = fence
        self.line = line
    }
}

public struct RunBrokerApplicationGracefulCancellation: Codable, Equatable, Sendable {
    public let fence: RunBrokerApplicationExecutionFence
    public init(fence: RunBrokerApplicationExecutionFence) { self.fence = fence }
}

public struct RunBrokerApplicationImmediateCancellationRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let fence: RunBrokerApplicationExecutionFence
    public let actorID: RuntimeSwitchActorID
    public let sessionID: UUID
    public let audit: RuntimeForceSwitchAudit

    public init(
        requestID: UUID,
        fence: RunBrokerApplicationExecutionFence,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        audit: RuntimeForceSwitchAudit
    ) {
        self.requestID = requestID
        self.fence = fence
        self.actorID = actorID
        self.sessionID = sessionID
        self.audit = audit
    }

    public func requestDigest() throws -> ExecutionForceRequestDigest {
        .init(value: try RuntimeSwitchDigests.canonical(self))
    }
}

public struct RunBrokerApplicationImmediateCancellationConfirmation: Codable, Equatable, Sendable {
    public let fence: RunBrokerApplicationExecutionFence
    public let challengeID: RuntimeForceChallengeID
    public let requestDigest: ExecutionForceRequestDigest
    public let actorID: RuntimeSwitchActorID
    public let sessionID: UUID
    public let confirmedAt: Date
    public let effectID: RuntimeSwitchEffectID

    public init(
        fence: RunBrokerApplicationExecutionFence,
        challengeID: RuntimeForceChallengeID,
        requestDigest: ExecutionForceRequestDigest,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        confirmedAt: Date,
        effectID: RuntimeSwitchEffectID
    ) {
        self.fence = fence
        self.challengeID = challengeID
        self.requestDigest = requestDigest
        self.actorID = actorID
        self.sessionID = sessionID
        self.confirmedAt = confirmedAt
        self.effectID = effectID
    }
}

public struct RunBrokerApplicationExecutionControlStatus: Codable, Equatable, Sendable {
    public let fence: RunBrokerApplicationExecutionFence
    public let acceptedSupervisorSequence: UInt64
    public let cancellationIntent: ExecutionCancellationIntent?
    public let challenge: ExecutionForceChallenge?
    public let acceptedEffectID: RuntimeSwitchEffectID?

    public init(
        fence: RunBrokerApplicationExecutionFence,
        acceptedSupervisorSequence: UInt64,
        cancellationIntent: ExecutionCancellationIntent?,
        challenge: ExecutionForceChallenge? = nil,
        acceptedEffectID: RuntimeSwitchEffectID? = nil
    ) {
        self.fence = fence
        self.acceptedSupervisorSequence = acceptedSupervisorSequence
        self.cancellationIntent = cancellationIntent
        self.challenge = challenge
        self.acceptedEffectID = acceptedEffectID
    }

    public func validate() throws {
        try fence.validate()
        guard acceptedSupervisorSequence >= fence.expectedSupervisorSequence,
              acceptedEffectID == nil || cancellationIntent == .immediate,
              challenge == nil || (
                challenge?.executionID == fence.executionID
                    && challenge?.authority == fence.authority
                    && challenge?.expectedSupervisorSequence
                        == fence.expectedSupervisorSequence
              ) else {
            throw RunBrokerApplicationContractError.invalidExecutionControl
        }
    }
}

public struct RunBrokerApplicationStopMonitoring: Codable, Equatable, Sendable {
    public let operationID: RunBrokerOperationID
    public let authority: RunBrokerAuthority
    public let expectedDeadline: RunBrokerMonitorDeadline?

    public init(
        operationID: RunBrokerOperationID,
        authority: RunBrokerAuthority,
        expectedDeadline: RunBrokerMonitorDeadline?
    ) {
        self.operationID = operationID
        self.authority = authority
        self.expectedDeadline = expectedDeadline
    }
}

public struct RunBrokerApplicationMonitoringStatus: Codable, Equatable, Sendable {
    public let operationID: RunBrokerOperationID
    public let authority: RunBrokerAuthority
    public let deadline: RunBrokerMonitorDeadline?
    public let stopped: Bool

    public init(
        operationID: RunBrokerOperationID,
        authority: RunBrokerAuthority,
        deadline: RunBrokerMonitorDeadline?,
        stopped: Bool
    ) {
        self.operationID = operationID
        self.authority = authority
        self.deadline = deadline
        self.stopped = stopped
    }
}

public enum RunBrokerApplicationTerminalOutcome: String, Codable, Equatable, Sendable {
    case completed, failed, cancelled, launchFailed = "launch_failed"
    case signaled, waitFailed = "wait_failed"
}

public struct RunBrokerApplicationTerminalEvidence: Codable, Equatable, Sendable {
    public let outcome: RunBrokerApplicationTerminalOutcome
    public let exitCode: Int32?
    public let cancellationIntent: ExecutionCancellationIntent?
    public let terminationSignal: Int32?
    public let terminationReason: RunBrokerTerminationReason?
    public let supervisorSequence: UInt64
    public let supervisorEventID: UUID
    public let occurredAt: Date

    public init(
        outcome: RunBrokerApplicationTerminalOutcome,
        exitCode: Int32?,
        cancellationIntent: ExecutionCancellationIntent?,
        terminationSignal: Int32? = nil,
        terminationReason: RunBrokerTerminationReason? = nil,
        supervisorSequence: UInt64,
        supervisorEventID: UUID,
        occurredAt: Date
    ) {
        self.outcome = outcome
        self.exitCode = exitCode
        self.cancellationIntent = cancellationIntent
        self.terminationSignal = terminationSignal
        self.terminationReason = terminationReason
        self.supervisorSequence = supervisorSequence
        self.supervisorEventID = supervisorEventID
        self.occurredAt = occurredAt
    }

    public func validate() throws {
        let ms = occurredAt.timeIntervalSince1970 * 1_000
        guard supervisorSequence > 0,
              ms.isFinite,
              Date(timeIntervalSince1970: TimeInterval(Int64(ms.rounded(.towardZero))) / 1_000)
                == occurredAt else {
            throw RunBrokerApplicationContractError.invalidExecutionStatus
        }
        switch outcome {
        case .completed:
            guard exitCode == 0, cancellationIntent == nil,
                  terminationReason == .exited, terminationSignal == nil else {
                throw RunBrokerApplicationContractError.invalidExecutionStatus
            }
        case .failed:
            guard let exitCode, exitCode > 0, cancellationIntent == nil,
                  terminationReason == .exited, terminationSignal == nil else {
                throw RunBrokerApplicationContractError.invalidExecutionStatus
            }
        case .cancelled:
            guard cancellationIntent == .graceful || cancellationIntent == .immediate,
                  terminationReason == nil || terminationReason == .signaled else {
                throw RunBrokerApplicationContractError.invalidExecutionStatus
            }
        case .launchFailed:
            guard exitCode == nil, cancellationIntent == nil,
                  terminationReason == nil, terminationSignal == nil else {
                throw RunBrokerApplicationContractError.invalidExecutionStatus
            }
        case .signaled:
            guard exitCode != nil, cancellationIntent == nil,
                  terminationReason == .signaled,
                  let terminationSignal, terminationSignal > 0 else {
                throw RunBrokerApplicationContractError.invalidExecutionStatus
            }
        case .waitFailed:
            guard exitCode.map({ $0 < 0 }) == true, cancellationIntent == nil,
                  terminationReason == .waitFailed, terminationSignal == nil else {
                throw RunBrokerApplicationContractError.invalidExecutionStatus
            }
        }
    }
}

public enum RunBrokerApplicationStreamChannel: String, Codable, Equatable, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
}

/// A bounded durable chunk with explicit logical-line boundaries. Consumers
/// retain a trailing fragment when `endsLogicalLine` is false and can resume
/// exactly after restart without provider-specific parsing assumptions.
public struct RunBrokerApplicationStreamRecord: Codable, Equatable, Sendable {
    public let channel: RunBrokerApplicationStreamChannel
    public let bytes: Data
    public let startsLogicalLine: Bool
    public let endsLogicalLine: Bool
    public let trailingFragmentByteCount: UInt32
    public let fragmentTruncated: Bool

    public init(
        channel: RunBrokerApplicationStreamChannel,
        bytes: Data,
        startsLogicalLine: Bool,
        endsLogicalLine: Bool,
        trailingFragmentByteCount: UInt32,
        fragmentTruncated: Bool = false
    ) {
        self.channel = channel
        self.bytes = bytes
        self.startsLogicalLine = startsLogicalLine
        self.endsLogicalLine = endsLogicalLine
        self.trailingFragmentByteCount = trailingFragmentByteCount
        self.fragmentTruncated = fragmentTruncated
    }

    public func validate() throws {
        guard !bytes.isEmpty,
              bytes.count <= RunBrokerApplicationBounds.maximumProjectionPayloadBytes,
              trailingFragmentByteCount <= 131_072,
              endsLogicalLine == (trailingFragmentByteCount == 0),
              !endsLogicalLine || !fragmentTruncated else {
            throw RunBrokerApplicationContractError.invalidProjectionMessage
        }
    }
}

public enum RunBrokerApplicationNormalizedEventKind: String, Codable, Equatable, Sendable {
    case progress, assistantMessage = "assistant_message", toolStarted = "tool_started"
    case toolFinished = "tool_finished", approvalRequested = "approval_requested"
}

public struct RunBrokerApplicationNormalizedEvent: Codable, Equatable, Sendable {
    public let kind: RunBrokerApplicationNormalizedEventKind
    public let eventID: UUID
    public let summary: String?
    public let operationID: String?

    public init(
        kind: RunBrokerApplicationNormalizedEventKind,
        eventID: UUID,
        summary: String?,
        operationID: String?
    ) {
        self.kind = kind
        self.eventID = eventID
        self.summary = summary
        self.operationID = operationID
    }

    public func validate() throws {
        guard summary.map({ $0.utf8.count <= 8_192 }) ?? true,
              operationID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw RunBrokerApplicationContractError.invalidProjectionMessage
        }
    }
}

public struct RunBrokerApplicationSupervisorProjection: Codable, Equatable, Sendable {
    public let observation: RunBrokerSupervisorObservation
    public let stream: RunBrokerApplicationStreamRecord?
    public let normalizedEvent: RunBrokerApplicationNormalizedEvent?
    public let terminal: RunBrokerApplicationTerminalEvidence?

    public init(
        observation: RunBrokerSupervisorObservation,
        stream: RunBrokerApplicationStreamRecord?,
        normalizedEvent: RunBrokerApplicationNormalizedEvent?,
        terminal: RunBrokerApplicationTerminalEvidence?
    ) {
        self.observation = observation
        self.stream = stream
        self.normalizedEvent = normalizedEvent
        self.terminal = terminal
    }

    public func validate() throws {
        try stream?.validate()
        try normalizedEvent?.validate()
        try terminal?.validate()
        guard (stream != nil) == (observation.kind == .standardOutput || observation.kind == .standardError),
              stream?.bytes == observation.output,
              terminal.map({ $0.supervisorSequence == observation.supervisorSequence
                && $0.supervisorEventID == observation.supervisorEventID
                && $0.occurredAt == observation.occurredAt }) ?? true else {
            throw RunBrokerApplicationContractError.invalidProjectionMessage
        }
    }
}

public enum RunBrokerApplicationProjectionEvent: Codable, Equatable, Sendable {
    case execution(RunBrokerApplicationExecutionStatus)
    case supervisor(RunBrokerApplicationSupervisorProjection)
    case operation(DurableExecutionClaimRecord)
    case monitor(RunBrokerApplicationMonitoringStatus)
    case runtimeSwitch(RunBrokerApplicationRuntimeSwitchStatus)
    case runtimeSwitchReservation(RunBrokerApplicationRuntimeSwitchReservationProjection)
    case executionControl(RunBrokerApplicationExecutionControlStatus)

    public func validate() throws {
        switch self {
        case .execution(let status): try status.validate()
        case .supervisor(let projection): try projection.validate()
        case .operation(let record):
            guard record.authority.epoch.rawValue > 0 else {
                throw RunBrokerApplicationContractError.invalidProjectionMessage
            }
        case .monitor(let status):
            guard status.authority.epoch.rawValue > 0 else {
                throw RunBrokerApplicationContractError.invalidProjectionMessage
            }
        case .runtimeSwitch(let status): try status.validate()
        case .runtimeSwitchReservation(let reservation): try reservation.validate()
        case .executionControl(let status): try status.validate()
        }
    }

    public func matches(eventKind: String) -> Bool {
        switch self {
        case .execution:
            eventKind == "execution.admitted"
                || eventKind == "execution.authority_transferred"
                || eventKind == "execution.control_transitioned"
        case .supervisor:
            eventKind == "execution.supervisor_observation_recorded"
        case .operation:
            eventKind == "operation.claimed" || eventKind == "operation.tombstoned"
        case .monitor:
            eventKind == "monitor.deadline_upserted"
                || eventKind == "monitor.deadline_removed"
                || eventKind == "monitor.attempt_recorded"
        case .runtimeSwitch:
            eventKind == "runtime_switch.admitted"
                || eventKind == "runtime_switch.policy_transitioned"
                || eventKind == "runtime_switch.completion_archived"
        case .runtimeSwitchReservation:
            eventKind == "runtime_switch.target_reserved"
        case .executionControl:
            eventKind == "execution.force_challenge_recorded"
                || eventKind == "execution.force_challenge_consumed"
        }
    }
}

public struct RunBrokerApplicationRuntimeSwitchReservationProjection: Codable, Equatable, Sendable {
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let reservationID: RuntimeSwitchEvidenceID
    public let targetExecutionID: RunBrokerExecutionID
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let ledgerSequence: UInt64

    public init(
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        reservationID: RuntimeSwitchEvidenceID,
        targetExecutionID: RunBrokerExecutionID,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        ledgerSequence: UInt64
    ) {
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.reservationID = reservationID
        self.targetExecutionID = targetExecutionID
        self.targetManifestSHA256 = targetManifestSHA256
        self.ledgerSequence = ledgerSequence
    }

    public func validate() throws {
        guard ledgerSequence > 0 else {
            throw RunBrokerApplicationContractError.invalidProjectionMessage
        }
    }
}

public struct RunBrokerApplicationProjectionCursor: Codable, Equatable, Sendable {
    public let acknowledgedThrough: Int64
    public let acknowledgedMessageID: UUID?

    public init(acknowledgedThrough: Int64, acknowledgedMessageID: UUID?) {
        self.acknowledgedThrough = acknowledgedThrough
        self.acknowledgedMessageID = acknowledgedMessageID
    }
}

public struct RunBrokerApplicationProjectionHandshake: Codable, Equatable, Sendable {
    public let brokerAcknowledgedThrough: Int64
    public let durableHeadSequence: Int64
    public let durableHeadMessageID: UUID?
    public let next: RunBrokerApplicationProjectionMessage?

    public init(
        brokerAcknowledgedThrough: Int64,
        durableHeadSequence: Int64,
        durableHeadMessageID: UUID?,
        next: RunBrokerApplicationProjectionMessage?
    ) {
        self.brokerAcknowledgedThrough = brokerAcknowledgedThrough
        self.durableHeadSequence = durableHeadSequence
        self.durableHeadMessageID = durableHeadMessageID
        self.next = next
    }

    public func validate() throws {
        guard brokerAcknowledgedThrough >= 0,
              durableHeadSequence >= brokerAcknowledgedThrough,
              (durableHeadSequence == 0) == (durableHeadMessageID == nil),
              next.map({ $0.sequence == brokerAcknowledgedThrough + 1 })
                ?? (durableHeadSequence == brokerAcknowledgedThrough) else {
            throw RunBrokerApplicationContractError.invalidProjectionMessage
        }
        try next?.validate()
    }
}

public extension RunBrokerApplicationExecutionStatus {
    func validate() throws {
        guard authority.epoch.rawValue > 0,
              authority.epoch.rawValue <= UInt64(Int64.max),
              configurationRevision.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              (state == .terminal) == (terminalEvidence != nil) else {
            throw RunBrokerApplicationContractError.invalidExecutionStatus
        }
        try runtimeProtocol?.validate()
        try terminalEvidence?.validate()
        guard terminalEvidence.map({ $0.supervisorSequence <= lastSupervisorSequence }) ?? true else {
            throw RunBrokerApplicationContractError.invalidExecutionStatus
        }
    }
}

public extension RunBrokerApplicationProjectionMessage {
    func validate() throws {
        let milliseconds = occurredAt.timeIntervalSince1970 * 1_000
        guard sequence > 0,
              !eventKind.isEmpty,
              eventKind.utf8.count <= 128,
              event.matches(eventKind: eventKind),
              milliseconds.isFinite,
              occurredAt == Date(
                timeIntervalSince1970: TimeInterval(Int64(milliseconds.rounded(.towardZero))) / 1_000
              ) else {
            throw RunBrokerApplicationContractError.invalidProjectionMessage
        }
        try event.validate()
    }
}
