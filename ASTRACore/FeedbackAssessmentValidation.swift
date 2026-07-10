import Foundation

public enum FeedbackAssessmentClassificationPolicyValue: String, CaseIterable, Sendable {
    case functionalDefect = "functional_defect"
    case runtimeFailure = "runtime_failure"
    case crash
    case performance
    case usability
    case security
    case dataLoss = "data_loss"
    case unknown
}

public enum FeedbackAssessmentImpactPolicyValue: String, CaseIterable, Sendable {
    case critical
    case blocked
    case degraded
    case minor
    case unknown
}

public enum FeedbackAssessmentConfidencePolicyValue: String, CaseIterable, Sendable {
    case high
    case medium
    case low
    case unknown
}

public enum FeedbackSourceRevisionDrift: String, Equatable, Sendable {
    case sameRevision = "same_revision"
    case currentMainDiffers = "current_main_differs"
}

public enum FeedbackAssessmentTriageDisposition: String, Equatable, Sendable {
    case assessed
    case needsInformation = "needs_information"
}

public enum FeedbackAssessmentSemanticValidationError: Error, Equatable, Sendable {
    case trustedContextReportIDMismatch
    case trustedContextSourceRevisionMismatch(reported: String, trusted: String)
    case reportIDMismatch
    case assessmentRevisionMismatch(expected: String, assessed: String)
    case sourceRevisionMismatch(reported: String, assessed: String)
    case currentMainRevisionMismatch(trusted: String, assessed: String)
    case invalidGitRevision(field: String, value: String)
    case invalidTrustedEvidenceID(String)
    case untrustedEvidenceID(String)
    case unsupportedClassification(String)
    case unsupportedImpact(String)
    case unsupportedConfidence(String)
    case duplicateEvidenceID(String)
    case unknownCauseRequiresQuestions
    case missingRootCauseRequiresQuestions
    case unknownCauseCannotClaimRootCause
    case unknownCauseCannotClaimConfidence(String)
}

/// Coordinator-issued provenance that is never sourced from analyzer output.
/// The coordinator obtains revision and citation identities before invoking a
/// read-only analyzer and passes the same immutable context to validation.
public struct FeedbackAssessmentTrustedContext: Equatable, Sendable {
    public let reportID: FeedbackReportIDV1
    public let assessmentRevisionID: String
    public let sourceRevision: String
    public let currentMainRevision: String
    public let allowedEvidenceIDs: Set<String>

    public init(
        reportID: FeedbackReportIDV1,
        assessmentRevisionID: String,
        sourceRevision: String,
        currentMainRevision: String,
        allowedEvidenceIDs: Set<String>
    ) {
        self.reportID = reportID
        self.assessmentRevisionID = assessmentRevisionID
        self.sourceRevision = sourceRevision
        self.currentMainRevision = currentMainRevision
        self.allowedEvidenceIDs = allowedEvidenceIDs
    }
}

public struct ValidatedFeedbackAssessment: Equatable, Sendable {
    public let assessment: FeedbackAssessmentV1
    public let classification: FeedbackAssessmentClassificationPolicyValue
    public let impact: FeedbackAssessmentImpactPolicyValue
    public let confidence: FeedbackAssessmentConfidencePolicyValue
    public let sourceDrift: FeedbackSourceRevisionDrift
    public let triageDisposition: FeedbackAssessmentTriageDisposition
    let trustedContext: FeedbackAssessmentTrustedContext

    fileprivate init(
        assessment: FeedbackAssessmentV1,
        classification: FeedbackAssessmentClassificationPolicyValue,
        impact: FeedbackAssessmentImpactPolicyValue,
        confidence: FeedbackAssessmentConfidencePolicyValue,
        sourceDrift: FeedbackSourceRevisionDrift,
        triageDisposition: FeedbackAssessmentTriageDisposition,
        trustedContext: FeedbackAssessmentTrustedContext
    ) {
        self.assessment = assessment
        self.classification = classification
        self.impact = impact
        self.confidence = confidence
        self.sourceDrift = sourceDrift
        self.triageDisposition = triageDisposition
        self.trustedContext = trustedContext
    }
}

/// Semantic adapter over the authoritative V1 wire contract. It accepts bytes
/// and normalized report data only; it has no process, tool, network, secret,
/// repository-write, issue-write, or deployment interface.
public enum FeedbackAssessmentValidator {
    public static func decodeAndValidate(
        _ data: Data,
        for report: FeedbackReportPayloadV1,
        trustedContext: FeedbackAssessmentTrustedContext
    ) throws -> ValidatedFeedbackAssessment {
        let assessment = try FeedbackCanonicalJSONV1.decode(FeedbackAssessmentV1.self, from: data)
        return try validate(assessment, for: report, trustedContext: trustedContext)
    }

