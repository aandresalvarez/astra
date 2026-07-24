import ASTRACore
import Foundation

/// Bounds applied after request authentication and before an application
/// command reaches durable state or a provider boundary. The outer frame limit
/// is necessary but insufficient: these per-field limits make resource use and
/// secret handling deterministic.
public enum RunBrokerApplicationBounds {
    public static let maximumArguments = 512
    public static let maximumArgumentBytes = 16_384
    public static let maximumTotalArgumentBytes = 524_288
    public static let maximumEnvironmentEntries = 512
    public static let maximumEnvironmentNameBytes = 256
    public static let maximumEnvironmentValueBytes = 16_384
    public static let maximumTotalEnvironmentBytes = 524_288
    public static let maximumProjectionPayloadBytes = 131_072
    public static let maximumLaunchFutureClockSkew: TimeInterval = 5 * 60
}

public enum RunBrokerApplicationContractError: Error, Equatable, Sendable {
    case taskRunIdentityMismatch
    case invalidLaunchArguments
    case invalidEnvironment
    case invalidManifestMetadata
    case projectionPayloadTooLarge
    case invalidProjectionMessage
    case invalidExecutionStatus
    case unexpectedApplicationResponse
    case invalidRuntimeSwitch
    case invalidExecutionControl
    case invalidProjectionCursor
}

/// Typed service failures safe to return across IPC. Internal errors and
/// filesystem details are never reflected to the caller.
public enum RunBrokerApplicationEndpointError: Error, Equatable, Sendable {
    case requestRejected
    case executionNotFound
    case projectionAcknowledgementConflict
    case externalOperationBlocked
}

