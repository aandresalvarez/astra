import ASTRACore
import ASTRARunLedger
import Foundation
import RunSupervisorSupport

public enum RunBrokerExecutionAuthorityMode: String, Codable, Equatable, Sendable {
    case durableBroker = "durable_broker"
    case appLocal = "app_local"
}

public struct RunBrokerStartRequest: Sendable {
    public let authorityMode: RunBrokerExecutionAuthorityMode
    public let manifest: ExecutionLaunchManifest
    public let primaryOperationID: RunBrokerOperationID
    public let admissionID: UUID
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        authorityMode: RunBrokerExecutionAuthorityMode,
        manifest: ExecutionLaunchManifest,
        primaryOperationID: RunBrokerOperationID,
        admissionID: UUID,
        arguments: [String],
        environment: [String: String]
    ) {
        self.authorityMode = authorityMode
        self.manifest = manifest
        self.primaryOperationID = primaryOperationID
        self.admissionID = admissionID
        self.arguments = arguments
        self.environment = environment
    }
}

public enum RunBrokerStartCrashPoint: String, CaseIterable, Sendable {
    case afterValidation
    case afterCapabilitySync
    case afterLedgerAdmission
    case afterSupervisorSpawn
    case afterReadyEvidence
    case afterProviderStartedObservation
    case afterProviderStartedEvidence
    case afterTerminalObservation
}

public protocol RunBrokerStartFaultInjecting: Sendable {
    func checkpoint(_ point: RunBrokerStartCrashPoint) throws
}

public struct NoOpRunBrokerStartFaultInjector: RunBrokerStartFaultInjecting {
    public init() {}
    public func checkpoint(_ point: RunBrokerStartCrashPoint) throws {}
}

public enum RunBrokerServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case dormant
    case localAuthorityForbidden
    case missingSupervisionPolicy
    case installationIdentityMismatch
    case storeIdentityMismatch
    case invalidManifest
    case missingCapability
    case capabilityIdentityMismatch
    case supervisorIdentityMismatch
    case supervisorUnavailable
    case nonContiguousSupervisorSequence(expected: UInt64, found: UInt64)
    case supervisorEventConflict(sequence: UInt64)
    case providerStartedBeforeReady
    case outputLimitExceeded(limit: UInt64)
    case supervisorRejected(String)
    case immediateTerminationUnauthorized
    case projectionDidNotBecomeDurable

    public var description: String {
        switch self {
        case .dormant: "RunBroker rollout is dormant"
        case .localAuthorityForbidden: "app-local execution authority is forbidden"
        case .missingSupervisionPolicy: "execution supervision policy is missing"
        case .installationIdentityMismatch: "installation identity mismatch"
        case .storeIdentityMismatch: "store identity mismatch"
        case .invalidManifest: "launch manifest validation failed"
        case .missingCapability: "execution capability is missing"
        case .capabilityIdentityMismatch: "execution capability identity mismatch"
        case .supervisorIdentityMismatch: "supervisor identity mismatch"
        case .supervisorUnavailable: "authenticated supervisor evidence is unavailable"
        case .nonContiguousSupervisorSequence(let expected, let found):
            "supervisor sequence is not contiguous (expected \(expected), found \(found))"
        case .supervisorEventConflict(let sequence):
            "supervisor event conflicts at sequence \(sequence)"
        case .providerStartedBeforeReady: "provider start preceded supervisor readiness"
        case .outputLimitExceeded(let limit): "durable output limit reached (\(limit) bytes)"
        case .supervisorRejected(let code): "supervisor rejected request (\(code))"
        case .immediateTerminationUnauthorized: "immediate termination is unauthorized"
        case .projectionDidNotBecomeDurable: "app projection did not become durable"
        }
    }
}

public enum RunBrokerSupervisorReplaySource: String, Equatable, Sendable {
    case liveAuthenticated
    case offlineAuthenticatedSpool
}

public struct RunBrokerSupervisorReplayBatch: Equatable, Sendable {
    public let identity: RunSupervisorIdentity
    public let source: RunBrokerSupervisorReplaySource
    public let events: [RunSupervisorEvent]
    public let lastSequence: UInt64

    public init(
        identity: RunSupervisorIdentity,
        source: RunBrokerSupervisorReplaySource,
        events: [RunSupervisorEvent],
        lastSequence: UInt64
    ) {
        self.identity = identity
        self.source = source
        self.events = events
        self.lastSequence = lastSequence
    }
}

