import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Feedback Outbox State Machine")
struct FeedbackOutboxStateMachineTests {
    @MainActor
    @Test("Prepared package adoption is validated, renamed into ownership, and queued explicitly")
    func packageAdoptionIsAtomicAndExplicit() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)

        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        var report = try fetchReport(fixture.container, id: fixture.reportID)
        let canonicalEnvelope = try fixture.envelope.canonicalData()
        #expect(report.localStatus == .prepared)
        #expect(report.canonicalEnvelopeData == canonicalEnvelope)
        #expect(report.packageRelativePath?.hasPrefix("packages/") == true)

        try fixture.service.queue(reportID: fixture.reportID)
        report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .queued)
        #expect(report.idempotencyKey == fixture.envelope.idempotencyKey)
    }

    @MainActor
    @Test("A crash after the ownership rename recovers the prepared transition")
    func interruptedPackageAdoptionRecovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let destination = fixture.root
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(fixture.reportID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.moveItem(at: source, to: destination)

        #expect(try fixture.service.recoverInterruptedAdoptions() == 1)
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .prepared)
        #expect(report.packageRelativePath == "packages/\(fixture.reportID.uuidString.lowercased())")
    }

    @MainActor
    @Test("A package that does not match the durable draft is rejected before ownership transfer")
    func mismatchedPackageIsRejectedBeforeMove() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mismatched = try makeFeedbackEnvelope(
            reportID: UUID(),
            installationID: fixture.envelope.installationID.rawValue,
            idempotencyKey: fixture.envelope.idempotencyKey,
            contents: fixture.contents,
            createdAt: fixture.clock.current
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: mismatched)

        #expect(throws: FeedbackOutboxError.preparedPackageDoesNotMatchDraft) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fetchReport(fixture.container, id: fixture.reportID).localStatus == .draft)
    }

    @MainActor
    @Test("A symlinked package root is rejected before ownership transfer")
    func symlinkedPackageRootIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let symlink = fixture.root.appendingPathComponent("prepared-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)

        #expect(throws: FeedbackPackageValidationError.sourceIsNotDirectory) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: symlink)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fetchReport(fixture.container, id: fixture.reportID).localStatus == .draft)
    }

    @MainActor
    @Test("Additive V1 package members remain inert and their original bytes survive adoption")
    func additivePackageMembersArePreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let envelopeURL = source.appendingPathComponent(FeedbackPackageLayout.envelope)
        let manifestURL = source.appendingPathComponent(FeedbackPackageLayout.manifest)
        let extendedEnvelope = try addingFeedbackMember(
            "futureEnvelopeMember",
            value: "inert",
            to: try Data(contentsOf: envelopeURL)
        )
        let extendedManifest = try addingFeedbackMember(
            "futureManifestMember",
            value: ["ignored": true],
            to: try Data(contentsOf: manifestURL)
        )
        try extendedEnvelope.write(to: envelopeURL, options: .atomic)
        try extendedManifest.write(to: manifestURL, options: .atomic)

        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        try fixture.service.queue(reportID: fixture.reportID)
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
        #expect(claim.canonicalEnvelopeData == extendedEnvelope)
    }

    @MainActor
    @Test("Illegal state transitions are rejected by the outbox owner")
    func illegalTransitionsAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: FeedbackOutboxError.illegalTransition(from: "draft", to: "queued")) {
            try fixture.service.queue(reportID: fixture.reportID)
        }
    }

    @MainActor
    @Test("Retry preserves identity and uses deterministic backoff")
    func retryPreservesIdempotencyAndBackoff() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
        try fixture.service.recordRetryableFailure(
            claim: claim,
            code: "offline",
            safeMessage: "Waiting for a network connection."
        )

        var report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .retryableFailure)
        #expect(report.idempotencyKey == fixture.envelope.idempotencyKey)
        #expect(report.nextRetryAt == fixture.clock.current.addingTimeInterval(2))
        #expect(throws: FeedbackOutboxError.retryNotDue) {
            try fixture.service.queueRetry(reportID: fixture.reportID)
        }

        fixture.clock.current = fixture.clock.current.addingTimeInterval(2)
        try fixture.service.queueRetry(reportID: fixture.reportID)
        let secondClaim = try fixture.service.claimUpload(reportID: fixture.reportID)
        report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(secondClaim.attempt == 2)
        #expect(report.idempotencyKey == fixture.envelope.idempotencyKey)
        #expect(report.uploadAttempts.count == 2)
    }

    @MainActor
    @Test("Interrupted upload recovers to an explicit retryable state")
    func interruptedUploadRecovery() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.service.claimUpload(reportID: fixture.reportID)

        let relaunched = try FeedbackOutboxService(
            modelContainer: fixture.container,
            storageRoot: fixture.root,
            clock: fixture.clock,
            policy: fixture.policy
        )
        #expect(try relaunched.recoverInterruptedUploads() == 1)
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .retryableFailure)
        #expect(report.lastFailureCode == "interrupted_upload")
        #expect(report.nextRetryAt == fixture.clock.current)
        #expect(report.activeClaimToken == nil)
        #expect(report.uploadAttempts.last?.outcome == "retryable_failure")
    }

    @MainActor
    @Test("Separate persistence contexts cannot obtain two active upload claims")
    func oneActiveClaimAcrossContexts() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let competingService = try FeedbackOutboxService(
            modelContainer: fixture.container,
            storageRoot: fixture.root,
            clock: fixture.clock,
            policy: fixture.policy
        )

        let first = try fixture.service.claimUpload(reportID: fixture.reportID)
        #expect(throws: FeedbackOutboxError.activeClaimExists) {
            _ = try competingService.claimUpload(reportID: fixture.reportID)
        }
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.activeClaimToken == first.token)
        #expect(report.uploadAttemptCount == 1)
    }

    @MainActor
    @Test("Retention and cancellation cannot delete a package with an active claim")
    func activeClaimProtectsPackageFromDeletion() throws {
        let fixture = try makeQueuedFixture(retention: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)

        #expect(try fixture.service.purgeExpiredArtifacts() == 0)
        #expect(FileManager.default.fileExists(atPath: claim.packageURL.path))
        #expect(throws: FeedbackOutboxError.illegalTransition(from: "uploading", to: "cancelled")) {
            try fixture.service.cancel(reportID: fixture.reportID, deleteArtifacts: true)
        }
        #expect(FileManager.default.fileExists(atPath: claim.packageURL.path))
    }

    @MainActor
    @Test("Submitted requires a canonical receipt matching the same report and hashes")
    func receiptMustMatchClaimedReport() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
        let otherEnvelope = try makeFeedbackEnvelope(
            reportID: UUID(),
            installationID: fixture.envelope.installationID.rawValue,
            idempotencyKey: fixture.envelope.idempotencyKey,
            contents: fixture.contents,
            createdAt: fixture.clock.current
        )

        #expect(throws: FeedbackOutboxError.receiptMismatch) {
            try fixture.service.completeSubmission(
                claim: claim,
                receiptData: try makeFeedbackReceiptData(
                    envelope: otherEnvelope,
                    receivedAt: fixture.clock.current
                )
            )
        }
        #expect(try fetchReport(fixture.container, id: fixture.reportID).localStatus == .uploading)
    }

    @MainActor
    @Test("Additive V1 receipt members remain inert and exact receipt bytes are retained")
    func additiveReceiptMembersArePreserved() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
        let receiptData = try addingFeedbackMember(
            "futureReceiptMember",
            value: ["ignored": true],
            to: try makeFeedbackReceiptData(
                envelope: fixture.envelope,
                receivedAt: fixture.clock.current
            )
        )

        try fixture.service.completeSubmission(claim: claim, receiptData: receiptData)
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .submitted)
        #expect(report.receiptData == receiptData)
    }

    @MainActor
    @Test("Permanent failure and cancellation remain distinct terminal paths")
    func permanentFailureAndCancellationAreDistinct() throws {
        let failed = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: failed.root) }
        let claim = try failed.service.claimUpload(reportID: failed.reportID)
        try failed.service.recordPermanentFailure(
            claim: claim,
            code: "invalid_payload",
            safeMessage: "The prepared report is not accepted."
        )
        var report = try fetchReport(failed.container, id: failed.reportID)
        #expect(report.localStatus == .permanentFailure)
        #expect(report.failureDisposition == .permanent)
        #expect(report.nextRetryAt == nil)

        let cancelled = try makeFixture()
        defer { try? FileManager.default.removeItem(at: cancelled.root) }
        let source = try writeFeedbackPreparedPackage(parent: cancelled.root, envelope: cancelled.envelope)
        try cancelled.service.adoptPreparedPackage(reportID: cancelled.reportID, from: source)
        try cancelled.service.cancel(reportID: cancelled.reportID, deleteArtifacts: true)
        report = try fetchReport(cancelled.container, id: cancelled.reportID)
        #expect(report.localStatus == .cancelled)
        #expect(report.artifactsDeletedAt == cancelled.clock.current)
        #expect(report.packageRelativePath == nil)
    }
}

