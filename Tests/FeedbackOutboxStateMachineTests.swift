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
    @Test("An untracked summary file is rejected before package adoption")
    func untrackedSummaryIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        try Data("unreviewed summary".utf8).write(to: source.appendingPathComponent("summary.md"))

        #expect(throws: FeedbackPackageValidationError.unexpectedFile("summary.md")) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .draft)
        #expect(report.packageRelativePath == nil)
    }

    @MainActor
    @Test("A non-empty loose package is byte-verified and retained after adoption")
    func nonEmptyLoosePackageIsVerifiedAndRetained() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try makeNonEmptyPackage(fixture: fixture)
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.evidence.write(to: evidenceURL, options: .atomic)

        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)

        let retained = fixture.root
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(fixture.reportID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(package.artifact.relativePath)
        #expect(try Data(contentsOf: retained) == package.evidence)
    }

    @MainActor
    @Test("A loose package missing a declared artifact is rejected before adoption")
    func missingDeclaredArtifactIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try makeNonEmptyPackage(fixture: fixture)
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)

        #expect(throws: FeedbackPackageValidationError.missingFile(package.artifact.relativePath)) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    @Test("A loose package with changed declared artifact bytes is rejected")
    func changedDeclaredArtifactIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try makeNonEmptyPackage(fixture: fixture)
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: package.evidence.count).write(to: evidenceURL)

        #expect(throws: FeedbackPackageValidationError.hashMismatch(package.artifact.relativePath)) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    @Test("A package with changed archive bytes is rejected")
    func changedArchiveIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = feedbackArtifactData()
        let artifact = makeFeedbackArtifact(data: evidence)
        let archiveData = try makeFeedbackArchive(
            parent: fixture.root,
            relativePath: artifact.relativePath,
            data: evidence
        )
        let package = try makeNonEmptyPackage(
            fixture: fixture,
            archiveSHA256: FeedbackCanonicalJSONV1.sha256Hex(archiveData)
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.evidence.write(to: evidenceURL)
        var changedArchive = archiveData
        changedArchive[changedArchive.startIndex] ^= 0xff
        try changedArchive.write(
            to: source.appendingPathComponent(FeedbackPackageLayout.archive),
            options: .atomic
        )

        #expect(throws: FeedbackPackageValidationError.hashMismatch(FeedbackPackageLayout.archive)) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    @Test("An archive with an undisclosed entry is rejected before adoption")
    func archiveInventoryMustMatchManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = feedbackArtifactData()
        let artifact = makeFeedbackArtifact(data: evidence)
        let archiveData = try makeFeedbackArchive(
            parent: fixture.root,
            entries: [
                artifact.relativePath: evidence,
                "hidden/private.txt": Data("undisclosed evidence".utf8)
            ]
        )
        let package = try makeNonEmptyPackage(
            fixture: fixture,
            archiveSHA256: FeedbackCanonicalJSONV1.sha256Hex(archiveData)
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.evidence.write(to: evidenceURL)
        try archiveData.write(to: source.appendingPathComponent(FeedbackPackageLayout.archive))

        #expect(throws: FeedbackPackageValidationError.archiveContentsMismatch("inventory")) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    @Test("Archive entry bytes must match the reviewed loose artifact")
    func archiveEntryBytesMustMatchManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = feedbackArtifactData()
        let artifact = makeFeedbackArtifact(data: evidence)
        let archiveData = try makeFeedbackArchive(
            parent: fixture.root,
            entries: [artifact.relativePath: Data(repeating: 0x78, count: evidence.count)]
        )
        let package = try makeNonEmptyPackage(
            fixture: fixture,
            archiveSHA256: FeedbackCanonicalJSONV1.sha256Hex(archiveData)
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.evidence.write(to: evidenceURL)
        try archiveData.write(to: source.appendingPathComponent(FeedbackPackageLayout.archive))

        #expect(throws: FeedbackPackageValidationError.archiveContentsMismatch(artifact.relativePath)) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
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
    @Test("Additive envelope members remain inert while manifests stay canonical")
    func additivePackageMembersArePreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let envelopeURL = source.appendingPathComponent(FeedbackPackageLayout.envelope)
        let extendedEnvelope = try addingFeedbackMember(
            "futureEnvelopeMember",
            value: "inert",
            to: try Data(contentsOf: envelopeURL)
        )
        try extendedEnvelope.write(to: envelopeURL, options: .atomic)

        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        try fixture.service.queue(reportID: fixture.reportID)
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
        #expect(claim.canonicalEnvelopeData == extendedEnvelope)
    }

    @MainActor
    @Test("Additive manifest members remain inert through adoption and recovery")
    func additiveManifestMembersArePreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let manifestURL = source.appendingPathComponent(FeedbackPackageLayout.manifest)
        let extendedManifest = try addingFeedbackMember(
            "futureManifestMember",
            value: ["ignored": true],
            to: try Data(contentsOf: manifestURL)
        )
        try extendedManifest.write(to: manifestURL, options: .atomic)

        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        let recovery = try fixture.service.recoverablePreparedPackage(reportID: fixture.reportID)

        #expect(recovery.manifest == fixture.envelope.payload.evidence.canonicalized())
        #expect(recovery.manifestSHA256 == FeedbackCanonicalJSONV1.sha256Hex(extendedManifest))
    }

    @MainActor
    @Test("Additive members nested inside array elements remain inert through adoption and recovery")
    func nestedAdditiveManifestMembersArePreserved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let package = try makeNonEmptyPackage(fixture: fixture)
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.evidence.write(to: evidenceURL, options: .atomic)

        let manifestURL = source.appendingPathComponent(FeedbackPackageLayout.manifest)
        let extendedManifest = try addingFeedbackMember(
            "futureArtifactField",
            value: "inert",
            toFirstElementOf: "artifacts",
            in: try Data(contentsOf: manifestURL)
        )
        try extendedManifest.write(to: manifestURL, options: .atomic)

        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        let recovery = try fixture.service.recoverablePreparedPackage(reportID: fixture.reportID)
        #expect(recovery.manifestSHA256 == FeedbackCanonicalJSONV1.sha256Hex(extendedManifest))
    }

    @MainActor
    @Test("Adoption rejects non-canonical manifest bytes before ownership transfer")
    func nonCanonicalManifestIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let manifestURL = source.appendingPathComponent(FeedbackPackageLayout.manifest)
        let canonical = try Data(contentsOf: manifestURL)
        try (Data(" \n".utf8) + canonical).write(to: manifestURL, options: .atomic)

        #expect(throws: FeedbackPackageValidationError.nonCanonicalManifest) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fetchReport(fixture.container, id: fixture.reportID).localStatus == .draft)
    }

    @MainActor
    @Test("Adoption rejects a manifest that reorders known array members away from the canonical sort")
    func nonCanonicalKnownMemberOrderIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = FeedbackEvidenceManifestV1(
            artifacts: [],
            omissions: [
                FeedbackEvidenceOmissionV1(artifactID: "a-item", kind: .applicationLog, reason: .notSelected),
                FeedbackEvidenceOmissionV1(artifactID: "b-item", kind: .applicationLog, reason: .notSelected)
            ],
            redactionPolicyVersion: "redaction-v1",
            totalByteCount: 0
        )
        let envelope = try makeFeedbackEnvelope(
            reportID: fixture.reportID,
            installationID: "installation-v1",
            idempotencyKey: "stable-idempotency-key",
            contents: fixture.contents,
            createdAt: fixture.clock.current,
            evidence: manifest
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: envelope)
        let manifestURL = source.appendingPathComponent(FeedbackPackageLayout.manifest)
        let reordered = try reversingFeedbackArrayOrder("omissions", in: try Data(contentsOf: manifestURL))
        try reordered.write(to: manifestURL, options: .atomic)

        // A generic, schema-agnostic canonical check cannot see that this
        // reordering violates the manifest's own canonical sort; only the
        // schema-aware known-member check catches it.
        #expect(FeedbackRawCanonicalJSONVerifier.isCanonicalObject(reordered))
        #expect(throws: FeedbackPackageValidationError.nonCanonicalManifest) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
    }

    @MainActor
    @Test("Adoption rejects a manifest that spells an omitted optional as explicit null")
    func nonCanonicalExplicitNullOptionalIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let manifestURL = source.appendingPathComponent(FeedbackPackageLayout.manifest)
        let withExplicitNull = try addingFeedbackMember(
            "archiveSHA256",
            value: NSNull(),
            to: try Data(contentsOf: manifestURL)
        )
        try withExplicitNull.write(to: manifestURL, options: .atomic)

        // V1 omits absent optionals rather than encoding null; a generic
        // canonical check alone cannot know that, so it wrongly accepts this.
        #expect(FeedbackRawCanonicalJSONVerifier.isCanonicalObject(withExplicitNull))
        #expect(throws: FeedbackPackageValidationError.nonCanonicalManifest) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
    }

    @MainActor
    @Test("Adoption rejects non-canonical report envelope bytes before ownership transfer")
    func nonCanonicalEnvelopeIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let envelopeURL = source.appendingPathComponent(FeedbackPackageLayout.envelope)
        let canonical = try Data(contentsOf: envelopeURL)
        try (Data(" \n".utf8) + canonical).write(to: envelopeURL, options: .atomic)

        #expect(throws: FeedbackPackageValidationError.nonCanonicalEnvelope) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fetchReport(fixture.container, id: fixture.reportID).localStatus == .draft)
    }

    @MainActor
    @Test("Adoption rejects additive reporter contact members before ownership transfer")
    func reporterContactMemberIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let envelopeURL = source.appendingPathComponent(FeedbackPackageLayout.envelope)
        let withContact = try addingFeedbackMember(
            "reporterEmail",
            value: "reporter@example.invalid",
            to: try Data(contentsOf: envelopeURL)
        )
        try withContact.write(to: envelopeURL, options: .atomic)

        #expect(throws: FeedbackPackageValidationError.forbiddenContactMember) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fetchReport(fixture.container, id: fixture.reportID).localStatus == .draft)
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
    @Test("Unknown persisted local state fails every stateful entrypoint and cannot project as draft")
    func unknownPersistedStateFailsClosed() throws {
        let fixture = try makeFixture(retention: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let context = ModelContext(fixture.container)
        let reportID = fixture.reportID
        let descriptor = FetchDescriptor<FeedbackReport>(
            predicate: #Predicate<FeedbackReport> { $0.id == reportID }
        )
        let corrupt = try #require(try context.fetch(descriptor).first)
        corrupt.localStatusRaw = "future_state"
        corrupt.artifactsExpireAt = fixture.clock.current
        try context.save()
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: fixture.envelope)
        let expected = FeedbackOutboxError.invalidStoredState(
            field: "localStatusRaw",
            value: "future_state"
        )

        #expect(throws: expected) {
            try fixture.service.updateDraft(reportID: fixture.reportID, contents: fixture.contents)
        }
        #expect(throws: expected) {
            try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        }
        #expect(throws: expected) { try fixture.service.queue(reportID: fixture.reportID) }
        #expect(throws: expected) { try fixture.service.queueRetry(reportID: fixture.reportID) }
        #expect(throws: expected) { _ = try fixture.service.claimUpload(reportID: fixture.reportID) }
        #expect(throws: expected) {
            try fixture.service.cancel(reportID: fixture.reportID, deleteArtifacts: true)
        }
        #expect(throws: expected) { _ = try fixture.service.recoverInterruptedAdoptions() }
        #expect(throws: expected) { _ = try fixture.service.recoverInterruptedUploads() }
        #expect(throws: expected) { _ = try fixture.service.purgeExpiredArtifacts() }

        let fetched = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(fetched.localStatus == nil)
        #expect(throws: FeedbackReportStoredStateError.invalidStoredState(
            field: "localStatusRaw",
            value: "future_state"
        )) {
            _ = try fetched.localStatusDTO
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
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
    @Test("Upload claim rejects changed owned envelope without consuming an attempt")
    func claimRejectsChangedOwnedEnvelope() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let envelopeURL = fixture.root
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(fixture.reportID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(FeedbackPackageLayout.envelope)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envelopeURL.path)
        var bytes = try Data(contentsOf: envelopeURL)
        bytes.append(0x0a)
        try bytes.write(to: envelopeURL)

        #expect(throws: FeedbackOutboxError.preparedPackageDoesNotMatchDraft) {
            _ = try fixture.service.claimUpload(reportID: fixture.reportID)
        }
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .queued)
        #expect(report.uploadAttemptCount == 0)
        #expect(report.activeClaimToken == nil)
        #expect(report.uploadAttempts.isEmpty)
    }

    @MainActor
    @Test("Upload claim rejects changed owned archive without consuming an attempt")
    func claimRejectsChangedOwnedArchive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = feedbackArtifactData()
        let artifact = makeFeedbackArtifact(data: evidence)
        let archiveData = try makeFeedbackArchive(
            parent: fixture.root,
            relativePath: artifact.relativePath,
            data: evidence
        )
        let package = try makeNonEmptyPackage(
            fixture: fixture,
            archiveSHA256: FeedbackCanonicalJSONV1.sha256Hex(archiveData)
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: package.envelope)
        let evidenceURL = source.appendingPathComponent(package.artifact.relativePath)
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try package.evidence.write(to: evidenceURL)
        try archiveData.write(to: source.appendingPathComponent(FeedbackPackageLayout.archive))
        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)
        try fixture.service.queue(reportID: fixture.reportID)

        let archiveURL = fixture.root
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent(fixture.reportID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(FeedbackPackageLayout.archive)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        try Data("changed archive".utf8).write(to: archiveURL)

        #expect(throws: FeedbackPackageValidationError.hashMismatch(FeedbackPackageLayout.archive)) {
            _ = try fixture.service.claimUpload(reportID: fixture.reportID)
        }
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .queued)
        #expect(report.uploadAttemptCount == 0)
        #expect(report.activeClaimToken == nil)
        #expect(report.uploadAttempts.isEmpty)
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
    @Test("An expired upload lease is recovered before issuing a replacement claim")
    func expiredClaimIsRecoveredAndReplaced() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try fixture.service.claimUpload(reportID: fixture.reportID)
        fixture.clock.current = fixture.clock.current.addingTimeInterval(
            fixture.policy.claimLeaseInterval + 1
        )
        let replacement = try fixture.service.claimUpload(reportID: fixture.reportID)

        #expect(replacement.token != first.token)
        #expect(replacement.attempt == 2)
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .uploading)
        #expect(report.activeClaimToken == replacement.token)
        #expect(report.claimAcquiredAt == fixture.clock.current)
        #expect(report.claimExpiresAt == fixture.clock.current.addingTimeInterval(
            fixture.policy.claimLeaseInterval
        ))
        #expect(report.uploadAttemptCount == 2)
        #expect(report.nextRetryAt == nil)
        #expect(report.uploadAttempts.count == 2)
        #expect(report.uploadAttempts[0].outcome == "retryable_failure")
        #expect(report.uploadAttempts[0].failureCode == "interrupted_upload")
        #expect(report.uploadAttempts[1].outcome == "uploading")
        #expect(throws: FeedbackOutboxError.claimMismatch) {
            try fixture.service.recordRetryableFailure(
                claim: first,
                code: "late-worker",
                safeMessage: "The superseded worker returned late."
            )
        }
    }

    @MainActor
    @Test("Claim rejects absolute traversal mismatched and symlinked persisted package paths")
    func claimRejectsUntrustedPersistedPackagePaths() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("feedback-sentinel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let sentinel = external.appendingPathComponent("sentinel.txt")
        try Data("untouched".utf8).write(to: sentinel)

        for corruptPath in [
            "../\(external.lastPathComponent)",
            external.path,
            "packages/\(UUID().uuidString.lowercased())"
        ] {
            try setPackagePath(corruptPath, reportID: fixture.reportID, container: fixture.container)
            #expect(throws: FeedbackOutboxError.invalidStoredPackagePath(corruptPath)) {
                _ = try fixture.service.claimUpload(reportID: fixture.reportID)
            }
            #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
        }

        let expectedPath = "packages/\(fixture.reportID.uuidString.lowercased())"
        try setPackagePath(expectedPath, reportID: fixture.reportID, container: fixture.container)
        let ownedPackage = fixture.root.appendingPathComponent(expectedPath, isDirectory: true)
        try FileManager.default.removeItem(at: ownedPackage)
        try FileManager.default.createSymbolicLink(at: ownedPackage, withDestinationURL: external)
        #expect(throws: FeedbackOutboxError.invalidStoredPackagePath(expectedPath)) {
            _ = try fixture.service.claimUpload(reportID: fixture.reportID)
        }
        #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
    }

    @MainActor
    @Test("Retention skips uploadable traversal without deleting an external sentinel")
    func retentionSkipsUploadableUntrustedPersistedPackagePath() throws {
        let fixture = try makeQueuedFixture(retention: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("feedback-retention-sentinel-\(UUID().uuidString)")
        try Data("untouched".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let corruptPath = "../\(external.lastPathComponent)"
        try setPackagePath(corruptPath, reportID: fixture.reportID, container: fixture.container)

        #expect(try fixture.service.purgeExpiredArtifacts() == 0)
        #expect(try Data(contentsOf: external) == Data("untouched".utf8))
        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.localStatus == .queued)
        #expect(report.packageRelativePath == corruptPath)
        #expect(report.artifactsDeletedAt == nil)
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
    @Test("Retention preserves packages for every uploadable state")
    func retentionPreservesUploadablePackages() throws {
        let prepared = try makeFixture(retention: 0)
        defer { try? FileManager.default.removeItem(at: prepared.root) }
        let preparedSource = try writeFeedbackPreparedPackage(
            parent: prepared.root,
            envelope: prepared.envelope
        )
        try prepared.service.adoptPreparedPackage(
            reportID: prepared.reportID,
            from: preparedSource
        )
        let preparedReport = try fetchReport(prepared.container, id: prepared.reportID)
        let preparedPackage = prepared.root.appendingPathComponent(
            try #require(preparedReport.packageRelativePath)
        )
        #expect(try prepared.service.purgeExpiredArtifacts() == 0)
        #expect(try fetchReport(prepared.container, id: prepared.reportID).localStatus == .prepared)
        #expect(FileManager.default.fileExists(atPath: preparedPackage.path))

        let queued = try makeQueuedFixture(retention: 0)
        defer { try? FileManager.default.removeItem(at: queued.root) }
        let queuedReport = try fetchReport(queued.container, id: queued.reportID)
        let queuedPackage = queued.root.appendingPathComponent(try #require(queuedReport.packageRelativePath))
        #expect(try queued.service.purgeExpiredArtifacts() == 0)
        #expect(try fetchReport(queued.container, id: queued.reportID).localStatus == .queued)
        #expect(FileManager.default.fileExists(atPath: queuedPackage.path))

        let retryable = try makeQueuedFixture(retention: 0)
        defer { try? FileManager.default.removeItem(at: retryable.root) }
        let claim = try retryable.service.claimUpload(reportID: retryable.reportID)
        try retryable.service.recordRetryableFailure(
            claim: claim,
            code: "offline",
            safeMessage: "Waiting for a network connection."
        )
        #expect(try retryable.service.purgeExpiredArtifacts() == 0)
        #expect(try fetchReport(retryable.container, id: retryable.reportID).localStatus == .retryableFailure)
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
    @Test("Future remote status bytes are retained after a monotonic server update")
    func futureRemoteStatusIsRetained() throws {
        let fixture = try makeQueuedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
        try fixture.service.completeSubmission(
            claim: claim,
            receiptData: try makeFeedbackReceiptData(
                envelope: fixture.envelope,
                receivedAt: fixture.clock.current
            )
        )
        let future = FeedbackRemoteStatusDTOv1(
            receiptID: "receipt-123",
            status: FeedbackRemoteStatusV1(rawValue: "future_server_state"),
            updatedAt: fixture.clock.current.addingTimeInterval(1)
        )
        let statusData = try future.canonicalData()

        try fixture.service.applyRemoteStatus(reportID: fixture.reportID, statusData: statusData)

        let report = try fetchReport(fixture.container, id: fixture.reportID)
        #expect(report.remoteStatusRaw == "future_server_state")
        #expect(report.remoteStatusData == statusData)
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

    @MainActor
    @Test("Retryable and permanent failures can be cancelled with exact package deletion")
    func failedReportsCanBeCancelled() throws {
        for disposition in [FeedbackFailureDispositionV1.retryable, .permanent] {
            let fixture = try makeQueuedFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let claim = try fixture.service.claimUpload(reportID: fixture.reportID)
            if disposition == .retryable {
                try fixture.service.recordRetryableFailure(
                    claim: claim,
                    code: "offline",
                    safeMessage: "Waiting for a network connection."
                )
            } else {
                try fixture.service.recordPermanentFailure(
                    claim: claim,
                    code: "invalid_payload",
                    safeMessage: "The report cannot be submitted."
                )
            }

            try fixture.service.cancel(reportID: fixture.reportID, deleteArtifacts: true)

            let report = try fetchReport(fixture.container, id: fixture.reportID)
            #expect(report.localStatus == .cancelled)
            #expect(report.artifactsDeletedAt == fixture.clock.current)
            #expect(report.packageRelativePath == nil)
            #expect(!FileManager.default.fileExists(atPath: claim.packageURL.path))
        }
    }

    @MainActor
    @Test("Queued archive-less packages remain discoverable and exportable after relaunch")
    func queuedArchiveLessPackageRecoversAfterRelaunch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var generalContents = fixture.contents
        generalContents.taskID = nil
        generalContents.runID = nil
        try fixture.service.updateDraft(reportID: fixture.reportID, contents: generalContents)
        let envelope = try makeFeedbackEnvelope(
            reportID: fixture.reportID,
            installationID: "installation-v1",
            idempotencyKey: "stable-idempotency-key",
            contents: generalContents,
            createdAt: fixture.clock.current
        )
        let source = try writeFeedbackPreparedPackage(parent: fixture.root, envelope: envelope)
        try fixture.service.adoptPreparedPackage(reportID: fixture.reportID, from: source)

        let prepared = try fixture.service.recoverablePreparedPackage(reportID: fixture.reportID)
        #expect(prepared.archiveSHA256 == nil)
        try fixture.service.queue(reportID: fixture.reportID)

        let relaunched = try FeedbackOutboxService(
            modelContainer: fixture.container,
            storageRoot: fixture.root,
            clock: fixture.clock,
            policy: fixture.policy
        )
        let latest = try #require(try relaunched.latestRecoverable(
            taskID: nil,
            runID: nil
        ))
        #expect(latest.reportID == fixture.reportID)
        #expect(latest.status == .queued)
        #expect(try relaunched.recoverableSnapshot(reportID: fixture.reportID).status == .queued)
        let resumed = try #require(try FeedbackReportResumeService(
            modelContainer: fixture.container,
            storageRoot: fixture.root
        ).latest(for: FeedbackReportLaunch(hostID: UUID(), entryPoint: .help)))
        #expect(resumed.id == fixture.reportID)
        let exported = try relaunched.recoverablePackageForManualExport(reportID: fixture.reportID)
        #expect(exported.archiveSHA256 == nil)
        #expect(!FileManager.default.fileExists(
            atPath: exported.directoryURL.appendingPathComponent(FeedbackPackageLayout.archive).path
        ))
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
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func reversingFeedbackArrayOrder(_ key: String, in data: Data) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let array = try #require(object[key] as? [Any])
    object[key] = Array(array.reversed())
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func addingFeedbackMember(
    _ key: String,
    value: Any,
    toFirstElementOf arrayKey: String,
    in data: Data
) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var array = try #require(object[arrayKey] as? [[String: Any]])
    var first = try #require(array.first)
    first[key] = value
    array[0] = first
    object[arrayKey] = array
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func feedbackArtifactData() -> Data {
    Data("sanitized application log".utf8)
}

