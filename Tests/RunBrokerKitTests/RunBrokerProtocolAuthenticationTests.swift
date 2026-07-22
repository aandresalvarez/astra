import Foundation
import Testing
import ASTRACore
@testable import RunBrokerClient
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
                client: try .init(minimum: .v1, maximum: .v1),
                server: try .init(minimum: .v1, maximum: .v1),
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

    @Test("Authenticated execution-control responses require exact request and effect correlation")
    func authenticatedExecutionControlResponseCorrelation() throws {
        let fixture = try authFixture()
        let fence = RunBrokerApplicationExecutionFence(
            executionID: .init(rawValue: uuid(70)),
            authority: .init(id: .init(rawValue: uuid(71)), epoch: .initial),
            expectedSupervisorSequence: 12
        )
        let actor = try RuntimeSwitchActorID(rawValue: "operator:test")
        let sessionID = uuid(72)
        let audit = RuntimeForceSwitchAudit(
            auditID: .init(rawValue: uuid(73)),
            source: .taskChat,
            reasonCode: .operatorEmergencyStop
        )
        let challengeRequest = RunBrokerApplicationImmediateCancellationRequest(
            requestID: uuid(74),
            fence: fence,
            actorID: actor,
            sessionID: sessionID,
            audit: audit
        )
        let digest = try challengeRequest.requestDigest()
        let challenge = try ExecutionForceChallenge(
            challengeID: .init(rawValue: uuid(75)),
            requestDigest: digest,
            requestID: challengeRequest.requestID,
            executionID: fence.executionID,
            authority: fence.authority,
            expectedSupervisorSequence: fence.expectedSupervisorSequence,
            actorID: actor,
            sessionID: sessionID,
            audit: audit,
            issuedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(300)
        )

        let validChallengeStatus = RunBrokerApplicationExecutionControlStatus(
            fence: fence,
            acceptedSupervisorSequence: fence.expectedSupervisorSequence,
            cancellationIntent: nil,
            challenge: challenge,
            acceptedEffectID: nil
        )
        _ = try authenticatedClient(
            fixture: fixture,
            response: .executionControl(validChallengeStatus)
        ).perform(
            .application(.requestImmediateCancellationChallenge(challengeRequest)),
            requestID: uuid(76),
            idempotencyKey: uuid(77)
        )

        let differentRequest = RunBrokerApplicationImmediateCancellationRequest(
            requestID: uuid(78),
            fence: fence,
            actorID: actor,
            sessionID: sessionID,
            audit: audit
        )
        #expect(throws: RunBrokerApplicationContractError.unexpectedApplicationResponse) {
            _ = try authenticatedClient(
                fixture: fixture,
                response: .executionControl(validChallengeStatus)
            ).perform(
                .application(.requestImmediateCancellationChallenge(differentRequest)),
                requestID: uuid(79),
                idempotencyKey: uuid(80)
            )
        }

        let effectID = RuntimeSwitchEffectID(rawValue: uuid(81))
        let confirmation = RunBrokerApplicationImmediateCancellationConfirmation(
            fence: fence,
            challengeID: challenge.challengeID,
            requestDigest: digest,
            actorID: actor,
            sessionID: sessionID,
            confirmedAt: fixture.now.addingTimeInterval(1),
            effectID: effectID
        )
        let wrongEffectStatus = RunBrokerApplicationExecutionControlStatus(
            fence: fence,
            acceptedSupervisorSequence: fence.expectedSupervisorSequence,
            cancellationIntent: .immediate,
            challenge: challenge,
            acceptedEffectID: .init(rawValue: uuid(82))
        )
        #expect(throws: RunBrokerApplicationContractError.unexpectedApplicationResponse) {
            _ = try authenticatedClient(
                fixture: fixture,
                response: .executionControl(wrongEffectStatus)
            ).perform(
                .application(.confirmImmediateCancellation(confirmation)),
                requestID: uuid(83),
                idempotencyKey: uuid(84)
            )
        }

        let unrelatedChallenge = try ExecutionForceChallenge(
            challengeID: .init(rawValue: uuid(85)),
            requestDigest: digest,
            requestID: challengeRequest.requestID,
            executionID: fence.executionID,
            authority: fence.authority,
            expectedSupervisorSequence: fence.expectedSupervisorSequence,
            actorID: actor,
            sessionID: sessionID,
            audit: audit,
            issuedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(300)
        )
        let unrelatedStatus = RunBrokerApplicationExecutionControlStatus(
            fence: fence,
            acceptedSupervisorSequence: fence.expectedSupervisorSequence,
            cancellationIntent: .immediate,
            challenge: unrelatedChallenge,
            acceptedEffectID: effectID
        )
        #expect(throws: RunBrokerApplicationContractError.unexpectedApplicationResponse) {
            _ = try authenticatedClient(
                fixture: fixture,
                response: .executionControl(unrelatedStatus)
            ).perform(
                .application(.confirmImmediateCancellation(confirmation)),
                requestID: uuid(86),
                idempotencyKey: uuid(87)
            )
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

    @Test("Production peer verifier requires the trusted team and exact ASTRA identifier")
    func productionPeerCodeIdentity() throws {
        let identities: [Int32: RunBrokerCodeSigningIdentity] = [
            10: .init(
                identifier: "com.coral.ASTRA",
                teamIdentifier: "TEAM123",
                cdHash: Data(repeating: 0x10, count: 20)
            ),
            11: .init(
                identifier: "com.attacker.tool",
                teamIdentifier: "TEAM123",
                cdHash: Data(repeating: 0x11, count: 20)
            ),
            12: .init(
                identifier: "com.coral.ASTRA",
                teamIdentifier: "OTHER",
                cdHash: Data(repeating: 0x12, count: 20)
            ),
        ]
        let verifier = DarwinRunBrokerPeerCodeIdentityVerifier(
            trustedTeamIdentifier: "TEAM123",
            allowedIdentifiers: ["com.coral.ASTRA", "com.coral.ASTRA.dev"],
            identity: { identities[$0] }
        )
        #expect(verifier.verify(processID: 10) == .verified)
        #expect(verifier.verify(processID: 11) == .rejected)
        #expect(verifier.verify(processID: 12) == .rejected)
        #expect(verifier.verify(processID: 13) == .rejected)

        let policy = RunBrokerPeerIdentityPolicy(
            expectedUserID: 501,
            requiresCodeIdentity: true,
            codeIdentityVerifier: verifier
        )
        try policy.verify(.init(effectiveUserID: 501, processID: 10))
        #expect(throws: RunBrokerAuthenticationError.peerCodeIdentityRejected) {
            try policy.verify(.init(effectiveUserID: 501, processID: 11))
        }

        let unavailable = DarwinRunBrokerPeerCodeIdentityVerifier(
            trustedTeamIdentifier: nil,
            allowedIdentifiers: ["com.coral.ASTRA"],
            identity: { _ in nil }
        )
        #expect(unavailable.verify(processID: 10) == .unavailable)
        #expect(!unavailable.requiresDeveloperIDIdentity)

        let developerID = DarwinRunBrokerPeerCodeIdentityVerifier(
            trustedTeamIdentifier: "TEAM123",
            allowedIdentifiers: ["com.coral.ASTRA"],
            identity: { _ in nil }
        )
        #expect(developerID.requiresDeveloperIDIdentity)
    }

    @Test("Application launch fields are bounded, strict-coded, MAC-bound, and redacted")
    func applicationLaunchBoundary() throws {
        let fixture = try authFixture()
        let wire = RunBrokerWireCodec()
        let start = applicationStartRequest(
            arguments: ["provider", "secret-argument"],
            environment: ["SECRET_TOKEN": "secret-environment"]
        )
        try start.validate()
        let request = try fixture.authenticator.authenticatedRequest(
            requestID: uuid(50),
            idempotencyKey: uuid(51),
            channel: .development,
            installationID: fixture.installationID,
            command: .application(.start(start)),
            now: fixture.now
        )
        let decoded = try wire.decodeRequest(frame: wire.encode(request: request))
        #expect(decoded == request)
        #expect(!String(describing: request.command).contains("secret-argument"))
        #expect(!String(describing: request.command).contains("secret-environment"))

        let tamperedStart = applicationStartRequest(
            arguments: ["provider", "changed"],
            environment: ["SECRET_TOKEN": "changed"]
        )
        let tampered = RunBrokerRequestEnvelope(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            channel: request.channel,
            installationID: request.installationID,
            command: .application(.start(tamperedStart)),
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

        let payload = try wire.frameCodec.decode(frame: wire.encode(request: request))
        var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var command = try #require(object["command"] as? [String: Any])
        var application = try #require(command["application"] as? [String: Any])
        application["unexpectedAuthority"] = true
        command["application"] = application
        object["command"] = command
        let hostile = try wire.frameCodec.encode(
            payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(throws: RunBrokerContractError.unexpectedJSONFields) {
            try wire.decodeRequest(frame: hostile)
        }
    }

    @Test("Application launch rejects identity drift and oversized ephemeral fields")
    func applicationLaunchBounds() throws {
        let mismatch = RunBrokerApplicationStartRequest(
            taskRunID: uuid(99),
            draft: applicationDraft(from: applicationManifest()),
            primaryOperationID: .init(rawValue: uuid(55)),
            arguments: [],
            environment: [:]
        )
        #expect(throws: RunBrokerApplicationContractError.taskRunIdentityMismatch) {
            try mismatch.validate()
        }
        let oversized = applicationStartRequest(
            arguments: [String(
                repeating: "x",
                count: RunBrokerApplicationBounds.maximumArgumentBytes + 1
            )],
            environment: [:]
        )
        #expect(throws: RunBrokerApplicationContractError.invalidLaunchArguments) {
            try oversized.validate()
        }
        let invalidEnvironment = applicationStartRequest(
            arguments: [],
            environment: ["BAD=NAME": "value"]
        )
        #expect(throws: RunBrokerApplicationContractError.invalidManifestMetadata) {
            try invalidEnvironment.validate()
        }

        let invalidPolicy = Data("""
        {
            "hardTimeoutSeconds":3600,
            "idleProgressTimeoutSeconds":300,
            "maximumOutputEventBytes":32768,
            "maximumPersistedOutputBytes":0
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExecutionSupervisionPolicySnapshot.self,
                from: invalidPolicy
            )
        }

        let configuration = applicationManifest().configuration
        let encodedConfiguration = try JSONEncoder().encode(configuration)
        var configurationObject = try #require(
            JSONSerialization.jsonObject(with: encodedConfiguration) as? [String: Any]
        )
        configurationObject["environmentVariableNames"] = ["Z_TOKEN", "A_TOKEN"]
        let noncanonicalConfiguration = try JSONSerialization.data(
            withJSONObject: configurationObject
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ExecutionLaunchConfigurationSnapshot.self,
                from: noncanonicalConfiguration
            )
        }
    }

    @Test("Authority-free launch draft has a strict stable wire identity")
    func applicationLaunchDraftStrictWireIdentity() throws {
        let draft = applicationDraft(from: applicationManifest())
        let canonical = try ASTRACanonicalJSON.encode(draft)
        #expect(try ASTRACanonicalJSON.encode(draft) == canonical)
        let object = try #require(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        #expect(object["authority"] == nil)
        #expect(object["installationID"] == nil)
        #expect(object["storeID"] == nil)

        var unknown = object
        unknown["authority"] = ["epoch": 999]
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                RunBrokerApplicationLaunchDraft.self,
                from: JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
            )
        }

        var future = object
        future["schemaVersion"] = RunBrokerApplicationLaunchDraft.currentSchemaVersion + 1
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                RunBrokerApplicationLaunchDraft.self,
                from: JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
            )
        }

        var missing = object
        missing.removeValue(forKey: "supervisionPolicy")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                RunBrokerApplicationLaunchDraft.self,
                from: JSONSerialization.data(withJSONObject: missing, options: [.sortedKeys])
            )
        }
    }

    @Test("Legacy application protocol receives typed update-required without dispatch")
    func applicationProtocolRequiresUpdate() throws {
        let fixture = try authFixture()
        let handler = RejectIfCalledApplicationHandler()
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: fixture.installationID,
            brokerVersion: "v2",
            authenticator: fixture.authenticator,
            peerPolicy: .init(expectedUserID: 501),
            scheduler: .init(
                ledger: UnavailableRunBrokerMonitorLedger(),
                monitor: UnavailableRunBrokerExternalOperationMonitor()
            ),
            applicationHandler: handler
        )
        let request = try fixture.authenticator.authenticatedRequest(
            protocolVersion: .v1,
            requestID: uuid(57),
            idempotencyKey: uuid(58),
            channel: .development,
            installationID: fixture.installationID,
            command: .application(.executionStatus(.init(rawValue: uuid(53)))),
            now: fixture.now
        )
        let response = endpoint.handle(
            request,
            peer: .init(effectiveUserID: 501, processID: 42),
            now: fixture.now
        )
        #expect(response.error?.code == .updateRequired)
        #expect(handler.callCount == 0)
    }

    @Test("application composition does not over-advertise destructive control")
    func applicationCapabilitiesComeFromHandler() throws {
        let fixture = try authFixture()
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: fixture.installationID,
            brokerVersion: "v2",
            authenticator: fixture.authenticator,
            peerPolicy: .init(expectedUserID: 501),
            scheduler: .init(
                ledger: UnavailableRunBrokerMonitorLedger(),
                monitor: UnavailableRunBrokerExternalOperationMonitor()
            ),
            applicationHandler: RejectIfCalledApplicationHandler()
        )
        let request = try fixture.authenticator.authenticatedRequest(
            protocolVersion: .current,
            requestID: uuid(59),
            idempotencyKey: uuid(60),
            channel: .development,
            installationID: fixture.installationID,
            command: .capabilities,
            now: fixture.now
        )
        let response = endpoint.handle(
            request,
            peer: .init(effectiveUserID: 501, processID: 42),
            now: fixture.now
        )
        guard case .capabilities(let capabilities) = response.result else {
            Issue.record("Expected capabilities response")
            return
        }
        #expect(capabilities.applicationControl)
        #expect(!capabilities.gracefulCancellation)
        #expect(!capabilities.immediateTermination)
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

    private func authenticatedClient(
        fixture: (
            authenticator: RunBrokerRequestAuthenticator,
            installationID: RunBrokerInstallationID,
            now: Date
        ),
        response: RunBrokerApplicationResponse
    ) -> RunBrokerClient {
        RunBrokerClient(
            connector: AuthenticatedApplicationResponseConnector(
                authenticator: fixture.authenticator,
                response: response
            ),
            authenticator: fixture.authenticator,
            channel: .development,
            installationID: fixture.installationID,
            now: { fixture.now }
        )
    }

    private func applicationStartRequest(
        arguments: [String],
        environment: [String: String]
    ) -> RunBrokerApplicationStartRequest {
        let base = applicationManifest()
        let configuration = ExecutionLaunchConfigurationSnapshot(
            runtimeID: base.configuration.runtimeID,
            modelID: base.configuration.modelID,
            executablePath: base.configuration.executablePath,
            launchArguments: .init(redacting: arguments),
            workingDirectory: base.configuration.workingDirectory,
            environmentVariableNames: environment.keys.sorted(),
            configurationRevision: base.configuration.configurationRevision
        )
        let manifest = ExecutionLaunchManifest(
            installationID: base.installationID,
            storeID: base.storeID,
            executionID: base.executionID,
            taskID: base.taskID,
            authority: base.authority,
            configuration: configuration,
            declaredEffects: base.declaredEffects,
            supervisionPolicy: base.supervisionPolicy,
            createdAt: base.createdAt
        )
        return .init(
            taskRunID: manifest.executionID.rawValue,
            draft: applicationDraft(from: manifest),
            primaryOperationID: .init(rawValue: uuid(55)),
            arguments: arguments,
            environment: environment
        )
    }

    private func applicationManifest() -> ExecutionLaunchManifest {
        .init(
            installationID: .init(rawValue: uuid(1)),
            storeID: .init(rawValue: uuid(52)),
            executionID: .init(rawValue: uuid(53)),
            taskID: uuid(54),
            authority: .init(id: .init(rawValue: uuid(56)), epoch: .initial),
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: "/usr/bin/true",
                workingDirectory: "/tmp",
                configurationRevision: "test"
            ),
            declaredEffects: [.computeOnly],
            supervisionPolicy: try! .init(
                hardTimeoutSeconds: 3_600,
                idleProgressTimeoutSeconds: 300
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func applicationDraft(
        from manifest: ExecutionLaunchManifest
    ) -> RunBrokerApplicationLaunchDraft {
        .init(
            executionID: manifest.executionID,
            taskID: manifest.taskID,
            configuration: manifest.configuration,
            declaredEffects: manifest.declaredEffects,
            supervisionPolicy: manifest.supervisionPolicy!,
            createdAt: manifest.createdAt
        )
    }
}

private final class RejectIfCalledApplicationHandler:
    RunBrokerApplicationCommandHandling, @unchecked Sendable
{
    private let lock = NSLock()
    private(set) var callCount = 0

    func handle(
        _ command: RunBrokerApplicationCommand,
        idempotencyKey: UUID,
        now: Date
    ) throws -> RunBrokerApplicationResponse {
        lock.lock()
        callCount += 1
        lock.unlock()
        throw RunBrokerApplicationEndpointError.requestRejected
    }
}

private struct AuthenticatedApplicationResponseConnector: RunBrokerConnecting {
    let authenticator: RunBrokerRequestAuthenticator
    let response: RunBrokerApplicationResponse

    func connect() throws -> any RunBrokerConnection {
        AuthenticatedApplicationResponseConnection(
            authenticator: authenticator,
            response: response
        )
    }
}

private final class AuthenticatedApplicationResponseConnection:
    RunBrokerConnection, @unchecked Sendable
{
    private let authenticator: RunBrokerRequestAuthenticator
    private let response: RunBrokerApplicationResponse
    private let wire = RunBrokerWireCodec()
    private let lock = NSLock()
    private var request: RunBrokerRequestEnvelope?

    init(
        authenticator: RunBrokerRequestAuthenticator,
        response: RunBrokerApplicationResponse
    ) {
        self.authenticator = authenticator
        self.response = response
    }

    var peerIdentity: RunBrokerPeerIdentity {
        get throws { .init(effectiveUserID: 501, processID: 42) }
    }

    func send(frame: Data) throws {
        let decoded = try wire.decodeRequest(frame: frame)
        lock.lock()
        request = decoded
        lock.unlock()
    }

    func receiveFrame(using codec: RunBrokerFrameCodec) throws -> Data? {
        lock.lock()
        let request = self.request
        lock.unlock()
        guard let request else { throw RunBrokerContractError.truncatedFrame }
        let envelope = RunBrokerResponseEnvelope(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            result: .application(response)
        )
        return try wire.encode(response: authenticator.authenticatedResponse(
            envelope,
            for: request
        ))
    }

    func close() {}
}

private struct FixedRandom: RunBrokerRandomGenerating {
    let bytes: Data
    func randomBytes(count: Int) throws -> Data { bytes }
}

private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}
