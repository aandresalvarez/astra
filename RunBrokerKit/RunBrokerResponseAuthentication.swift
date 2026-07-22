import Foundation

/// The response body remains opaque until its MAC has been verified against
/// the originating request transcript. This prevents a same-UID replacement
/// socket from claiming broker health, acceptance, scheduler state, or errors.
public struct RunBrokerAuthenticatedResponseEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let body: Data
    public let authentication: Data

    public init(body: Data, authentication: Data) throws {
        guard !body.isEmpty,
              body.count <= RunBrokerFrameCodec.defaultMaximumPayloadBytes,
              authentication.count == RunBrokerAuthenticationPolicy.macByteCount else {
            throw RunBrokerContractError.invalidEnvelope
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.body = body
        self.authentication = authentication
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, body, authentication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion)
                == Self.currentSchemaVersion else {
            throw RunBrokerContractError.invalidEnvelope
        }
        try self.init(
            body: container.decode(Data.self, forKey: .body),
            authentication: container.decode(Data.self, forKey: .authentication)
        )
    }
}
