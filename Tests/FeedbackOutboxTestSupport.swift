import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

final class TestFeedbackOutboxClock: FeedbackOutboxClock {
    var current: Date

    init(_ current: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.current = current
    }

    func now() -> Date { current }
}

@MainActor
func makeFeedbackOutboxContainer(url: URL? = nil) throws -> ModelContainer {
    let configuration: ModelConfiguration
    if let url {
        configuration = ModelConfiguration(url: url)
    } else {
        configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [configuration]
    )
}

func makeFeedbackDraftContents(
    now: Date,
    intendedOutcome: String = "Complete the task",
    actualResult: String = "The operation failed",
    expectedResult: String = "The operation succeeds"
) -> FeedbackDraftContents {
    FeedbackDraftContents(
        intendedOutcome: intendedOutcome,
        actualResult: actualResult,
        expectedResult: expectedResult,
        workBlocked: true,
        taskID: "task-123",
        runID: "run-456",
        evidenceWindow: FeedbackEvidenceWindowV1(
            start: now.addingTimeInterval(-15 * 60),
            end: now
        ),
        consent: FeedbackConsentV1(version: "consent-v1", evidenceSelections: [])
    )
}

func makeFeedbackEnvelope(
    reportID: UUID,
    installationID: String,
    idempotencyKey: String,
    contents: FeedbackDraftContents,
    createdAt: Date
) throws -> FeedbackReportEnvelopeV1 {
    let manifest = FeedbackEvidenceManifestV1(
        artifacts: [],
        redactionPolicyVersion: "redaction-v1",
        totalByteCount: 0
    )
    let payload = FeedbackReportPayloadV1(
        reportID: FeedbackReportIDV1(reportID),
        createdAt: createdAt,
        statement: FeedbackUserStatementV1(
            intendedOutcome: contents.intendedOutcome,
            actualResult: contents.actualResult,
            expectedResult: contents.expectedResult,
            workBlocked: contents.workBlocked
        ),
        build: FeedbackBuildProvenanceV1(
            version: "1.0",
            build: "1",
            channel: "dev",
            gitCommit: "abc123",
            buildDate: "2026-07-09",
            source: "tests"
        ),
        platform: FeedbackPlatformV1(macOSVersion: "15.5", architecture: "arm64"),
        evidenceWindow: contents.evidenceWindow,
        consent: contents.consent,
        taskID: contents.taskID,
        runID: contents.runID,
        evidence: manifest
    )
    let payloadHash = try payload.canonicalSHA256()
    let placeholder = FeedbackReportEnvelopeV1(
        installationID: FeedbackInstallationIDV1(rawValue: installationID),
        idempotencyKey: idempotencyKey,
        payloadSHA256: payloadHash,
        canonicalDigestSHA256: String(repeating: "0", count: 64),
        payload: payload
    )
    return FeedbackReportEnvelopeV1(
        installationID: placeholder.installationID,
        idempotencyKey: idempotencyKey,
        payloadSHA256: payloadHash,
        canonicalDigestSHA256: try placeholder.computedCanonicalDigestSHA256(),
        payload: payload
    )
}

func writeFeedbackPreparedPackage(
    parent: URL,
    envelope: FeedbackReportEnvelopeV1
) throws -> URL {
    let directory = parent.appendingPathComponent("prepared-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try envelope.canonicalData().write(
        to: directory.appendingPathComponent(FeedbackPackageLayout.envelope),
        options: .atomic
    )
    let manifestData = try FeedbackCanonicalJSONV1.encodeValidated(
        envelope.payload.evidence.canonicalized()
    )
    try manifestData.write(
        to: directory.appendingPathComponent(FeedbackPackageLayout.manifest),
        options: .atomic
    )
    return directory
}

func makeFeedbackReceiptData(
    envelope: FeedbackReportEnvelopeV1,
    receivedAt: Date
) throws -> Data {
    let receipt = FeedbackSubmissionReceiptV1(
        receiptID: "receipt-123",
        reportID: envelope.payload.reportID,
        installationID: envelope.installationID,
        idempotencyKey: envelope.idempotencyKey,
        payloadSHA256: envelope.payloadSHA256,
        evidenceArchiveSHA256: envelope.evidenceArchiveSHA256,
        receivedAt: receivedAt,
        disposition: .accepted,
        remoteStatus: .received,
        statusReadCredential: FeedbackStatusReadCredentialV1(
            rawValue: String(repeating: "a", count: 32)
        ),
        statusCredentialExpiresAt: receivedAt.addingTimeInterval(24 * 60 * 60)
    )
    return try receipt.canonicalData()
}