/// Authority-free launch intent supplied by an authenticated application.
/// Installation, store, and execution authority are broker-owned facts and
/// therefore cannot be asserted by a client request.
public struct RunBrokerApplicationLaunchDraft: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let executionID: RunBrokerExecutionID
    public let taskID: UUID
    public let configuration: ExecutionLaunchConfigurationSnapshot
    public let declaredEffects: [ExecutionEffectClaim]
    public let supervisionPolicy: ExecutionSupervisionPolicySnapshot
    public let createdAt: Date

    public init(
        executionID: RunBrokerExecutionID,
        taskID: UUID,
        configuration: ExecutionLaunchConfigurationSnapshot,
        declaredEffects: [ExecutionEffectClaim],
        supervisionPolicy: ExecutionSupervisionPolicySnapshot,
        createdAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.executionID = executionID
        self.taskID = taskID
        self.configuration = configuration
        self.declaredEffects = declaredEffects
        self.supervisionPolicy = supervisionPolicy
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, executionID, taskID, configuration
        case declaredEffects, supervisionPolicy, createdAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.stringValue)),
            typeName: "application launch draft"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported application launch draft schema version"
            )
        }
        self.schemaVersion = schemaVersion
        self.executionID = try container.decode(RunBrokerExecutionID.self, forKey: .executionID)
        self.taskID = try container.decode(UUID.self, forKey: .taskID)
        self.configuration = try container.decode(
            ExecutionLaunchConfigurationSnapshot.self,
            forKey: .configuration
        )
        self.declaredEffects = try container.decode([ExecutionEffectClaim].self, forKey: .declaredEffects)
        self.supervisionPolicy = try container.decode(
            ExecutionSupervisionPolicySnapshot.self,
            forKey: .supervisionPolicy
        )
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// Validates the authority-free launch truth shared by initial admission
    /// and runtime-switch replacement admission. Keeping this at the draft
    /// boundary prevents the two entry points from accepting different path,
    /// effect, supervision, or timestamp shapes.
    func validate(now: Date?) throws {
        let launchConfiguration = configuration
        guard Self.validPath(launchConfiguration.executablePath),
              Self.validPath(launchConfiguration.workingDirectory),
              Self.canonicalText(launchConfiguration.configurationRevision, maximumBytes: 256),
              launchConfiguration.modelID.map({ Self.canonicalText($0, maximumBytes: 256) }) ?? true,
              launchConfiguration.environmentVariableNames.count
                <= RunBrokerApplicationBounds.maximumEnvironmentEntries,
              launchConfiguration.environmentVariableNames
                == Array(Set(launchConfiguration.environmentVariableNames)).sorted(),
              launchConfiguration.environmentVariableNames.allSatisfy({ name in
                  !name.isEmpty
                      && name.utf8.count <= RunBrokerApplicationBounds.maximumEnvironmentNameBytes
                      && !name.contains("=")
                      && !name.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              schemaVersion == Self.currentSchemaVersion,
              !declaredEffects.isEmpty,
              declaredEffects.count <= 256,
              Set(declaredEffects).count == declaredEffects.count,
              declaredEffects.allSatisfy({ effect in
                  effect.isKnownAndWellFormed
                      && (!effect.scope.isComputeOnly || effect.access == .shared)
              }),
              Self.hasCanonicalMilliseconds(createdAt),
              now.map({ createdAt <= $0.addingTimeInterval(
                  RunBrokerApplicationBounds.maximumLaunchFutureClockSkew
              ) }) ?? true,
              (try ASTRACanonicalJSON.encode(self)).count
                <= RunBrokerApplicationBounds.maximumProjectionPayloadBytes else {
            throw RunBrokerApplicationContractError.invalidManifestMetadata
        }
    }

    private static func validPath(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && value.first == "/"
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    private static func canonicalText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func hasCanonicalMilliseconds(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > TimeInterval(Int64.min),
              milliseconds < TimeInterval(Int64.max) else { return false }
        let canonical = Date(
            timeIntervalSince1970: TimeInterval(Int64(milliseconds.rounded(.towardZero))) / 1_000
        )
        return date == canonical
    }
}

/// Authenticated, ephemeral launch input. `arguments` and `environment` are
/// intentionally absent from all application responses and status contracts.
/// They may cross the local authenticated socket once and are then handed
/// directly to the supervisor bootstrap payload in memory.
public struct RunBrokerApplicationStartRequest:
    Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
    public let taskRunID: UUID
    public let draft: RunBrokerApplicationLaunchDraft
    public let primaryOperationID: RunBrokerOperationID
    public let runtimeProtocol: RunBrokerRuntimeProtocolManifest
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        taskRunID: UUID,
        draft: RunBrokerApplicationLaunchDraft,
        primaryOperationID: RunBrokerOperationID,
        runtimeProtocol: RunBrokerRuntimeProtocolManifest = .baseline,
        arguments: [String],
        environment: [String: String]
    ) {
        self.taskRunID = taskRunID
        self.draft = draft
        self.primaryOperationID = primaryOperationID
        self.runtimeProtocol = runtimeProtocol
        self.arguments = arguments
        self.environment = environment
    }

    public func validate() throws {
        try validate(now: nil)
    }

    public func validate(now: Date) throws {
        try validate(now: Optional(now))
    }

    private func validate(now: Date?) throws {
        guard draft.executionID.rawValue == taskRunID else {
            throw RunBrokerApplicationContractError.taskRunIdentityMismatch
        }
        try draft.validate(now: now)
        let configuration = draft.configuration
        guard runtimeProtocol.features.contains(.durableTypedStream) else {
            throw RunBrokerApplicationContractError.invalidManifestMetadata
        }
        guard arguments.count <= RunBrokerApplicationBounds.maximumArguments,
              configuration.launchArguments == .init(redacting: arguments),
              arguments.allSatisfy({
                  $0.utf8.count <= RunBrokerApplicationBounds.maximumArgumentBytes
                      && !$0.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              arguments.reduce(into: 0, { $0 += $1.utf8.count })
                <= RunBrokerApplicationBounds.maximumTotalArgumentBytes else {
            throw RunBrokerApplicationContractError.invalidLaunchArguments
        }
        guard environment.count <= RunBrokerApplicationBounds.maximumEnvironmentEntries,
              Set(environment.keys) == Set(configuration.environmentVariableNames),
              environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && key.utf8.count <= RunBrokerApplicationBounds.maximumEnvironmentNameBytes
                      && value.utf8.count <= RunBrokerApplicationBounds.maximumEnvironmentValueBytes
                      && !key.contains("=")
                      && !key.unicodeScalars.contains(where: { $0.value == 0 })
                      && !value.unicodeScalars.contains(where: { $0.value == 0 })
              }),
              environment.reduce(into: 0, { $0 += $1.key.utf8.count + $1.value.utf8.count })
                <= RunBrokerApplicationBounds.maximumTotalEnvironmentBytes else {
            throw RunBrokerApplicationContractError.invalidEnvironment
        }
    }

    public var description: String {
        "RunBrokerApplicationStartRequest(execution: \(draft.executionID.rawValue), arguments: <redacted:\(arguments.count)>, environment: <redacted:\(environment.count)>)"
    }

    public var debugDescription: String { description }

}

