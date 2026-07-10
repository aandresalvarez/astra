import Foundation

public enum FeedbackLocalStatusV1: String, Codable, CaseIterable, Equatable, Sendable {
    case draft
    case prepared
    case queued
    case uploading
    case submitted
    case retryableFailure = "retryable_failure"
    case cancelled
    case permanentFailure = "permanent_failure"

    public func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.draft, .prepared), (.draft, .cancelled),
             (.prepared, .queued), (.prepared, .cancelled),
             (.queued, .uploading), (.queued, .retryableFailure), (.queued, .cancelled),
             (.uploading, .submitted), (.uploading, .retryableFailure),
             (.uploading, .permanentFailure),
             (.retryableFailure, .queued):
            true
        default:
            false
        }
    }
}

/// Remote states are extensible data. Unknown future values are retained so an
/// older client can display and persist a server state without mislabeling it.
public struct FeedbackRemoteStatusV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let received = Self(rawValue: "received")
    public static let assessmentPending = Self(rawValue: "assessment_pending")
    public static let needsInformation = Self(rawValue: "needs_information")
    public static let accepted = Self(rawValue: "accepted")
    public static let duplicate = Self(rawValue: "duplicate")
    public static let declined = Self(rawValue: "declined")
    public static let securityPrivate = Self(rawValue: "security_private")
    public static let implementationQueued = Self(rawValue: "implementation_queued")
    public static let inProgress = Self(rawValue: "in_progress")
    public static let fixReady = Self(rawValue: "fix_ready")
    public static let merged = Self(rawValue: "merged")
    public static let released = Self(rawValue: "released")

    private static let known: Set<Self> = [
        .received, .assessmentPending, .needsInformation, .accepted, .duplicate,
        .declined, .securityPrivate, .implementationQueued, .inProgress,
        .fixReady, .merged, .released
    ]

    public func validateTransition(to next: Self) throws {
        if self == next { return }
        // The server status vocabulary is intentionally extensible. An older
        // client cannot order a value it does not know, so the DTO timestamp is
        // the only safe advancement signal whenever either side is unknown.
        // Known-to-known transitions retain the stricter V1 state machine.
        guard Self.known.contains(self), Self.known.contains(next) else { return }
        let allowed: Bool = switch (self, next) {
        case (.received, .assessmentPending),
             (.assessmentPending, .needsInformation),
             (.assessmentPending, .accepted),
             (.assessmentPending, .duplicate),
             (.assessmentPending, .declined),
             (.assessmentPending, .securityPrivate),
             (.needsInformation, .assessmentPending),
             (.accepted, .implementationQueued),
             (.implementationQueued, .inProgress),
             (.inProgress, .fixReady),
             (.fixReady, .merged),
             (.merged, .released):
            true
        default:
            false
        }
        guard allowed else {
            throw FeedbackRemoteStatusTransitionError.illegalOrDowngrade(
                from: rawValue,
                to: next.rawValue
            )
        }
    }
}

public enum FeedbackRemoteStatusTransitionError: Error, Equatable, Sendable {
    case unknownStatus(String)
    case illegalOrDowngrade(from: String, to: String)
}

public struct FeedbackReceiptDispositionV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let accepted = Self(rawValue: "accepted")
    public static let duplicate = Self(rawValue: "duplicate")
}

public enum FeedbackFailureDispositionV1: String, Codable, CaseIterable, Equatable, Sendable {
    case retryable
    case permanent
}

public struct FeedbackStatusReadCredentialV1: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func validate(path: String = "statusReadCredential") throws {
        guard (32...FeedbackContractLimitsV1.credentialLength).contains(rawValue.count),
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                  (scalar.value >= 65 && scalar.value <= 90) ||
                  (scalar.value >= 97 && scalar.value <= 122) ||
                  scalar.value == 45 || scalar.value == 95
              }) else {
            throw FeedbackContractError.invalidValue(
                path: path,
                description: "must be 32 to 512 base64url characters"
            )
        }
    }
}

public struct FeedbackStatusFailureV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var code: String
    public var disposition: FeedbackFailureDispositionV1
    public var safeMessage: String

    public init(code: String, disposition: FeedbackFailureDispositionV1, safeMessage: String) {
        self.code = code
        self.disposition = disposition
        self.safeMessage = safeMessage
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case disposition
        case safeMessage
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            code,
            path: "status.lastFailure.code",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            safeMessage,
            path: "status.lastFailure.safeMessage",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
    }
}