@MainActor
private func makeNonEmptyPackage(
    fixture: FeedbackOutboxFixture,
    archiveSHA256: String? = nil
) throws -> (
    evidence: Data,
    artifact: FeedbackEvidenceArtifactV1,
    envelope: FeedbackReportEnvelopeV1
) {
    let evidence = feedbackArtifactData()
    let artifact = makeFeedbackArtifact(data: evidence)
    let contents = feedbackContents(fixture.contents, including: artifact)
    try fixture.service.updateDraft(reportID: fixture.reportID, contents: contents)
    let manifest = FeedbackEvidenceManifestV1(
        artifacts: [artifact],
        redactionPolicyVersion: "redaction-v1",
        totalByteCount: Int64(evidence.count),
        archiveSHA256: archiveSHA256
    )
    let envelope = try makeFeedbackEnvelope(
        reportID: fixture.reportID,
        installationID: "installation-v1",
        idempotencyKey: "stable-idempotency-key",
        contents: contents,
        createdAt: fixture.clock.current,
        evidence: manifest
    )
    return (evidence, artifact, envelope)
}

private func makeFeedbackArtifact(data: Data) -> FeedbackEvidenceArtifactV1 {
    FeedbackEvidenceArtifactV1(
        artifactID: "application-log",
        kind: .applicationLog,
        disclosureClass: .standard,
        relativePath: "logs/application.json",
        mediaType: "application/json",
        byteCount: Int64(data.count),
        sha256: FeedbackCanonicalJSONV1.sha256Hex(data),
        redaction: FeedbackRedactionSummaryV1(
            replacements: 1,
            secretPatterns: 1,
            pathPatterns: 0,
            contactPatterns: 0
        )
    )
}

