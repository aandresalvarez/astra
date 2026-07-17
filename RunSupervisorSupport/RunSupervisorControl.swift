import ASTRACore
import CryptoKit
import Darwin
import Foundation

public enum RunSupervisorControlActionKind: String, Codable, Sendable {
    case handshake
    case replay
    case acknowledge
    case writeStandardInput = "write_stdin"
    case closeStandardInput = "close_stdin"
    case cancel
    case status
}

public struct RunSupervisorControlAction: Codable, Equatable, Sendable {
    public let kind: RunSupervisorControlActionKind
    public let afterSequence: UInt64?
    public let acknowledgeThrough: UInt64?
    public let standardInputLine: String?
    public let cancellationIntent: ExecutionCancellationIntent?

    public init(
        kind: RunSupervisorControlActionKind,
        afterSequence: UInt64? = nil,
        acknowledgeThrough: UInt64? = nil,
        standardInputLine: String? = nil,
        cancellationIntent: ExecutionCancellationIntent? = nil
    ) {
        self.kind = kind
        self.afterSequence = afterSequence
        self.acknowledgeThrough = acknowledgeThrough
        self.standardInputLine = standardInputLine
        self.cancellationIntent = cancellationIntent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, afterSequence, acknowledgeThrough, standardInputLine, cancellationIntent
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(RunSupervisorControlActionKind.self, forKey: .kind)
        afterSequence = try container.decodeIfPresent(UInt64.self, forKey: .afterSequence)
        acknowledgeThrough = try container.decodeIfPresent(UInt64.self, forKey: .acknowledgeThrough)
        standardInputLine = try container.decodeIfPresent(String.self, forKey: .standardInputLine)
        cancellationIntent = try container.decodeIfPresent(
            ExecutionCancellationIntent.self,
            forKey: .cancellationIntent
        )
        try validate()
    }

    public func validate() throws {
        switch kind {
        case .handshake, .status, .closeStandardInput:
            guard afterSequence == nil, acknowledgeThrough == nil,
                  standardInputLine == nil, cancellationIntent == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .replay:
            guard afterSequence != nil, acknowledgeThrough == nil,
                  standardInputLine == nil, cancellationIntent == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .acknowledge:
            guard acknowledgeThrough != nil, afterSequence == nil,
                  standardInputLine == nil, cancellationIntent == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .writeStandardInput:
            guard let standardInputLine,
                  !standardInputLine.contains("\n"),
                  standardInputLine.utf8.count <= 32_768,
                  afterSequence == nil, acknowledgeThrough == nil, cancellationIntent == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .cancel:
            guard let cancellationIntent, cancellationIntent != .none,
                  afterSequence == nil, acknowledgeThrough == nil, standardInputLine == nil else {
                throw RunSupervisorError.invalidSchema
            }
        }
    }
}

public struct RunSupervisorControlRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let protocolVersion: UInt16
    public let executionID: RunBrokerExecutionID
    public let nonce: UUID
    public let issuedAtMilliseconds: Int64
    public let action: RunSupervisorControlAction
    public let authentication: String

    public init(
        protocolVersion: UInt16 = RunSupervisorProtocol.maximumVersion,
        executionID: RunBrokerExecutionID,
        nonce: UUID,
        issuedAtMilliseconds: Int64,
        action: RunSupervisorControlAction,
        authentication: String
    ) {
        self.schemaVersion = 1
        self.protocolVersion = protocolVersion
        self.executionID = executionID
        self.nonce = nonce
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.action = action
        self.authentication = authentication
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, protocolVersion, executionID, nonce, issuedAtMilliseconds, action, authentication
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw RunSupervisorError.invalidSchema
        }
        schemaVersion = 1
        protocolVersion = try container.decode(UInt16.self, forKey: .protocolVersion)
        executionID = try container.decode(RunBrokerExecutionID.self, forKey: .executionID)
        nonce = try container.decode(UUID.self, forKey: .nonce)
        issuedAtMilliseconds = try container.decode(Int64.self, forKey: .issuedAtMilliseconds)
        action = try container.decode(RunSupervisorControlAction.self, forKey: .action)
        authentication = try container.decode(String.self, forKey: .authentication)
        guard authentication.utf8.count == 64 else { throw RunSupervisorError.invalidSchema }
    }
}

package struct RunSupervisorUnsignedControlRequest: Codable {
    let schemaVersion: Int
    let protocolVersion: UInt16
    let executionID: RunBrokerExecutionID
    let nonce: UUID
    let issuedAtMilliseconds: Int64
    let action: RunSupervisorControlAction
}