public struct RunBrokerApplicationProjectionAcknowledgement: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let messageID: UUID

    public init(sequence: Int64, messageID: UUID) {
        self.sequence = sequence
        self.messageID = messageID
    }
}

public struct RunBrokerApplicationExternalOperationRequest: Codable, Equatable, Sendable {
    public let target: ExternalOperationControlTarget
    public let binding: ExternalOperationControlBinding
    public let cancellationIntent: ExecutionCancellationIntent

    public init(
        target: ExternalOperationControlTarget,
        binding: ExternalOperationControlBinding,
        cancellationIntent: ExecutionCancellationIntent
    ) {
        self.target = target
        self.binding = binding
        self.cancellationIntent = cancellationIntent
    }
}

public enum RunBrokerApplicationExternalOperationCommand: Codable, Equatable, Sendable {
    case observe(RunBrokerApplicationExternalOperationRequest)
    case control(RunBrokerApplicationExternalOperationRequest)
}

public enum RunBrokerApplicationCommand:
    Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
    case start(RunBrokerApplicationStartRequest)
    case brokerContext
    case reconcile(RunBrokerExecutionID)
    case executionStatus(RunBrokerExecutionID)
    case nextProjectionMessage
    case projectionHandshake(RunBrokerApplicationProjectionCursor)
    case acknowledgeProjection(RunBrokerApplicationProjectionAcknowledgement)
    case externalOperation(RunBrokerApplicationExternalOperationCommand)
    case requestGracefulRuntimeSwitch(RunBrokerApplicationRuntimeSwitchSubmission)
    case requestImmediateRuntimeSwitchChallenge(RunBrokerApplicationRuntimeSwitchSubmission)
    case confirmImmediateRuntimeSwitch(RunBrokerApplicationForceConfirmation)
    case runtimeSwitchStatus(RuntimeSwitchRequestID, RuntimeSwitchRequestDigest)
    case cancelExecution(RunBrokerApplicationGracefulCancellation)
    case requestImmediateCancellationChallenge(RunBrokerApplicationImmediateCancellationRequest)
    case confirmImmediateCancellation(RunBrokerApplicationImmediateCancellationConfirmation)
    case writeStandardInput(RunBrokerApplicationInputWrite)
    case closeStandardInput(RunBrokerApplicationExecutionFence)
    case stopMonitoring(RunBrokerApplicationStopMonitoring)

    public func validate(now: Date) throws {
        switch self {
        case .start(let request):
            try request.validate(now: now)
        case .acknowledgeProjection(let acknowledgement):
            guard acknowledgement.sequence > 0 else {
                throw RunBrokerApplicationContractError.invalidProjectionMessage
            }
        case .externalOperation(let command):
            let request = switch command {
            case .observe(let value), .control(let value): value
            }
            guard request.target.authority.epoch.rawValue > 0,
                  request.target.authority.epoch.rawValue <= UInt64(Int64.max),
                  request.binding.authority.epoch.rawValue > 0,
                  request.binding.authority.epoch.rawValue <= UInt64(Int64.max) else {
                throw RunBrokerApplicationContractError.invalidManifestMetadata
            }
        case .projectionHandshake(let cursor):
            guard cursor.acknowledgedThrough >= 0,
                  (cursor.acknowledgedThrough == 0) == (cursor.acknowledgedMessageID == nil) else {
                throw RunBrokerApplicationContractError.invalidProjectionCursor
            }
        case .requestGracefulRuntimeSwitch(let submission):
            try submission.validate(now: now)
            guard submission.mode == .graceful else {
                throw RunBrokerApplicationContractError.invalidRuntimeSwitch
            }
        case .requestImmediateRuntimeSwitchChallenge(let submission):
            try submission.validate(now: now)
            guard submission.mode == .immediate else {
                throw RunBrokerApplicationContractError.invalidRuntimeSwitch
            }
        case .confirmImmediateRuntimeSwitch(let confirmation):
            guard Self.hasCanonicalMilliseconds(confirmation.confirmedAt) else {
                throw RunBrokerApplicationContractError.invalidRuntimeSwitch
            }
        case .cancelExecution(let request):
            try Self.validate(request.fence)
        case .requestImmediateCancellationChallenge(let request):
            try Self.validate(request.fence)
        case .confirmImmediateCancellation(let request):
            try Self.validate(request.fence)
            guard Self.hasCanonicalMilliseconds(request.confirmedAt) else {
                throw RunBrokerApplicationContractError.invalidExecutionControl
            }
        case .writeStandardInput(let request):
            try Self.validate(request.fence)
        case .closeStandardInput(let fence):
            try Self.validate(fence)
        case .stopMonitoring(let request):
            guard request.authority.epoch.rawValue > 0,
                  request.expectedDeadline.map({
                    $0.operationID == request.operationID && $0.authority == request.authority
                  }) ?? true else {
                throw RunBrokerApplicationContractError.invalidExecutionControl
            }
        case .brokerContext, .reconcile, .executionStatus, .nextProjectionMessage,
             .runtimeSwitchStatus:
            break
        }
    }

    public var description: String {
        switch self {
        case .start(let request): request.description
        case .brokerContext: "brokerContext"
        case .reconcile(let executionID): "reconcile(\(executionID.rawValue))"
        case .executionStatus(let executionID): "executionStatus(\(executionID.rawValue))"
        case .nextProjectionMessage: "nextProjectionMessage"
        case .projectionHandshake: "projectionHandshake(<cursor>)"
        case .acknowledgeProjection(let value): "acknowledgeProjection(\(value.sequence))"
        case .externalOperation: "externalOperation(<redacted-descriptor>)"
        case .requestGracefulRuntimeSwitch: "requestGracefulRuntimeSwitch(<redacted>)"
        case .requestImmediateRuntimeSwitchChallenge: "requestImmediateRuntimeSwitchChallenge(<redacted>)"
        case .confirmImmediateRuntimeSwitch: "confirmImmediateRuntimeSwitch(<redacted>)"
        case .runtimeSwitchStatus(let requestID, _): "runtimeSwitchStatus(\(requestID.rawValue))"
        case .cancelExecution: "cancelExecution(<fence>)"
        case .requestImmediateCancellationChallenge: "requestImmediateCancellationChallenge(<redacted>)"
        case .confirmImmediateCancellation: "confirmImmediateCancellation(<redacted>)"
        case .writeStandardInput: "writeStandardInput(<redacted>)"
        case .closeStandardInput: "closeStandardInput(<fence>)"
        case .stopMonitoring(let request): "stopMonitoring(\(request.operationID.rawValue))"
        }
    }

    public var debugDescription: String { description }

    private static func validate(_ fence: RunBrokerApplicationExecutionFence) throws {
        try fence.validate()
    }

    private static func hasCanonicalMilliseconds(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > TimeInterval(Int64.min),
              milliseconds < TimeInterval(Int64.max) else { return false }
        return date == Date(
            timeIntervalSince1970: TimeInterval(Int64(milliseconds.rounded(.towardZero))) / 1_000
        )
    }
}

