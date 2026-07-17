import ASTRACore
import Foundation

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

package struct RunSupervisorAuthenticatedControlResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let body: Data
    let authentication: String

    package init(body: Data, authentication: String) throws {
        guard !body.isEmpty,
              body.count <= RunSupervisorProtocol.maximumControlFrameBytes,
              authentication.utf8.count == 64 else {
            throw RunSupervisorError.invalidSchema
        }
        schemaVersion = 1
        self.body = body
        self.authentication = authentication
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, body, authentication
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw RunSupervisorError.invalidSchema
        }
        schemaVersion = 1
        body = try container.decode(Data.self, forKey: .body)
        authentication = try container.decode(String.self, forKey: .authentication)
        guard !body.isEmpty,
              body.count <= RunSupervisorProtocol.maximumControlFrameBytes,
              authentication.utf8.count == 64 else {
            throw RunSupervisorError.invalidSchema
        }
    }
}

package struct RunSupervisorUnsignedControlResponse: Codable {
    let domain: String
    let protocolVersion: UInt16
    let executionID: RunBrokerExecutionID
    let nonce: UUID
    let action: RunSupervisorControlAction
    let body: Data
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
            authentication: authentication,
            responseVerificationCapability: capability
        )
    }

    package static func makeResponse(
        _ response: RunSupervisorControlResponse,
        for request: RunSupervisorControlRequest,
        capability: RunSupervisorCapability
    ) throws -> RunSupervisorAuthenticatedControlResponse {
        let body = try RunSupervisorDigests.canonicalData(response)
        let unsigned = RunSupervisorUnsignedControlResponse(
            domain: "astra.run-supervisor.control-response.v1",
            protocolVersion: request.protocolVersion,
            executionID: request.executionID,
            nonce: request.nonce,
            action: request.action,
            body: body
        )
        return try .init(
            body: body,
            authentication: RunSupervisorDigests.hmac(
                try RunSupervisorDigests.canonicalData(unsigned),
                capability: capability
            )
        )
    }

    package static func verifyResponse(
        _ envelope: RunSupervisorAuthenticatedControlResponse,
        for request: RunSupervisorControlRequest,
        capability: RunSupervisorCapability
    ) throws -> RunSupervisorControlResponse {
        let unsigned = RunSupervisorUnsignedControlResponse(
            domain: "astra.run-supervisor.control-response.v1",
            protocolVersion: request.protocolVersion,
            executionID: request.executionID,
            nonce: request.nonce,
            action: request.action,
            body: envelope.body
        )
        let expected = RunSupervisorDigests.hmac(
            try RunSupervisorDigests.canonicalData(unsigned),
            capability: capability
        )
        guard RunSupervisorDigests.constantTimeEqual(expected, envelope.authentication) else {
            throw RunSupervisorError.responseAuthenticationFailed
        }
        return try RunSupervisorWireCoding.decode(
            RunSupervisorControlResponse.self,
            from: envelope.body
        )
    }
}
