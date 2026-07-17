import Foundation
import ASTRACore

public enum RunBrokerChannel: String, Codable, CaseIterable, Sendable {
    case production = "prod"
    case development = "dev"

    public init(appChannel: AppChannel) throws {
        switch appChannel {
        case .production:
            self = .production
        case .development:
            self = .development
        case .beta:
            throw RunBrokerContractError.unsupportedChannel(appChannel.rawValue)
        }
    }

    public var appChannel: AppChannel {
        switch self {
        case .production: .production
        case .development: .development
        }
    }
}

public enum RunBrokerContractError: Error, Equatable, Sendable {
    case unsupportedChannel(String)
    case invalidProtocolRange
    case incompatibleProtocol
    case insecureProtocolDowngrade
    case invalidEnvelope
    case invalidAuthentication
    case invalidNonce
    case invalidCapabilitySecret
    case invalidFrame
    case frameTooLarge(actual: Int, maximum: Int)
    case truncatedFrame
    case unexpectedJSONFields
}

public struct RunBrokerProtocolVersion: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let v1 = Self(rawValue: 1)
    /// v2 adds the authenticated application control plane. A v1 app may
    /// negotiate, but it must update before it can start or control a run.
    public static let v2 = Self(rawValue: 2)
    public static let current = Self.v2
    public static let minimumSecure = Self.v1

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RunBrokerProtocolRange: Codable, Equatable, Sendable {
    public let minimum: RunBrokerProtocolVersion
    public let maximum: RunBrokerProtocolVersion

    public init(
        minimum: RunBrokerProtocolVersion,
        maximum: RunBrokerProtocolVersion
    ) throws {
        guard minimum <= maximum else {
            throw RunBrokerContractError.invalidProtocolRange
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    public static let current = try! Self(minimum: .current, maximum: .current)

    private enum CodingKeys: String, CodingKey { case minimum, maximum }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimum: container.decode(RunBrokerProtocolVersion.self, forKey: .minimum),
            maximum: container.decode(RunBrokerProtocolVersion.self, forKey: .maximum)
        )
    }
}

public enum RunBrokerProtocolNegotiator {
    /// Selects the highest mutually supported version, but never below the
    /// security floor declared by either endpoint. Adding a compatibility
    /// version therefore cannot silently downgrade authentication semantics.
    public static func negotiate(
        client: RunBrokerProtocolRange,
        server: RunBrokerProtocolRange,
        clientSecurityFloor: RunBrokerProtocolVersion = .minimumSecure,
        serverSecurityFloor: RunBrokerProtocolVersion = .minimumSecure
    ) throws -> RunBrokerProtocolVersion {
        let lowerBound = max(
            client.minimum,
            server.minimum,
            clientSecurityFloor,
            serverSecurityFloor
        )
        let upperBound = min(client.maximum, server.maximum)
        guard lowerBound <= upperBound else {
            if min(client.maximum, server.maximum) < max(clientSecurityFloor, serverSecurityFloor) {
                throw RunBrokerContractError.insecureProtocolDowngrade
            }
            throw RunBrokerContractError.incompatibleProtocol
        }
        return upperBound
    }
}

public struct RunBrokerNegotiationRequest: Codable, Equatable, Sendable {
    public let supportedVersions: RunBrokerProtocolRange
    public let securityFloor: RunBrokerProtocolVersion

    public init(
        supportedVersions: RunBrokerProtocolRange = .current,
        securityFloor: RunBrokerProtocolVersion = .minimumSecure
    ) {
        self.supportedVersions = supportedVersions
        self.securityFloor = securityFloor
    }
}

public struct RunBrokerNegotiationResponse: Codable, Equatable, Sendable {
    public let selectedVersion: RunBrokerProtocolVersion
    public let serverSupportedVersions: RunBrokerProtocolRange
    public let serverSecurityFloor: RunBrokerProtocolVersion

    public init(
        selectedVersion: RunBrokerProtocolVersion,
        serverSupportedVersions: RunBrokerProtocolRange,
        serverSecurityFloor: RunBrokerProtocolVersion
    ) {
        self.selectedVersion = selectedVersion
        self.serverSupportedVersions = serverSupportedVersions
        self.serverSecurityFloor = serverSecurityFloor
    }
}

public enum RunBrokerHealthStatus: String, Codable, Sendable {
    case healthy
    case degraded
}

public struct RunBrokerHealth: Codable, Equatable, Sendable {
    public let status: RunBrokerHealthStatus
    public let brokerVersion: String
    public let protocolRange: RunBrokerProtocolRange
    public let ledgerAvailable: Bool

    public init(
        status: RunBrokerHealthStatus,
        brokerVersion: String,
        protocolRange: RunBrokerProtocolRange = .current,
        ledgerAvailable: Bool
    ) {
        self.status = status
        self.brokerVersion = brokerVersion
        self.protocolRange = protocolRange
        self.ledgerAvailable = ledgerAvailable
    }
}

public struct RunBrokerCapabilities: Codable, Equatable, Sendable {
    public let health: Bool
    public let schedulerRead: Bool
    public let schedulerMutation: Bool
    public let durableIdempotency: Bool
    public let applicationControl: Bool
    public let gracefulCancellation: Bool
    public let immediateTermination: Bool

    public init(
        health: Bool = true,
        schedulerRead: Bool,
        schedulerMutation: Bool,
        durableIdempotency: Bool,
        applicationControl: Bool = false,
        gracefulCancellation: Bool = false,
        immediateTermination: Bool = false
    ) {
        self.health = health
        self.schedulerRead = schedulerRead
        self.schedulerMutation = schedulerMutation
        self.durableIdempotency = durableIdempotency
        self.applicationControl = applicationControl
        self.gracefulCancellation = gracefulCancellation
        self.immediateTermination = immediateTermination
    }
}