public struct FeedbackSubmissionReceiptV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var receiptID: String
    public var reportID: FeedbackReportIDV1
    public var installationID: FeedbackInstallationIDV1
    public var idempotencyKey: String
    public var payloadSHA256: String
    public var evidenceArchiveSHA256: String?
    public var receivedAt: Date
    public var disposition: FeedbackReceiptDispositionV1
    public var remoteStatus: FeedbackRemoteStatusV1
    public var statusReadCredential: FeedbackStatusReadCredentialV1
    public var statusCredentialExpiresAt: Date

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        receiptID: String,
        reportID: FeedbackReportIDV1,
        installationID: FeedbackInstallationIDV1,
        idempotencyKey: String,
        payloadSHA256: String,
        evidenceArchiveSHA256: String? = nil,
        receivedAt: Date,
        disposition: FeedbackReceiptDispositionV1,
        remoteStatus: FeedbackRemoteStatusV1,
        statusReadCredential: FeedbackStatusReadCredentialV1,
        statusCredentialExpiresAt: Date
    ) {
        self.formatVersion = formatVersion
        self.receiptID = receiptID
        self.reportID = reportID
        self.installationID = installationID
        self.idempotencyKey = idempotencyKey
        self.payloadSHA256 = payloadSHA256
        self.evidenceArchiveSHA256 = evidenceArchiveSHA256
        self.receivedAt = receivedAt
        self.disposition = disposition
        self.remoteStatus = remoteStatus
        self.statusReadCredential = statusReadCredential
        self.statusCredentialExpiresAt = statusCredentialExpiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case receiptID
        case reportID
        case installationID
        case idempotencyKey
        case payloadSHA256
        case evidenceArchiveSHA256
        case receivedAt
        case disposition
        case remoteStatus
        case statusReadCredential
        case statusCredentialExpiresAt
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackSubmissionReceiptV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receiptID = try container.decode(String.self, forKey: .receiptID)
        reportID = try container.decode(FeedbackReportIDV1.self, forKey: .reportID)
        installationID = try container.decode(FeedbackInstallationIDV1.self, forKey: .installationID)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        payloadSHA256 = try container.decode(String.self, forKey: .payloadSHA256)
        evidenceArchiveSHA256 = try container.decodeIfPresent(String.self, forKey: .evidenceArchiveSHA256)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        disposition = try container.decode(FeedbackReceiptDispositionV1.self, forKey: .disposition)
        remoteStatus = try container.decode(FeedbackRemoteStatusV1.self, forKey: .remoteStatus)
        statusReadCredential = try container.decode(FeedbackStatusReadCredentialV1.self, forKey: .statusReadCredential)
        statusCredentialExpiresAt = try container.decode(Date.self, forKey: .statusCredentialExpiresAt)
        try validate()
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(self)
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackSubmissionReceiptV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.required(
            receiptID,
            path: "receipt.receiptID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            installationID.rawValue,
            path: "receipt.installationID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            idempotencyKey,
            path: "receipt.idempotencyKey",
            maximum: FeedbackContractLimitsV1.idempotencyKeyLength
        )
        try FeedbackContractValidationV1.sha256(payloadSHA256, path: "receipt.payloadSHA256")
        if let evidenceArchiveSHA256 {
            try FeedbackContractValidationV1.sha256(
                evidenceArchiveSHA256,
                path: "receipt.evidenceArchiveSHA256"
            )
        }
        try FeedbackContractValidationV1.required(
            disposition.rawValue,
            path: "receipt.disposition",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            remoteStatus.rawValue,
            path: "receipt.remoteStatus",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try statusReadCredential.validate(path: "receipt.statusReadCredential")
        guard statusCredentialExpiresAt > receivedAt else {
            throw FeedbackContractError.valueOutOfRange(
                path: "receipt.statusCredentialExpiresAt",
                description: "must be later than receivedAt"
            )
        }
    }

    public func validateStatusCredential(now: Date) throws {
        try validate()
        guard now < statusCredentialExpiresAt else {
            throw FeedbackStatusCredentialError.expired
        }
    }
}

public enum FeedbackStatusCredentialError: Error, Equatable, Sendable {
    case expired
    case installationMismatch
}