public enum RunBrokerApplicationExecutionState: String, Codable, Equatable, Sendable {
    case admitted
    case running
    case terminal
    case inDoubt = "in_doubt"
}

/// Secret-free canonical status. Provider and supervisor PIDs are diagnostics,
/// not authority, and are deliberately excluded.
public struct RunBrokerApplicationExecutionStatus: Codable, Equatable, Sendable {
    public let executionID: RunBrokerExecutionID
    /// Broker-minted fencing authority. A client must persist this returned
    /// value before constructing any subsequent control fence.
    public let authority: RunBrokerAuthority
    public let state: RunBrokerApplicationExecutionState
    public let lastSupervisorSequence: UInt64
    public let manifestSHA256: ExecutionLaunchArgumentsSHA256?
    public let configurationRevision: String?
    public let runtimeProtocol: RunBrokerRuntimeProtocolManifest?
    public let terminalEvidence: RunBrokerApplicationTerminalEvidence?

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        state: RunBrokerApplicationExecutionState,
        lastSupervisorSequence: UInt64,
        manifestSHA256: ExecutionLaunchArgumentsSHA256? = nil,
        configurationRevision: String? = nil,
        runtimeProtocol: RunBrokerRuntimeProtocolManifest? = nil,
        terminalEvidence: RunBrokerApplicationTerminalEvidence? = nil
    ) {
        self.executionID = executionID
        self.authority = authority
        self.state = state
        self.lastSupervisorSequence = lastSupervisorSequence
        self.manifestSHA256 = manifestSHA256
        self.configurationRevision = configurationRevision
        self.runtimeProtocol = runtimeProtocol
        self.terminalEvidence = terminalEvidence
    }
}

