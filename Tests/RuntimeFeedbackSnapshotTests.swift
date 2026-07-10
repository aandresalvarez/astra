import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Runtime Feedback Snapshot")
struct RuntimeFeedbackSnapshotTests {
    private let builder = RuntimeFeedbackSnapshotBuilder()

    @Test("Codex missing executable maps to provider-neutral missing evidence")
    func codexMissing() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            executableFound: false,
            readiness: "blocked",
            failureCategory: "missing_executable",
            stopReason: "runtime_readiness_failed"
        )))

        #expect(snapshot.runtimeID == .codexCLI)
        #expect(snapshot.executableFound == false)
        #expect(snapshot.readiness == "blocked")
        #expect(snapshot.failureCategory == .missing)
        #expect(snapshot.unavailableReason == .unavailable)
    }

    @Test("Codex logged out and unavailable model use stable categories")
    func codexReadinessFailures() throws {
        let loggedOut = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            executableFound: true,
            readiness: "blocked",
            failureCategory: "authentication_failed"
        )))
        let modelUnavailable = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            executableFound: true,
            readiness: "ready",
            failureCategory: "model_unavailable"
        )))

        #expect(loggedOut.failureCategory == .unauthenticated)
        #expect(modelUnavailable.failureCategory == .misconfigured)
    }

    @Test("Claude stdout-only diagnostic retains only its sanitized summary")
    func claudeResultOutputDiagnostic() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "claude_code",
            providerVersion: "2.1.0",
            executableFound: true,
            failureCategory: "provider_process_failed",
            sanitizedSummary: "Hook failed for reporter@example.com using Bearer tiny-secret",
            exitCode: 1,
            stream: RuntimeFeedbackPersistedStreamCounters(
                rawLines: 4,
                parsedEvents: 3,
                textEvents: 0,
                failedEvents: 1
            )
        )))

        #expect(snapshot.runtimeID == .claudeCode)
        #expect(snapshot.failureCategory == .processFailed)
        #expect(snapshot.sanitizedSummary?.contains("reporter@example.com") == false)
        #expect(snapshot.sanitizedSummary?.contains("tiny-secret") == false)
        #expect(snapshot.stream?.failedEvents == 1)
    }

    @Test("Copilot auth and permission failures share the frozen categories")
    func copilotFailures() throws {
        let auth = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "copilot_cli",
            failureCategory: "authentication_failed"
        )))
        let permission = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "copilot_cli",
            failureCategory: "permission_denied",
            policyState: "approval_required"
        )))

        #expect(auth.runtimeID == .copilotCLI)
        #expect(auth.failureCategory == .unauthenticated)
        #expect(permission.failureCategory == .permissionDenied)
        #expect(permission.policyState == "approval_required")
    }

    @Test("Antigravity consumes the persisted structured diagnostic summary")
    func antigravityDiagnostic() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "antigravity_cli",
            providerVersion: "0.8.0",
            executableFound: true,
            failureCategory: "quota_exhausted",
            sanitizedSummary: "Provider capacity was exhausted; quota resets later.",
            exitCode: 0,
            stopReason: "no_usable_result"
        )))

        #expect(snapshot.runtimeID == .antigravityCLI)
        #expect(snapshot.failureCategory == .quotaLimited)
        #expect(snapshot.sanitizedSummary == "Provider capacity was exhausted; quota resets later.")
    }

    @Test("Recorded hung runtime completes through the persistence-only seam")
    func hungRuntimeNeverLaunchesOrProbes() throws {
        let spy = FailFastRuntimeEvidenceSpy(evidence: RuntimeFeedbackPersistedEvidence(
            runtimeID: "antigravity_cli",
            executableFound: true,
            readiness: "ready",
            stopReason: "provider_semantic_progress_stalled"
        ))

        let persistedSnapshot = try builder.build(reading: spy)
        let snapshot = try #require(persistedSnapshot)

        #expect(spy.persistedReadCount == 1)
        #expect(spy.launchCount == 0)
        #expect(spy.readinessProbeCount == 0)
        #expect(snapshot.failureCategory == .timedOut)
        #expect(snapshot.stopReason == "provider_semantic_progress_stalled")
        #expect(snapshot.sanitizedSummary == "ASTRA recorded a stalled provider runtime.")
    }

    @Test("All runtimes absent yields no snapshot without failing report capture")
    func allRuntimesAbsent() throws {
        let spy = FailFastRuntimeEvidenceSpy(evidence: nil)

        let snapshot = try builder.build(reading: spy)
        #expect(snapshot == nil)
        #expect(spy.persistedReadCount == 1)
        #expect(spy.launchCount == 0)
        #expect(spy.readinessProbeCount == 0)
    }

    @Test("Unknown runtime and failure category are preserved")
    func unknownRuntimeAndFailure() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "future_runtime_v2",
            failureCategory: "future_provider_failure",
            sanitizedSummary: "Future runtime returned a typed failure."
        )))

        #expect(snapshot.runtimeID.rawValue == "future_runtime_v2")
        #expect(snapshot.failureCategory?.rawValue == "future_provider_failure")
    }

    @Test("Secret-shaped runtime identifiers are rejected before contract projection")
    func secretShapedRuntimeIdentifiersAreRejected() {
        for runtimeID in [
            "ghp_abcdefgh12345678",
            "sk-abcdefgh12345678",
            "650-555-0123"
        ] {
            #expect(builder.build(from: RuntimeFeedbackPersistedEvidence(
                runtimeID: runtimeID
            )) == nil)
        }
    }

    @Test("Secret-shaped failure categories are omitted while safe unknowns remain compatible")
    func secretShapedFailureCategoriesAreOmitted() throws {
        for failureCategory in [
            "ghp_abcdefgh12345678",
            "sk-abcdefgh12345678",
            "650-555-0123"
        ] {
            let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
                runtimeID: "future_runtime_v2",
                failureCategory: failureCategory
            )))
            #expect(snapshot.failureCategory == nil)
            #expect(snapshot.unavailableReason == .notRecorded)
        }

        let safeUnknown = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "future_runtime_v2",
            failureCategory: "future_provider_failure"
        )))
        #expect(safeUnknown.failureCategory?.rawValue == "future_provider_failure")
    }

    @Test("Runtime identity without observations uses a typed not-recorded reason")
    func runtimeOnlyIsNotRecorded() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli"
        )))

        #expect(snapshot.unavailableReason == .notRecorded)
        #expect(snapshot.failureCategory == nil)
    }

    @Test("Whitespace-only evidence remains typed as not recorded")
    func whitespaceOnlyEvidenceIsNotRecorded() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            providerVersion: " \n ",
            readiness: "\t",
            failureCategory: " ",
            sanitizedSummary: "\n",
            stopReason: " ",
            sandboxState: "\t",
            policyState: "\n"
        )))

        #expect(snapshot.unavailableReason == .notRecorded)
    }

    @Test("Invalid-only evidence remains typed as not recorded")
    func invalidOnlyEvidenceIsNotRecorded() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            failureCategory: "invalid category/path",
            exitCode: Int.max
        )))

        #expect(snapshot.failureCategory == nil)
        #expect(snapshot.exitCode == nil)
        #expect(snapshot.unavailableReason == .notRecorded)
    }

    @Test("Secret-only evidence remains typed as not recorded")
    func secretOnlyEvidenceIsNotRecorded() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            providerVersion: "ghp_abcdefgh12345678",
            readiness: "sk-abcdefgh12345678",
            failureCategory: "ghp_abcdefgh12345678",
            sanitizedSummary: "650-555-0123",
            stopReason: "sk-abcdefgh12345678",
            sandboxState: "ghp_abcdefgh12345678",
            policyState: "650-555-0123"
        )))

        #expect(snapshot.providerVersion == nil)
        #expect(snapshot.readiness == nil)
        #expect(snapshot.failureCategory == nil)
        #expect(snapshot.sanitizedSummary == nil)
        #expect(snapshot.stopReason == nil)
        #expect(snapshot.sandboxState == nil)
        #expect(snapshot.policyState == nil)
        #expect(snapshot.unavailableReason == .notRecorded)
    }

    @Test("Multiple redactions in one field do not become recorded evidence")
    func multipleRedactionsInOneFieldAreNotRecorded() throws {
        for summary in [
            "ghp_abcdefgh12345678 sk-abcdefgh12345678",
            "token=ghp_abcdefgh12345678 password=sk-abcdefgh12345678"
        ] {
            let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
                runtimeID: "codex_cli",
                sanitizedSummary: summary
            )))

            #expect(snapshot.sanitizedSummary == nil)
            #expect(snapshot.unavailableReason == .notRecorded)
        }

        let meaningful = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            sanitizedSummary: "Provider authentication failed: ghp_abcdefgh12345678 sk-abcdefgh12345678"
        )))
        #expect(meaningful.sanitizedSummary?.contains("Provider authentication failed") == true)
        #expect(meaningful.unavailableReason == nil)

        for (summary, semanticLabel) in [
            ("Failure: ghp_abcdefgh12345678 sk-abcdefgh12345678", "Failure"),
            ("TimedOut: ghp_abcdefgh12345678", "TimedOut"),
            ("AuthFailed=ghp_abcdefgh12345678", "AuthFailed")
        ] {
            let semantic = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
                runtimeID: "codex_cli",
                sanitizedSummary: summary
            )))
            #expect(semantic.sanitizedSummary?.contains(semanticLabel) == true)
            #expect(semantic.unavailableReason == nil)
        }
    }

    @Test("Persisted projection round-trips deterministically without generic provider fields")
    func persistedProjectionRoundTrip() throws {
        let evidence = RuntimeFeedbackPersistedEvidence(
            runtimeID: "claude_code",
            providerVersion: "2.1.0",
            executableFound: true,
            readiness: "ready",
            failureCategory: "provider_process_failed",
            sanitizedSummary: "Typed summary",
            exitCode: 1,
            stopReason: "failed",
            stream: RuntimeFeedbackPersistedStreamCounters(
                rawLines: 4,
                parsedEvents: 3,
                textEvents: 1,
                failedEvents: 1
            ),
            sandboxState: "restricted",
            policyState: "interactive"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        let decoded = try JSONDecoder().decode(RuntimeFeedbackPersistedEvidence.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded == evidence)
        #expect(!json.contains("payload"))
        #expect(!json.contains("output"))
        #expect(!json.contains("stderr"))
        #expect(!json.contains("environment"))
        #expect(!json.contains("reporter"))
        #expect(!json.contains("contact"))
    }

    @Test("Only allowlisted bounded fields reach the contract")
    func fieldsAreBoundedAndValidated() throws {
        let snapshot = try #require(builder.build(from: RuntimeFeedbackPersistedEvidence(
            runtimeID: "codex_cli",
            providerVersion: String(repeating: "version ", count: 300),
            failureCategory: "provider_process_failed",
            sanitizedSummary: String(repeating: "runtime summary ", count: 200),
            exitCode: Int.max,
            stream: RuntimeFeedbackPersistedStreamCounters(
                rawLines: -5,
                parsedEvents: Int.max,
                textEvents: 2,
                failedEvents: 1
            )
        )))

        #expect((snapshot.providerVersion?.utf8.count ?? 0) <= FeedbackContractLimitsV1.shortTextLength)
        #expect((snapshot.sanitizedSummary?.utf8.count ?? 0) <= FeedbackContractLimitsV1.shortTextLength)
        #expect(snapshot.providerVersion?.hasSuffix("[truncated]") == true)
        #expect(snapshot.sanitizedSummary?.hasSuffix("[truncated]") == true)
        #expect(snapshot.exitCode == nil)
        #expect(snapshot.stream?.rawLines == 0)
        #expect(snapshot.stream?.parsedEvents == FeedbackContractLimitsV1.maximumRuntimeCounter)
        #expect(throws: Never.self) { try snapshot.validate() }
    }
}

private final class FailFastRuntimeEvidenceSpy: RuntimeFeedbackPersistedEvidenceReading {
    private let evidence: RuntimeFeedbackPersistedEvidence?
    private(set) var persistedReadCount = 0
    private(set) var launchCount = 0
    private(set) var readinessProbeCount = 0

    init(evidence: RuntimeFeedbackPersistedEvidence?) {
        self.evidence = evidence
    }

    func readPersistedRuntimeEvidence() throws -> RuntimeFeedbackPersistedEvidence? {
        persistedReadCount += 1
        return evidence
    }

    func launchProvider() -> Never {
        launchCount += 1
        fatalError("Feedback capture must never launch a provider")
    }

    func probeReadiness() -> Never {
        readinessProbeCount += 1
        fatalError("Feedback capture must never probe runtime readiness")
    }
}
