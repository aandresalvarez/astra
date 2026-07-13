import Foundation

public enum FeedbackEvidenceDisclosureClassV1: String, Codable, CaseIterable, Equatable, Sendable {
    case standard
    case sensitive
    case explicitOptIn = "explicit_opt_in"
}

public struct FeedbackEvidenceArtifactKindV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let applicationLog = Self(rawValue: "application_log")
    public static let taskLog = Self(rawValue: "task_log")
    public static let runtimeSnapshot = Self(rawValue: "runtime_snapshot")
    public static let browserEvidence = Self(rawValue: "browser_evidence")
    public static let screenshot = Self(rawValue: "screenshot")
    public static let macOSDiagnostic = Self(rawValue: "macos_diagnostic")
}

public struct FeedbackRuntimeIDV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let codexCLI = Self(rawValue: "codex_cli")
    public static let claudeCode = Self(rawValue: "claude_code")
    public static let copilotCLI = Self(rawValue: "copilot_cli")
    public static let antigravityCLI = Self(rawValue: "antigravity_cli")
}

public struct FeedbackInstallationIDV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct FeedbackRuntimeFailureCategoryV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let missing = Self(rawValue: "missing")
    public static let unauthenticated = Self(rawValue: "unauthenticated")
    public static let misconfigured = Self(rawValue: "misconfigured")
    public static let permissionDenied = Self(rawValue: "permission_denied")
    public static let timedOut = Self(rawValue: "timed_out")
    public static let rateLimited = Self(rawValue: "rate_limited")
    public static let quotaLimited = Self(rawValue: "quota_limited")
    public static let processFailed = Self(rawValue: "process_failed")
    public static let notRecorded = Self(rawValue: "not_recorded")
}

public struct FeedbackEvidenceReasonV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let unavailable = Self(rawValue: "unavailable")
    public static let notRecorded = Self(rawValue: "not_recorded")
    public static let notSelected = Self(rawValue: "not_selected")
    public static let unsupported = Self(rawValue: "unsupported")
    public static let oversized = Self(rawValue: "oversized")
    public static let redactionFailed = Self(rawValue: "redaction_failed")
}

public struct FeedbackUserStatementV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var intendedOutcome: String
    public var actualResult: String
    public var expectedResult: String
    public var workBlocked: Bool

    public init(intendedOutcome: String, actualResult: String, expectedResult: String, workBlocked: Bool) {
        self.intendedOutcome = intendedOutcome
        self.actualResult = actualResult
        self.expectedResult = expectedResult
        self.workBlocked = workBlocked
    }

    private enum CodingKeys: String, CodingKey {
        case intendedOutcome
        case actualResult
        case expectedResult
        case workBlocked
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            intendedOutcome,
            path: "payload.statement.intendedOutcome",
            maximum: FeedbackContractLimitsV1.userStatementLength
        )
        try FeedbackContractValidationV1.required(
            actualResult,
            path: "payload.statement.actualResult",
            maximum: FeedbackContractLimitsV1.userStatementLength
        )
        try FeedbackContractValidationV1.required(
            expectedResult,
            path: "payload.statement.expectedResult",
            maximum: FeedbackContractLimitsV1.userStatementLength
        )
    }
}

public struct FeedbackBuildProvenanceV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var version: String
    public var build: String
    public var channel: String
    public var gitCommit: String
    public var buildDate: String
    public var source: String

    public init(version: String, build: String, channel: String, gitCommit: String, buildDate: String, source: String) {
        self.version = version
        self.build = build
        self.channel = channel
        self.gitCommit = gitCommit
        self.buildDate = buildDate
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case channel
        case gitCommit
        case buildDate
        case source
    }

    public func validate() throws {
        for (name, value) in [
            ("version", version), ("build", build), ("channel", channel),
            ("gitCommit", gitCommit), ("buildDate", buildDate), ("source", source)
        ] {
            try FeedbackContractValidationV1.required(
                value,
                path: "payload.build.\(name)",
                maximum: FeedbackContractLimitsV1.shortTextLength
            )
        }
    }
}

