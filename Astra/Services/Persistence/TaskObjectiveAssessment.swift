import Foundation
import ASTRACore

extension TaskContextState {
    /// Result of a Tier 2 (model-backed) re-assessment of whether the task's
    /// active objective is still the right one to keep working toward.
    ///
    /// This is produced asynchronously/in the background (never on the
    /// refresh/promptContext path) and is purely advisory: consumers must
    /// fail safe to `original_active` on any uncertainty, timeout, or parse
    /// failure, and the original goal is never deleted when a verdict of
    /// `superseded` is recorded -- only demoted to background framing.
    public struct ObjectiveAssessment: Codable, Sendable, Equatable {
        public init(verdict: String, currentObjective: String? = nil, assessedAtTurn: Int, inputHash: String) {
            self.verdict = verdict
            self.currentObjective = currentObjective
            self.assessedAtTurn = assessedAtTurn
            self.inputHash = inputHash
        }

        /// One of "original_active", "original_satisfied", "superseded".
        public var verdict: String
        /// Only populated when `verdict == "superseded"`.
        public var currentObjective: String?
        public var assessedAtTurn: Int
        public var inputHash: String
    }
}

extension TaskContextStateManager {
    public static func appendObjectiveAssessment(
        _ assessment: TaskContextState.ObjectiveAssessment?,
        to lines: inout [String]
    ) {
        guard let assessment else { return }
        lines.append("- Objective assessment: \(assessment.verdict) (turn \(assessment.assessedAtTurn))")
        if let currentObjective = assessment.currentObjective, !currentObjective.isEmpty {
            lines.append("  - Current objective: \(objectiveAssessmentBoundedInline(currentObjective, maxCharacters: 320))")
        }
    }

    public static func appendMarkdownObjectiveAssessment(
        _ assessment: TaskContextState.ObjectiveAssessment?,
        to parts: inout [String]
    ) {
        guard let assessment else { return }
        parts.append("")
        parts.append("## Objective Assessment")
        parts.append("- Verdict: \(assessment.verdict)")
        parts.append("- Assessed at turn: \(assessment.assessedAtTurn)")
        if let currentObjective = assessment.currentObjective, !currentObjective.isEmpty {
            parts.append("- Current objective: \(currentObjective)")
        }
    }
}

private func objectiveAssessmentBoundedInline(_ value: String, maxCharacters: Int) -> String {
    let collapsed = value
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > maxCharacters else { return collapsed }
    return String(collapsed.prefix(maxCharacters)) + "..."
}