    public static func validate(
        _ assessment: FeedbackAssessmentV1,
        for report: FeedbackReportPayloadV1,
        trustedContext: FeedbackAssessmentTrustedContext
    ) throws -> ValidatedFeedbackAssessment {
        try report.validate()
        try assessment.validate()

        guard trustedContext.reportID == report.reportID else {
            throw FeedbackAssessmentSemanticValidationError.trustedContextReportIDMismatch
        }
        guard trustedContext.sourceRevision == report.build.gitCommit else {
            throw FeedbackAssessmentSemanticValidationError.trustedContextSourceRevisionMismatch(
                reported: report.build.gitCommit,
                trusted: trustedContext.sourceRevision
            )
        }
        try validateGitRevision(trustedContext.sourceRevision, field: "trustedContext.sourceRevision")
        try validateGitRevision(
            trustedContext.currentMainRevision,
            field: "trustedContext.currentMainRevision"
        )
        for evidenceID in trustedContext.allowedEvidenceIDs {
            do {
                try FeedbackContractValidationV1.required(
                    evidenceID,
                    path: "trustedContext.allowedEvidenceIDs[]",
                    maximum: FeedbackContractLimitsV1.identifierLength
                )
            } catch {
                throw FeedbackAssessmentSemanticValidationError.invalidTrustedEvidenceID(evidenceID)
            }
        }

        guard assessment.reportID == trustedContext.reportID else {
            throw FeedbackAssessmentSemanticValidationError.reportIDMismatch
        }
        guard assessment.revisionID == trustedContext.assessmentRevisionID else {
            throw FeedbackAssessmentSemanticValidationError.assessmentRevisionMismatch(
                expected: trustedContext.assessmentRevisionID,
                assessed: assessment.revisionID
            )
        }
        guard assessment.sourceRevision == trustedContext.sourceRevision else {
            throw FeedbackAssessmentSemanticValidationError.sourceRevisionMismatch(
                reported: trustedContext.sourceRevision,
                assessed: assessment.sourceRevision
            )
        }
        guard assessment.currentMainRevision == trustedContext.currentMainRevision else {
            throw FeedbackAssessmentSemanticValidationError.currentMainRevisionMismatch(
                trusted: trustedContext.currentMainRevision,
                assessed: assessment.currentMainRevision
            )
        }

        guard let classification = FeedbackAssessmentClassificationPolicyValue(
            rawValue: assessment.classification.rawValue
        ) else {
            throw FeedbackAssessmentSemanticValidationError.unsupportedClassification(
                assessment.classification.rawValue
            )
        }
        guard let impact = FeedbackAssessmentImpactPolicyValue(rawValue: assessment.impact.rawValue) else {
            throw FeedbackAssessmentSemanticValidationError.unsupportedImpact(assessment.impact.rawValue)
        }
        guard let confidence = FeedbackAssessmentConfidencePolicyValue(
            rawValue: assessment.reproductionConfidence.rawValue
        ) else {
            throw FeedbackAssessmentSemanticValidationError.unsupportedConfidence(
                assessment.reproductionConfidence.rawValue
            )
        }

        var evidenceIDs = Set<String>()
        for item in assessment.evidence + assessment.counterevidence {
            guard trustedContext.allowedEvidenceIDs.contains(item.evidenceID) else {
                throw FeedbackAssessmentSemanticValidationError.untrustedEvidenceID(item.evidenceID)
            }
            guard evidenceIDs.insert(item.evidenceID).inserted else {
                throw FeedbackAssessmentSemanticValidationError.duplicateEvidenceID(item.evidenceID)
            }
        }

        let hasRootCause = assessment.rootCauseHypothesis?.isEmpty == false
        let isUnknownClassification = classification == .unknown
        let needsInformation = isUnknownClassification || !hasRootCause
        if needsInformation {
            guard !assessment.missingQuestions.isEmpty else {
                throw isUnknownClassification
                    ? FeedbackAssessmentSemanticValidationError.unknownCauseRequiresQuestions
                    : FeedbackAssessmentSemanticValidationError.missingRootCauseRequiresQuestions
            }
            if isUnknownClassification, hasRootCause {
                throw FeedbackAssessmentSemanticValidationError.unknownCauseCannotClaimRootCause
            }
            guard confidence == .low || confidence == .unknown else {
                throw FeedbackAssessmentSemanticValidationError.unknownCauseCannotClaimConfidence(
                    confidence.rawValue
                )
            }
        }

        return ValidatedFeedbackAssessment(
            assessment: assessment.canonicalized(),
            classification: classification,
            impact: impact,
            confidence: confidence,
            sourceDrift: trustedContext.sourceRevision == trustedContext.currentMainRevision
                ? .sameRevision
                : .currentMainDiffers,
            triageDisposition: needsInformation ? .needsInformation : .assessed,
            trustedContext: trustedContext
        )
    }

    private static func validateGitRevision(_ value: String, field: String) throws {
        let valid = (7...64).contains(value.count) && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 97 && scalar.value <= 102)
        }
        guard valid else {
            throw FeedbackAssessmentSemanticValidationError.invalidGitRevision(
                field: field,
                value: value
            )
        }
    }
}

public enum FeedbackAssessmentFailure: Equatable, Sendable {
    case analyzerUnavailable
    case malformedOrInvalidOutput
}

public enum FeedbackAssessmentProcessingState: Equatable, Sendable {
    case pending
    case validated(ValidatedFeedbackAssessment)
    case failed(FeedbackAssessmentFailure)

    /// Assessment is advisory. No state here can block report acceptance or
    /// authenticated human triage.
    public var allowsHumanTriage: Bool { true }

    public static func resolve(
        output: Data,
        for report: FeedbackReportPayloadV1,
        trustedContext: FeedbackAssessmentTrustedContext
    ) -> Self {
        do {
            return .validated(try FeedbackAssessmentValidator.decodeAndValidate(
                output,
                for: report,
                trustedContext: trustedContext
            ))
        } catch {
            return .failed(.malformedOrInvalidOutput)
        }
    }
}