public struct FeedbackPlatformV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var macOSVersion: String
    public var architecture: String

    public init(macOSVersion: String, architecture: String) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    private enum CodingKeys: String, CodingKey {
        case macOSVersion
        case architecture
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            macOSVersion,
            path: "payload.platform.macOSVersion",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
        try FeedbackContractValidationV1.required(
            architecture,
            path: "payload.platform.architecture",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
    }
}

public struct FeedbackEvidenceWindowV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public func validate() throws {
        guard end >= start else {
            throw FeedbackContractError.valueOutOfRange(
                path: "payload.evidenceWindow",
                description: "end must not precede start"
            )
        }
        guard end.timeIntervalSince(start) <= FeedbackContractLimitsV1.maximumEvidenceWindow else {
            throw FeedbackContractError.valueOutOfRange(
                path: "payload.evidenceWindow",
                description: "duration exceeds 24 hours"
            )
        }
    }
}

public struct FeedbackEvidenceSelectionV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var artifactID: String
    public var disclosureClass: FeedbackEvidenceDisclosureClassV1
    public var included: Bool
    public var reviewedAt: Date?

    public init(
        artifactID: String,
        disclosureClass: FeedbackEvidenceDisclosureClassV1,
        included: Bool,
        reviewedAt: Date? = nil
    ) {
        self.artifactID = artifactID
        self.disclosureClass = disclosureClass
        self.included = included
        self.reviewedAt = reviewedAt
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID
        case disclosureClass
        case included
        case reviewedAt
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            artifactID,
            path: "payload.consent.evidenceSelections[].artifactID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        if included, disclosureClass != .standard, reviewedAt == nil {
            throw FeedbackContractError.missingRequiredField(
                path: "payload.consent.evidenceSelections[].reviewedAt"
            )
        }
    }
}

public struct FeedbackConsentV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var version: String
    public var evidenceSelections: [FeedbackEvidenceSelectionV1]

    public init(
        version: String,
        evidenceSelections: [FeedbackEvidenceSelectionV1]
    ) {
        self.version = version
        self.evidenceSelections = evidenceSelections
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case evidenceSelections
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            version,
            path: "payload.consent.version",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.count(
            evidenceSelections.count,
            path: "payload.consent.evidenceSelections",
            maximum: FeedbackContractLimitsV1.maximumEvidenceItems
        )
        var ids = Set<String>()
        for selection in evidenceSelections {
            try selection.validate()
            guard ids.insert(selection.artifactID).inserted else {
                throw FeedbackContractError.duplicateValue(
                    path: "payload.consent.evidenceSelections",
                    value: selection.artifactID
                )
            }
        }
    }
}

public struct FeedbackRuntimeStreamCountersV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var rawLines: Int
    public var parsedEvents: Int
    public var textEvents: Int
    public var failedEvents: Int

    public init(rawLines: Int, parsedEvents: Int, textEvents: Int, failedEvents: Int) {
        self.rawLines = rawLines
        self.parsedEvents = parsedEvents
        self.textEvents = textEvents
        self.failedEvents = failedEvents
    }

    private enum CodingKeys: String, CodingKey {
        case rawLines
        case parsedEvents
        case textEvents
        case failedEvents
    }

    public func validate() throws {
        for (name, value) in [
            ("rawLines", rawLines), ("parsedEvents", parsedEvents),
            ("textEvents", textEvents), ("failedEvents", failedEvents)
        ] {
            let path = "payload.runtimeSnapshot.stream.\(name)"
            try FeedbackContractValidationV1.nonnegative(value, path: path)
            guard value <= FeedbackContractLimitsV1.maximumRuntimeCounter else {
                throw FeedbackContractError.valueOutOfRange(
                    path: path,
                    description: "exceeds maximum runtime counter"
                )
            }
        }
    }
}

