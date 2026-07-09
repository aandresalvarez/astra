import Foundation

public struct FeedbackAssessmentValueV1: RawRepresentable, Codable, Equatable, Hashable, Sendable {
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

public struct FeedbackAssessmentEvidenceV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public var evidenceID: String
    public var summary: String

    public init(evidenceID: String, summary: String) {
        self.evidenceID = evidenceID
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case evidenceID
        case summary
    }

    public func validate() throws {
        try FeedbackContractValidationV1.required(
            evidenceID,
            path: "assessment.evidence[].evidenceID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            summary,
            path: "assessment.evidence[].summary",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
    }
}

public struct FeedbackAssessmentV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var reportID: FeedbackReportIDV1
    public var revisionID: String
    public var classification: FeedbackAssessmentValueV1
    public var impact: FeedbackAssessmentValueV1
    public var behavioralOwner: String
    public var evidence: [FeedbackAssessmentEvidenceV1]
    public var counterevidence: [FeedbackAssessmentEvidenceV1]
    public var rootCauseHypothesis: String?
    public var reproductionConfidence: FeedbackAssessmentValueV1
    public var duplicateCandidateReceiptIDs: [String]
    public var missingQuestions: [String]
    public var regressionTestProposal: String
    public var acceptanceCriteria: [String]
    public var sourceRevision: String
    public var currentMainRevision: String

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        reportID: FeedbackReportIDV1,
        revisionID: String,
        classification: FeedbackAssessmentValueV1,
        impact: FeedbackAssessmentValueV1,
        behavioralOwner: String,
        evidence: [FeedbackAssessmentEvidenceV1],
        counterevidence: [FeedbackAssessmentEvidenceV1],
        rootCauseHypothesis: String? = nil,
        reproductionConfidence: FeedbackAssessmentValueV1,
        duplicateCandidateReceiptIDs: [String] = [],
        missingQuestions: [String] = [],
        regressionTestProposal: String,
        acceptanceCriteria: [String],
        sourceRevision: String,
        currentMainRevision: String
    ) {
        self.formatVersion = formatVersion
        self.reportID = reportID
        self.revisionID = revisionID
        self.classification = classification
        self.impact = impact
        self.behavioralOwner = behavioralOwner
        self.evidence = evidence
        self.counterevidence = counterevidence
        self.rootCauseHypothesis = rootCauseHypothesis
        self.reproductionConfidence = reproductionConfidence
        self.duplicateCandidateReceiptIDs = duplicateCandidateReceiptIDs
        self.missingQuestions = missingQuestions
        self.regressionTestProposal = regressionTestProposal
        self.acceptanceCriteria = acceptanceCriteria
        self.sourceRevision = sourceRevision
        self.currentMainRevision = currentMainRevision
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case reportID
        case revisionID
        case classification
        case impact
        case behavioralOwner
        case evidence
        case counterevidence
        case rootCauseHypothesis
        case reproductionConfidence
        case duplicateCandidateReceiptIDs
        case missingQuestions
        case regressionTestProposal
        case acceptanceCriteria
        case sourceRevision
        case currentMainRevision
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackAssessmentV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try container.decode(FeedbackReportIDV1.self, forKey: .reportID)
        revisionID = try container.decode(String.self, forKey: .revisionID)
        classification = try container.decode(FeedbackAssessmentValueV1.self, forKey: .classification)
        impact = try container.decode(FeedbackAssessmentValueV1.self, forKey: .impact)
        behavioralOwner = try container.decode(String.self, forKey: .behavioralOwner)
        evidence = try container.decode([FeedbackAssessmentEvidenceV1].self, forKey: .evidence)
        counterevidence = try container.decodeIfPresent(
            [FeedbackAssessmentEvidenceV1].self,
            forKey: .counterevidence
        ) ?? []
        rootCauseHypothesis = try container.decodeIfPresent(String.self, forKey: .rootCauseHypothesis)
        reproductionConfidence = try container.decode(
            FeedbackAssessmentValueV1.self,
            forKey: .reproductionConfidence
        )
        duplicateCandidateReceiptIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .duplicateCandidateReceiptIDs
        ) ?? []
        missingQuestions = try container.decodeIfPresent([String].self, forKey: .missingQuestions) ?? []
        regressionTestProposal = try container.decode(String.self, forKey: .regressionTestProposal)
        acceptanceCriteria = try container.decode([String].self, forKey: .acceptanceCriteria)
        sourceRevision = try container.decode(String.self, forKey: .sourceRevision)
        currentMainRevision = try container.decode(String.self, forKey: .currentMainRevision)
        try validate()
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(canonicalized())
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.evidence.sort { $0.evidenceID.utf8.lexicographicallyPrecedes($1.evidenceID.utf8) }
        copy.counterevidence.sort { $0.evidenceID.utf8.lexicographicallyPrecedes($1.evidenceID.utf8) }
        copy.duplicateCandidateReceiptIDs.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return copy
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackAssessmentV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        for (path, value, maximum) in [
            ("revisionID", revisionID, FeedbackContractLimitsV1.identifierLength),
            ("classification", classification.rawValue, FeedbackContractLimitsV1.identifierLength),
            ("impact", impact.rawValue, FeedbackContractLimitsV1.identifierLength),
            ("behavioralOwner", behavioralOwner, FeedbackContractLimitsV1.shortTextLength),
            ("reproductionConfidence", reproductionConfidence.rawValue, FeedbackContractLimitsV1.identifierLength),
            ("regressionTestProposal", regressionTestProposal, FeedbackContractLimitsV1.shortTextLength),
            ("sourceRevision", sourceRevision, FeedbackContractLimitsV1.identifierLength),
            ("currentMainRevision", currentMainRevision, FeedbackContractLimitsV1.identifierLength)
        ] {
            try FeedbackContractValidationV1.required(
                value,
                path: "assessment.\(path)",
                maximum: maximum
            )
        }
        try FeedbackContractValidationV1.optional(
            rootCauseHypothesis,
            path: "assessment.rootCauseHypothesis",
            maximum: FeedbackContractLimitsV1.userStatementLength
        )
        for (path, count) in [
            ("evidence", evidence.count),
            ("counterevidence", counterevidence.count),
            ("duplicateCandidateReceiptIDs", duplicateCandidateReceiptIDs.count),
            ("missingQuestions", missingQuestions.count),
            ("acceptanceCriteria", acceptanceCriteria.count)
        ] {
            try FeedbackContractValidationV1.count(
                count,
                path: "assessment.\(path)",
                maximum: FeedbackContractLimitsV1.maximumAssessmentItems
            )
        }
        guard !evidence.isEmpty else {
            throw FeedbackContractError.missingRequiredField(path: "assessment.evidence")
        }
        guard !acceptanceCriteria.isEmpty else {
            throw FeedbackContractError.missingRequiredField(path: "assessment.acceptanceCriteria")
        }
        for item in evidence + counterevidence { try item.validate() }
        for (path, values) in [
            ("duplicateCandidateReceiptIDs", duplicateCandidateReceiptIDs),
            ("missingQuestions", missingQuestions),
            ("acceptanceCriteria", acceptanceCriteria)
        ] {
            for value in values {
                try FeedbackContractValidationV1.required(
                    value,
                    path: "assessment.\(path)[]",
                    maximum: FeedbackContractLimitsV1.shortTextLength
                )
            }
        }
    }
}