public struct RunSupervisorControlResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let protocolMinimumVersion: UInt16
    public let protocolMaximumVersion: UInt16
    public let accepted: Bool
    public let events: [RunSupervisorEvent]
    public let lastSequence: UInt64
    public let errorCode: String?

    public init(
        accepted: Bool,
        events: [RunSupervisorEvent] = [],
        lastSequence: UInt64,
        errorCode: String? = nil
    ) {
        schemaVersion = 1
        protocolMinimumVersion = RunSupervisorProtocol.minimumVersion
        protocolMaximumVersion = RunSupervisorProtocol.maximumVersion
        self.accepted = accepted
        self.events = events
        self.lastSequence = lastSequence
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, protocolMinimumVersion, protocolMaximumVersion
        case accepted, events, lastSequence, errorCode
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw RunSupervisorError.invalidSchema
        }
        schemaVersion = 1
        protocolMinimumVersion = try container.decode(UInt16.self, forKey: .protocolMinimumVersion)
        protocolMaximumVersion = try container.decode(UInt16.self, forKey: .protocolMaximumVersion)
        accepted = try container.decode(Bool.self, forKey: .accepted)
        events = try container.decode([RunSupervisorEvent].self, forKey: .events)
        lastSequence = try container.decode(UInt64.self, forKey: .lastSequence)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        guard protocolMinimumVersion <= protocolMaximumVersion,
              protocolMinimumVersion <= RunSupervisorProtocol.maximumVersion,
              protocolMaximumVersion >= RunSupervisorProtocol.minimumVersion,
              events.count <= 4,
              events.allSatisfy({ $0.sequence <= lastSequence }),
              (accepted ? errorCode == nil : errorCode != nil) else {
            throw RunSupervisorError.invalidSchema
        }
    }
}

public enum RunSupervisorControlAuthentication {
    public static func makeRequest(
        executionID: RunBrokerExecutionID,
        action: RunSupervisorControlAction,
        capability: RunSupervisorCapability,
        nonce: UUID = UUID(),
        now: Date = Date(),
        protocolVersion: UInt16 = RunSupervisorProtocol.maximumVersion
    ) throws -> RunSupervisorControlRequest {
        let millis = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let unsigned = RunSupervisorUnsignedControlRequest(
            schemaVersion: 1,
            protocolVersion: protocolVersion,
            executionID: executionID,
            nonce: nonce,
            issuedAtMilliseconds: millis,
            action: action
        )
        let authentication = RunSupervisorDigests.hmac(
            try RunSupervisorDigests.canonicalData(unsigned),
            capability: capability
        )
        return .init(
            protocolVersion: protocolVersion,
            executionID: executionID,
            nonce: nonce,
            issuedAtMilliseconds: millis,
            action: action,
            authentication: authentication
        )
    }
}

public final class RunSupervisorControlAuthenticator: @unchecked Sendable {
    private static let maximumTrackedNonces = 4_096
    private let executionID: RunBrokerExecutionID
    private let capability: RunSupervisorCapability
    private let expectedUID: uid_t
    private let clock: any RunSupervisorClock
    private let allowedSkew: TimeInterval
    private let lock = NSLock()
    private var seenNonces: [UUID: Date] = [:]

    public init(
        executionID: RunBrokerExecutionID,
        capability: RunSupervisorCapability,
        expectedUID: uid_t = geteuid(),
        clock: any RunSupervisorClock = SystemRunSupervisorClock(),
        allowedSkew: TimeInterval = 60
    ) {
        self.executionID = executionID
        self.capability = capability
        self.expectedUID = expectedUID
        self.clock = clock
        self.allowedSkew = allowedSkew
    }

    public func authenticate(_ request: RunSupervisorControlRequest, peerUID: uid_t) throws {
        guard peerUID == expectedUID else { throw RunSupervisorError.peerUIDMismatch }
        guard request.executionID == executionID else { throw RunSupervisorError.invalidIdentity }
        guard request.protocolVersion >= RunSupervisorProtocol.minimumVersion,
              request.protocolVersion <= RunSupervisorProtocol.maximumVersion else {
            throw RunSupervisorError.unsupportedProtocol(request.protocolVersion)
        }
        try request.action.validate()
        let issuedAt = Date(timeIntervalSince1970: Double(request.issuedAtMilliseconds) / 1_000)
        let now = clock.now()
        guard abs(now.timeIntervalSince(issuedAt)) <= allowedSkew else {
            throw RunSupervisorError.staleAuthentication
        }
        let unsigned = RunSupervisorUnsignedControlRequest(
            schemaVersion: request.schemaVersion,
            protocolVersion: request.protocolVersion,
            executionID: request.executionID,
            nonce: request.nonce,
            issuedAtMilliseconds: request.issuedAtMilliseconds,
            action: request.action
        )
        let expected = RunSupervisorDigests.hmac(
            try RunSupervisorDigests.canonicalData(unsigned),
            capability: capability
        )
        guard constantTimeEqual(expected, request.authentication) else {
            throw RunSupervisorError.authenticationFailed
        }
        lock.lock()
        defer { lock.unlock() }
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) <= allowedSkew }
        guard seenNonces[request.nonce] == nil else { throw RunSupervisorError.replayedNonce }
        guard seenNonces.count < Self.maximumTrackedNonces else {
            throw RunSupervisorError.authenticationFailed
        }
        seenNonces[request.nonce] = now
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