public struct RunBrokerApplicationProjectionMessage: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let messageID: UUID
    public let eventKind: String
    public let event: RunBrokerApplicationProjectionEvent
    public let occurredAt: Date

    public init(
        sequence: Int64,
        messageID: UUID,
        eventKind: String,
        event: RunBrokerApplicationProjectionEvent,
        occurredAt: Date
    ) throws {
        guard sequence > 0 else { throw RunBrokerApplicationContractError.invalidProjectionMessage }
        guard !eventKind.isEmpty,
              eventKind.utf8.count <= 128,
              !eventKind.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RunBrokerApplicationContractError.projectionPayloadTooLarge
        }
        self.sequence = sequence
        self.messageID = messageID
        self.eventKind = eventKind
        self.event = event
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, messageID, eventKind, event, occurredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(Int64.self, forKey: .sequence),
            messageID: container.decode(UUID.self, forKey: .messageID),
            eventKind: container.decode(String.self, forKey: .eventKind),
            event: container.decode(RunBrokerApplicationProjectionEvent.self, forKey: .event),
            occurredAt: container.decode(Date.self, forKey: .occurredAt)
        )
    }
}

public enum RunBrokerApplicationResponse: Codable, Equatable, Sendable {
    case brokerContext(RunBrokerApplicationContext)
    case executionStatus(RunBrokerApplicationExecutionStatus)
    case projectionMessage(RunBrokerApplicationProjectionMessage?)
    case projectionHandshake(RunBrokerApplicationProjectionHandshake)
    case projectionAcknowledged
    case externalOperation(ExternalOperationControlAssessment)
    case runtimeSwitchStatus(RunBrokerApplicationRuntimeSwitchStatus)
    case executionControl(RunBrokerApplicationExecutionControlStatus)
    case monitoring(RunBrokerApplicationMonitoringStatus)