public struct FeedbackRuntimeSnapshotV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var runtimeID: FeedbackRuntimeIDV1
    public var providerVersion: String?
    public var executableFound: Bool?
    public var readiness: String?
    public var failureCategory: FeedbackRuntimeFailureCategoryV1?
    public var unavailableReason: FeedbackEvidenceReasonV1?
    public var exitCode: Int?
    public var stopReason: String?
    public var stream: FeedbackRuntimeStreamCountersV1?
    public var sandboxState: String?
    public var policyState: String?
    public var sanitizedSummary: String?

    public init(
        runtimeID: FeedbackRuntimeIDV1,
        providerVersion: String? = nil,
        executableFound: Bool? = nil,
        readiness: String? = nil,
        failureCategory: FeedbackRuntimeFailureCategoryV1? = nil,
        unavailableReason: FeedbackEvidenceReasonV1? = nil,
        exitCode: Int? = nil,
        stopReason: String? = nil,
        stream: FeedbackRuntimeStreamCountersV1? = nil,
        sandboxState: String? = nil,
        policyState: String? = nil,
        sanitizedSummary: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.providerVersion = providerVersion
        self.executableFound = executableFound
        self.readiness = readiness
        self.failureCategory = failureCategory
        self.unavailableReason = unavailableReason
        self.exitCode = exitCode
        self.stopReason = stopReason
        self.stream = stream
        self.sandboxState = sandboxState
        self.policyState = policyState
        self.sanitizedSummary = sanitizedSummary
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeID
        case providerVersion
        case executableFound
        case readiness
        case failureCategory
        case unavailableReason
        case exitCode
        case stopReason
        case stream
        case sandboxState
        case policyState
        case sanitizedSummary
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            runtimeID.rawValue,
            path: "payload.runtimeSnapshot.runtimeID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.optional(
            failureCategory?.rawValue,
            path: "payload.runtimeSnapshot.failureCategory",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.optional(
            unavailableReason?.rawValue,
            path: "payload.runtimeSnapshot.unavailableReason",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        for (name, value) in [
            ("providerVersion", providerVersion), ("readiness", readiness),
            ("stopReason", stopReason), ("sandboxState", sandboxState),
            ("policyState", policyState), ("sanitizedSummary", sanitizedSummary)
        ] {
            try FeedbackContractValidationV1.optional(
                value,
                path: "payload.runtimeSnapshot.\(name)",
                maximum: FeedbackContractLimitsV1.shortTextLength
            )
        }
        if let exitCode, !(Int(Int32.min)...Int(Int32.max)).contains(exitCode) {
            throw FeedbackContractError.valueOutOfRange(
                path: "payload.runtimeSnapshot.exitCode",
                description: "must fit in a signed 32-bit integer"
            )
        }
        try stream?.validate()
    }
}

public struct FeedbackRedactionSummaryV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var replacements: Int
    public var secretPatterns: Int
    public var pathPatterns: Int
    public var contactPatterns: Int

    public init(replacements: Int, secretPatterns: Int, pathPatterns: Int, contactPatterns: Int) {
        self.replacements = replacements
        self.secretPatterns = secretPatterns
        self.pathPatterns = pathPatterns
        self.contactPatterns = contactPatterns
    }

    private enum CodingKeys: String, CodingKey {
        case replacements
        case secretPatterns
        case pathPatterns
        case contactPatterns
    }

    public func validate() throws {
        for (name, value) in [
            ("replacements", replacements), ("secretPatterns", secretPatterns),
            ("pathPatterns", pathPatterns), ("contactPatterns", contactPatterns)
        ] {
            try FeedbackContractValidationV1.nonnegative(value, path: "payload.evidence.redaction.\(name)")
            guard value <= FeedbackContractLimitsV1.maximumRedactionCount else {
                throw FeedbackContractError.valueOutOfRange(
                    path: "payload.evidence.redaction.\(name)",
                    description: "exceeds maximum redaction count"
                )
            }
        }
    }
}

