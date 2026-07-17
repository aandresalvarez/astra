import Foundation
import Testing
import WorkspaceToolSupport

@Suite("Remote workspace job helper protocol")
struct RemoteWorkspaceJobHelperProtocolTests {
    private let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let generation = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let helperDigest = String(repeating: "a", count: 64)
    private let commandDigest = String(repeating: "b", count: 64)
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private let acceptedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Start request is deterministic and carries no command or path")
    func startRequestIsPathFree() throws {
        let request = startRequest()

        let first = try RemoteWorkspaceJobHelperProtocol.encodeRequest(request)
        let second = try RemoteWorkspaceJobHelperProtocol.encodeRequest(request)
        let text = try #require(String(data: first, encoding: .utf8))

        #expect(first == second)
        #expect(text.contains(commandDigest))
        #expect(!text.contains("launchCommand"))
        #expect(!text.contains("command.sh"))
        #expect(!text.contains("/home/"))
        #expect(try RemoteWorkspaceJobHelperProtocol.decodeRequest(first) == request)
    }

    @Test("Unknown request fields fail closed")
    func unknownRequestFieldsFailClosed() {
        let data = Data("""
        {"protocolVersion":1,"operationID":"11111111-1111-1111-1111-111111111111","operation":"handshake","command":"rm -rf /"}
        """.utf8)

        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try RemoteWorkspaceJobHelperProtocol.decodeRequest(data)
        }
    }

    @Test("Job IDs cannot become paths or shell fragments")
    func jobIDsArePathFree() {
        for invalid in ["../job", "Job", "job name", "job;touch-pwned", "/tmp/job"] {
            let request = RemoteWorkspaceJobHelperRequest(
                operationID: operationID,
                operation: .status,
                jobID: invalid
            )
            #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
                try request.validate()
            }
        }
    }

    @Test("Start requires a generation, valid digest, and bounded finite timeout")
    func startRequirementsFailClosed() {
        let missingGeneration = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .start,
            jobID: "job-1",
            commandSHA256: commandDigest
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try missingGeneration.validate()
        }

        let invalidDigest = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .start,
            jobID: "job-1",
            generation: generation,
            commandSHA256: "ABC"
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try invalidDigest.validate()
        }

        let invalidTimeout = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .start,
            jobID: "job-1",
            generation: generation,
            commandSHA256: commandDigest,
            timeoutSeconds: .infinity
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try invalidTimeout.validate()
        }
    }

    @Test("Tail reads are explicitly streamed and bounded")
    func tailReadsAreBounded() throws {
        let valid = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .tail,
            jobID: "job-1",
            generation: generation,
            stream: .stderr,
            lines: RemoteWorkspaceJobHelperProtocol.maximumTailLines
        )
        try valid.validate()

        let oversized = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .tail,
            jobID: "job-1",
            generation: generation,
            stream: .stdout,
            lines: RemoteWorkspaceJobHelperProtocol.maximumTailLines + 1
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try oversized.validate()
        }
    }

    @Test("Every job observation is bound to its durable generation")
    func observationsRequireGeneration() {
        for operation in [RemoteWorkspaceJobHelperOperation.status, .tail] {
            let request = RemoteWorkspaceJobHelperRequest(
                operationID: operationID,
                operation: operation,
                jobID: "job-1",
                stream: operation == .tail ? .stdout : nil,
                lines: operation == .tail ? 10 : nil
            )
            #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
                try request.validate()
            }
        }
    }

    @Test("Oversized envelopes fail before JSON parsing")
    func oversizedEnvelopesFailClosed() {
        let oversizedRequest = Data(repeating: 0x20, count: RemoteWorkspaceJobHelperProtocol.maximumRequestBytes + 1)
        let oversizedResponse = Data(repeating: 0x20, count: RemoteWorkspaceJobHelperProtocol.maximumResponseBytes + 1)

        #expect(throws: RemoteWorkspaceJobHelperProtocolError.envelopeTooLarge) {
            try RemoteWorkspaceJobHelperProtocol.decodeRequest(oversizedRequest)
        }
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.envelopeTooLarge) {
            try RemoteWorkspaceJobHelperProtocol.decodeResponse(oversizedResponse)
        }
    }

    @Test("Cancellation requires the exact durable job generation")
    func cancellationRequiresGeneration() {
        let request = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .cancel,
            jobID: "job-1"
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try request.validate()
        }
    }

    @Test("Running jobs require reboot-safe process group identity")
    func runningJobRequiresStrongProcessIdentity() {
        let missing = snapshot(process: nil)
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try missing.validate()
        }

        let reusedPIDRisk = snapshot(process: .init(
            pid: 42,
            processGroupID: 42,
            bootID: "",
            startMarker: "1234"
        ))
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try reusedPIDRisk.validate()
        }
    }

    @Test("Helper responses bind operation, helper digest, job, and generation")
    func responseBindingRejectsCrossTalk() throws {
        let request = startRequest()
        let response = RemoteWorkspaceJobHelperResponse(
            operationID: operationID,
            helperSHA256: helperDigest,
            outcome: .accepted,
            job: snapshot(process: validProcess())
        )
        try RemoteWorkspaceJobHelperProtocol.validate(
            response: response,
            for: request,
            expectedHelperSHA256: helperDigest
        )

        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try RemoteWorkspaceJobHelperProtocol.validate(
                response: response,
                for: request,
                expectedHelperSHA256: String(repeating: "c", count: 64)
            )
        }

        let otherOperationResponse = RemoteWorkspaceJobHelperResponse(
            operationID: UUID(),
            helperSHA256: helperDigest,
            outcome: .accepted,
            job: snapshot(process: validProcess())
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try RemoteWorkspaceJobHelperProtocol.validate(
                response: otherOperationResponse,
                for: request,
                expectedHelperSHA256: helperDigest
            )
        }
    }

    @Test("Remote responses cannot redirect durable files")
    func fileLayoutCannotBeRedirected() {
        let snapshot = RemoteWorkspaceJobSnapshot(
            jobID: "job-1",
            generation: generation,
            status: .running,
            observedAt: observedAt,
            acceptedAt: acceptedAt,
            startedAt: acceptedAt,
            process: validProcess(),
            files: .init(standardOutput: "../../outside.log")
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try snapshot.validate()
        }
    }

    @Test("Tail payload bytes remain bounded independently of requested lines")
    func tailPayloadBytesAreBounded() {
        let payload = RemoteWorkspaceJobTailPayload(
            stream: .stdout,
            text: String(repeating: "x", count: RemoteWorkspaceJobHelperProtocol.maximumTailBytes + 1),
            truncated: false
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.self) {
            try payload.validate()
        }
    }

    @Test("Tail responses cannot exceed the caller's requested line count")
    func tailResponseHonorsRequestedLines() throws {
        let request = RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .tail,
            jobID: "job-1",
            generation: generation,
            stream: .stdout,
            lines: 2
        )
        let accepted = RemoteWorkspaceJobHelperResponse(
            operationID: operationID,
            helperSHA256: helperDigest,
            outcome: .accepted,
            job: snapshot(process: validProcess()),
            tail: .init(stream: .stdout, text: "first\nsecond\n", truncated: true)
        )
        try RemoteWorkspaceJobHelperProtocol.validate(
            response: accepted,
            for: request,
            expectedHelperSHA256: helperDigest
        )

        let excessive = RemoteWorkspaceJobHelperResponse(
            operationID: operationID,
            helperSHA256: helperDigest,
            outcome: .accepted,
            job: snapshot(process: validProcess()),
            tail: .init(stream: .stdout, text: "first\nsecond\nthird\n", truncated: false)
        )
        #expect(throws: RemoteWorkspaceJobHelperProtocolError.tailTooManyLines) {
            try RemoteWorkspaceJobHelperProtocol.validate(
                response: excessive,
                for: request,
                expectedHelperSHA256: helperDigest
            )
        }
    }

    @Test("Response round trips preserve fractional timestamp precision")
    func responseRoundTripPreservesFractionalTimestamps() throws {
        let fractionalAcceptedAt = Date(timeIntervalSince1970: 1_700_000_000.789_123)
        let fractionalObservedAt = Date(timeIntervalSince1970: 1_700_000_100.456_789)
        let response = RemoteWorkspaceJobHelperResponse(
            operationID: operationID,
            helperSHA256: helperDigest,
            outcome: .accepted,
            job: RemoteWorkspaceJobSnapshot(
                jobID: "job-1",
                generation: generation,
                status: .running,
                observedAt: fractionalObservedAt,
                acceptedAt: fractionalAcceptedAt,
                startedAt: fractionalAcceptedAt,
                lastHeartbeatAt: fractionalObservedAt,
                process: validProcess()
            )
        )

        let encoded = try RemoteWorkspaceJobHelperProtocol.encodeResponse(response)
        let decoded = try RemoteWorkspaceJobHelperProtocol.decodeResponse(encoded)

        #expect(decoded == response)
    }

    @Test("Deployment manifest pins integrity, private paths, modes, and symlink policy")
    func deploymentManifestIsSecurityOwned() throws {
        let manifest = try RemoteWorkspaceJobHelperDeploymentManifest(helperSHA256: helperDigest)

        #expect(manifest.protocolVersion == 1)
        #expect(manifest.helperInstallRelativePath.hasPrefix(".local/share/astra/"))
        #expect(manifest.jobRootRelativePath.hasPrefix(".local/state/astra/"))
        #expect(manifest.helperFileMode == 0o700)
        #expect(manifest.jobRootMode == 0o700)
        #expect(manifest.rejectsSymlinks)
    }

    @Test("Decoded deployment manifests cannot override security-owned values")
    func decodedDeploymentManifestFailsClosed() throws {
        let valid = try RemoteWorkspaceJobHelperDeploymentManifest(helperSHA256: helperDigest)
        let encoded = try RemoteWorkspaceJobHelperProtocol.makeEncoder().encode(valid)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let mutations: [(String, Any)] = [
            ("protocolVersion", 2),
            ("helperSHA256", "invalid"),
            ("helperInstallRelativePath", "../../tmp/helper"),
            ("jobRootRelativePath", "../../tmp/jobs"),
            ("helperFileMode", 0o777),
            ("jobRootMode", 0o777),
            ("rejectsSymlinks", false)
        ]

        for (key, value) in mutations {
            var tampered = object
            tampered[key] = value
            let data = try JSONSerialization.data(withJSONObject: tampered)
            #expect(throws: RemoteWorkspaceJobHelperProtocolError.self, "Accepted tampered field: \(key)") {
                try RemoteWorkspaceJobHelperProtocol.makeDecoder().decode(
                    RemoteWorkspaceJobHelperDeploymentManifest.self,
                    from: data
                )
            }
        }
    }

    private func startRequest() -> RemoteWorkspaceJobHelperRequest {
        RemoteWorkspaceJobHelperRequest(
            operationID: operationID,
            operation: .start,
            jobID: "job-1",
            generation: generation,
            commandSHA256: commandDigest,
            timeoutSeconds: 7_200
        )
    }

    private func snapshot(process: RemoteWorkspaceJobProcessIdentity?) -> RemoteWorkspaceJobSnapshot {
        RemoteWorkspaceJobSnapshot(
            jobID: "job-1",
            generation: generation,
            status: .running,
            observedAt: observedAt,
            acceptedAt: acceptedAt,
            startedAt: acceptedAt,
            lastHeartbeatAt: observedAt,
            process: process
        )
    }

    private func validProcess() -> RemoteWorkspaceJobProcessIdentity {
        RemoteWorkspaceJobProcessIdentity(
            pid: 42,
            processGroupID: 42,
            bootID: "8b08caa0-7b9d-4ef0-8120-2b02d3a92f18",
            startMarker: "987654"
        )
    }
}
