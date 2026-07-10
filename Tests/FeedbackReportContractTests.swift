import Foundation
import Testing
import ASTRACore

@Suite("Feedback report contract V1")
struct FeedbackReportContractTests {
    @Test("golden request bytes and hashes are stable")
    func goldenRequestBytesAndHashesAreStable() throws {
        let bytes = try fixture("request.json")
        let envelope = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: bytes)
        let expectedRequestHash = try fixtureText("request.sha256")
        let expectedPayloadHash = try fixtureText("payload.sha256")
        let actualPayloadHash = try envelope.payload.canonicalSHA256()

        #expect(try envelope.canonicalData() == bytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(bytes) == expectedRequestHash)
        #expect(actualPayloadHash == expectedPayloadHash)
        #expect(envelope.payloadSHA256 == expectedPayloadHash)
    }

    @Test("golden receipt and status bytes round trip")
    func goldenReceiptAndStatusBytesRoundTrip() throws {
        let receiptBytes = try fixture("receipt.json")
        let receipt = try FeedbackCanonicalJSONV1.decode(FeedbackSubmissionReceiptV1.self, from: receiptBytes)
        let receiptHash = try fixtureText("receipt.sha256")
        #expect(try receipt.canonicalData() == receiptBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(receiptBytes) == receiptHash)

        let localBytes = try fixture("status-local.json")
        let local = try FeedbackCanonicalJSONV1.decode(FeedbackLocalStatusDTOv1.self, from: localBytes)
        let localHash = try fixtureText("status-local.sha256")
        #expect(try local.canonicalData() == localBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(localBytes) == localHash)
        #expect(local.status == .submitted)
        #expect(local.receipt == receipt)

        let remoteBytes = try fixture("status-remote.json")
        let remote = try FeedbackCanonicalJSONV1.decode(FeedbackRemoteStatusDTOv1.self, from: remoteBytes)
        let remoteHash = try fixtureText("status-remote.sha256")
        #expect(try remote.canonicalData() == remoteBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(remoteBytes) == remoteHash)
        #expect(remote.status == .accepted)

        let statusReadBytes = try fixture("status-read-request.json")
        let statusRead = try FeedbackCanonicalJSONV1.decode(
            FeedbackStatusReadRequestV1.self,
            from: statusReadBytes
        )
        let statusReadHash = try fixtureText("status-read-request.sha256")
        #expect(try FeedbackCanonicalJSONV1.encodeValidated(statusRead) == statusReadBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(statusReadBytes) == statusReadHash)
        try statusRead.validate(against: receipt, now: sampleDate)

        let errorBytes = try fixture("error.json")
        let error = try FeedbackCanonicalJSONV1.decode(FeedbackAPIErrorV1.self, from: errorBytes)
        let errorHash = try fixtureText("error.sha256")
        #expect(try error.canonicalData() == errorBytes)
        #expect(FeedbackCanonicalJSONV1.sha256Hex(errorBytes) == errorHash)
    }

    @Test("language-neutral schema permits additive DTO shape overlap")
    func languageNeutralSchemaPermitsAdditiveDTOShapeOverlap() throws {
        let schema = try contractSchema()
        let rootAlternatives = try #require(schema["anyOf"] as? [[String: Any]])

        #expect(schema["oneOf"] == nil)
        #expect(rootAlternatives.count == 8)
        #expect(rootAlternatives.compactMap { $0["$ref"] as? String }.contains(
            "#/$defs/receipt"
        ))
        #expect(rootAlternatives.compactMap { $0["$ref"] as? String }.contains(
            "#/$defs/statusReadRequest"
        ))
    }

    @Test("required string policy matches schema for statements and identity bindings")
    func requiredStringPolicyMatchesSchema() throws {
        let schema = try contractSchema()
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let identifier = try #require(definitions["identifier"] as? [String: Any])
        let statement = try #require(definitions["statement"] as? [String: Any])
        let statementProperties = try #require(statement["properties"] as? [String: Any])
        let actualResult = try #require(statementProperties["actualResult"] as? [String: Any])

        let identifierMinimum = try #require(identifier["minLength"] as? Int)
        let statementMinimum = try #require(actualResult["minLength"] as? Int)
        #expect(identifierMinimum == 1)
        #expect(statementMinimum == 1)
        #expect("".unicodeScalars.count < identifierMinimum)
        #expect(" \t".unicodeScalars.count >= identifierMinimum)
        #expect("".unicodeScalars.count < statementMinimum)
        #expect(" \t".unicodeScalars.count >= statementMinimum)

        var payload = samplePayload()
        payload.statement.actualResult = ""
        #expect(throws: FeedbackContractError.missingRequiredField(
            path: "payload.statement.actualResult"
        )) {
            try payload.validate()
        }
        payload.statement.actualResult = " \t"
        try payload.validate()

        var envelope = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: fixture("request.json")
        )
        envelope.installationID = FeedbackInstallationIDV1(rawValue: "")
        #expect(throws: FeedbackContractError.missingRequiredField(path: "installationID")) {
            try envelope.validate()
        }
        envelope.installationID = FeedbackInstallationIDV1(rawValue: "install-test-001")
        envelope.idempotencyKey = ""
        #expect(throws: FeedbackContractError.missingRequiredField(path: "idempotencyKey")) {
            try envelope.validate()
        }
        envelope.installationID = FeedbackInstallationIDV1(rawValue: " \t")
        envelope.idempotencyKey = " \t"
        try envelope.validate()
    }

    @Test("canonical encoding sorts evidence independently of input order")
    func canonicalEncodingSortsEvidenceIndependentlyOfInputOrder() throws {
        let first = artifact(id: "z-log", path: "z/task.log", byteCount: 2, hash: repeated("c"))
        let second = artifact(id: "a-log", path: "a/app.log", byteCount: 3, hash: repeated("d"))
        var payload = samplePayload()
        payload.evidence.artifacts = [first, second]
        payload.evidence.totalByteCount = 5
        payload.consent.evidenceSelections = [
            FeedbackEvidenceSelectionV1(artifactID: "z-log", disclosureClass: .standard, included: true),
            FeedbackEvidenceSelectionV1(artifactID: "a-log", disclosureClass: .standard, included: true)
        ]

        var reversed = payload
        reversed.evidence.artifacts.reverse()
        reversed.consent.evidenceSelections.reverse()

        #expect(try payload.canonicalData() == reversed.canonicalData())
        let decoded = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportPayloadV1.self,
            from: payload.canonicalData()
        )
        #expect(decoded.evidence.artifacts.map(\.relativePath) == ["a/app.log", "z/task.log"])
        #expect(decoded.consent.evidenceSelections.map(\.artifactID) == ["a-log", "z-log"])
    }

    @Test("missing and unknown required versions fail with typed errors")
    func versionsFailWithTypedErrors() {
        let missing = Data(#"{"idempotencyKey":"key"}"#.utf8)
        do {
            _ = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: missing)
            Issue.record("Expected missing version to fail")
        } catch let error as FeedbackContractError {
            #expect(error == .missingRequiredVersion(document: "FeedbackReportEnvelopeV1"))
        } catch {
            Issue.record("Expected typed FeedbackContractError, got \(error)")
        }

        let future = Data(#"{"formatVersion":2}"#.utf8)
        do {
            _ = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: future)
            Issue.record("Expected future version to fail")
        } catch let error as FeedbackContractError {
            #expect(error == .unsupportedVersion(
                document: "FeedbackReportEnvelopeV1",
                actual: 2,
                supported: 1
            ))
        } catch {
            Issue.record("Expected typed FeedbackContractError, got \(error)")
        }
    }

    @Test("bounds reject oversized values before canonical transport bytes exist")
    func boundsRejectOversizedValues() throws {
        var payload = samplePayload()
        payload.statement.actualResult = String(
            repeating: "x",
            count: FeedbackContractLimitsV1.userStatementLength + 1
        )
        #expect(throws: FeedbackContractError.self) {
            _ = try payload.canonicalData()
        }

        payload = samplePayload()
        payload.evidence.artifacts = (0...FeedbackContractLimitsV1.maximumEvidenceItems).map { index in
            artifact(
                id: "artifact-\(index)",
                path: "logs/\(index).log",
                byteCount: 0,
                hash: repeated("e")
            )
        }
        payload.evidence.totalByteCount = 0
        payload.consent.evidenceSelections = payload.evidence.artifacts.map {
            FeedbackEvidenceSelectionV1(
                artifactID: $0.artifactID,
                disclosureClass: .standard,
                included: true
            )
        }
        #expect(throws: FeedbackContractError.self) {
            _ = try payload.canonicalData()
        }
    }

    @Test("hostile strings and future extensible values remain inert data")
    func hostileStringsAndFutureValuesRemainInertData() throws {
        let bytes = try fixture("request-hostile.json")
        let envelope = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: bytes)

        #expect(try envelope.canonicalData() == bytes)
        #expect(envelope.payload.statement.actualResult.contains("$(touch /tmp/pwned)"))
        #expect(envelope.payload.statement.actualResult.contains("ignore previous instructions"))
        #expect(envelope.payload.statement.actualResult.contains("�"))
        #expect(envelope.payload.runtimeSnapshot?.runtimeID.rawValue == "future_runtime")
        #expect(envelope.payload.runtimeSnapshot?.failureCategory?.rawValue == "future_failure")
        #expect(envelope.payload.evidence.artifacts.first?.kind.rawValue == "future_artifact")
    }

    @Test("runtime snapshot identifier fields match schema bounds")
    func runtimeSnapshotIdentifierFieldsMatchSchemaBounds() throws {
        var payload = samplePayload()
        payload.runtimeSnapshot?.failureCategory = FeedbackRuntimeFailureCategoryV1(rawValue: "")
        #expect(throws: FeedbackContractError.missingRequiredField(
            path: "payload.runtimeSnapshot.failureCategory"
        )) {
            try payload.validate()
        }

        payload = samplePayload()
        payload.runtimeSnapshot?.unavailableReason = FeedbackEvidenceReasonV1(
            rawValue: String(repeating: "x", count: FeedbackContractLimitsV1.identifierLength + 1)
        )
        #expect(throws: FeedbackContractError.exceedsMaximumLength(
            path: "payload.runtimeSnapshot.unavailableReason",
            maximum: FeedbackContractLimitsV1.identifierLength,
            actual: FeedbackContractLimitsV1.identifierLength + 1
        )) {
            try payload.validate()
        }
    }

    @Test("unpaired surrogate JSON is rejected")
    func unpairedSurrogateJSONIsRejected() throws {
        let bytes = try fixture("request-malformed-unicode.json")
        #expect(throws: (any Error).self) {
            _ = try FeedbackCanonicalJSONV1.decode(FeedbackReportEnvelopeV1.self, from: bytes)
        }
    }

    @Test("additive unknown V1 members decode as inert non-semantic data")
    func additiveUnknownMembersDecodeAsInertData() throws {
        let golden = try fixture("request.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: golden) as? [String: Any]
        )
        var payload = try #require(object["payload"] as? [String: Any])
        payload["futureOptional"] = ["ignored": true]
        object["payload"] = payload
        object["futureEnvelopeMember"] = "ignored"
        let extended = try JSONSerialization.data(withJSONObject: object)

        let decoded = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: extended
        )
        #expect(try decoded.canonicalData() == golden)
    }

    @Test("timestamp decoding requires UTC milliseconds")
    func timestampDecodingRequiresUTCMilliseconds() throws {
        let golden = String(decoding: try fixture("request.json"), as: UTF8.self)
        let wholeSeconds = golden.replacingOccurrences(
            of: "2023-11-14T22:13:20.123Z",
            with: "2023-11-14T22:13:20Z"
        )
        #expect(throws: (any Error).self) {
            _ = try FeedbackCanonicalJSONV1.decode(
                FeedbackReportEnvelopeV1.self,
                from: Data(wholeSeconds.utf8)
            )
        }
    }

    @Test("unknown closed privacy and local state enums fail decoding")
    func unknownClosedEnumsFailDecoding() {
        let disclosure = Data(#""future_privacy_class""#.utf8)
        #expect(throws: (any Error).self) {
            _ = try FeedbackCanonicalJSONV1.decode(
                FeedbackEvidenceDisclosureClassV1.self,
                from: disclosure
            )
        }
        let localStatus = Data(#""future_local_state""#.utf8)
        #expect(throws: (any Error).self) {
            _ = try FeedbackCanonicalJSONV1.decode(FeedbackLocalStatusV1.self, from: localStatus)
        }
        let futureRemote = Data(#""future_remote_state""#.utf8)
        let decoded = try? FeedbackCanonicalJSONV1.decode(
            FeedbackRemoteStatusV1.self,
            from: futureRemote
        )
        #expect(decoded?.rawValue == "future_remote_state")
    }

    @Test("idempotency reuse is deterministic")
    func idempotencyReuseIsDeterministic() throws {
        let request = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: fixture("request.json")
        )
        #expect(FeedbackIdempotencyDecisionV1.evaluate(
            existingKey: nil,
            existingInstallationID: nil,
            existingCanonicalDigestSHA256: nil,
            request: request
        ) == .acceptNew)
        #expect(FeedbackIdempotencyDecisionV1.evaluate(
            existingKey: request.idempotencyKey,
            existingInstallationID: request.installationID,
            existingCanonicalDigestSHA256: request.canonicalDigestSHA256,
            request: request
        ) == .returnExistingReceipt)
        #expect(FeedbackIdempotencyDecisionV1.evaluate(
            existingKey: request.idempotencyKey,
            existingInstallationID: request.installationID,
            existingCanonicalDigestSHA256: repeated("f"),
            request: request
        ) == .rejectKeyReuse)
        #expect(FeedbackIdempotencyDecisionV1.evaluate(
            existingKey: request.idempotencyKey,
            existingInstallationID: FeedbackInstallationIDV1(rawValue: "different-install"),
            existingCanonicalDigestSHA256: request.canonicalDigestSHA256,
            request: request
        ) == .rejectCrossInstallationReplay)
    }

    @Test("omission warning assessment triage and failure DTOs round trip")
    func remainingDTOsRoundTrip() throws {
        var payload = samplePayload()
        payload.evidence.omissions = [
            FeedbackEvidenceOmissionV1(
                artifactID: "browser-1",
                kind: .browserEvidence,
                reason: .notSelected,
                detail: "Not selected by the reporter."
            )
        ]
        payload.evidence.warnings = [
            FeedbackEvidenceWarningV1(
                code: "truncated",
                artifactID: "app-log",
                message: "The retained window was bounded."
            )
        ]
        let payloadBytes = try payload.canonicalData()
        #expect(try FeedbackCanonicalJSONV1.decode(
            FeedbackReportPayloadV1.self,
            from: payloadBytes
        ) == payload.canonicalized())

        let retryable = FeedbackLocalStatusDTOv1(
            reportID: payload.reportID,
            status: .retryableFailure,
            updatedAt: sampleDate,
            uploadAttemptCount: 1,
            nextRetryAt: sampleDate.addingTimeInterval(60),
            lastFailure: FeedbackStatusFailureV1(
                code: "offline",
                disposition: .retryable,
                safeMessage: "Network unavailable."
            )
        )
        let statusBytes = try retryable.canonicalData()
        #expect(try FeedbackCanonicalJSONV1.decode(
            FeedbackLocalStatusDTOv1.self,
            from: statusBytes
        ) == retryable)

        let assessment = FeedbackAssessmentV1(
            reportID: payload.reportID,
            revisionID: "assessment-1",
            classification: FeedbackAssessmentValueV1(rawValue: "runtime_failure"),
            impact: FeedbackAssessmentValueV1(rawValue: "blocked"),
            behavioralOwner: "Feedback intake contract",
            evidence: [
                FeedbackAssessmentEvidenceV1(
                    evidenceID: "app-log",
                    summary: "The provider exited before completing."
                )
            ],
            counterevidence: [],
            rootCauseHypothesis: "The provider process failed.",
            reproductionConfidence: FeedbackAssessmentValueV1(rawValue: "medium"),
            regressionTestProposal: "Replay the sanitized failure fixture.",
            acceptanceCriteria: ["A receipt is returned without an AI runtime."],
            sourceRevision: "040e80a6",
            currentMainRevision: "67beae00"
        )
        let assessmentBytes = try assessment.canonicalData()
        #expect(try FeedbackCanonicalJSONV1.decode(
            FeedbackAssessmentV1.self,
            from: assessmentBytes
        ) == assessment.canonicalized())

        let triage = FeedbackStaffTriageDecisionV1(
            reportID: payload.reportID,
            assessmentRevisionID: assessment.revisionID,
            decision: .accepted,
            reviewerID: "reviewer-1",
            decidedAt: sampleDate,
            reason: "Evidence supports implementation work.",
            priorityOverride: FeedbackAssessmentValueV1(rawValue: "p1"),
            draftTaskRequested: true
        )
        let triageBytes = try triage.canonicalData()
        #expect(try FeedbackCanonicalJSONV1.decode(
            FeedbackStaffTriageDecisionV1.self,
            from: triageBytes
        ) == triage)
        var invalidTriage = triage
        invalidTriage.decision = .declined
        #expect(throws: FeedbackContractError.self) {
            try invalidTriage.validate()
        }
    }

    @Test("local state and receipt rules are explicit")
    func localStateAndReceiptRulesAreExplicit() throws {
        #expect(FeedbackLocalStatusV1.draft.canTransition(to: .prepared))
        #expect(FeedbackLocalStatusV1.uploading.canTransition(to: .submitted))
        #expect(FeedbackLocalStatusV1.queued.canTransition(to: .retryableFailure))
        #expect(FeedbackLocalStatusV1.retryableFailure.canTransition(to: .queued))
        #expect(!FeedbackLocalStatusV1.draft.canTransition(to: .submitted))
        #expect(!FeedbackLocalStatusV1.submitted.canTransition(to: .queued))

        let invalid = FeedbackLocalStatusDTOv1(
            reportID: FeedbackReportIDV1(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!),
            status: .submitted,
            updatedAt: sampleDate,
            uploadAttemptCount: 1
        )
        #expect(throws: FeedbackContractError.self) {
            try invalid.validate()
        }
    }

    @Test("status credentials reject expiry malformed input and cross-install reads")
    func statusCredentialsFailClosed() throws {
        let receipt = try FeedbackCanonicalJSONV1.decode(
            FeedbackSubmissionReceiptV1.self,
            from: fixture("receipt.json")
        )
        #expect(throws: FeedbackStatusCredentialError.expired) {
            try receipt.validateStatusCredential(now: receipt.statusCredentialExpiresAt)
        }
        #expect(throws: FeedbackContractError.self) {
            try FeedbackStatusReadCredentialV1(rawValue: "short").validate()
        }

        var read = try FeedbackCanonicalJSONV1.decode(
            FeedbackStatusReadRequestV1.self,
            from: fixture("status-read-request.json")
        )
        read.installationID = FeedbackInstallationIDV1(rawValue: "another-install")
        #expect(throws: FeedbackStatusCredentialError.installationMismatch) {
            try read.validate(against: receipt, now: sampleDate)
        }
    }

    @Test("remote status downgrade and illegal jumps fail with typed errors")
    func remoteStatusDowngradeFailsClosed() throws {
        try FeedbackRemoteStatusV1.accepted.validateTransition(to: .implementationQueued)
        try FeedbackRemoteStatusV1.received.validateTransition(
            to: FeedbackRemoteStatusV1(rawValue: "future_server_state")
        )
        try FeedbackRemoteStatusV1(rawValue: "future_server_state").validateTransition(to: .released)
        #expect(throws: FeedbackRemoteStatusTransitionError.illegalOrDowngrade(
            from: "released",
            to: "merged"
        )) {
            try FeedbackRemoteStatusV1.released.validateTransition(to: .merged)
        }
        #expect(throws: FeedbackRemoteStatusTransitionError.illegalOrDowngrade(
            from: "accepted",
            to: "merged"
        )) {
            try FeedbackRemoteStatusV1.accepted.validateTransition(to: .merged)
        }
    }

    @Test("Unicode timestamp and numeric canonical boundaries are deterministic")
    func canonicalBoundaryRulesAreDeterministic() throws {
        let decomposed = "Cafe\u{301}"
        #expect(
            FeedbackContractNormalizationV1.text(decomposed).unicodeScalars.elementsEqual("Café".unicodeScalars)
        )
        var payload = samplePayload()
        payload.statement.actualResult = decomposed
        #expect(throws: FeedbackContractError.self) {
            _ = try payload.canonicalData()
        }

        let counters = FeedbackRuntimeStreamCountersV1(
            rawLines: FeedbackContractLimitsV1.maximumRuntimeCounter,
            parsedEvents: 0,
            textEvents: 0,
            failedEvents: 0
        )
        try counters.validate()
        var tooLarge = counters
        tooLarge.rawLines += 1
        #expect(throws: FeedbackContractError.self) {
            try tooLarge.validate()
        }

        let window = FeedbackEvidenceWindowV1(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 0.999)
        )
        let bytes = try FeedbackCanonicalJSONV1.encodeValidated(window)
        #expect(String(decoding: bytes, as: UTF8.self) ==
            #"{"end":"1970-01-01T00:00:00.999Z","start":"1970-01-01T00:00:00.000Z"}"#)
    }

    @Test("NFC multi-scalar graphemes use schema code-point length bounds")
    func multiScalarGraphemesUseSchemaCodePointBounds() throws {
        let schema = try contractSchema()
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let statement = try #require(definitions["statement"] as? [String: Any])
        let properties = try #require(statement["properties"] as? [String: Any])
        let actualResult = try #require(properties["actualResult"] as? [String: Any])
        let schemaMaximum = try #require(actualResult["maxLength"] as? Int)
        #expect(schemaMaximum == FeedbackContractLimitsV1.userStatementLength)

        let familyEmoji = "👨‍👩‍👧‍👦"
        #expect(familyEmoji.count == 1)
        #expect(familyEmoji.unicodeScalars.count == 7)
        let repeatedCount = schemaMaximum / familyEmoji.unicodeScalars.count
        let remainder = schemaMaximum % familyEmoji.unicodeScalars.count
        let exactlyAtMaximum = String(repeating: familyEmoji, count: repeatedCount) +
            String(repeating: "a", count: remainder)
        #expect(exactlyAtMaximum.unicodeScalars.count == schemaMaximum)
        #expect(exactlyAtMaximum.count < schemaMaximum)

        var payload = samplePayload()
        payload.statement.actualResult = exactlyAtMaximum
        try payload.validate()

        payload.statement.actualResult += "b"
        do {
            try payload.validate()
            Issue.record("Expected code-point length bound to reject the over-limit value")
        } catch let error as FeedbackContractError {
            #expect(error == .exceedsMaximumLength(
                path: "payload.statement.actualResult",
                maximum: schemaMaximum,
                actual: schemaMaximum + 1
            ))
        } catch {
            Issue.record("Expected FeedbackContractError, got \(error)")
        }
    }

    @Test("SHA-256 implementation matches the standard abc vector")
    func sha256MatchesStandardVector() {
        #expect(
            FeedbackCanonicalJSONV1.sha256Hex(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("contract implementation stays Foundation-only")
    func contractImplementationStaysFoundationOnly() throws {
        let feedbackRoot = repositoryRoot.appendingPathComponent("ASTRACore/Feedback")
        let files = try FileManager.default.contentsOfDirectory(
            at: feedbackRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let imports = source
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.hasPrefix("import ") }
            #expect(imports == ["import Foundation"], "Unexpected imports in \(file.lastPathComponent)")
        }
    }

    private var sampleDate: Date { Date(timeIntervalSince1970: 1_700_000_000.123) }

    private func samplePayload() -> FeedbackReportPayloadV1 {
        let evidenceArtifact = artifact(
            id: "app-log",
            path: "logs/app.log",
            byteCount: 12,
            hash: repeated("a")
        )
        return FeedbackReportPayloadV1(
            reportID: FeedbackReportIDV1(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!),
            createdAt: sampleDate,
            statement: FeedbackUserStatementV1(
                intendedOutcome: "Submit a report without an AI runtime.",
                actualResult: "The task stopped before completion.",
                expectedResult: "The report is accepted and receives a receipt.",
                workBlocked: true
            ),
            build: FeedbackBuildProvenanceV1(
                version: "0.1.28",
                build: "28",
                channel: "development",
                gitCommit: "040e80a6",
                buildDate: "2026-07-09T19:00:00Z",
                source: "local_build"
            ),
            platform: FeedbackPlatformV1(macOSVersion: "15.5", architecture: "arm64"),
            evidenceWindow: FeedbackEvidenceWindowV1(
                start: sampleDate.addingTimeInterval(-900),
                end: sampleDate
            ),
            consent: FeedbackConsentV1(
                version: "feedback-consent-v1",
                evidenceSelections: [
                    FeedbackEvidenceSelectionV1(
                        artifactID: "app-log",
                        disclosureClass: .standard,
                        included: true
                    ),
                    FeedbackEvidenceSelectionV1(
                        artifactID: "browser-1",
                        disclosureClass: .explicitOptIn,
                        included: false
                    )
                ]
            ),
            taskID: "task-123",
            runID: "run-456",
            runtimeSnapshot: FeedbackRuntimeSnapshotV1(
                runtimeID: .codexCLI,
                providerVersion: "1.2.3",
                executableFound: true,
                readiness: "ready",
                failureCategory: .processFailed,
                exitCode: 1,
                stopReason: "provider_process_failed",
                stream: FeedbackRuntimeStreamCountersV1(
                    rawLines: 3,
                    parsedEvents: 2,
                    textEvents: 1,
                    failedEvents: 1
                ),
                sandboxState: "restricted",
                policyState: "allowed",
                sanitizedSummary: "Provider exited before completion."
            ),
            evidence: FeedbackEvidenceManifestV1(
                artifacts: [evidenceArtifact],
                redactionPolicyVersion: "redaction-v1",
                totalByteCount: 12,
                archiveSHA256: repeated("b")
            )
        )
    }

    private func artifact(
        id: String,
        path: String,
        byteCount: Int64,
        hash: String
    ) -> FeedbackEvidenceArtifactV1 {
        FeedbackEvidenceArtifactV1(
            artifactID: id,
            kind: .applicationLog,
            disclosureClass: .standard,
            relativePath: path,
            mediaType: "text/plain",
            byteCount: byteCount,
            sha256: hash,
            redaction: FeedbackRedactionSummaryV1(
                replacements: 1,
                secretPatterns: 1,
                pathPatterns: 0,
                contactPatterns: 0
            )
        )
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureRoot.appendingPathComponent(name))
    }

    private func fixtureText(_ name: String) throws -> String {
        String(decoding: try fixture(name), as: UTF8.self)
    }

    private var fixtureRoot: URL {
        repositoryRoot.appendingPathComponent("docs/contracts/feedback/v1/fixtures")
    }

    private func contractSchema() throws -> [String: Any] {
        let schemaURL = repositoryRoot
            .appendingPathComponent("docs/contracts/feedback/v1/feedback-contract.schema.json")
        let schemaData = try Data(contentsOf: schemaURL)
        return try #require(
            JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func repeated(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
