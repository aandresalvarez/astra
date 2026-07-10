import Foundation
import ASTRACore

public protocol FeedbackOutboxClock {
    func now() -> Date
}

public struct SystemFeedbackOutboxClock: FeedbackOutboxClock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct FeedbackOutboxPolicy: Equatable, Sendable {
    public var artifactRetentionInterval: TimeInterval
    public var claimLeaseInterval: TimeInterval
    public var initialRetryDelay: TimeInterval
    public var maximumRetryDelay: TimeInterval

    public init(
        artifactRetentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        claimLeaseInterval: TimeInterval = 10 * 60,
        initialRetryDelay: TimeInterval = 60,
        maximumRetryDelay: TimeInterval = 60 * 60
    ) {
        self.artifactRetentionInterval = artifactRetentionInterval
        self.claimLeaseInterval = claimLeaseInterval
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }

    public func retryDelay(attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return initialRetryDelay }
        let exponent = min(attempt - 1, 20)
        return min(initialRetryDelay * pow(2, Double(exponent)), maximumRetryDelay)
    }
}

public struct FeedbackDraftContents: Equatable, Sendable {
    public var intendedOutcome: String
    public var actualResult: String
    public var expectedResult: String
    public var workBlocked: Bool
    public var taskID: String?
    public var runID: String?
    public var evidenceWindow: FeedbackEvidenceWindowV1
    public var consent: FeedbackConsentV1

    public init(
        intendedOutcome: String,
        actualResult: String,
        expectedResult: String,
        workBlocked: Bool,
        taskID: String? = nil,
        runID: String? = nil,
        evidenceWindow: FeedbackEvidenceWindowV1,
        consent: FeedbackConsentV1
    ) {
        self.intendedOutcome = FeedbackContractNormalizationV1.text(intendedOutcome)
        self.actualResult = FeedbackContractNormalizationV1.text(actualResult)
        self.expectedResult = FeedbackContractNormalizationV1.text(expectedResult)
        self.workBlocked = workBlocked
        self.taskID = taskID
        self.runID = runID
        self.evidenceWindow = evidenceWindow
        self.consent = consent
    }

    public func validate() throws {
        try FeedbackUserStatementV1(
            intendedOutcome: intendedOutcome,
            actualResult: actualResult,
            expectedResult: expectedResult,
            workBlocked: workBlocked
        ).validate()
        try evidenceWindow.validate()
        try consent.validate()
        if let taskID, taskID.count > FeedbackContractLimitsV1.identifierLength {
            throw FeedbackContractError.exceedsMaximumLength(
                path: "draft.taskID",
                maximum: FeedbackContractLimitsV1.identifierLength,
                actual: taskID.count
            )
        }
        if let runID, runID.count > FeedbackContractLimitsV1.identifierLength {
            throw FeedbackContractError.exceedsMaximumLength(
                path: "draft.runID",
                maximum: FeedbackContractLimitsV1.identifierLength,
                actual: runID.count
            )
        }
    }
}

/// Bounded, normalized UI progress stored by the outbox owner. Unlike
/// `FeedbackDraftContents`, statements may be incomplete until preparation.
public struct FeedbackDraftProgress: Equatable, Sendable {
    public let intendedOutcome: String
    public let actualResult: String
    public let expectedResult: String
    public let workBlocked: Bool
    public let taskID: String?
    public let runID: String?
    public let evidenceWindow: FeedbackEvidenceWindowV1
    public let consent: FeedbackConsentV1

    public init(
        intendedOutcome: String,
        actualResult: String,
        expectedResult: String,
        workBlocked: Bool,
        taskID: String? = nil,
        runID: String? = nil,
        evidenceWindow: FeedbackEvidenceWindowV1,
        consent: FeedbackConsentV1
    ) {
        self.intendedOutcome = FeedbackContractNormalizationV1.text(intendedOutcome)
        self.actualResult = FeedbackContractNormalizationV1.text(actualResult)
        self.expectedResult = FeedbackContractNormalizationV1.text(expectedResult)
        self.workBlocked = workBlocked
        self.taskID = taskID
        self.runID = runID
        self.evidenceWindow = evidenceWindow
        self.consent = consent
    }

    public func validate() throws {
        for (path, value) in [
            ("draft.intendedOutcome", intendedOutcome),
            ("draft.actualResult", actualResult),
            ("draft.expectedResult", expectedResult)
        ] where value.count > FeedbackContractLimitsV1.userStatementLength {
            throw FeedbackContractError.exceedsMaximumLength(
                path: path,
                maximum: FeedbackContractLimitsV1.userStatementLength,
                actual: value.count
            )
        }
        for (path, value) in [
            ("draft.intendedOutcome", intendedOutcome),
            ("draft.actualResult", actualResult),
            ("draft.expectedResult", expectedResult)
        ] where FeedbackContractNormalizationV1.text(value) != value {
            throw FeedbackContractError.invalidValue(
                path: path,
                description: "must use canonical normalized text"
            )
        }
        try evidenceWindow.validate()
        try consent.validate()
        for (path, value) in [("draft.taskID", taskID), ("draft.runID", runID)] {
            if let value, value.count > FeedbackContractLimitsV1.identifierLength {
                throw FeedbackContractError.exceedsMaximumLength(
                    path: path,
                    maximum: FeedbackContractLimitsV1.identifierLength,
                    actual: value.count
                )
            }
        }
    }
}

public struct FeedbackDraftSnapshot: Equatable, Sendable {
    public let reportID: UUID
    public let status: FeedbackLocalStatusV1
    public let progress: FeedbackDraftProgress
    public let createdAt: Date
    public let updatedAt: Date
}

public struct FeedbackPreparedPackageRecovery: Equatable, Sendable {
    public let reportID: UUID
    public let reportCreatedAt: Date
    public let directoryURL: URL
    public let envelopeData: Data
    public let manifest: FeedbackEvidenceManifestV1
    public let manifestSHA256: String
    public let reportSHA256: String
    public let archiveSHA256: String

    public init(
        reportID: UUID,
        reportCreatedAt: Date,
        directoryURL: URL,
        envelopeData: Data,
        manifest: FeedbackEvidenceManifestV1,
        manifestSHA256: String,
        reportSHA256: String,
        archiveSHA256: String
    ) {
        self.reportID = reportID
        self.reportCreatedAt = reportCreatedAt
        self.directoryURL = directoryURL
        self.envelopeData = envelopeData
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.reportSHA256 = reportSHA256
        self.archiveSHA256 = archiveSHA256
    }
}

public struct FeedbackUploadClaim: Equatable, Sendable {
    public let reportID: UUID
    public let token: String
    public let packageURL: URL
    public let canonicalEnvelopeData: Data
    public let attempt: Int
}

public enum FeedbackOutboxError: Error, Equatable {
    case reportNotFound
    case invalidStoredState(field: String, value: String)
    case invalidStoredPackagePath(String)
    case invalidInstallationID
    case invalidIdempotencyKey
    case illegalTransition(from: String, to: String)
    case packageAlreadyAdopted
    case packageNotOnOutboxVolume
    case preparedPackageDoesNotMatchDraft
    case missingPreparedPackage
    case activeClaimExists
    case claimMismatch
    case retryNotDue
    case receiptMismatch
    case remoteStatusMismatch
    case maximumAttemptsExceeded
}