public struct FeedbackStatusReadRequestV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var installationID: FeedbackInstallationIDV1
    public var receiptID: String
    public var statusReadCredential: FeedbackStatusReadCredentialV1

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        installationID: FeedbackInstallationIDV1,
        receiptID: String,
        statusReadCredential: FeedbackStatusReadCredentialV1
    ) {
        self.formatVersion = formatVersion
        self.installationID = installationID
        self.receiptID = receiptID
        self.statusReadCredential = statusReadCredential
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case installationID
        case receiptID
        case statusReadCredential
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackStatusReadRequestV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try container.decode(FeedbackInstallationIDV1.self, forKey: .installationID)
        receiptID = try container.decode(String.self, forKey: .receiptID)
        statusReadCredential = try container.decode(
            FeedbackStatusReadCredentialV1.self,
            forKey: .statusReadCredential
        )
        try validate()
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            installationID.rawValue,
            path: "statusRead.installationID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            receiptID,
            path: "statusRead.receiptID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try statusReadCredential.validate(path: "statusRead.statusReadCredential")
    }

    public func validate(against receipt: FeedbackSubmissionReceiptV1, now: Date) throws {
        try validate()
        try receipt.validateStatusCredential(now: now)
        guard installationID == receipt.installationID else {
            throw FeedbackStatusCredentialError.installationMismatch
        }
        guard receiptID == receipt.receiptID,
              statusReadCredential == receipt.statusReadCredential else {
            throw FeedbackAPIContractError.unauthorizedStatusRead
        }
    }
}

public struct FeedbackAPIErrorCodeV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let invalidRequest = Self(rawValue: "invalid_request")
    public static let unsupportedVersion = Self(rawValue: "unsupported_version")
    public static let idempotencyKeyReuse = Self(rawValue: "idempotency_key_reuse")
    public static let crossInstallationReplay = Self(rawValue: "cross_installation_replay")
    public static let statusUnauthorized = Self(rawValue: "status_unauthorized")
    public static let statusCredentialExpired = Self(rawValue: "status_credential_expired")
    public static let remoteStatusDowngrade = Self(rawValue: "remote_status_downgrade")
}

public enum FeedbackAPIContractError: Error, Equatable, Sendable {
    case unauthorizedStatusRead
}

public struct FeedbackAPIErrorV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var code: FeedbackAPIErrorCodeV1
    public var safeMessage: String
    public var retryable: Bool
    public var requestID: String?

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        code: FeedbackAPIErrorCodeV1,
        safeMessage: String,
        retryable: Bool,
        requestID: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.code = code
        self.safeMessage = safeMessage
        self.retryable = retryable
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case code
        case safeMessage
        case retryable
        case requestID
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackAPIErrorV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(FeedbackAPIErrorCodeV1.self, forKey: .code)
        safeMessage = try container.decode(String.self, forKey: .safeMessage)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        try validate()
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(self)
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackAPIErrorV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.required(
            code.rawValue,
            path: "error.code",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            safeMessage,
            path: "error.safeMessage",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
        try FeedbackContractValidationV1.optional(
            requestID,
            path: "error.requestID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
    }
}

public struct FeedbackLocalStatusDTOv1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var reportID: FeedbackReportIDV1
    public var status: FeedbackLocalStatusV1
    public var updatedAt: Date
    public var uploadAttemptCount: Int
    public var nextRetryAt: Date?
    public var lastFailure: FeedbackStatusFailureV1?
    public var receipt: FeedbackSubmissionReceiptV1?

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        reportID: FeedbackReportIDV1,
        status: FeedbackLocalStatusV1,
        updatedAt: Date,
        uploadAttemptCount: Int,
        nextRetryAt: Date? = nil,
        lastFailure: FeedbackStatusFailureV1? = nil,
        receipt: FeedbackSubmissionReceiptV1? = nil
    ) {
        self.formatVersion = formatVersion
        self.reportID = reportID
        self.status = status
        self.updatedAt = updatedAt
        self.uploadAttemptCount = uploadAttemptCount
        self.nextRetryAt = nextRetryAt
        self.lastFailure = lastFailure
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case reportID
        case status
        case updatedAt
        case uploadAttemptCount
        case nextRetryAt
        case lastFailure
        case receipt
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackLocalStatusDTOv1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try container.decode(FeedbackReportIDV1.self, forKey: .reportID)
        status = try container.decode(FeedbackLocalStatusV1.self, forKey: .status)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        uploadAttemptCount = try container.decode(Int.self, forKey: .uploadAttemptCount)
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastFailure = try container.decodeIfPresent(FeedbackStatusFailureV1.self, forKey: .lastFailure)
        receipt = try container.decodeIfPresent(FeedbackSubmissionReceiptV1.self, forKey: .receipt)
        try validate()
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(self)
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackLocalStatusDTOv1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.nonnegative(uploadAttemptCount, path: "status.uploadAttemptCount")
        guard uploadAttemptCount <= FeedbackContractLimitsV1.maximumUploadAttempts else {
            throw FeedbackContractError.valueOutOfRange(
                path: "status.uploadAttemptCount",
                description: "exceeds maximum attempt count"
            )
        }
        try lastFailure?.validate()
        try receipt?.validate()
        if status == .submitted, receipt == nil {
            throw FeedbackContractError.missingRequiredField(path: "status.receipt")
        }
        if let receipt, receipt.reportID != reportID {
            throw FeedbackContractError.inconsistentValue(
                path: "status.receipt.reportID",
                description: "must match local reportID"
            )
        }
        if status == .retryableFailure {
            guard let lastFailure, lastFailure.disposition == .retryable else {
                throw FeedbackContractError.inconsistentValue(
                    path: "status.lastFailure",
                    description: "retryable failure status requires a retryable failure"
                )
            }
        }
        if status == .permanentFailure {
            guard let lastFailure, lastFailure.disposition == .permanent else {
                throw FeedbackContractError.inconsistentValue(
                    path: "status.lastFailure",
                    description: "permanent failure status requires a permanent failure"
                )
            }
        }
    }
}

