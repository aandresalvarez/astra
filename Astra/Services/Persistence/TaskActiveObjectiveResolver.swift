import Foundation
import ASTRAModels
import ASTRACore

extension TaskContextStateManager {
    public struct ActiveObjectiveResolution: Equatable, Sendable {
        public init(objective: String, sourcePointers: [TaskContextState.SourcePointer], supersedesOriginalGoal: Bool, hasExplicitOverride: Bool = false) {
            self.objective = objective
            self.sourcePointers = sourcePointers
            self.supersedesOriginalGoal = supersedesOriginalGoal
            self.hasExplicitOverride = hasExplicitOverride
        }

        public var objective: String
        public var sourcePointers: [TaskContextState.SourcePointer]
        public var supersedesOriginalGoal: Bool
        /// True whenever an explicit objective-override message was found,
        /// regardless of whether its resolved text differs from `task.goal`.
        /// Distinct from `supersedesOriginalGoal`, which is specifically about
        /// whether the resolved text differs -- a user who explicitly says
        /// "no wait, go back to the original goal: <goal text verbatim>" DID
        /// just issue a fresh, authoritative correction, even though the
        /// override's resolved text happens to equal `task.goal` (adversarial
        /// finding: a stale Tier 2 pivot must not survive this because
        /// `supersedesOriginalGoal` alone reads as "nothing changed").
        public var hasExplicitOverride: Bool = false
    }

    public static func activeObjectiveText(for task: AgentTask) -> String {
        let planState = TaskPlanReconstructionSeam.required.reconstruct(for: task)
        let startingRequest = activeFirstNonEmpty(firstConversationRequestValue(for: task), task.goal)
        return activeObjectiveResolution(
            for: task,
            planState: planState,
            startingRequest: startingRequest,
            approvedGoal: nil
        ).objective
    }

    public static func capabilitySearchText(for task: AgentTask, contextText: String) -> String {
        let activeObjective = activeObjectiveText(for: task)
        let taskGoal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActivePivot = !activeObjective.isEmpty
            && !activeCaseInsensitiveEquals(activeObjective, taskGoal)
            && !activeCaseInsensitiveEquals(activeObjective, taskTitle)
        let historicalText = hasActivePivot ? "" : [taskTitle, taskGoal].joined(separator: " ")
        return [
            activeObjective,
            historicalText,
            task.inputs.joined(separator: " "),
            task.constraints.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " "),
            contextText
        ].joined(separator: " ")
    }

    public static func activeObjectiveResolution(
        for task: AgentTask,
        planState: TaskPlanState,
        startingRequest: String,
        approvedGoal: String?
    ) -> ActiveObjectiveResolution {
        if let override = latestObjectiveOverride(for: task) {
            return ActiveObjectiveResolution(
                objective: override.objective,
                sourcePointers: [override.source],
                supersedesOriginalGoal: !activeCaseInsensitiveEquals(override.objective, task.goal),
                hasExplicitOverride: true
            )
        }

        let trimmedPlanGoal = (planState.plan?.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let planGoalReconciled = trimmedPlanGoal.isEmpty
            || [.approved, .executing, .completed].contains(planState.lifecycleStatus)
            || activeCaseInsensitiveEquals(trimmedPlanGoal, task.goal)
        let objective = activeFirstNonEmpty(
            planGoalReconciled ? planState.plan?.goal : nil,
            approvedGoal,
            task.goal,
            startingRequest
        )
        let planSource = planState.plan.map {
            activeSourcePointer(kind: "plan", id: $0.planID.uuidString, summary: "Task plan goal")
        }
        return ActiveObjectiveResolution(
            objective: objective,
            sourcePointers: [planSource].compactMap { $0 },
            supersedesOriginalGoal: false
        )
    }

    public static func objectiveDivergenceNote(
        task: AgentTask,
        planState: TaskPlanState,
        activeObjective: ActiveObjectiveResolution
    ) -> String? {
        if activeObjective.supersedesOriginalGoal {
            return "Later user follow-up supersedes the original task goal for current work; the original request is preserved only as starting context."
        }

        let trimmedPlanGoal = (planState.plan?.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let planGoalReconciled = trimmedPlanGoal.isEmpty
            || [.approved, .executing, .completed].contains(planState.lifecycleStatus)
            || activeCaseInsensitiveEquals(trimmedPlanGoal, task.goal)
        return (!trimmedPlanGoal.isEmpty && !planGoalReconciled)
            ? "Draft plan goal differs from the task goal; using the task goal as the objective until reconciled. Draft plan goal: \(activeBoundedInline(trimmedPlanGoal, maxCharacters: 240))"
            : nil
    }

    public static func firstConversationRequestValue(for task: AgentTask) -> String? {
        firstConversationEventValue(for: task)?
            .payload
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func firstConversationEventValue(for task: AgentTask) -> TaskEvent? {
        task.events
            .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
            .sorted { $0.timestamp < $1.timestamp }
            .first
    }

    /// Whether `text` (typically the CURRENT turn's follow-up message, before
    /// it has been persisted as a `TaskEvent`) would itself be recognized as
    /// an explicit objective-override message -- i.e. the same marker-based
    /// detection `latestObjectiveOverride` applies to persisted events, but
    /// against a live, not-yet-persisted string. `continueSession` builds the
    /// prompt before inserting the new `user.message` event, so a correction
    /// arriving on THIS turn (e.g. "no, go back to the original goal") is
    /// invisible to `task.events`-based checks until the NEXT turn; callers
    /// that need to react to it within the same turn must check this
    /// alongside `hasExplicitOverride` (adversarial finding).
    public static func isExplicitObjectiveOverrideMessage(_ text: String) -> Bool {
        objectiveOverrideCandidate(from: text) != nil
    }

    public static func isGeneratedResumeInstruction(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "continue where you left off. complete the original goal."
            || lower == "continue where you left off. continue the current objective."
            || lower.hasPrefix("continue where you left off. continue the current objective:")
    }
}

private struct ObjectiveOverride: Equatable {
    public var objective: String
    public var source: TaskContextState.SourcePointer
}

private func latestObjectiveOverride(for task: AgentTask) -> ObjectiveOverride? {
    let userMessages = task.events
        .filter { $0.type == "user.message" || $0.type == TaskPlanConversationEventTypes.userMessage }
        .sorted { $0.timestamp < $1.timestamp }
    guard userMessages.count > 1 else { return nil }

    for event in userMessages.dropFirst().reversed() {
        guard let objective = objectiveOverrideCandidate(from: event.payload) else { continue }
        return ObjectiveOverride(
            objective: objective,
            source: activeEventSource(event, summary: "User objective override")
        )
    }
    return nil
}

private func objectiveOverrideCandidate(from payload: String) -> String? {
    let text = activeBoundedInline(payload, maxCharacters: 360)
    guard !text.isEmpty,
          !isLowSignalObjectiveAcknowledgement(text),
          !TaskContextStateManager.isGeneratedResumeInstruction(text) else {
        return nil
    }

    let lower = text.lowercased()
    if lower.contains("original goal") && !lower.contains("plan.md") {
        return nil
    }

    for marker in explicitObjectiveMarkers {
        guard let range = lower.range(of: marker) else { continue }
        let rawCandidate = String(text[range.upperBound...])
        if let cleaned = cleanedObjectiveCandidate(rawCandidate) {
            return cleaned
        }
    }

    if mentionsPlanDocument(lower),
       objectivePlanActionTerms.contains(where: { lower.contains($0) }) {
        return "Complete plan.md."
    }

    return nil
}

private func cleanedObjectiveCandidate(_ text: String) -> String? {
    var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ":;,.!?- "))
    let lower = candidate.lowercased()
    if lower.hasPrefix("to ") {
        candidate = String(candidate.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ":;,.!?- "))
    guard candidate.count >= 3 else { return nil }
    return activeBoundedInline(candidate, maxCharacters: 320)
}

