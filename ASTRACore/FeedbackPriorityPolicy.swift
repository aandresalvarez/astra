import Foundation

public enum FeedbackPriority: String, CaseIterable, Codable, Equatable, Comparable, Sendable {
    case p0
    case p1
    case p2
    case p3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ value: Self) -> Int {
        switch value {
        case .p0: 0
        case .p1: 1
        case .p2: 2
        case .p3: 3
        }
    }
}

public enum FeedbackPriorityReason: String, Codable, Equatable, Sendable {
    case securityClassification = "security_classification"
    case dataLossClassification = "data_loss_classification"
    case criticalImpact = "critical_impact"
    case reportBlocksWork = "report_blocks_work"
    case blockedImpact = "blocked_impact"
    case degradedImpact = "degraded_impact"
    case minorImpact = "minor_impact"
    case assessmentUnavailable = "assessment_unavailable"
    case conservativeDefault = "conservative_default"
}

public struct FeedbackPriorityOverrideAudit: Codable, Equatable, Sendable {
    public var reportID: FeedbackReportIDV1
    public var assessmentRevisionID: String?
    public var reviewerID: String
    public var decidedAt: Date
    public var reason: String
    public var previousPriority: FeedbackPriority
    public var effectivePriority: FeedbackPriority

    public init(
        reportID: FeedbackReportIDV1,
        assessmentRevisionID: String?,
        reviewerID: String,
        decidedAt: Date,
        reason: String,
        previousPriority: FeedbackPriority,
        effectivePriority: FeedbackPriority
    ) {
        self.reportID = reportID
        self.assessmentRevisionID = assessmentRevisionID
        self.reviewerID = reviewerID
        self.decidedAt = decidedAt
        self.reason = reason
        self.previousPriority = previousPriority
        self.effectivePriority = effectivePriority
    }
}

public struct FeedbackPriorityDecision: Equatable, Sendable {
    public var reportID: FeedbackReportIDV1
    public var basePriority: FeedbackPriority
    public var effectivePriority: FeedbackPriority
    public var reasons: [FeedbackPriorityReason]
    public var assessmentRevisionID: String?
    public var overrideAudit: FeedbackPriorityOverrideAudit?

    public init(
        reportID: FeedbackReportIDV1,
        basePriority: FeedbackPriority,
        effectivePriority: FeedbackPriority,
        reasons: [FeedbackPriorityReason],
        assessmentRevisionID: String?,
        overrideAudit: FeedbackPriorityOverrideAudit? = nil
    ) {
        self.reportID = reportID
        self.basePriority = basePriority
        self.effectivePriority = effectivePriority
        self.reasons = reasons
        self.assessmentRevisionID = assessmentRevisionID
        self.overrideAudit = overrideAudit
    }
}

public enum FeedbackPriorityPolicyError: Error, Equatable, Sendable {
    case reportIDMismatch
    case assessmentRevisionMismatch
    case invalidOverride(String)
}

/// Deterministic priority owner. Assessment contributes validated facts only;
/// model wording and ordering never participate in the decision.
public enum FeedbackPriorityPolicy {
    public static func decide(
        report: FeedbackReportPayloadV1,
        assessment: ValidatedFeedbackAssessment?
    ) throws -> FeedbackPriorityDecision {
        // The sealed value proves initial validation; revalidation here binds
        // that value to the exact report supplied at the policy boundary.
        let assessment = try assessment.map {
            try FeedbackAssessmentValidator.validate(
                $0.assessment,
                for: report,
                trustedContext: $0.trustedContext
            )
        }
        let priorityAndReasons: (FeedbackPriority, [FeedbackPriorityReason])

        if let assessment, assessment.classification == .security {
            priorityAndReasons = (.p0, [.securityClassification])
        } else if let assessment, assessment.classification == .dataLoss {
            priorityAndReasons = (.p0, [.dataLossClassification])
        } else if let assessment, assessment.impact == .critical {
            priorityAndReasons = (.p0, [.criticalImpact])
        } else if report.statement.workBlocked {
            priorityAndReasons = (.p1, [.reportBlocksWork])
        } else if let assessment, assessment.impact == .blocked {
            priorityAndReasons = (.p1, [.blockedImpact])
        } else if let assessment, assessment.impact == .minor {
            priorityAndReasons = (.p3, [.minorImpact])
        } else if let assessment, assessment.impact == .degraded {
            priorityAndReasons = (.p2, [.degradedImpact])
        } else if assessment == nil {
            priorityAndReasons = (.p2, [.assessmentUnavailable])
        } else {
            priorityAndReasons = (.p2, [.conservativeDefault])
        }

        return FeedbackPriorityDecision(
            reportID: report.reportID,
            basePriority: priorityAndReasons.0,
            effectivePriority: priorityAndReasons.0,
            reasons: priorityAndReasons.1,
            assessmentRevisionID: assessment?.assessment.revisionID
        )
    }

    public static func applyingHumanOverride(
        _ triage: FeedbackStaffTriageDecisionV1,
        to decision: FeedbackPriorityDecision
    ) throws -> FeedbackPriorityDecision {
        try triage.validate()
        guard triage.reportID == decision.reportID else {
            throw FeedbackPriorityPolicyError.reportIDMismatch
        }
        guard let rawOverride = triage.priorityOverride?.rawValue else { return decision }
        guard triage.assessmentRevisionID == decision.assessmentRevisionID else {
            throw FeedbackPriorityPolicyError.assessmentRevisionMismatch
        }
        guard let priority = FeedbackPriority(rawValue: rawOverride) else {
            throw FeedbackPriorityPolicyError.invalidOverride(rawOverride)
        }

        var overridden = decision
        overridden.effectivePriority = priority
        overridden.overrideAudit = FeedbackPriorityOverrideAudit(
            reportID: triage.reportID,
            assessmentRevisionID: triage.assessmentRevisionID,
            reviewerID: triage.reviewerID,
            decidedAt: triage.decidedAt,
            reason: triage.reason,
            previousPriority: decision.effectivePriority,
            effectivePriority: priority
        )
        return overridden
    }
}
