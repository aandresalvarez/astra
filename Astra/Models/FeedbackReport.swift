import Foundation
import SwiftData
import ASTRACore

public struct FeedbackUploadAttemptRecord: Codable, Equatable, Sendable {
    public var sequence: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: String
    public var failureCode: String?

    public init(
        sequence: Int,
        startedAt: Date,
        finishedAt: Date? = nil,
        outcome: String = "uploading",
        failureCode: String? = nil
    ) {
        self.sequence = sequence
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failureCode = failureCode
    }
}

public enum FeedbackReportStoredStateError: Error, Equatable, Sendable {
    case invalidStoredState(field: String, value: String)
}

@Model
public final class FeedbackReport {
    @Attribute(.unique) public var id: UUID
    public var installationID: String
    public var idempotencyKey: String

    public var intendedOutcome: String
    public var actualResult: String
    public var expectedResult: String
    public var workBlocked: Bool
    public var taskID: String?
    public var runID: String?
    public var evidenceWindowStart: Date
    public var evidenceWindowEnd: Date
    public var consentVersion: String
    public var evidenceSelectionsJSON: String

    public var localStatusRaw: String
    public var canonicalEnvelopeData: Data?
    public var packageRelativePath: String?
    public var payloadSHA256: String?
    public var evidenceArchiveSHA256: String?
    public var canonicalDigestSHA256: String?

    public var uploadAttemptCount: Int
    public var uploadAttemptsJSON: String
    public var lastAttemptAt: Date?
    public var nextRetryAt: Date?
    public var lastFailureCode: String?
    public var lastFailureDispositionRaw: String?
    public var lastFailureSafeMessage: String?

    public var activeClaimToken: String?
    public var claimAcquiredAt: Date?
    public var claimExpiresAt: Date?

    public var receiptData: Data?
    public var remoteStatusRaw: String?
    public var remoteStatusData: Data?
    public var remoteStatusUpdatedAt: Date?

    public var artifactsExpireAt: Date?
    public var artifactsDeletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var cancelledAt: Date?

    public init(
        id: UUID = UUID(),
        installationID: String,
        idempotencyKey: String = UUID().uuidString.lowercased(),
        intendedOutcome: String = "",
        actualResult: String = "",
        expectedResult: String = "",
        workBlocked: Bool = false,
        taskID: String? = nil,
        runID: String? = nil,
        evidenceWindowStart: Date,
        evidenceWindowEnd: Date,
        consentVersion: String,
        evidenceSelectionsJSON: String = "[]",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.installationID = installationID
        self.idempotencyKey = idempotencyKey
        self.intendedOutcome = intendedOutcome
        self.actualResult = actualResult
        self.expectedResult = expectedResult
        self.workBlocked = workBlocked
        self.taskID = taskID
        self.runID = runID
        self.evidenceWindowStart = evidenceWindowStart
        self.evidenceWindowEnd = evidenceWindowEnd
        self.consentVersion = consentVersion
        self.evidenceSelectionsJSON = evidenceSelectionsJSON
        self.localStatusRaw = FeedbackLocalStatusV1.draft.rawValue
        self.uploadAttemptCount = 0
        self.uploadAttemptsJSON = "[]"
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var localStatus: FeedbackLocalStatusV1? {
        FeedbackLocalStatusV1(rawValue: localStatusRaw)
    }

    public func requireLocalStatus() throws -> FeedbackLocalStatusV1 {
        guard let localStatus else {
            throw FeedbackReportStoredStateError.invalidStoredState(
                field: "localStatusRaw",
                value: localStatusRaw
            )
        }
        return localStatus
    }

    public var failureDisposition: FeedbackFailureDispositionV1? {
        lastFailureDispositionRaw.flatMap(FeedbackFailureDispositionV1.init(rawValue:))
    }

    public var uploadAttempts: [FeedbackUploadAttemptRecord] {
        get {
            guard let data = uploadAttemptsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([FeedbackUploadAttemptRecord].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else { return }
            uploadAttemptsJSON = json
        }
    }

    public var receipt: FeedbackSubmissionReceiptV1? {
        guard let receiptData else { return nil }
        return try? FeedbackCanonicalJSONV1.decode(FeedbackSubmissionReceiptV1.self, from: receiptData)
    }

    public var localStatusDTO: FeedbackLocalStatusDTOv1 {
        get throws {
            let dto = FeedbackLocalStatusDTOv1(
                reportID: FeedbackReportIDV1(id),
                status: try requireLocalStatus(),
                updatedAt: updatedAt,
                uploadAttemptCount: uploadAttemptCount,
                nextRetryAt: nextRetryAt,
                lastFailure: lastFailureCode.flatMap { code in
                    guard let disposition = failureDisposition,
                          let message = lastFailureSafeMessage else { return nil }
                    return FeedbackStatusFailureV1(
                        code: code,
                        disposition: disposition,
                        safeMessage: message
                    )
                },
                receipt: receipt
            )
            try dto.validate()
            return dto
        }
    }
}
