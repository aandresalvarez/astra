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
    case reportIDMismatch
    case sourceRevisionMismatch(reported: String, assessed: String)
    case invalidGitRevision(field: String, value: String)
    case unsupportedClassification(String)
    case unsupportedImpact(String)
    case unsupportedConfidence(String)
    case duplicateEvidenceID(String)
    case unknownCauseRequiresQuestions
    case unknownCauseCannotClaimRootCause
    case unknownCauseCannotClaimConfidence(String)
}

public struct ValidatedFeedbackAssessment: Equatable, Sendable {
    public var assessment: FeedbackAssessmentV1
    public var classification: FeedbackAssessmentClassificationPolicyValue
    public var impact: FeedbackAssessmentImpactPolicyValue
    public var confidence: FeedbackAssessmentConfidencePolicyValue
    public var sourceDrift: FeedbackSourceRevisionDrift
    public var triageDisposition: FeedbackAssessmentTriageDisposition

    public init(
        assessment: FeedbackAssessmentV1,
        classification: FeedbackAssessmentClassificationPolicyValue,
        impact: FeedbackAssessmentImpactPolicyValue,
        confidence: FeedbackAssessmentConfidencePolicyValue,
        sourceDrift: FeedbackSourceRevisionDrift,
        triageDisposition: FeedbackAssessmentTriageDisposition
    ) {
        self.assessment = assessment
        self.classification = classification
        self.impact = impact
        self.confidence = confidence
        self.sourceDrift = sourceDrift
        self.triageDisposition = triageDisposition
    }
}

/// Semantic adapter over the authoritative V1 wire contract. It accepts bytes
/// and normalized report data only; it has no process, tool, network, secret,
/// repository-write, issue-write, or deployment interface.
public enum FeedbackAssessmentValidator {
    public static func decodeAndValidate(
        _ data: Data,
        for report: FeedbackReportPayloadV1
    ) throws -> ValidatedFeedbackAssessment {
        let assessment = try FeedbackCanonicalJSONV1.decode(FeedbackAssessmentV1.self, from: data)
        return try validate(assessment, for: report)
    }

    public static func validate(
        _ assessment: FeedbackAssessmentV1,
        for report: FeedbackReportPayloadV1
    ) throws -> ValidatedFeedbackAssessment {
        try report.validate()
        try assessment.validate()

        guard assessment.reportID == report.reportID else {
            throw FeedbackAssessmentSemanticValidationError.reportIDMismatch
        }
        guard assessment.sourceRevision == report.build.gitCommit else {
            throw FeedbackAssessmentSemanticValidationError.sourceRevisionMismatch(
                reported: report.build.gitCommit,
                assessed: assessment.sourceRevision
            )
        }
        try validateGitRevision(assessment.sourceRevision, field: "sourceRevision")
        try validateGitRevision(assessment.currentMainRevision, field: "currentMainRevision")

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
            guard evidenceIDs.insert(item.evidenceID).inserted else {
                throw FeedbackAssessmentSemanticValidationError.duplicateEvidenceID(item.evidenceID)
            }
        }

        let hasRootCause = assessment.rootCauseHypothesis?.isEmpty == false
        let needsInformation = classification == .unknown || !hasRootCause
        if needsInformation {
            guard !assessment.missingQuestions.isEmpty else {
                throw FeedbackAssessmentSemanticValidationError.unknownCauseRequiresQuestions
            }
            if classification == .unknown, hasRootCause {
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
            sourceDrift: assessment.sourceRevision == assessment.currentMainRevision
                ? .sameRevision
                : .currentMainDiffers,
            triageDisposition: needsInformation ? .needsInformation : .assessed
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
        for report: FeedbackReportPayloadV1
    ) -> Self {
        do {
            return .validated(try FeedbackAssessmentValidator.decodeAndValidate(output, for: report))
        } catch {
            return .failed(.malformedOrInvalidOutput)
        }
    }
}