public protocol RunBrokerSupervisorTransporting: Sendable {
    func replay(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        after sequence: UInt64
    ) throws -> RunBrokerSupervisorReplayBatch

    func acknowledge(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        source: RunBrokerSupervisorReplaySource,
        through sequence: UInt64
    ) throws

    func requestImmediateTermination(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws
}

public protocol RunBrokerSupervisorSpawning: Sendable {
    func spawn(
        payload: RunSupervisorBootstrapPayload,
        installedBrokerExecutableURL: URL
    ) throws
}

public struct RunBrokerCapabilityRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: RunSupervisorIdentity
    public let manifestSHA256: ExecutionLaunchArgumentsSHA256
    public let capability: RunSupervisorCapability

    public init(
        identity: RunSupervisorIdentity,
        manifestSHA256: ExecutionLaunchArgumentsSHA256,
        capability: RunSupervisorCapability
    ) {
        self.identity = identity
        self.manifestSHA256 = manifestSHA256
        self.capability = capability
    }

    public var description: String {
        "RunBrokerCapabilityRecord(execution: \(identity.executionID.rawValue), capability: <redacted>)"
    }
    public var debugDescription: String { description }
}

public protocol RunBrokerCapabilityVaulting: Sendable {
    /// Must not return until both file contents and parent-directory metadata
    /// are durable.
    func persistAndSynchronize(_ record: RunBrokerCapabilityRecord) throws
    func load(executionID: RunBrokerExecutionID) throws -> RunBrokerCapabilityRecord?
}

public protocol RunBrokerServiceLogging: Sendable {
    func record(event: String, fields: [String: String])
}

public struct NoOpRunBrokerServiceLogger: RunBrokerServiceLogging {
    public init() {}
    public func record(event: String, fields: [String: String]) {}
}

public struct RunBrokerReconciliationOutcome: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case admitted
        case running
        case terminal
        case inDoubt = "in_doubt"
    }
    public let state: State
    public let lastSupervisorSequence: UInt64
    public let replaySource: RunBrokerSupervisorReplaySource?

    public init(
        state: State,
        lastSupervisorSequence: UInt64,
        replaySource: RunBrokerSupervisorReplaySource?
    ) {
        self.state = state
        self.lastSupervisorSequence = lastSupervisorSequence
        self.replaySource = replaySource
    }
}

/// Untrusted app/UI input. It contains no verifier-minted evidence or secret.
public struct RunBrokerImmediateTerminationRequest: Equatable, Sendable {
    public let executionID: RunBrokerExecutionID
    public let intent: ExecutionCancellationIntent

    public init(executionID: RunBrokerExecutionID, intent: ExecutionCancellationIntent) {
        self.executionID = executionID
        self.intent = intent
    }
}

struct RunBrokerImmediateTerminationAuthorization: Sendable {
    let identity: RunSupervisorIdentity
    fileprivate init(identity: RunSupervisorIdentity) { self.identity = identity }
}

/// Implemented inside the broker composition root. App/UI code submits only an
/// untrusted request and cannot mint the returned authorization value.
protocol RunBrokerImmediateTerminationAuthorizing: Sendable {
    func authorize(
        request: RunBrokerImmediateTerminationRequest,
        expectedIdentity: RunSupervisorIdentity
    ) throws -> RunBrokerImmediateTerminationAuthorization
}

struct DenyRunBrokerImmediateTerminationAuthorizer: RunBrokerImmediateTerminationAuthorizing {
    init() {}
    func authorize(
        request: RunBrokerImmediateTerminationRequest,
        expectedIdentity: RunSupervisorIdentity
    ) throws -> RunBrokerImmediateTerminationAuthorization {
        throw RunBrokerServiceError.immediateTerminationUnauthorized
    }
}

struct AllowExactRunBrokerImmediateTerminationAuthorizer: RunBrokerImmediateTerminationAuthorizing {
    init() {}
    func authorize(
        request: RunBrokerImmediateTerminationRequest,
        expectedIdentity: RunSupervisorIdentity
    ) throws -> RunBrokerImmediateTerminationAuthorization {
        guard request.intent == .immediate,
              request.executionID == expectedIdentity.executionID else {
            throw RunBrokerServiceError.immediateTerminationUnauthorized
        }
        return .init(identity: expectedIdentity)
    }
}