public enum FeedbackStaffTriageDecisionValueV1: String, Codable, CaseIterable, Equatable, Sendable {
    case needsInformation = "needs_information"
    case accepted
    case duplicate
    case declined
    case securityPrivate = "security_private"
}

public struct FeedbackStaffTriageDecisionV1: Codable, Equatable, Sendable, FeedbackContractValidatableV1 {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var reportID: FeedbackReportIDV1
    public var assessmentRevisionID: String?
    public var decision: FeedbackStaffTriageDecisionValueV1
    public var reviewerID: String
    public var decidedAt: Date
    public var reason: String
    public var priorityOverride: FeedbackAssessmentValueV1?
    public var draftTaskRequested: Bool

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        reportID: FeedbackReportIDV1,
        assessmentRevisionID: String? = nil,
        decision: FeedbackStaffTriageDecisionValueV1,
        reviewerID: String,
        decidedAt: Date,
        reason: String,
        priorityOverride: FeedbackAssessmentValueV1? = nil,
        draftTaskRequested: Bool = false
    ) {
        self.formatVersion = formatVersion
        self.reportID = reportID
        self.assessmentRevisionID = assessmentRevisionID
        self.decision = decision
        self.reviewerID = reviewerID
        self.decidedAt = decidedAt
        self.reason = reason
        self.priorityOverride = priorityOverride
        self.draftTaskRequested = draftTaskRequested
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case reportID
        case assessmentRevisionID
        case decision
        case reviewerID
        case decidedAt
        case reason
        case priorityOverride
        case draftTaskRequested
    }

    public init(from decoder: Decoder) throws {
        let versionContainer = try decoder.container(keyedBy: FeedbackFormatVersionCodingKey.self)
        formatVersion = try FeedbackContractValidationV1.version(
            in: versionContainer,
            document: "FeedbackStaffTriageDecisionV1",
            supported: Self.supportedFormatVersion
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try container.decode(FeedbackReportIDV1.self, forKey: .reportID)
        assessmentRevisionID = try container.decodeIfPresent(String.self, forKey: .assessmentRevisionID)
        decision = try container.decode(FeedbackStaffTriageDecisionValueV1.self, forKey: .decision)
        reviewerID = try container.decode(String.self, forKey: .reviewerID)
        decidedAt = try container.decode(Date.self, forKey: .decidedAt)
        reason = try container.decode(String.self, forKey: .reason)
        priorityOverride = try container.decodeIfPresent(
            FeedbackAssessmentValueV1.self,
            forKey: .priorityOverride
        )
        draftTaskRequested = try container.decode(Bool.self, forKey: .draftTaskRequested)
        try validate()
    }

    public func canonicalData() throws -> Data {
        try FeedbackCanonicalJSONV1.encodeValidated(self)
    }

    public func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw FeedbackContractError.unsupportedVersion(
                document: "FeedbackStaffTriageDecisionV1",
                actual: formatVersion,
                supported: Self.supportedFormatVersion
            )
        }
        try FeedbackContractValidationV1.optional(
            assessmentRevisionID,
            path: "staffTriage.assessmentRevisionID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            reviewerID,
            path: "staffTriage.reviewerID",
            maximum: FeedbackContractLimitsV1.identifierLength
        )
        try FeedbackContractValidationV1.required(
            reason,
            path: "staffTriage.reason",
            maximum: FeedbackContractLimitsV1.shortTextLength
        )
        if let priorityOverride {
            try FeedbackContractValidationV1.required(
                priorityOverride.rawValue,
                path: "staffTriage.priorityOverride",
                maximum: FeedbackContractLimitsV1.identifierLength
            )
        }
        if draftTaskRequested, decision != .accepted {
            throw FeedbackContractError.inconsistentValue(
                path: "staffTriage.draftTaskRequested",
                description: "only an accepted human decision may request a draft task"
            )
        }
    }
}