private func mentionsPlanDocument(_ lowercasedText: String) -> Bool {
    lowercasedText.contains("plan.md")
        || lowercasedText.contains("plan document")
        || lowercasedText.contains("plan doc")
}

private func isLowSignalObjectiveAcknowledgement(_ text: String) -> Bool {
    let tokens = text
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return true }
    let fillerWords: Set<String> = [
        "ok", "okay", "k", "kk", "thanks", "thank", "you", "ty",
        "proceed", "continue", "go", "ahead", "do", "it",
        "sure", "great", "perfect", "nice", "cool", "done", "lgtm", "please",
        "now", "then", "sounds", "good", "sg", "ack", "got", "fine"
    ]
    return tokens.allSatisfy { fillerWords.contains($0) }
}

private func activeFirstNonEmpty(_ values: String?...) -> String {
    for value in values {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return ""
}

private func activeCaseInsensitiveEquals(_ lhs: String, _ rhs: String) -> Bool {
    lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
}

private func activeBoundedInline(_ value: String, maxCharacters: Int) -> String {
    let collapsed = value
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > maxCharacters else { return collapsed }
    return String(collapsed.prefix(maxCharacters)) + "..."
}

private func activeSourcePointer(
    kind: String,
    id: String? = nil,
    path: String? = nil,
    summary: String
) -> TaskContextState.SourcePointer {
    TaskContextState.SourcePointer(
        kind: kind,
        id: id,
        path: path,
        summary: activeBoundedInline(summary, maxCharacters: 220)
    )
}

private func activeEventSource(_ event: TaskEvent, summary: String) -> TaskContextState.SourcePointer {
    activeSourcePointer(kind: "event", id: event.id.uuidString, summary: summary)
}

private let explicitObjectiveMarkers: [String] = [
    "your goal is to",
    "your goal is",
    "the goal is to",
    "the goal is",
    "current goal is to",
    "current goal is",
    "new goal is to",
    "new goal is",
    "actual goal is to",
    "actual goal is",
    "real goal is to",
    "real goal is",
    "your objective is to",
    "your objective is",
    "the objective is to",
    "the objective is",
    "current objective is to",
    "current objective is",
    "new objective is to",
    "new objective is"
]

private let objectivePlanActionTerms: [String] = [
    "complete",
    "complet",
    "finish",
    "follow",
    "following",
    "implement",
    "continue",
    "work through",
    "working through"
]
