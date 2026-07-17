import Foundation
import Testing
import ASTRACore
@testable import RunBrokerKit

@Suite("RunBroker framed protocol and authentication")
struct RunBrokerProtocolAuthenticationTests {
    @Test("Frame codec round trips and rejects an oversized length before payload allocation")
    func frameBounds() throws {
        let codec = RunBrokerFrameCodec(maximumPayloadBytes: 8)
        let frame = try codec.encode(payload: Data("12345678".utf8))
        #expect(try codec.decode(frame: frame) == Data("12345678".utf8))

        let oversizedHeader = Data([0, 0, 0, 9])
        #expect(throws: RunBrokerContractError.frameTooLarge(actual: 9, maximum: 8)) {
            try codec.decodedPayloadLength(header: oversizedHeader)
        }
        #expect(throws: RunBrokerContractError.truncatedFrame) {
            try codec.decode(frame: Data([0, 0, 0, 4, 1]))
        }
    }

    @Test("Negotiation chooses the highest secure overlap and fails closed")
    func negotiation() throws {
        let v2 = RunBrokerProtocolVersion(rawValue: 2)
        let v3 = RunBrokerProtocolVersion(rawValue: 3)
        let client = try RunBrokerProtocolRange(minimum: .v1, maximum: v3)
        let server = try RunBrokerProtocolRange(minimum: v2, maximum: v2)
        #expect(
            try RunBrokerProtocolNegotiator.negotiate(
                client: client,
                server: server,
                clientSecurityFloor: v2,
                serverSecurityFloor: v2
            ) == v2
        )

        #expect(throws: RunBrokerContractError.insecureProtocolDowngrade) {
            try RunBrokerProtocolNegotiator.negotiate(
                client: .current,
                server: .current,
                clientSecurityFloor: v2,
                serverSecurityFloor: v2
            )
        }
        #expect(throws: RunBrokerContractError.incompatibleProtocol) {
            try RunBrokerProtocolNegotiator.negotiate(
                client: .current,
                server: try .init(minimum: v3, maximum: v3)
            )
        }
    }

    @Test("Strict JSON rejects unknown fields at any nesting level")
    func strictJSON() throws {
        let fixture = try authFixture()
        let wire = RunBrokerWireCodec()
        let request = try fixture.authenticator.authenticatedRequest(
            requestID: uuid(10),
            idempotencyKey: uuid(11),
            channel: .development,
            installationID: fixture.installationID,
            command: .health,
            now: fixture.now
        )
        let encoded = try wire.encode(request: request)
        let payload = try wire.frameCodec.decode(frame: encoded)
        var object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        var authentication = try #require(object["authentication"] as? [String: Any])
        authentication["unexpected"] = true
        object["authentication"] = authentication
        let hostilePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let hostileFrame = try wire.frameCodec.encode(payload: hostilePayload)

        #expect(throws: RunBrokerContractError.unexpectedJSONFields) {
            try wire.decodeRequest(frame: hostileFrame)
        }
    }

    @Test("Decoded authentication enforces fixed nonce and MAC lengths")
    func decodedAuthenticationBounds() throws {
        let fixture = try authFixture()
        let wire = RunBrokerWireCodec()
        let request = try fixture.authenticator.authenticatedRequest(
            channel: .development,
            installationID: fixture.installationID,
            command: .health,
            now: fixture.now
        )
        let payload = try wire.frameCodec.decode(frame: wire.encode(request: request))
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var authentication = try #require(object["authentication"] as? [String: Any])
        authentication["nonce"] = Data([1]).base64EncodedString()
        object["authentication"] = authentication
        let invalid = try wire.frameCodec.encode(
            payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(throws: (any Error).self) {
            try wire.decodeRequest(frame: invalid)
        }
    }

    @Test("MAC binds channel, installation, command, and full request transcript")
    func transcriptBinding() throws {
        let fixture = try authFixture()
        let request = try fixture.authenticator.authenticatedRequest(
            requestID: uuid(20),
            idempotencyKey: uuid(21),
            channel: .development,
            installationID: fixture.installationID,
            command: .health,
            now: fixture.now
        )
        try fixture.authenticator.verify(
            request,
            expectedChannel: .development,
            expectedInstallationID: fixture.installationID,
            now: fixture.now
        )
        #expect(throws: RunBrokerAuthenticationError.wrongChannel) {
            try fixture.authenticator.verify(
                request,
                expectedChannel: .production,
                expectedInstallationID: fixture.installationID,
                now: fixture.now
            )
        }
        #expect(throws: RunBrokerAuthenticationError.wrongInstallation) {
            try fixture.authenticator.verify(
                request,
                expectedChannel: .development,
                expectedInstallationID: RunBrokerInstallationID(rawValue: uuid(99)),
                now: fixture.now
            )
        }

        let tampered = RunBrokerRequestEnvelope(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            channel: request.channel,
            installationID: request.installationID,
            command: .capabilities,
            authentication: request.authentication
        )
        #expect(throws: RunBrokerAuthenticationError.invalidMAC) {
            try fixture.authenticator.verify(
                tampered,
                expectedChannel: .development,
                expectedInstallationID: fixture.installationID,
                now: fixture.now
            )
        }
    }

    @Test("Replay protector is bounded and rejects a live nonce replay")
    func replay() throws {
        let protector = RunBrokerReplayProtector(capacity: 2, retention: 10)
        let now = Date(timeIntervalSince1970: 1_000)
        try protector.consume(nonce: Data([1]), now: now)
        #expect(throws: RunBrokerAuthenticationError.replay) {
            try protector.consume(nonce: Data([1]), now: now)
        }
        try protector.consume(nonce: Data([2]), now: now)
        #expect(throws: RunBrokerAuthenticationError.replayCapacityExceeded) {
            try protector.consume(nonce: Data([3]), now: now)
        }
        // Saturation must not evict a still-live nonce and reopen its replay
        // window. Capacity pressure fails closed until an entry expires.
        #expect(throws: RunBrokerAuthenticationError.replay) {
            try protector.consume(nonce: Data([1]), now: now)
        }

        let expiring = RunBrokerReplayProtector(capacity: 2, retention: 1)
        try expiring.consume(nonce: Data([4]), now: now)
        try expiring.consume(nonce: Data([4]), now: now.addingTimeInterval(2))
    }

    @Test("Response MAC binds exact response bytes to the originating request transcript")
    func responseTranscriptBinding() throws {
        let fixture = try authFixture()
        let request = try fixture.authenticator.authenticatedRequest(
            requestID: uuid(30),
            idempotencyKey: uuid(31),
            channel: .development,
            installationID: fixture.installationID,
            command: .health,
            now: fixture.now
        )
        let body = RunBrokerResponseEnvelope(
            protocolVersion: .current,
            requestID: request.requestID,
            result: .health(
                .init(status: .healthy, brokerVersion: "sealed", ledgerAvailable: true)
            )
        )
        let authenticated = try fixture.authenticator.authenticatedResponse(body, for: request)
        #expect(try fixture.authenticator.verify(authenticated, for: request) == body)

        let forgedBody = RunBrokerResponseEnvelope(
            protocolVersion: .current,
            requestID: request.requestID,
            result: .accepted
        )
        let forgedBytes = try RunBrokerWireCodec.responseBodyData(forgedBody)
        let forged = try RunBrokerAuthenticatedResponseEnvelope(
            body: forgedBytes,
            authentication: authenticated.authentication
        )
        #expect(throws: RunBrokerAuthenticationError.invalidResponseMAC) {
            try fixture.authenticator.verify(forged, for: request)
        }

        let reboundRequest = RunBrokerRequestEnvelope(
            protocolVersion: request.protocolVersion,
            requestID: uuid(32),
            idempotencyKey: uuid(33),
            channel: request.channel,
            installationID: request.installationID,
            command: .capabilities,
            authentication: request.authentication
        )
        #expect(throws: RunBrokerAuthenticationError.invalidResponseMAC) {
            try fixture.authenticator.verify(authenticated, for: reboundRequest)
        }
    }

    @Test("Full-length comparison logic accepts equality and rejects first and last byte mismatches")
    func fullLengthComparisonLogic() {
        let value = Data(repeating: 7, count: 32)
        var firstMismatch = value
        firstMismatch[0] = 8
        var lastMismatch = value
        lastMismatch[31] = 8
        #expect(RunBrokerRequestAuthenticator.constantTimeEqual(value, value))
        #expect(!RunBrokerRequestAuthenticator.constantTimeEqual(value, firstMismatch))
        #expect(!RunBrokerRequestAuthenticator.constantTimeEqual(value, lastMismatch))
        #expect(!RunBrokerRequestAuthenticator.constantTimeEqual(value, Data(value.dropLast())))
    }

    @Test("Peer policy enforces UID and fails closed when required code identity is unavailable")
    func peerPolicy() throws {
        let peer = RunBrokerPeerIdentity(effectiveUserID: 501, processID: 42)
        try RunBrokerPeerIdentityPolicy(expectedUserID: 501).verify(peer)
        #expect(throws: RunBrokerAuthenticationError.wrongPeerUID(expected: 501, actual: 502)) {
            try RunBrokerPeerIdentityPolicy(expectedUserID: 501).verify(
                .init(effectiveUserID: 502, processID: 42)
            )
        }
        #expect(throws: RunBrokerAuthenticationError.peerCodeIdentityUnavailable) {
            try RunBrokerPeerIdentityPolicy(
                expectedUserID: 501,
                requiresCodeIdentity: true
            ).verify(peer)
        }
    }

    private func authFixture() throws -> (
        authenticator: RunBrokerRequestAuthenticator,
        installationID: RunBrokerInstallationID,
        now: Date
    ) {
        let secret = try RunBrokerCapabilitySecret(bytes: Data(repeating: 0xA5, count: 32))
        return (
            RunBrokerRequestAuthenticator(
                secret: secret,
                random: FixedRandom(bytes: Data(repeating: 0x5A, count: 16))
            ),
            RunBrokerInstallationID(rawValue: uuid(1)),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private struct FixedRandom: RunBrokerRandomGenerating {
    let bytes: Data
    func randomBytes(count: Int) throws -> Data { bytes }
}

private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}
