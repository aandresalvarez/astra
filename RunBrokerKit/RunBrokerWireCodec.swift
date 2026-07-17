import Foundation
import ASTRACore

public struct RunBrokerFrameCodec: Sendable {
    public static let defaultMaximumPayloadBytes = 1_048_576

    public let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes) {
        precondition(maximumPayloadBytes > 0 && maximumPayloadBytes <= Int(UInt32.max))
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public func encode(payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadBytes else {
            throw RunBrokerContractError.frameTooLarge(
                actual: payload.count,
                maximum: maximumPayloadBytes
            )
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    public func decode(frame: Data) throws -> Data {
        guard frame.count >= MemoryLayout<UInt32>.size else {
            throw RunBrokerContractError.truncatedFrame
        }
        let length = frame.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length <= UInt32(maximumPayloadBytes) else {
            throw RunBrokerContractError.frameTooLarge(
                actual: Int(length),
                maximum: maximumPayloadBytes
            )
        }
        let expected = MemoryLayout<UInt32>.size + Int(length)
        guard frame.count == expected else {
            throw RunBrokerContractError.truncatedFrame
        }
        return frame.dropFirst(MemoryLayout<UInt32>.size)
    }

    public func decodedPayloadLength(header: Data) throws -> Int {
        guard header.count == MemoryLayout<UInt32>.size else {
            throw RunBrokerContractError.truncatedFrame
        }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumPayloadBytes) else {
            throw RunBrokerContractError.frameTooLarge(
                actual: Int(length),
                maximum: maximumPayloadBytes
            )
        }
        return Int(length)
    }
}

public struct RunBrokerWireCodec: Sendable {
    public let frameCodec: RunBrokerFrameCodec

    public init(frameCodec: RunBrokerFrameCodec = .init()) {
        self.frameCodec = frameCodec
    }

    public func encode(request: RunBrokerRequestEnvelope) throws -> Data {
        try frameCodec.encode(payload: Self.encoder().encode(request))
    }

    public func decodeRequest(frame: Data) throws -> RunBrokerRequestEnvelope {
        let request: RunBrokerRequestEnvelope = try strictDecode(
            Self.self,
            data: frameCodec.decode(frame: frame)
        )
        guard request.protocolVersion >= .minimumSecure else {
            throw RunBrokerContractError.insecureProtocolDowngrade
        }
        return request
    }

    public func encode(response: RunBrokerResponseEnvelope) throws -> Data {
        try response.validate()
        return try frameCodec.encode(payload: Self.encoder().encode(response))
    }

    public func decodeResponse(frame: Data) throws -> RunBrokerResponseEnvelope {
        let response: RunBrokerResponseEnvelope = try strictDecode(
            Self.self,
            data: frameCodec.decode(frame: frame)
        )
        try response.validate()
        return response
    }

    /// Encodes the authenticated fields without the MAC. Sorted-key JSON is
    /// the v1 canonical transcript; future versions must define a new one.
    public static func authenticationTranscript(
        protocolVersion: RunBrokerProtocolVersion,
        requestID: UUID,
        idempotencyKey: UUID,
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        command: RunBrokerCommand,
        issuedAtMilliseconds: Int64,
        nonce: Data
    ) throws -> Data {
        try encoder().encode(
            RunBrokerAuthenticationTranscriptV1(
                protocolVersion: protocolVersion,
                requestID: requestID,
                idempotencyKey: idempotencyKey,
                channel: channel,
                installationID: installationID,
                command: command,
                issuedAtMilliseconds: issuedAtMilliseconds,
                nonce: nonce
            )
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func strictDecode<T: Codable>(
        _: RunBrokerWireCodec.Type,
        data: Data
    ) throws -> T {
        let decoded = try Self.decoder().decode(T.self, from: data)

        // Foundation's Codable decoder otherwise ignores unknown keys. Compare
        // the complete JSON object with a canonical re-encoding so additional
        // fields at any nesting level are rejected instead of being treated as
        // a forward-compatible authority expansion.
        let receivedObject = try JSONSerialization.jsonObject(with: data)
        let canonicalData = try Self.encoder().encode(decoded)
        let canonicalObject = try JSONSerialization.jsonObject(with: canonicalData)
        guard (receivedObject as AnyObject).isEqual(canonicalObject) else {
            throw RunBrokerContractError.unexpectedJSONFields
        }
        return decoded
    }
}

private struct RunBrokerAuthenticationTranscriptV1: Encodable {
    let domain = "astra.run-broker.request.v1"
    let protocolVersion: RunBrokerProtocolVersion
    let requestID: UUID
    let idempotencyKey: UUID
    let channel: RunBrokerChannel
    let installationID: RunBrokerInstallationID
    let command: RunBrokerCommand
    let issuedAtMilliseconds: Int64
    let nonce: Data
}