public struct FeedbackEvidenceArtifactV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var artifactID: String
    public var kind: FeedbackEvidenceArtifactKindV1
    public var disclosureClass: FeedbackEvidenceDisclosureClassV1
    public var relativePath: String
    public var mediaType: String
    public var byteCount: Int64
    public var sha256: String
    public var redaction: FeedbackRedactionSummaryV1

    public init(
        artifactID: String,
        kind: FeedbackEvidenceArtifactKindV1,
        disclosureClass: FeedbackEvidenceDisclosureClassV1,
        relativePath: String,
        mediaType: String,
        byteCount: Int64,
        sha256: String,
        redaction: FeedbackRedactionSummaryV1
    ) {
        self.artifactID = artifactID
        self.kind = kind
        self.disclosureClass = disclosureClass
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.redaction = redaction
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID
        case kind
        case disclosureClass
        case relativePath
        case mediaType
        case byteCount
        case sha256
        case redaction
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            artifactID,
            path: "payload.evidence.artifacts[].artifactID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            kind.rawValue,
            path: "payload.evidence.artifacts[].kind",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            relativePath,
            path: "payload.evidence.artifacts[].relativePath",
            maximum: FeedbackContractLimitsV1.pathLength
        )
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw FeedbackContractError.invalidValue(
                path: "payload.evidence.artifacts[].relativePath",
                description: "must be a relative path without parent traversal"
            )
        }
        try FeedbackContractValidationV1.required(
            mediaType,
            path: "payload.evidence.artifacts[].mediaType",
            maximum: FeedbackContractLimitsV1.mediaTypeLength
        )
        try FeedbackContractValidationV1.nonnegative(byteCount, path: "payload.evidence.artifacts[].byteCount")
        guard byteCount <= FeedbackContractLimitsV1.maximumArtifactBytes else {
            throw FeedbackContractError.valueOutOfRange(
                path: "payload.evidence.artifacts[].byteCount",
                description: "exceeds maximum artifact size"
            )
        }
        try FeedbackContractValidationV1.sha256(sha256, path: "payload.evidence.artifacts[].sha256")
        try redaction.validate()
    }
}

public struct FeedbackEvidenceOmissionV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var artifactID: String
    public var kind: FeedbackEvidenceArtifactKindV1
    public var reason: FeedbackEvidenceReasonV1
    public var detail: String?

    public init(artifactID: String, kind: FeedbackEvidenceArtifactKindV1, reason: FeedbackEvidenceReasonV1, detail: String? = nil) {
        self.artifactID = artifactID
        self.kind = kind
        self.reason = reason
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID
        case kind
        case reason
        case detail
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            artifactID,
            path: "payload.evidence.omissions[].artifactID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            kind.rawValue,
            path: "payload.evidence.omissions[].kind",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            reason.rawValue,
            path: "payload.evidence.omissions[].reason",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.optional(
            detail,
            path: "payload.evidence.omissions[].detail",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
    }
}

public struct FeedbackEvidenceWarningV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var code: String
    public var artifactID: String?
    public var message: String

    public init(code: String, artifactID: String? = nil, message: String) {
        self.code = code
        self.artifactID = artifactID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case artifactID
        case message
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            code,
            path: "payload.evidence.warnings[].code",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.optional(
            artifactID,
            path: "payload.evidence.warnings[].artifactID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            message,
            path: "payload.evidence.warnings[].message",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
    }
}