private struct FeedbackOutboxFixture {
    let root: URL
    let container: ModelContainer
    let service: FeedbackOutboxService
    let clock: TestFeedbackOutboxClock
    let policy: FeedbackOutboxPolicy
    let reportID: UUID
    let contents: FeedbackDraftContents
    let envelope: FeedbackReportEnvelopeV1
}

@MainActor
private func makeFixture(retention: TimeInterval = 60) throws -> FeedbackOutboxFixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("feedback-outbox-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clock = TestFeedbackOutboxClock()
    let policy = FeedbackOutboxPolicy(
        artifactRetentionInterval: retention,
        claimLeaseInterval: 60,
        initialRetryDelay: 2,
        maximumRetryDelay: 8
    )
    let container = try makeFeedbackOutboxContainer()
    let service = try FeedbackOutboxService(
        modelContainer: container,
        storageRoot: root,
        clock: clock,
        policy: policy
    )
    let contents = makeFeedbackDraftContents(now: clock.current)
    let reportID = try service.createDraft(
        installationID: FeedbackInstallationIDV1(rawValue: "installation-v1"),
        idempotencyKey: "stable-idempotency-key",
        contents: contents
    )
    let envelope = try makeFeedbackEnvelope(
        reportID: reportID,
        installationID: "installation-v1",
        idempotencyKey: "stable-idempotency-key",
        contents: contents,
        createdAt: clock.current
    )
    return FeedbackOutboxFixture(
        root: root,
        container: container,
        service: service,
        clock: clock,
        policy: policy,
        reportID: reportID,
        contents: contents,
        envelope: envelope
    )
}

@MainActor
private func makeQueuedFixture(retention: TimeInterval = 60) throws -> FeedbackOutboxFixture {
    let fixture = try makeFixture(retention: retention)
    let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
    try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
    try fixture.service.queue(reportID: fixture.reportID)
    return fixture
}

private func addingFeedbackMember(_ key: String, value: Any, to data: Data) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object[key] = value
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@MainActor
private func fetchReport(_ container: ModelContainer, id: UUID) throws -> FeedbackReport {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<FeedbackReport>(
        predicate: #Predicate<FeedbackReport> { $0.id == id }
    )
    return try #require(try context.fetch(descriptor).first)
}
