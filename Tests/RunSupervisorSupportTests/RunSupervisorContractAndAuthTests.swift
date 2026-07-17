import ASTRACore
import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor bootstrap and control contracts", .serialized)
struct RunSupervisorContractAndAuthTests {
    @Test("bootstrap validates exact identity manifest argv and environment")
    func bootstrapValidation() throws {
        let arguments = ["--opaque", "secret value"]
        let payload = try RunSupervisorTestSupport.payload(arguments: arguments)
        try RunSupervisorBootstrapValidator.validate(payload)

        let encoded = try RunSupervisorDigests.canonicalData(payload)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("secret value"))
        let discovery = RunSupervisorDiscoveryRecord(
            identity: payload.expectedIdentity,
            manifestSHA256: payload.manifestSHA256,
            launchAuthenticator: try RunSupervisorDigests.launchAuthenticator(
                payload: payload,
                capability: payload.capability
            ),
            capabilitySHA256: try RunSupervisorDigests.capability(payload.capability),
            createdAt: .distantPast
        )
        let durable = String(decoding: try RunSupervisorDigests.canonicalData(discovery), as: UTF8.self)
        #expect(!durable.contains("secret value"))
        #expect(!durable.contains(payload.capability.base64))
    }

    @Test("changed argv with retained manifest digest fails before admission")
    func changedArgumentsFail() throws {
        let original = try RunSupervisorTestSupport.payload(arguments: ["first"])
        let changed = RunSupervisorBootstrapPayload(
            manifest: original.manifest,
            manifestSHA256: original.manifestSHA256,
            expectedIdentity: original.expectedIdentity,
            arguments: ["second"],
            environment: original.environment,
            capability: original.capability
        )
        #expect(throws: RunSupervisorError.invalidArgumentDigest) {
            try RunSupervisorBootstrapValidator.validate(changed)
        }
    }

    @Test("bootstrap rejects C string truncation and ambiguous environment names")
    func bootstrapRejectsCStringAmbiguity() throws {
        let nulArgument = try RunSupervisorTestSupport.payload(arguments: ["prefix\0suffix"])
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorBootstrapValidator.validate(nulArgument)
        }
        let invalidEnvironment = try RunSupervisorTestSupport.payload(
            environment: ["BAD=NAME": "value"]
        )
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorBootstrapValidator.validate(invalidEnvironment)
        }
    }

    @Test("unknown bootstrap keys and oversized frames fail closed")
    func unknownKeysAndOversize() throws {
        let payload = try RunSupervisorTestSupport.payload()
        let data = try RunSupervisorDigests.canonicalData(payload)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["futureField"] = true
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorWireCoding.decode(RunSupervisorBootstrapPayload.self, from: changed)
        }

        var pipeFDs = [Int32](repeating: -1, count: 2)
        #expect(pipe(&pipeFDs) == 0)
        defer { close(pipeFDs[0]); close(pipeFDs[1]) }
        var size = UInt32(1025).bigEndian
        _ = withUnsafeBytes(of: &size) { Darwin.write(pipeFDs[1], $0.baseAddress, 4) }
        #expect(throws: RunSupervisorError.oversizedFrame(limit: 1_024)) {
            try RunSupervisorFrameIO.readFrame(from: pipeFDs[0], maximumBytes: 1_024)
        }
    }

    @Test("read-only run-directory lookup cannot steal launch creation authority")
    func openExecutionDirectoryDoesNotCreate() throws {
        let rootURL = try RunSupervisorTestSupport.temporaryDirectory("open-only")
        let root = try RunSupervisorTrustedRoot(path: rootURL.path)
        let executionID = try RunSupervisorTestSupport.payload(identitySeed: 24).manifest.executionID
        #expect(throws: RunSupervisorError.self) {
            try root.openExecutionDirectory(executionID)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty)
        #expect(try root.acquireExecutionDirectory(executionID).wasCreated)
    }

    @Test("authenticated control rejects wrong uid key stale timestamp and nonce replay")
    func authenticatedControl() throws {
        let payload = try RunSupervisorTestSupport.payload()
        let clock = FixedClock(date: Date(timeIntervalSince1970: 1_000))
        let authenticator = RunSupervisorControlAuthenticator(
            executionID: payload.manifest.executionID,
            capability: payload.capability,
            expectedUID: 501,
            clock: clock,
            allowedSkew: 10
        )
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .status),
            capability: payload.capability,
            nonce: RunSupervisorTestSupport.uuid(42),
            now: clock.date
        )
        try authenticator.authenticate(request, peerUID: 501)
        #expect(throws: RunSupervisorError.replayedNonce) {
            try authenticator.authenticate(request, peerUID: 501)
        }
        let wrongUID = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .status),
            capability: payload.capability,
            now: clock.date
        )
        #expect(throws: RunSupervisorError.peerUIDMismatch) {
            try authenticator.authenticate(wrongUID, peerUID: 502)
        }
        let stale = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .status),
            capability: payload.capability,
            now: clock.date.addingTimeInterval(-11)
        )
        #expect(throws: RunSupervisorError.staleAuthentication) {
            try authenticator.authenticate(stale, peerUID: 501)
        }
        let wrongCapability = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .status),
            capability: .init(bytes: Data(repeating: 9, count: 32)),
            now: clock.date
        )
        #expect(throws: RunSupervisorError.authenticationFailed) {
            try authenticator.authenticate(wrongCapability, peerUID: 501)
        }
    }

    @Test("nested control and response schemas reject unknown keys and incompatible versions")
    func strictNestedControlSchemas() throws {
        let payload = try RunSupervisorTestSupport.payload()
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .status),
            capability: payload.capability
        )
        var requestObject = try #require(
            JSONSerialization.jsonObject(with: RunSupervisorWireCoding.encode(request)) as? [String: Any]
        )
        var action = try #require(requestObject["action"] as? [String: Any])
        action["futureActionField"] = true
        requestObject["action"] = action
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorWireCoding.decode(
                RunSupervisorControlRequest.self,
                from: JSONSerialization.data(withJSONObject: requestObject)
            )
        }

        let response = RunSupervisorControlResponse(accepted: true, lastSequence: 0)
        var responseObject = try #require(
            JSONSerialization.jsonObject(with: RunSupervisorWireCoding.encode(response)) as? [String: Any]
        )
        responseObject["futureResponseField"] = true
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorWireCoding.decode(
                RunSupervisorControlResponse.self,
                from: JSONSerialization.data(withJSONObject: responseObject)
            )
        }
        responseObject.removeValue(forKey: "futureResponseField")
        responseObject["protocolMinimumVersion"] = 9
        responseObject["protocolMaximumVersion"] = 10
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorWireCoding.decode(
                RunSupervisorControlResponse.self,
                from: JSONSerialization.data(withJSONObject: responseObject)
            )
        }
        #expect(String(describing: payload.capability) == "<redacted execution capability>")
        #expect(String(reflecting: payload.capability) == "<redacted execution capability>")

        let event = RunSupervisorEvent(
            sequence: 1,
            id: RunSupervisorTestSupport.uuid(88),
            timestamp: RunSupervisorTestSupport.fixedDate,
            kind: .supervisorReady,
            payload: .init()
        )
        var nestedResponse = try #require(
            JSONSerialization.jsonObject(with: RunSupervisorWireCoding.encode(
                RunSupervisorControlResponse(accepted: true, events: [event], lastSequence: 1)
            )) as? [String: Any]
        )
        var events = try #require(nestedResponse["events"] as? [[String: Any]])
        var nestedEvent = events[0]
        var nestedPayload = try #require(nestedEvent["payload"] as? [String: Any])
        nestedPayload["futurePayloadField"] = true
        nestedEvent["payload"] = nestedPayload
        events[0] = nestedEvent
        nestedResponse["events"] = events
        #expect(throws: RunSupervisorError.invalidSchema) {
            try RunSupervisorWireCoding.decode(
                RunSupervisorControlResponse.self,
                from: JSONSerialization.data(withJSONObject: nestedResponse)
            )
        }
    }

    @Test("response MAC binds the nonce execution action protocol and exact response body")
    func mutuallyAuthenticatedResponse() throws {
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 71)
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .replay, afterSequence: 3),
            capability: payload.capability,
            nonce: RunSupervisorTestSupport.uuid(72),
            protocolVersion: 1
        )
        let response = RunSupervisorControlResponse(accepted: true, lastSequence: 4)
        let envelope = try RunSupervisorControlAuthentication.makeResponse(
            response,
            for: request,
            capability: payload.capability
        )
        #expect(try RunSupervisorControlAuthentication.verifyResponse(
            envelope,
            for: request,
            capability: payload.capability
        ) == response)

        var changedBodyObject = try #require(
            JSONSerialization.jsonObject(with: envelope.body) as? [String: Any]
        )
        changedBodyObject["lastSequence"] = 5
        let changedBody = try JSONSerialization.data(withJSONObject: changedBodyObject)
        let forgedBody = try RunSupervisorAuthenticatedControlResponse(
            body: changedBody,
            authentication: envelope.authentication
        )
        #expect(throws: RunSupervisorError.responseAuthenticationFailed) {
            try RunSupervisorControlAuthentication.verifyResponse(
                forgedBody,
                for: request,
                capability: payload.capability
            )
        }

        let changedContexts = [
            try RunSupervisorControlAuthentication.makeRequest(
                executionID: payload.manifest.executionID,
                action: request.action,
                capability: payload.capability,
                nonce: RunSupervisorTestSupport.uuid(73),
                protocolVersion: request.protocolVersion
            ),
            try RunSupervisorControlAuthentication.makeRequest(
                executionID: payload.manifest.executionID,
                action: .init(kind: .status),
                capability: payload.capability,
                nonce: request.nonce,
                protocolVersion: request.protocolVersion
            ),
            try RunSupervisorControlAuthentication.makeRequest(
                executionID: try RunSupervisorTestSupport.payload(identitySeed: 81).manifest.executionID,
                action: request.action,
                capability: payload.capability,
                nonce: request.nonce,
                protocolVersion: request.protocolVersion
            ),
            try RunSupervisorControlAuthentication.makeRequest(
                executionID: payload.manifest.executionID,
                action: request.action,
                capability: payload.capability,
                nonce: request.nonce,
                protocolVersion: request.protocolVersion + 1
            )
        ]
        for changedContext in changedContexts {
            #expect(throws: RunSupervisorError.responseAuthenticationFailed) {
                try RunSupervisorControlAuthentication.verifyResponse(
                    envelope,
                    for: changedContext,
                    capability: payload.capability
                )
            }
        }

        let wrongCapability = try RunSupervisorCapability(bytes: Data(repeating: 0xCC, count: 32))
        #expect(throws: RunSupervisorError.responseAuthenticationFailed) {
            try RunSupervisorControlAuthentication.verifyResponse(
                envelope,
                for: request,
                capability: wrongCapability
            )
        }
    }

    @Test("one maximum-output event fits the mutually authenticated control frame")
    func maximumOutputResponseFitsControlFrame() throws {
        let payload = try RunSupervisorTestSupport.payload(identitySeed: 91)
        let request = try RunSupervisorControlAuthentication.makeRequest(
            executionID: payload.manifest.executionID,
            action: .init(kind: .replay, afterSequence: 0),
            capability: payload.capability,
            nonce: RunSupervisorTestSupport.uuid(92)
        )
        let event = RunSupervisorEvent(
            sequence: 1,
            id: RunSupervisorTestSupport.uuid(93),
            timestamp: RunSupervisorTestSupport.fixedDate,
            kind: .standardOutput,
            payload: .init(data: Data(repeating: 0xFE, count: 32_768))
        )
        let response = RunSupervisorControlResponse(
            accepted: true,
            events: [event],
            lastSequence: event.sequence
        )
        let envelope = try RunSupervisorControlAuthentication.makeResponse(
            response,
            for: request,
            capability: payload.capability
        )
        let wire = try RunSupervisorWireCoding.encode(envelope)
        #expect(wire.count <= RunSupervisorProtocol.maximumControlFrameBytes)
        #expect(try RunSupervisorControlAuthentication.verifyResponse(
            envelope,
            for: request,
            capability: payload.capability
        ) == response)
    }

    @Test("exact replay requires authenticated liveness; changed stale and wrong identity fail")
    func admissionFencing() throws {
        let payload = try RunSupervisorTestSupport.payload(authorityEpoch: 4)
        let record = RunSupervisorDiscoveryRecord(
            identity: payload.expectedIdentity,
            manifestSHA256: payload.manifestSHA256,
            launchAuthenticator: try RunSupervisorDigests.launchAuthenticator(
                payload: payload,
                capability: payload.capability
            ),
            capabilitySHA256: try RunSupervisorDigests.capability(payload.capability),
            createdAt: .distantPast
        )
        #expect(try RunSupervisorAdmission.decide(
            payload: payload,
            existing: record,
            wasDirectoryCreated: false,
            authenticatedLiveness: true
        ) == .existingLive)
        #expect(throws: RunSupervisorError.alreadyRunningOrInDoubt) {
            try RunSupervisorAdmission.decide(
                payload: payload,
                existing: record,
                wasDirectoryCreated: false,
                authenticatedLiveness: false
            )
        }

        let changed = try RunSupervisorTestSupport.payload(arguments: ["changed"], authorityEpoch: 4)
        #expect(throws: RunSupervisorError.launchPayloadConflict) {
            try RunSupervisorAdmission.decide(
                payload: changed,
                existing: record,
                wasDirectoryCreated: false,
                authenticatedLiveness: true
            )
        }
        let stale = try RunSupervisorTestSupport.payload(authorityEpoch: 3)
        #expect(throws: RunSupervisorError.staleAuthorityEpoch) {
            try RunSupervisorAdmission.decide(
                payload: stale,
                existing: record,
                wasDirectoryCreated: false,
                authenticatedLiveness: true
            )
        }
        let wrong = try RunSupervisorTestSupport.payload(identitySeed: 20, authorityEpoch: 4)
        #expect(throws: RunSupervisorError.invalidIdentity) {
            try RunSupervisorAdmission.decide(
                payload: wrong,
                existing: record,
                wasDirectoryCreated: false,
                authenticatedLiveness: true
            )
        }
    }
}

private struct FixedClock: RunSupervisorClock {
    let date: Date
    func now() -> Date { date }
}