public struct FeedbackEvidenceManifestV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var artifacts: [FeedbackEvidenceArtifactV1]
    public var omissions: [FeedbackEvidenceOmissionV1]
    public var warnings: [FeedbackEvidenceWarningV1]
    public var redactionPolicyVersion: String
    public var totalByteCount: Int64
    public var archiveSHA256: String?

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        artifacts: [FeedbackEvidenceArtifactV1],
        omissions: [FeedbackEvidenceOmissionV1] = [],
        warnings: [FeedbackEvidenceWarningV1] = [],
        redactionPolicyVersion: String,
        totalByteCount: Int64,
        archiveSHA256: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.artifacts = artifacts
        self.omissions = omissions
        self.warnings = warnings
        self.redactionPolicyVersion = redactionPolicyVersion
        self.totalByteCount = totalByteCount
        self.archiveSHA256 = archiveSHA256
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case artifacts
        case omissions
        case warnings
        case redactionPolicyVersion
        case totalByteCount
        case archiveSHA256
    }

    /// The manifest's schema-defined top-level member names. Used to isolate
    /// known fields from forward-compatible additive members when verifying
    /// raw manifest bytes are schema-canonical.
    public static let knownMemberNames: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackEvidenceManifestV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifacts = try container.decode([FeedbackEvidenceArtifactV1].self, forKey: .artifacts)
        omissions = try container.decode([FeedbackEvidenceOmissionV1].self, forKey: .omissions)
        warnings = try container.decode([FeedbackEvidenceWarningV1].self, forKey: .warnings)
        redactionPolicyVersion = try container.decode(String.self, forKey: .redactionPolicyVersion)
        totalByteCount = try container.decode(Int64.self, forKey: .totalByteCount)
        archiveSHA256 = try container.decodeIfPresent(String.self, forKey: .archiveSHA256)
        try validate()
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.artifacts.sort { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
            }
            return lhs.artifactID.utf8.lexicographicallyPrecedes(rhs.artifactID.utf8)
        }
        copy.omissions.sort { lhs, rhs in
            lhs.artifactID.utf8.lexicographicallyPrecedes(rhs.artifactID.utf8)
        }
        copy.warnings.sort { lhs, rhs in
            if lhs.code != rhs.code { return lhs.code.utf8.lexicographicallyPrecedes(rhs.code.utf8) }
            return (lhs.artifactID ?? "").utf8.lexicographicallyPrecedes((rhs.artifactID ?? "").utf8)
        }
        return copy
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackEvidenceManifestV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.count(
            artifacts.count,
            path: "payload.evidence.artifacts",
            maximum: FeedbackContractLimitsV1.maximumEvidenceItems
        )
        try FeedbackContractValidationV1.required(
            redactionPolicyVersion,
            path: "payload.evidence.redactionPolicyVersion",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.count(
            omissions.count,
            path: "payload.evidence.omissions",
            maximum: FeedbackContractLimitsV1.maximumOmissions
        )
        try FeedbackContractValidationV1.count(
            warnings.count,
            path: "payload.evidence.warnings",
            maximum: FeedbackContractLimitsV1.maximumWarnings
        )
        try FeedbackContractValidationV1.nonnegative(totalByteCount, path: "payload.evidence.totalByteCount")
        guard totalByteCount <= FeedbackContractLimitsV1.maximumEvidenceBytes else {
            throw FeedbackContractError.valueOutOfRange(
                path: "payload.evidence.totalByteCount",
                description: "exceeds maximum evidence size"
            )
        }
        var ids = Set<String>()
        var actualTotal: Int64 = 0
        for artifact in artifacts {
            try artifact.validate()
            guard ids.insert(artifact.artifactID).inserted else {
                throw FeedbackContractError.duplicateValue(
                    path: "payload.evidence.artifacts",
                    value: artifact.artifactID
                )
            }
            actualTotal += artifact.byteCount
        }
        guard actualTotal == totalByteCount else {
            throw FeedbackContractError.inconsistentValue(
                path: "payload.evidence.totalByteCount",
                description: "declared \(totalByteCount), artifact sum \(actualTotal)"
            )
        }
        for omission in omissions { try omission.validate() }
        for warning in warnings { try warning.validate() }
        if let archiveSHA256 {
            try FeedbackContractValidationV1.sha256(archiveSHA256, path: "payload.evidence.archiveSHA256")
        }
    }
}

