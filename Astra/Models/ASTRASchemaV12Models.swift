import Foundation
import SwiftData

/// Frozen feedback entity from the production V12 shape.
public enum ASTRASchemaV12Models {
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
      self.localStatusRaw = "draft"
      self.uploadAttemptCount = 0
      self.uploadAttemptsJSON = "[]"
      self.createdAt = createdAt
      self.updatedAt = createdAt
    }

  }
}
