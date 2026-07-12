import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Feedback Report Persistence")
struct FeedbackReportPersistenceTests {
    @MainActor
    @Test("Every V1 local state round trips through SwiftData")
    func everyLocalStateRoundTrips() throws {
        let container = try makeFeedbackOutboxContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, status) in FeedbackLocalStatusV1.allCases.enumerated() {
            let report = FeedbackReport(
                installationID: "installation-\(index)",
                idempotencyKey: "state-\(status.rawValue)",
                evidenceWindowStart: now.addingTimeInterval(-60),
                evidenceWindowEnd: now,
                consentVersion: "consent-v1",
                createdAt: now
            )
            report.localStatusRaw = status.rawValue
            context.insert(report)
        }
        try context.save()

        let statuses = Set(try context.fetch(FetchDescriptor<FeedbackReport>()).map(\.localStatusRaw))
        #expect(statuses == Set(FeedbackLocalStatusV1.allCases.map(\.rawValue)))
    }

    @MainActor
    @Test("Durable report fields and exact receipt bytes round trip without reporter contact data")
    func durableFieldsRoundTripWithoutReporterContact() throws {
        let container = try makeFeedbackOutboxContainer()
        let context = container.mainContext
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let report = FeedbackReport(
            id: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            installationID: "installation-v1",
            idempotencyKey: "idempotency-v1",
            intendedOutcome: "Finish work",
            actualResult: "Failed",
            expectedResult: "Succeeded",
            workBlocked: true,
            taskID: "task-1",
            runID: "run-1",
            evidenceWindowStart: createdAt.addingTimeInterval(-900),
            evidenceWindowEnd: createdAt,
            consentVersion: "consent-v1",
            evidenceSelectionsJSON: "[]",
            createdAt: createdAt
        )
        report.localStatusRaw = FeedbackLocalStatusV1.retryableFailure.rawValue
        report.uploadAttemptCount = 2
        report.nextRetryAt = createdAt.addingTimeInterval(120)
        report.lastFailureCode = "offline"
        report.lastFailureDispositionRaw = FeedbackFailureDispositionV1.retryable.rawValue
        report.lastFailureSafeMessage = "Waiting for a network connection."
        report.uploadAttempts = [
            FeedbackUploadAttemptRecord(
                sequence: 1,
                startedAt: createdAt,
                finishedAt: createdAt.addingTimeInterval(1),
                outcome: "retryable_failure",
                failureCode: "offline"
            )
        ]
        context.insert(report)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<FeedbackReport>()).first)
        #expect(fetched.id == report.id)
        #expect(fetched.idempotencyKey == "idempotency-v1")
        #expect(fetched.localStatus == .retryableFailure)
        #expect(fetched.failureDisposition == .retryable)
        #expect(fetched.uploadAttempts.count == 1)
        #expect(try fetched.localStatusDTO.lastFailure?.code == "offline")

        let fieldNames = Set(Mirror(reflecting: fetched).children.compactMap(\.label))
        #expect(!fieldNames.contains(where: { name in
            let lower = name.lowercased()
            return lower.contains("email") || lower.contains("contact") || lower.contains("reportername")
        }))
    }

    @MainActor
    @Test("Receipt bytes and optional evidence hash round trip without loss")
    func receiptWithOptionalEvidenceHashRoundTrips() throws {
        let container = try makeFeedbackOutboxContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reportID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let receipt = FeedbackSubmissionReceiptV1(
            receiptID: "receipt-with-evidence",
            reportID: FeedbackReportIDV1(reportID),
            installationID: FeedbackInstallationIDV1(rawValue: "installation-v1"),
            idempotencyKey: "receipt-round-trip",
            payloadSHA256: String(repeating: "a", count: 64),
            evidenceArchiveSHA256: String(repeating: "b", count: 64),
            receivedAt: now,
            disposition: .accepted,
            remoteStatus: .received,
            statusReadCredential: FeedbackStatusReadCredentialV1(
                rawValue: String(repeating: "c", count: 32)
            ),
            statusCredentialExpiresAt: now.addingTimeInterval(86_400)
        )
        let receiptData = try receipt.canonicalData()
        let report = FeedbackReport(
            id: reportID,
            installationID: "installation-v1",
            idempotencyKey: "receipt-round-trip",
            evidenceWindowStart: now.addingTimeInterval(-60),
            evidenceWindowEnd: now,
            consentVersion: "consent-v1",
            createdAt: now
        )
        report.localStatusRaw = FeedbackLocalStatusV1.submitted.rawValue
        report.receiptData = receiptData
        context.insert(report)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<FeedbackReport>()).first)
        #expect(fetched.receiptData == receiptData)
        #expect(fetched.receipt == receipt)
        #expect(fetched.receipt?.evidenceArchiveSHA256 == String(repeating: "b", count: 64))
        #expect(try fetched.localStatusDTO.receipt == receipt)
    }

    @MainActor
    @Test("Submitted persisted state without a valid receipt cannot project as a status DTO")
    func submittedStatusWithoutReceiptFailsProjection() throws {
        let container = try makeFeedbackOutboxContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = FeedbackReport(
            installationID: "installation-v1",
            idempotencyKey: "corrupt-submitted-status",
            evidenceWindowStart: now.addingTimeInterval(-60),
            evidenceWindowEnd: now,
            consentVersion: "consent-v1",
            createdAt: now
        )
        report.localStatusRaw = FeedbackLocalStatusV1.submitted.rawValue
        report.receiptData = Data("not a receipt".utf8)
        context.insert(report)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<FeedbackReport>()).first)
        #expect(fetched.receipt == nil)
        #expect(throws: FeedbackContractError.missingRequiredField(path: "status.receipt")) {
            _ = try fetched.localStatusDTO
        }
    }

    @MainActor
    @Test("Expired evidence is removed while receipt, hashes, and status survive")
    func receiptSurvivesArtifactExpiry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("feedback-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = TestFeedbackOutboxClock()
        let container = try makeFeedbackOutboxContainer()
        let service = try FeedbackOutboxService(
            modelContainer: container,
            storageRoot: root,
            clock: clock,
            policy: FeedbackOutboxPolicy(artifactRetentionInterval: 60)
        )
        let contents = makeFeedbackDraftContents(now: clock.current)
        let reportID = try service.createDraft(
            installationID: FeedbackInstallationIDV1(rawValue: "installation-v1"),
            idempotencyKey: "retention-key",
            contents: contents
        )
        let envelope = try makeFeedbackEnvelope(
            reportID: reportID,
            installationID: "installation-v1",
            idempotencyKey: "retention-key",
            contents: contents,
            createdAt: clock.current
        )
        let source = try writeFeedbackPreparedPackage(parent: root, envelope: envelope)
        try service.adoptPreparedPackage(reportID: reportID, from: source)
        try service.queue(reportID: reportID)
        let claim = try service.claimUpload(reportID: reportID)
        try service.completeSubmission(
            claim: claim,
            receiptData: try makeFeedbackReceiptData(envelope: envelope, receivedAt: clock.current)
        )

        clock.current = clock.current.addingTimeInterval(61)
        #expect(try service.purgeExpiredArtifacts() == 1)
        let context = ModelContext(container)
        let fetched = try #require(try context.fetch(FetchDescriptor<FeedbackReport>()).first)
        #expect(fetched.localStatus == .submitted)
        #expect(fetched.receipt?.receiptID == "receipt-123")
        #expect(fetched.payloadSHA256 == envelope.payloadSHA256)
        #expect(fetched.canonicalDigestSHA256 == envelope.canonicalDigestSHA256)
        #expect(fetched.canonicalEnvelopeData == nil)
        #expect(fetched.packageRelativePath == nil)
        #expect(fetched.intendedOutcome.isEmpty)
        #expect(fetched.artifactsDeletedAt == clock.current)
        #expect(!FileManager.default.fileExists(atPath: claim.packageURL.path))
    }
}