public struct FeedbackReportPayloadV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var reportID: FeedbackReportIDV1
    public var createdAt: Date
    public var statement: FeedbackUserStatementV1
    public var build: FeedbackBuildProvenanceV1
    public var platform: FeedbackPlatformV1
    public var evidenceWindow: FeedbackEvidenceWindowV1
    public var consent: FeedbackConsentV1
    public var taskID: String?
    public var runID: String?
    public var runtimeSnapshot: FeedbackRuntimeSnapshotV1?
    public var evidence: FeedbackEvidenceManifestV1

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        reportID: FeedbackReportIDV1,
        createdAt: Date,
        statement: FeedbackUserStatementV1,
        build: FeedbackBuildProvenanceV1,
        platform: FeedbackPlatformV1,
        evidenceWindow: FeedbackEvidenceWindowV1,
        consent: FeedbackConsentV1,
        taskID: String? = nil,
        runID: String? = nil,
        runtimeSnapshot: FeedbackRuntimeSnapshotV1? = nil,
        evidence: FeedbackEvidenceManifestV1
    ) {
        self.formatVersion = formatVersion
        self.reportID = reportID
        self.createdAt = createdAt
        self.statement = statement
        self.build = build
        self.platform = platform
        self.evidenceWindow = evidenceWindow
        self.consent = consent
        self.taskID = taskID
        self.runID = runID
        self.runtimeSnapshot = runtimeSnapshot
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case reportID
        case createdAt
        case statement
        case build
        case platform
        case evidenceWindow
        case consent
        case taskID
        case runID
        case runtimeSnapshot
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackReportPayloadV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try container.decode(FeedbackReportIDV1.self, forKey: .reportID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        statement = try container.decode(FeedbackUserStatementV1.self, forKey: .statement)
        build = try container.decode(FeedbackBuildProvenanceV1.self, forKey: .build)
        platform = try container.decode(FeedbackPlatformV1.self, forKey: .platform)
        evidenceWindow = try container.decode(FeedbackEvidenceWindowV1.self, forKey: .evidenceWindow)
        consent = try container.decode(FeedbackConsentV1.self, forKey: .consent)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
        runtimeSnapshot = try container.decodeIfPresent(FeedbackRuntimeSnapshotV1.self, forKey: .runtimeSnapshot)
        evidence = try container.decode(FeedbackEvidenceManifestV1.self, forKey: .evidence)
        try validate()
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.consent.evidenceSelections.sort {
            $0.artifactID.utf8.lexicographicallyPrecedes($1.artifactID.utf8)
        }
        copy.evidence = evidence.canonicalized()
        return copy
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(canonicalized())
    }

    public func canonicalSHA256() throws -> String {
        FeedbackCanonicalJSONV1.sha256Hex(try canonicalData())
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackReportPayloadV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try reportID.validate()
        try statement.validate()
        try build.validate()
        try platform.validate()
        try evidenceWindow.validate()
        try consent.validate()
        try FeedbackContractValidationV1.optional(taskID, path: "payload.taskID", maximum: FeedbackContractLimitsV1.identifierLength)
        try FeedbackContractValidationV1.optional(runID, path: "payload.runID", maximum: FeedbackContractLimitsV1.identifierLength)
        try runtimeSnapshot?.validate()
        try evidence.validate()
        let selected = Set(consent.evidenceSelections.filter(\.included).map(\.artifactID))
        let included = Set(evidence.artifacts.map(\.artifactID))
        guard selected == included else {
            throw FeedbackContractError.inconsistentValue(
                path: "payload.consent.evidenceSelections",
                description: "included selections must match evidence artifacts"
            )
        }
        let includedSelections = Dictionary(
            uniqueKeysWithValues: consent.evidenceSelections
                .filter(\.included)
                .map { ($0.artifactID, $0) }
        )
        for artifact in evidence.artifacts {
            guard includedSelections[artifact.artifactID]?.disclosureClass == artifact.disclosureClass else {
                throw FeedbackContractError.inconsistentValue(
                    path: "payload.consent.evidenceSelections[].disclosureClass",
                    description: "must match the corresponding evidence artifact"
                )
            }
        }
    }
}