    public func validate(for command: RunBrokerApplicationCommand) throws {
        switch (command, self) {
        case (.brokerContext, .brokerContext(let context)):
            try context.validate()
        case (.start(let request), .executionStatus(let status)):
            try Self.validate(
                status,
                expectedExecutionID: request.draft.executionID,
                expectedAuthority: nil
            )
        case (.reconcile(let executionID), .executionStatus(let status)),
             (.executionStatus(let executionID), .executionStatus(let status)):
            try Self.validate(status, expectedExecutionID: executionID, expectedAuthority: nil)
        case (.nextProjectionMessage, .projectionMessage(let message)):
            try message?.validate()
        case (.acknowledgeProjection, .projectionAcknowledged):
            break
        case (.projectionHandshake(let cursor), .projectionHandshake(let handshake)):
            try handshake.validate()
            let exact = cursor.acknowledgedThrough == handshake.brokerAcknowledgedThrough
            let saveBeforeAckReplay = cursor.acknowledgedThrough
                    == handshake.brokerAcknowledgedThrough + 1
                && handshake.next?.sequence == cursor.acknowledgedThrough
                && handshake.next?.messageID == cursor.acknowledgedMessageID
            guard exact || saveBeforeAckReplay else {
                throw RunBrokerApplicationContractError.invalidProjectionMessage
            }
        case (.externalOperation(let external), .externalOperation(let assessment)):
            let expectedIntent = switch external {
            case .observe(let request), .control(let request): request.cancellationIntent
            }
            guard assessment.cancellationIntent == expectedIntent else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
        case (.requestGracefulRuntimeSwitch(let submission), .runtimeSwitchStatus(let status)),
             (.requestImmediateRuntimeSwitchChallenge(let submission), .runtimeSwitchStatus(let status)):
            try Self.validate(status, submission: submission)
        case (.confirmImmediateRuntimeSwitch(let confirmation), .runtimeSwitchStatus(let status)):
            guard status.requestID == confirmation.requestID,
                  status.requestDigest == confirmation.requestDigest else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
        case (.runtimeSwitchStatus(let requestID, let digest), .runtimeSwitchStatus(let status)):
            guard status.requestID == requestID, status.requestDigest == digest else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
        case (.cancelExecution(let request), .executionControl(let status)):
            try Self.validate(status, fence: request.fence, intent: .graceful)
        case (.requestImmediateCancellationChallenge(let request), .executionControl(let status)):
            try Self.validate(status, fence: request.fence, intent: nil)
            let requestDigest = try request.requestDigest()
            guard let challenge = status.challenge,
                  challenge.requestID == request.requestID,
                  challenge.requestDigest == requestDigest,
                  challenge.executionID == request.fence.executionID,
                  challenge.authority == request.fence.authority,
                  challenge.expectedSupervisorSequence
                    == request.fence.expectedSupervisorSequence,
                  challenge.actorID == request.actorID,
                  challenge.sessionID == request.sessionID,
                  challenge.audit == request.audit,
                  status.cancellationIntent == nil,
                  status.acceptedEffectID == nil else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
        case (.confirmImmediateCancellation(let request), .executionControl(let status)):
            try Self.validate(status, fence: request.fence, intent: .immediate)
            guard let challenge = status.challenge,
                  challenge.challengeID == request.challengeID,
                  challenge.requestDigest == request.requestDigest,
                  challenge.executionID == request.fence.executionID,
                  challenge.authority == request.fence.authority,
                  challenge.expectedSupervisorSequence
                    == request.fence.expectedSupervisorSequence,
                  challenge.actorID == request.actorID,
                  challenge.sessionID == request.sessionID,
                  status.cancellationIntent == .immediate,
                  status.acceptedEffectID == request.effectID else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
        case (.writeStandardInput(let request), .executionControl(let status)):
            try Self.validate(status, fence: request.fence, intent: nil)
        case (.closeStandardInput(let fence), .executionControl(let status)):
            try Self.validate(status, fence: fence, intent: nil)
        case (.stopMonitoring(let request), .monitoring(let status)):
            guard status.operationID == request.operationID,
                  status.authority == request.authority,
                  status.stopped,
                  status.deadline == nil else {
                throw RunBrokerApplicationContractError.unexpectedApplicationResponse
            }
        default:
            throw RunBrokerApplicationContractError.unexpectedApplicationResponse
        }
    }

    private static func validate(
        _ status: RunBrokerApplicationRuntimeSwitchStatus,
        submission: RunBrokerApplicationRuntimeSwitchSubmission
    ) throws {
        try status.validate()
        guard status.requestID == submission.requestID,
              status.source == submission.expectedSource,
              status.targetExecutionID == submission.targetDraft.executionID else {
            throw RunBrokerApplicationContractError.unexpectedApplicationResponse
        }
    }

    private static func validate(
        _ status: RunBrokerApplicationExecutionControlStatus,
        fence: RunBrokerApplicationExecutionFence,
        intent: ExecutionCancellationIntent?
    ) throws {
        try status.validate()
        guard status.fence.executionID == fence.executionID,
              status.fence.authority == fence.authority,
              status.fence.expectedSupervisorSequence == fence.expectedSupervisorSequence,
              status.acceptedSupervisorSequence >= fence.expectedSupervisorSequence,
              intent.map({ status.cancellationIntent == $0 }) ?? true else {
            throw RunBrokerApplicationContractError.unexpectedApplicationResponse
        }
    }

    private static func validate(
        _ status: RunBrokerApplicationExecutionStatus,
        expectedExecutionID: RunBrokerExecutionID,
        expectedAuthority: RunBrokerAuthority?
    ) throws {
        try status.validate()
        guard status.executionID == expectedExecutionID,
              expectedAuthority.map({ status.authority == $0 }) ?? true,
              status.authority.epoch.rawValue > 0,
              status.authority.epoch.rawValue <= UInt64(Int64.max) else {
            throw RunBrokerApplicationContractError.invalidExecutionStatus
        }
    }
}