public struct FeedbackIssueReferenceV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var number: Int
    public var url: URL

    public init(number: Int, url: URL) {
        self.number = number
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case number
        case url
    }

    public func validate() throws {
        guard number > 0, number <= Int(Int32.max) else {
            throw FeedbackContractError.valueOutOfRange(
                path: "remoteStatus.issue.number",
                description: "must be positive"
            )
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw FeedbackContractError.invalidValue(
                path: "remoteStatus.issue.url",
                description: "must be an absolute HTTPS URL"
            )
        }
    }
}

public struct FeedbackRemoteStatusDTOv1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var receiptID: String
    public var status: FeedbackRemoteStatusV1
    public var updatedAt: Date
    public var issue: FeedbackIssueReferenceV1?
    public var duplicateOfReceiptID: String?
    public var releasedVersion: String?

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        receiptID: String,
        status: FeedbackRemoteStatusV1,
        updatedAt: Date,
        issue: FeedbackIssueReferenceV1? = nil,
        duplicateOfReceiptID: String? = nil,
        releasedVersion: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.receiptID = receiptID
        self.status = status
        self.updatedAt = updatedAt
        self.issue = issue
        self.duplicateOfReceiptID = duplicateOfReceiptID
        self.releasedVersion = releasedVersion
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case receiptID
        case status
        case updatedAt
        case issue
        case duplicateOfReceiptID
        case releasedVersion
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackRemoteStatusDTOv1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receiptID = try container.decode(String.self, forKey: .receiptID)
        status = try container.decode(FeedbackRemoteStatusV1.self, forKey: .status)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        issue = try container.decodeIfPresent(FeedbackIssueReferenceV1.self, forKey: .issue)
        duplicateOfReceiptID = try container.decodeIfPresent(String.self, forKey: .duplicateOfReceiptID)
        releasedVersion = try container.decodeIfPresent(String.self, forKey: .releasedVersion)
        try validate()
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(self)
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackRemoteStatusDTOv1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.required(
            receiptID,
            path: "remoteStatus.receiptID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            status.rawValue,
            path: "remoteStatus.status",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try issue?.validate()
        try FeedbackContractValidationV1.optional(
            duplicateOfReceiptID,
            path: "remoteStatus.duplicateOfReceiptID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.optional(
            releasedVersion,
            path: "remoteStatus.releasedVersion",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
        if status == .duplicate, duplicateOfReceiptID == nil {
            throw FeedbackContractError.missingRequiredField(path: "remoteStatus.duplicateOfReceiptID")
        }
        if status == .released, releasedVersion == nil {
            throw FeedbackContractError.missingRequiredField(path: "remoteStatus.releasedVersion")
        }
    }

    public func validateAdvancing(from previous: Self) throws {
        guard previous.receiptID == receiptID else {
            throw FeedbackContractError.inconsistentValue(
                path: "remoteStatus.receiptID",
                description: "status projections must belong to the same receipt"
            )
        }
        try previous.status.validateTransition(to: status)
        guard updatedAt >= previous.updatedAt else {
            throw FeedbackRemoteStatusTransitionError.illegalOrDowngrade(
                from: previous.status.rawValue,
                to: status.rawValue
            )
        }
    }
}