private func feedbackContents(
    _ contents: FeedbackDraftContents,
    including artifact: FeedbackEvidenceArtifactV1
) -> FeedbackDraftContents {
    var copy = contents
    copy.consent = FeedbackConsentV1(
        version: contents.consent.version,
        evidenceSelections: [FeedbackEvidenceSelectionV1(
            artifactID: artifact.artifactID,
            disclosureClass: artifact.disclosureClass,
            included: true
        )]
    )
    return copy
}

private func makeFeedbackArchive(parent: URL, relativePath: String, data: Data) throws -> Data {
    try makeFeedbackArchive(parent: parent, entries: [relativePath: data])
}

private func makeFeedbackArchive(parent: URL, entries: [String: Data]) throws -> Data {
    let contents = parent.appendingPathComponent("archive-contents-\(UUID().uuidString)", isDirectory: true)
    for (relativePath, data) in entries {
        let artifactURL = contents.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: artifactURL)
    }
    let archiveURL = parent.appendingPathComponent("archive-\(UUID().uuidString).zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = contents
    process.arguments = ["-X", "-q", archiveURL.path] + entries.keys.sorted()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    defer {
        try? FileManager.default.removeItem(at: contents)
        try? FileManager.default.removeItem(at: archiveURL)
    }
    return try Data(contentsOf: archiveURL)
}

@MainActor
private func setPackagePath(
    _ path: String,
    reportID: UUID,
    container: ModelContainer
) throws {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<FeedbackReport>(
        predicate: #Predicate<FeedbackReport> { $0.id == reportID }
    )
    let report = try #require(try context.fetch(descriptor).first)
    report.packageRelativePath = path
    try context.save()
}

@MainActor
private func fetchReport(_ container: ModelContainer, id: UUID) throws -> FeedbackReport {
    let context = ModelContext(container)
    let descriptor = FetchDescriptor<FeedbackReport>(
        predicate: #Predicate<FeedbackReport> { $0.id == id }
    )
    return try #require(try context.fetch(descriptor).first)
}
