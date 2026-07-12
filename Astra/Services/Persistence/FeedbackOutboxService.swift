import Foundation
import OSLog
import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
public final class FeedbackOutboxService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.coral.ASTRA",
        category: "FeedbackOutbox"
    )

    private let modelContainer: ModelContainer
    private let storageRoot: URL
    private let packagesRoot: URL
    private let clock: any FeedbackOutboxClock
    private let policy: FeedbackOutboxPolicy
    private let fileManager: FileManager

    public init(
        modelContainer: ModelContainer,
        storageRoot: URL,
        clock: any FeedbackOutboxClock = SystemFeedbackOutboxClock(),
        policy: FeedbackOutboxPolicy = FeedbackOutboxPolicy(),
        fileManager: FileManager = .default
    ) throws {
        let normalizedStorageRoot = storageRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.modelContainer = modelContainer
        self.storageRoot = normalizedStorageRoot
        self.packagesRoot = normalizedStorageRoot.appendingPathComponent("packages", isDirectory: true)
        self.clock = clock
        self.policy = policy
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: self.packagesRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @discardableResult
    public func createDraft(
        reportID: UUID = UUID(),
        installationID: FeedbackInstallationIDV1,
        idempotencyKey: String = UUID().uuidString.lowercased(),
        contents: FeedbackDraftContents
    ) throws -> UUID {
        try contents.validate()
        try validateIdentity(installationID: installationID, idempotencyKey: idempotencyKey)
        let context = makeContext()
        let duplicateDescriptor = FetchDescriptor<FeedbackReport>(
            predicate: #Predicate<FeedbackReport> {
                $0.installationID == installationID.rawValue && $0.idempotencyKey == idempotencyKey
            }
        )
        guard try context.fetch(duplicateDescriptor).isEmpty else {
            throw FeedbackOutboxError.invalidIdempotencyKey
        }
        let now = clock.now()
        let report = FeedbackReport(
            id: reportID,
            installationID: installationID.rawValue,
            idempotencyKey: idempotencyKey,
            intendedOutcome: contents.intendedOutcome,
            actualResult: contents.actualResult,
            expectedResult: contents.expectedResult,
            workBlocked: contents.workBlocked,
            taskID: contents.taskID,
            runID: contents.runID,
            evidenceWindowStart: contents.evidenceWindow.start,
            evidenceWindowEnd: contents.evidenceWindow.end,
            consentVersion: contents.consent.version,
            evidenceSelectionsJSON: try encodeSelections(contents.consent.evidenceSelections),
            createdAt: now
        )
        context.insert(report)
        try save(context, operation: "draft_created")
        return reportID
    }

    public func updateDraft(reportID: UUID, contents: FeedbackDraftContents) throws {
        try contents.validate()
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let current = try storedStatus(report)
        guard current == .draft else {
            throw illegalTransition(from: current, to: .draft)
        }
        report.intendedOutcome = contents.intendedOutcome
        report.actualResult = contents.actualResult
        report.expectedResult = contents.expectedResult
        report.workBlocked = contents.workBlocked
        report.taskID = contents.taskID
        report.runID = contents.runID
        report.evidenceWindowStart = contents.evidenceWindow.start
        report.evidenceWindowEnd = contents.evidenceWindow.end
        report.consentVersion = contents.consent.version
        report.evidenceSelectionsJSON = try encodeSelections(contents.consent.evidenceSelections)
        report.updatedAt = clock.now()
        try save(context, operation: "draft_updated")
    }

    @discardableResult
    public func createDraftProgress(
        reportID: UUID,
        installationID: FeedbackInstallationIDV1,
        idempotencyKey: String = UUID().uuidString.lowercased(),
        progress: FeedbackDraftProgress
    ) throws -> UUID {
        try progress.validate()
        try validateIdentity(installationID: installationID, idempotencyKey: idempotencyKey)
        let context = makeContext()
        guard try fetchIfPresent(reportID: reportID, in: context) == nil else {
            throw FeedbackOutboxError.invalidIdempotencyKey
        }
        let duplicateDescriptor = FetchDescriptor<FeedbackReport>(
            predicate: #Predicate<FeedbackReport> {
                $0.installationID == installationID.rawValue && $0.idempotencyKey == idempotencyKey
            }
        )
        guard try context.fetch(duplicateDescriptor).isEmpty else {
            throw FeedbackOutboxError.invalidIdempotencyKey
        }
        context.insert(FeedbackReport(
            id: reportID,
            installationID: installationID.rawValue,
            idempotencyKey: idempotencyKey,
            intendedOutcome: progress.intendedOutcome,
            actualResult: progress.actualResult,
            expectedResult: progress.expectedResult,
            workBlocked: progress.workBlocked,
            taskID: progress.taskID,
            runID: progress.runID,
            evidenceWindowStart: progress.evidenceWindow.start,
            evidenceWindowEnd: progress.evidenceWindow.end,
            consentVersion: progress.consent.version,
            evidenceSelectionsJSON: try encodeSelections(progress.consent.evidenceSelections),
            createdAt: clock.now()
        ))
        try save(context, operation: "draft_progress_saved")
        return reportID
    }

    public func updateDraftProgress(reportID: UUID, progress: FeedbackDraftProgress) throws {
        try progress.validate()
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let status = try storedStatus(report)
        guard status == .draft else { throw illegalTransition(from: status, to: .draft) }
        guard report.taskID == progress.taskID, report.runID == progress.runID else {
            throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft
        }
        try apply(progress, to: report)
        report.updatedAt = clock.now()
        try save(context, operation: "draft_progress_updated")
    }

    public func draftSnapshot(reportID: UUID) throws -> FeedbackDraftSnapshot {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let status = try storedStatus(report)
        guard status == .draft else { throw illegalTransition(from: status, to: .draft) }
        return try snapshot(report, status: status)
    }

    public func recoverableSnapshot(reportID: UUID) throws -> FeedbackDraftSnapshot {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let status = try storedStatus(report)
        guard status == .draft || status == .prepared else {
            throw illegalTransition(from: status, to: .draft)
        }
        if status == .prepared {
            _ = try validatedPreparedRecovery(for: report)
        }
        return try snapshot(report, status: status)
    }

    public func manualExportSnapshot(reportID: UUID) throws -> FeedbackDraftSnapshot {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let status = try storedStatus(report)
        guard status == .prepared || status == .queued else {
            throw illegalTransition(from: status, to: .prepared)
        }
        _ = try validatedPreparedRecovery(for: report)
        return try snapshot(report, status: status)
    }

    public func latestDraft(
        taskID: String?,
        runID: String?,
        excluding reportIDs: Set<UUID> = []
    ) throws -> FeedbackDraftSnapshot? {
        let context = makeContext()
        let reports = try context.fetch(FetchDescriptor<FeedbackReport>())
        let exactContext = reports.filter {
            $0.taskID == taskID && $0.runID == runID && !reportIDs.contains($0.id)
        }
        let matching = try exactContext.filter { try storedStatus($0) == .draft }
        guard let report = matching.sorted(by: {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }).first else { return nil }
        return try snapshot(report, status: .draft)
    }

    public func latestRecoverable(
        taskID: String?,
        runID: String?,
        excluding reportIDs: Set<UUID> = []
    ) throws -> FeedbackDraftSnapshot? {
        let context = makeContext()
        let reports = try context.fetch(FetchDescriptor<FeedbackReport>())
        let exactContext = reports.filter {
            $0.taskID == taskID && $0.runID == runID && !reportIDs.contains($0.id)
        }
        let matching = try exactContext.filter {
            let status = try storedStatus($0)
            return status == .draft || status == .prepared
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        guard let report = matching.first else { return nil }
        let status = try storedStatus(report)
        if status == .prepared {
            _ = try validatedPreparedRecovery(for: report)
        }
        return try snapshot(report, status: status)
    }

    public func recoverablePreparedPackage(reportID: UUID) throws -> FeedbackPreparedPackageRecovery {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        guard try storedStatus(report) == .prepared else {
            throw FeedbackOutboxError.illegalTransition(
                from: report.localStatusRaw,
                to: FeedbackLocalStatusV1.queued.rawValue
            )
        }
        return try validatedPreparedRecovery(for: report)
    }

    /// Returns a fully revalidated owned package for explicit manual export.
    /// Queued reports remain eligible because local queueing is not submission
    /// and the remote sender may not be available yet.
    public func recoverablePackageForManualExport(
        reportID: UUID
    ) throws -> FeedbackPreparedPackageRecovery {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let status = try storedStatus(report)
        guard status == .prepared || status == .queued else {
            throw FeedbackOutboxError.illegalTransition(
                from: report.localStatusRaw,
                to: FeedbackLocalStatusV1.queued.rawValue
            )
        }
        return try validatedPreparedRecovery(for: report)
    }

    /// Revalidates the exact package shown at the review boundary without
    /// adopting, queueing, or otherwise mutating durable state. Manual export
    /// uses this read-only boundary so it can never bypass the same package,
    /// report-binding, inventory, byte-count, and hash checks used by adoption.
    public func validatedReviewedPackageFiles(
        reportID: UUID,
        directory: URL,
        matching review: FeedbackPreparedPackageReview,
        expectedContents: FeedbackDraftContents
    ) throws -> [String] {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let status = try storedStatus(report)
        guard status == .draft || status == .prepared || status == .queued else {
            throw illegalTransition(from: status, to: .prepared)
        }

        if status != .draft {
            guard let ownedDirectory = try validatedOwnedPackageURL(
                for: report,
                requireExists: true
            ), ownedDirectory == directory.standardizedFileURL else {
                throw FeedbackOutboxError.invalidStoredPackagePath(directory.lastPathComponent)
            }
        }

        let validated = try FeedbackPackageAdoptionValidator.validate(
            directory: directory,
            fileManager: fileManager
        )
        try validate(validated.envelope, matches: report, expectedContents: expectedContents)
        guard validated.manifest == review.manifest.canonicalized(),
              validated.manifestSHA256 == review.manifestSHA256,
              validated.reportSHA256 == review.reportSHA256,
              validated.archiveSHA256 == review.archiveSHA256 else {
            throw FeedbackOutboxError.preparedPackageChangedAfterReview
        }

        var files = [FeedbackPackageLayout.envelope, FeedbackPackageLayout.manifest]
        if validated.archiveSHA256 != nil {
            files.append(FeedbackPackageLayout.archive)
        }
        files.append(contentsOf: validated.manifest.artifacts.map(\.relativePath))
        return Array(Set(files)).sorted()
    }

    public func recoverableReportIDs() throws -> Set<UUID> {
        let context = makeContext()
        let reports = try context.fetch(FetchDescriptor<FeedbackReport>())
        var result = Set<UUID>()
        for report in reports {
            let status = try storedStatus(report)
            if status == .draft {
                result.insert(report.id)
            } else if status == .prepared {
                _ = try validatedPreparedRecovery(for: report)
                result.insert(report.id)
            }
        }
        return result
    }

    /// Atomically transfers a complete PR 2 package into outbox ownership by a
    /// same-volume directory rename. If the process stops after the rename but
    /// before SwiftData saves, `recoverInterruptedAdoptions` completes the
    /// durable transition from the deterministic destination.
    public func adoptPreparedPackage(
        reportID: UUID,
        from sourceDirectory: URL,
        matching review: FeedbackPreparedPackageReview? = nil
    ) throws {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let current = try storedStatus(report)
        guard current == .draft else {
            throw illegalTransition(from: current, to: .prepared)
        }
        let destination = packageURL(reportID: reportID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FeedbackOutboxError.packageAlreadyAdopted
        }
        guard try sameVolume(sourceDirectory, packagesRoot) else {
            throw FeedbackOutboxError.packageNotOnOutboxVolume
        }

        let validated = try FeedbackPackageAdoptionValidator.validate(
            directory: sourceDirectory,
            fileManager: fileManager
        )
        try validate(validated.envelope, matches: report)
        if let review {
            guard validated.manifest == review.manifest.canonicalized(),
                  validated.manifestSHA256 == review.manifestSHA256,
                  validated.reportSHA256 == review.reportSHA256,
                  validated.archiveSHA256 == review.archiveSHA256
            else { throw FeedbackOutboxError.preparedPackageChangedAfterReview }
        }
        try fileManager.moveItem(at: sourceDirectory, to: destination)

        applyPreparedPackage(validated, to: report, at: clock.now())
        do {
            try save(context, operation: "package_adopted")
        } catch {
            Self.logger.error(
                "Feedback package adoption requires startup recovery after persistence failure"
            )
            throw error
        }
    }

    @discardableResult
    public func recoverInterruptedAdoptions() throws -> Int {
        let context = makeContext()
        let reports = try context.fetch(FetchDescriptor<FeedbackReport>())
        let drafts = try reports.filter { try storedStatus($0) == .draft }
        var recovered = 0
        for report in drafts {
            let destination = packageURL(reportID: report.id)
            guard fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                let validated = try FeedbackPackageAdoptionValidator.validate(
                    directory: destination,
                    fileManager: fileManager
                )
                try validate(validated.envelope, matches: report)
                applyPreparedPackage(validated, to: report, at: clock.now())
                recovered += 1
            } catch {
                try? FeedbackPackageRemoval.removeOwnedPackage(
                    at: destination,
                    fileManager: fileManager
                )
                Self.logger.warning("Discarded invalid interrupted feedback package adoption")
            }
        }
        if recovered > 0 {
            try save(context, operation: "package_adoptions_recovered")
        }
        return recovered
    }

    public func queue(reportID: UUID) throws {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        try transition(report, to: .queued, at: clock.now())
        try save(context, operation: "report_queued")
    }

    public func queueRetry(reportID: UUID, force: Bool = false) throws {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        _ = try storedStatus(report)
        let now = clock.now()
        guard force || report.nextRetryAt.map({ $0 <= now }) != false else {
            throw FeedbackOutboxError.retryNotDue
        }
        try transition(report, to: .queued, at: now)
        report.nextRetryAt = nil
        try save(context, operation: "report_retry_queued")
    }

    public func claimUpload(reportID: UUID) throws -> FeedbackUploadClaim {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        _ = try storedStatus(report)
        let now = clock.now()
        if report.activeClaimToken != nil {
            guard let claimExpiresAt = report.claimExpiresAt, claimExpiresAt <= now else {
                throw FeedbackOutboxError.activeClaimExists
            }
            try recoverExpiredClaim(report, at: now)
        }
        guard report.uploadAttemptCount < FeedbackContractLimitsV1.maximumUploadAttempts else {
            throw FeedbackOutboxError.maximumAttemptsExceeded
        }
        guard report.packageRelativePath != nil,
              let envelopeData = report.canonicalEnvelopeData else {
            throw FeedbackOutboxError.missingPreparedPackage
        }
        guard let packageURL = try validatedOwnedPackageURL(for: report, requireExists: true) else {
            throw FeedbackOutboxError.missingPreparedPackage
        }
        try validateOwnedPackageForUpload(
            report: report,
            directory: packageURL,
            storedEnvelopeData: envelopeData
        )

        try transition(report, to: .uploading, at: now)
        let token = UUID().uuidString.lowercased()
        report.activeClaimToken = token
        report.claimAcquiredAt = now
        report.claimExpiresAt = now.addingTimeInterval(policy.claimLeaseInterval)
        report.uploadAttemptCount += 1
        report.lastAttemptAt = now
        var attempts = report.uploadAttempts
        attempts.append(FeedbackUploadAttemptRecord(
            sequence: report.uploadAttemptCount,
            startedAt: now
        ))
        report.uploadAttempts = attempts
        try save(context, operation: "upload_claimed")
        return FeedbackUploadClaim(
            reportID: reportID,
            token: token,
            packageURL: packageURL,
            canonicalEnvelopeData: envelopeData,
            attempt: report.uploadAttemptCount
        )
    }

    public func recordRetryableFailure(
        claim: FeedbackUploadClaim,
        code: String,
        safeMessage: String
    ) throws {
        try recordFailure(
            claim: claim,
            code: code,
            safeMessage: safeMessage,
            disposition: .retryable
        )
    }

    public func recordPermanentFailure(
        claim: FeedbackUploadClaim,
        code: String,
        safeMessage: String
    ) throws {
        try recordFailure(
            claim: claim,
            code: code,
            safeMessage: safeMessage,
            disposition: .permanent
        )
    }

    public func completeSubmission(
        claim: FeedbackUploadClaim,
        receiptData: Data
    ) throws {
        let receipt = try FeedbackCanonicalJSONV1.decode(
            FeedbackSubmissionReceiptV1.self,
            from: receiptData
        )
        try receipt.validate()

        let context = makeContext()
        let report = try fetch(reportID: claim.reportID, in: context)
        try validateClaim(claim, report: report)
        guard receipt.reportID.uuid == report.id,
              receipt.installationID.rawValue == report.installationID,
              receipt.idempotencyKey == report.idempotencyKey,
              receipt.payloadSHA256 == report.payloadSHA256,
              receipt.evidenceArchiveSHA256 == report.evidenceArchiveSHA256 else {
            throw FeedbackOutboxError.receiptMismatch
        }

        let now = clock.now()
        try transition(report, to: .submitted, at: now)
        finishLatestAttempt(report, outcome: "submitted", failureCode: nil, at: now)
        report.receiptData = receiptData
        report.remoteStatusRaw = receipt.remoteStatus.rawValue
        report.remoteStatusUpdatedAt = receipt.receivedAt
        report.artifactsExpireAt = now.addingTimeInterval(policy.artifactRetentionInterval)
        clearClaimAndFailure(report)
        try save(context, operation: "report_submitted")
    }

    public func applyRemoteStatus(reportID: UUID, statusData: Data) throws {
        let status = try FeedbackCanonicalJSONV1.decode(
            FeedbackRemoteStatusDTOv1.self,
            from: statusData
        )
        try status.validate()

        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        guard try storedStatus(report) == .submitted,
              let receipt = report.receipt,
              receipt.receiptID == status.receiptID else {
            throw FeedbackOutboxError.remoteStatusMismatch
        }
        if let previousData = report.remoteStatusData {
            let previous = try FeedbackCanonicalJSONV1.decode(
                FeedbackRemoteStatusDTOv1.self,
                from: previousData
            )
            try status.validateAdvancing(from: previous)
        } else {
            let previous = FeedbackRemoteStatusDTOv1(
                receiptID: receipt.receiptID,
                status: receipt.remoteStatus,
                updatedAt: receipt.receivedAt
            )
            try status.validateAdvancing(from: previous)
        }
        report.remoteStatusRaw = status.status.rawValue
        report.remoteStatusData = statusData
        report.remoteStatusUpdatedAt = status.updatedAt
        report.updatedAt = clock.now()
        try save(context, operation: "remote_status_updated")
    }

    @discardableResult
    public func recoverInterruptedUploads() throws -> Int {
        let context = makeContext()
        let reports = try context.fetch(FetchDescriptor<FeedbackReport>())
        let uploads = try reports.filter { try storedStatus($0) == .uploading }
        let now = clock.now()
        for report in uploads {
            try markInterruptedUpload(report, at: now)
        }
        if !uploads.isEmpty {
            try save(context, operation: "uploads_recovered")
        }
        return uploads.count
    }

    public func cancel(reportID: UUID, deleteArtifacts: Bool) throws {
        let context = makeContext()
        let report = try fetch(reportID: reportID, in: context)
        let now = clock.now()
        try transition(report, to: .cancelled, at: now)
        report.cancelledAt = now
        if deleteArtifacts { report.artifactsExpireAt = now }
        try save(context, operation: "report_cancelled")
        if deleteArtifacts {
            _ = try purgeExpiredArtifacts(now: now)
        }
    }

    @discardableResult
    public func purgeExpiredArtifacts(now: Date? = nil) throws -> Int {
        let cutoff = now ?? clock.now()
        let context = makeContext()
        let reports = try context.fetch(FetchDescriptor<FeedbackReport>())
        let reportsWithStatus = try reports.map { ($0, try storedStatus($0)) }
        var purged = 0
        for (report, status) in reportsWithStatus {
            guard report.artifactsDeletedAt == nil,
                  report.activeClaimToken == nil,
                  [.submitted, .cancelled, .permanentFailure].contains(status),
                  report.artifactsExpireAt.map({ $0 <= cutoff }) == true else { continue }
            if report.packageRelativePath != nil,
               let packageURL = try validatedOwnedPackageURL(for: report, requireExists: false) {
                try FeedbackPackageRemoval.removeOwnedPackage(
                    at: packageURL,
                    fileManager: fileManager
                )
            }
            minimizeExpiredReport(report, at: cutoff)
            purged += 1
        }
        if purged > 0 {
            try save(context, operation: "artifacts_purged")
        }
        return purged
    }

    private func recordFailure(
        claim: FeedbackUploadClaim,
        code: String,
        safeMessage: String,
        disposition: FeedbackFailureDispositionV1
    ) throws {
        let failure = FeedbackStatusFailureV1(
            code: code,
            disposition: disposition,
            safeMessage: safeMessage
        )
        try failure.validate()
        let context = makeContext()
        let report = try fetch(reportID: claim.reportID, in: context)
        try validateClaim(claim, report: report)
        let now = clock.now()
        let next: FeedbackLocalStatusV1 = disposition == .retryable
            ? .retryableFailure
            : .permanentFailure
        try transition(report, to: next, at: now)
        finishLatestAttempt(
            report,
            outcome: next.rawValue,
            failureCode: code,
            at: now
        )
        report.lastFailureCode = code
        report.lastFailureDispositionRaw = disposition.rawValue
        report.lastFailureSafeMessage = safeMessage
        report.nextRetryAt = disposition == .retryable
            ? now.addingTimeInterval(policy.retryDelay(attempt: report.uploadAttemptCount))
            : nil
        clearClaim(report)
        try save(context, operation: "upload_failed")
    }

    private func validateIdentity(
        installationID: FeedbackInstallationIDV1,
        idempotencyKey: String
    ) throws {
        let installation = installationID.rawValue
        guard !installation.isEmpty,
              installation.count <= FeedbackContractLimitsV1.identifierLength else {
            throw FeedbackOutboxError.invalidInstallationID
        }
        guard !idempotencyKey.isEmpty,
              idempotencyKey.count <= FeedbackContractLimitsV1.idempotencyKeyLength else {
            throw FeedbackOutboxError.invalidIdempotencyKey
        }
    }

    private func validatedPreparedRecovery(
        for report: FeedbackReport
    ) throws -> FeedbackPreparedPackageRecovery {
        guard let directory = try validatedOwnedPackageURL(for: report, requireExists: true) else {
            throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft
        }
        let validated = try validateOwnedPackage(at: directory)
        try validate(validated.envelope, matches: report)
        guard let storedEnvelope = report.canonicalEnvelopeData,
              storedEnvelope == validated.envelopeData,
              let storedArchiveSHA256 = report.evidenceArchiveSHA256,
              storedArchiveSHA256 == validated.envelope.evidenceArchiveSHA256
        else { throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft }

        let manifest = validated.envelope.payload.evidence.canonicalized()
        let canonicalManifest = try FeedbackCanonicalJSONV1.encodeValidated(manifest)
        let manifestURL = directory.appendingPathComponent(FeedbackPackageLayout.manifest)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              manifestData == canonicalManifest
        else { throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft }
        return FeedbackPreparedPackageRecovery(
            reportID: report.id,
            reportCreatedAt: report.createdAt,
            directoryURL: directory,
            envelopeData: storedEnvelope,
            manifest: manifest,
            manifestSHA256: FeedbackCanonicalJSONV1.sha256Hex(manifestData),
            reportSHA256: FeedbackCanonicalJSONV1.sha256Hex(storedEnvelope),
            archiveSHA256: storedArchiveSHA256
        )
    }

    /// Revalidates the complete owned package immediately before a claim can
    /// mutate durable state or consume an upload attempt. Containment alone is
    /// insufficient because package bytes can be corrupted after adoption.
    private func validateOwnedPackageForUpload(
        report: FeedbackReport,
        directory: URL,
        storedEnvelopeData: Data
    ) throws {
        let validated = try validateOwnedPackage(at: directory)
        try validate(validated.envelope, matches: report)
        guard validated.envelopeData == storedEnvelopeData,
              validated.archiveSHA256 == report.evidenceArchiveSHA256
        else { throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft }
    }

    private func validateOwnedPackage(at directory: URL) throws -> ValidatedFeedbackPackage {
        do {
            return try FeedbackPackageAdoptionValidator.validate(
                directory: directory,
                fileManager: fileManager
            )
        } catch FeedbackPackageValidationError.nonCanonicalEnvelope {
            throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft
        } catch FeedbackPackageValidationError.forbiddenContactMember {
            // Raw envelope violations discovered after ownership are exposed
            // as durable-package corruption, matching other envelope drift.
            throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft
        }
    }

    private func validate(
        _ envelope: FeedbackReportEnvelopeV1,
        matches report: FeedbackReport
    ) throws {
        try envelope.validate()
        let payload = envelope.payload
        let storedSelections = try decodeSelections(report.evidenceSelectionsJSON)
            .sorted { $0.artifactID < $1.artifactID }
        let envelopeSelections = payload.consent.evidenceSelections
            .sorted { $0.artifactID < $1.artifactID }
        guard payload.reportID.uuid == report.id,
              envelope.installationID.rawValue == report.installationID,
              envelope.idempotencyKey == report.idempotencyKey,
              payload.statement.intendedOutcome == report.intendedOutcome,
              payload.statement.actualResult == report.actualResult,
              payload.statement.expectedResult == report.expectedResult,
              payload.statement.workBlocked == report.workBlocked,
              payload.taskID == report.taskID,
              payload.runID == report.runID,
              payload.evidenceWindow.start == report.evidenceWindowStart,
              payload.evidenceWindow.end == report.evidenceWindowEnd,
              payload.consent.version == report.consentVersion,
              envelopeSelections == storedSelections else {
            throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft
        }
    }

    private func validate(
        _ envelope: FeedbackReportEnvelopeV1,
        matches report: FeedbackReport,
        expectedContents: FeedbackDraftContents
    ) throws {
        try expectedContents.validate()
        try envelope.validate()
        let payload = envelope.payload
        let expectedSelections = expectedContents.consent.evidenceSelections
            .sorted { $0.artifactID < $1.artifactID }
        let envelopeSelections = payload.consent.evidenceSelections
            .sorted { $0.artifactID < $1.artifactID }
        guard payload.reportID.uuid == report.id,
              envelope.installationID.rawValue == report.installationID,
              envelope.idempotencyKey == report.idempotencyKey,
              payload.statement.intendedOutcome == expectedContents.intendedOutcome,
              payload.statement.actualResult == expectedContents.actualResult,
              payload.statement.expectedResult == expectedContents.expectedResult,
              payload.statement.workBlocked == expectedContents.workBlocked,
              payload.taskID == expectedContents.taskID,
              payload.runID == expectedContents.runID,
              payload.evidenceWindow == expectedContents.evidenceWindow,
              payload.consent.version == expectedContents.consent.version,
              envelopeSelections == expectedSelections else {
            throw FeedbackOutboxError.preparedPackageDoesNotMatchDraft
        }
    }

    private func applyPreparedPackage(
        _ validated: ValidatedFeedbackPackage,
        to report: FeedbackReport,
        at date: Date
    ) {
        report.canonicalEnvelopeData = validated.envelopeData
        report.packageRelativePath = packageRelativePath(reportID: report.id)
        report.payloadSHA256 = validated.envelope.payloadSHA256
        report.evidenceArchiveSHA256 = validated.envelope.evidenceArchiveSHA256
        report.canonicalDigestSHA256 = validated.envelope.canonicalDigestSHA256
        report.artifactsExpireAt = date.addingTimeInterval(policy.artifactRetentionInterval)
        report.localStatusRaw = FeedbackLocalStatusV1.prepared.rawValue
        report.updatedAt = date
    }

    private func transition(
        _ report: FeedbackReport,
        to next: FeedbackLocalStatusV1,
        at date: Date
    ) throws {
        let current = try storedStatus(report)
        guard current.canTransition(to: next) else {
            throw FeedbackOutboxError.illegalTransition(
                from: current.rawValue,
                to: next.rawValue
            )
        }
        report.localStatusRaw = next.rawValue
        report.updatedAt = date
    }

    private func illegalTransition(
        from current: FeedbackLocalStatusV1,
        to next: FeedbackLocalStatusV1
    ) -> FeedbackOutboxError {
        .illegalTransition(from: current.rawValue, to: next.rawValue)
    }

    private func validateClaim(_ claim: FeedbackUploadClaim, report: FeedbackReport) throws {
        guard try storedStatus(report) == .uploading,
              report.activeClaimToken == claim.token else {
            throw FeedbackOutboxError.claimMismatch
        }
    }

    private func finishLatestAttempt(
        _ report: FeedbackReport,
        outcome: String,
        failureCode: String?,
        at date: Date
    ) {
        var attempts = report.uploadAttempts
        guard !attempts.isEmpty else { return }
        attempts[attempts.count - 1].finishedAt = date
        attempts[attempts.count - 1].outcome = outcome
        attempts[attempts.count - 1].failureCode = failureCode
        report.uploadAttempts = attempts
    }

    /// Records an abandoned in-flight upload through the same durable state
    /// transition whether recovery happens at launch or when a lease expires.
    private func markInterruptedUpload(_ report: FeedbackReport, at date: Date) throws {
        try transition(report, to: .retryableFailure, at: date)
        finishLatestAttempt(
            report,
            outcome: "retryable_failure",
            failureCode: "interrupted_upload",
            at: date
        )
        report.lastFailureCode = "interrupted_upload"
        report.lastFailureDispositionRaw = FeedbackFailureDispositionV1.retryable.rawValue
        report.lastFailureSafeMessage = "The upload was interrupted and can be retried."
        report.nextRetryAt = date
        clearClaim(report)
    }

    /// Requeues an expired lease in the same transaction that issues its
    /// replacement, so callers cannot observe an unclaimed intermediate state.
    private func recoverExpiredClaim(_ report: FeedbackReport, at date: Date) throws {
        try markInterruptedUpload(report, at: date)
        try transition(report, to: .queued, at: date)
        report.nextRetryAt = nil
    }

    private func clearClaimAndFailure(_ report: FeedbackReport) {
        clearClaim(report)
        report.nextRetryAt = nil
        report.lastFailureCode = nil
        report.lastFailureDispositionRaw = nil
        report.lastFailureSafeMessage = nil
    }

    private func clearClaim(_ report: FeedbackReport) {
        report.activeClaimToken = nil
        report.claimAcquiredAt = nil
        report.claimExpiresAt = nil
    }

    private func minimizeExpiredReport(_ report: FeedbackReport, at date: Date) {
        report.canonicalEnvelopeData = nil
        report.packageRelativePath = nil
        report.intendedOutcome = ""
        report.actualResult = ""
        report.expectedResult = ""
        report.taskID = nil
        report.runID = nil
        report.evidenceSelectionsJSON = "[]"
        report.artifactsDeletedAt = date
        report.updatedAt = date
    }

    private func encodeSelections(_ selections: [FeedbackEvidenceSelectionV1]) throws -> String {
        let sorted = selections.sorted { $0.artifactID < $1.artifactID }
        let data = try FeedbackCanonicalJSONV1.encode(sorted)
        guard let value = String(data: data, encoding: .utf8) else {
            throw FeedbackContractError.invalidValue(
                path: "draft.evidenceSelections",
                description: "canonical JSON was not UTF-8"
            )
        }
        return value
    }

    private func apply(_ progress: FeedbackDraftProgress, to report: FeedbackReport) throws {
        report.intendedOutcome = progress.intendedOutcome
        report.actualResult = progress.actualResult
        report.expectedResult = progress.expectedResult
        report.workBlocked = progress.workBlocked
        report.taskID = progress.taskID
        report.runID = progress.runID
        report.evidenceWindowStart = progress.evidenceWindow.start
        report.evidenceWindowEnd = progress.evidenceWindow.end
        report.consentVersion = progress.consent.version
        report.evidenceSelectionsJSON = try encodeSelections(progress.consent.evidenceSelections)
    }

    private func snapshot(
        _ report: FeedbackReport,
        status: FeedbackLocalStatusV1
    ) throws -> FeedbackDraftSnapshot {
        try validateStoredProgressText(report.intendedOutcome, path: "draft.intendedOutcome")
        try validateStoredProgressText(report.actualResult, path: "draft.actualResult")
        try validateStoredProgressText(report.expectedResult, path: "draft.expectedResult")
        let consent = FeedbackConsentV1(
            version: report.consentVersion,
            evidenceSelections: try decodeSelections(report.evidenceSelectionsJSON)
        )
        let progress = FeedbackDraftProgress(
            intendedOutcome: report.intendedOutcome,
            actualResult: report.actualResult,
            expectedResult: report.expectedResult,
            workBlocked: report.workBlocked,
            taskID: report.taskID,
            runID: report.runID,
            evidenceWindow: FeedbackEvidenceWindowV1(
                start: report.evidenceWindowStart,
                end: report.evidenceWindowEnd
            ),
            consent: consent
        )
        try progress.validate()
        return FeedbackDraftSnapshot(
            reportID: report.id,
            status: status,
            progress: progress,
            createdAt: report.createdAt,
            updatedAt: report.updatedAt
        )
    }

    private func validateStoredProgressText(_ value: String, path: String) throws {
        guard FeedbackContractNormalizationV1.text(value) == value else {
            throw FeedbackContractError.invalidValue(
                path: path,
                description: "stored text is not canonically normalized"
            )
        }
        guard value.count <= FeedbackContractLimitsV1.userStatementLength else {
            throw FeedbackContractError.exceedsMaximumLength(
                path: path,
                maximum: FeedbackContractLimitsV1.userStatementLength,
                actual: value.count
            )
        }
    }

    private func fetchIfPresent(reportID: UUID, in context: ModelContext) throws -> FeedbackReport? {
        let id = reportID
        let descriptor = FetchDescriptor<FeedbackReport>(
            predicate: #Predicate<FeedbackReport> { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    private func decodeSelections(_ json: String) throws -> [FeedbackEvidenceSelectionV1] {
        try FeedbackCanonicalJSONV1.decode(
            [FeedbackEvidenceSelectionV1].self,
            from: Data(json.utf8)
        )
    }

    private func packageURL(reportID: UUID) -> URL {
        packagesRoot.appendingPathComponent(reportID.uuidString.lowercased(), isDirectory: true)
    }

    private func packageRelativePath(reportID: UUID) -> String {
        "packages/\(reportID.uuidString.lowercased())"
    }

    private func validatedOwnedPackageURL(
        for report: FeedbackReport,
        requireExists: Bool
    ) throws -> URL? {
        let expectedRelativePath = packageRelativePath(reportID: report.id)
        guard report.packageRelativePath == expectedRelativePath else {
            throw FeedbackOutboxError.invalidStoredPackagePath(
                report.packageRelativePath ?? "<nil>"
            )
        }
        let candidate = packageURL(reportID: report.id).standardizedFileURL
        let rootPath = packagesRoot.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/"),
              candidate.deletingLastPathComponent().path == rootPath else {
            throw FeedbackOutboxError.invalidStoredPackagePath(expectedRelativePath)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw FeedbackOutboxError.invalidStoredPackagePath(expectedRelativePath)
            }
            if requireExists { throw FeedbackOutboxError.missingPreparedPackage }
            return nil
        }
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().standardizedFileURL == candidate else {
            throw FeedbackOutboxError.invalidStoredPackagePath(expectedRelativePath)
        }
        return candidate
    }

    private func sameVolume(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsAttributes = try fileManager.attributesOfFileSystem(forPath: lhs.path)
        let rhsAttributes = try fileManager.attributesOfFileSystem(forPath: rhs.path)
        return (lhsAttributes[.systemNumber] as? NSNumber)
            == (rhsAttributes[.systemNumber] as? NSNumber)
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    private func fetch(reportID: UUID, in context: ModelContext) throws -> FeedbackReport {
        let descriptor = FetchDescriptor<FeedbackReport>(
            predicate: #Predicate<FeedbackReport> { $0.id == reportID }
        )
        guard let report = try context.fetch(descriptor).first else {
            throw FeedbackOutboxError.reportNotFound
        }
        _ = try storedStatus(report)
        return report
    }

    private func storedStatus(_ report: FeedbackReport) throws -> FeedbackLocalStatusV1 {
        do {
            return try report.requireLocalStatus()
        } catch let error as FeedbackReportStoredStateError {
            switch error {
            case .invalidStoredState(let field, let value):
                throw FeedbackOutboxError.invalidStoredState(field: field, value: value)
            }
        }
    }

    private func save(_ context: ModelContext, operation: String) throws {
        do {
            try context.save()
            Self.logger.info(
                "Feedback outbox operation succeeded: \(operation, privacy: .public)"
            )
        } catch {
            Self.logger.error(
                "Feedback outbox operation failed: \(operation, privacy: .public)"
            )
            throw error
        }
    }
}