public struct FeedbackReportEnvelopeV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1
    public static let digestContext = "astra-feedback-digest-v1"

    public var formatVersion: Int
    public var installationID: FeedbackInstallationIDV1
    public var idempotencyKey: String
    public var payloadSHA256: String
    public var evidenceArchiveSHA256: String?
    public var canonicalDigestSHA256: String
    public var payload: FeedbackReportPayloadV1

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        installationID: FeedbackInstallationIDV1,
        idempotencyKey: String,
        payloadSHA256: String,
        evidenceArchiveSHA256: String? = nil,
        canonicalDigestSHA256: String,
        payload: FeedbackReportPayloadV1
    ) {
        self.formatVersion = formatVersion
        self.installationID = installationID
        self.idempotencyKey = idempotencyKey
        self.payloadSHA256 = payloadSHA256
        self.evidenceArchiveSHA256 = evidenceArchiveSHA256
        self.canonicalDigestSHA256 = canonicalDigestSHA256
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case installationID
        case idempotencyKey
        case payloadSHA256
        case evidenceArchiveSHA256
        case canonicalDigestSHA256
        case payload
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackReportEnvelopeV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try container.decode(FeedbackInstallationIDV1.self, forKey: .installationID)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        payloadSHA256 = try container.decode(String.self, forKey: .payloadSHA256)
        evidenceArchiveSHA256 = try container.decodeIfPresent(String.self, forKey: .evidenceArchiveSHA256)
        canonicalDigestSHA256 = try container.decode(String.self, forKey: .canonicalDigestSHA256)
        payload = try container.decode(FeedbackReportPayloadV1.self, forKey: .payload)
        try validate()
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.payload = payload.canonicalized()
        return copy
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(canonicalized())
    }

    /// Stable framing for the idempotency digest. It binds the schema version,
    /// canonical payload, redaction policy, archive, and final ordered artifact
    /// hashes without selecting an authentication/signature algorithm.
    public func digestInputData() throws -> Data {
        try payload.validate()
        var lines = [
            Self.digestContext,
            "formatVersion=\(formatVersion)",
            "payloadSHA256=\(payloadSHA256)",
            "redactionPolicyVersion=\(payload.evidence.redactionPolicyVersion)",
            "evidenceArchiveSHA256=\(evidenceArchiveSHA256 ?? "-")"
        ]
        for artifact in payload.evidence.canonicalized().artifacts {
            lines.append("artifact=\(artifact.artifactID):\(artifact.sha256)")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public func computedCanonicalDigestSHA256() throws -> String {
        FeedbackCanonicalJSONV1.sha256Hex(try digestInputData())
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackReportEnvelopeV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.required(
            installationID.rawValue,
            path: "installationID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            idempotencyKey,
            path: "idempotencyKey",
            maximum: FeedbackContractLimitsV1.idempotencyKeyLength
        )
        try FeedbackContractValidationV1.sha256(payloadSHA256, path: "payloadSHA256")
        if let evidenceArchiveSHA256 {
            try FeedbackContractValidationV1.sha256(evidenceArchiveSHA256, path: "evidenceArchiveSHA256")
        }
        try FeedbackContractValidationV1.sha256(
            canonicalDigestSHA256,
            path: "canonicalDigestSHA256"
        )
        try payload.validate()
        let actualPayloadHash = try payload.canonicalSHA256()
        guard actualPayloadHash == payloadSHA256 else {
            throw FeedbackContractError.inconsistentValue(
                path: "payloadSHA256",
                description: "does not match canonical payload bytes"
            )
        }
        guard evidenceArchiveSHA256 == payload.evidence.archiveSHA256 else {
            throw FeedbackContractError.inconsistentValue(
                path: "evidenceArchiveSHA256",
                description: "must match payload evidence manifest"
            )
        }
        let actualDigest = try computedCanonicalDigestSHA256()
        guard actualDigest == canonicalDigestSHA256 else {
            throw FeedbackContractError.inconsistentValue(
                path: "canonicalDigestSHA256",
                description: "does not match the V1 digest framing"
            )
        }
    }
}

public enum FeedbackIdempotencyDecisionV1: Equatable, Sendable {
    case acceptNew
    case returnExistingReceipt
    case rejectKeyReuse
    case rejectCrossInstallationReplay

    public static func evaluate(
        existingKey: String?,
        existingInstallationID: FeedbackInstallationIDV1?,
        existingCanonicalDigestSHA256: String?,
        request: FeedbackReportEnvelopeV1
    ) -> Self {
        guard let existingKey else { return .acceptNew }
        guard existingKey == request.idempotencyKey else { return .acceptNew }
        guard existingInstallationID == request.installationID else {
            return .rejectCrossInstallationReplay
        }
        guard existingCanonicalDigestSHA256 == request.canonicalDigestSHA256 else {
            return .rejectKeyReuse
        }
        return .returnExistingReceipt
    }
}
