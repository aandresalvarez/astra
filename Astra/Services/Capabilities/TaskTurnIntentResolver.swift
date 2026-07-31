import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskTurnIntentResolver {
    private static let maxTurnCharacters = 4_000
    private static let maxObjectiveCharacters = 1_000

    @MainActor
    static func capture(
        for task: AgentTask,
        sourceEventID: UUID?,
        acceptedTurn: String?,
        includeTaskInputs: Bool
    ) -> TaskTurnIntentSnapshot {
        let currentTurn = bounded(
            firstNonEmpty(acceptedTurn, task.goal),
            limit: maxTurnCharacters
        )
        let referential = isReferentialTurn(currentTurn)
        let inheritedTurn = referential
            ? latestPriorUserTurn(for: task, excluding: sourceEventID)
                .map { bounded($0, limit: maxTurnCharacters) }
            : nil
        let activeObjective = bounded(
            TaskContextStateManager.activeObjectiveText(for: task),
            limit: maxObjectiveCharacters
        )

        return TaskTurnIntentSnapshot(
            taskID: task.id,
            sourceEventID: sourceEventID,
            acceptedTurn: currentTurn,
            inheritedTurn: inheritedTurn,
            activeObjective: activeObjective.isEmpty ? nil : activeObjective,
            attachmentPaths: includeTaskInputs ? unique(task.inputs) : [],
            pinnedSkillIDs: unique(task.skills.map(\.id)),
            isReferential: referential
        )
    }

    static func preview(
        for task: AgentTask,
        acceptedTurn: String
    ) -> TaskTurnIntentSnapshot {
        let currentTurn = bounded(acceptedTurn, limit: maxTurnCharacters)
        let referential = isReferentialTurn(currentTurn)
        let inheritedTurn = referential
            ? latestPriorUserTurn(for: task, excluding: nil)
                .map { bounded($0, limit: maxTurnCharacters) }
            : nil
        let activeObjective = bounded(
            TaskContextStateManager.activeObjectiveText(for: task),
            limit: maxObjectiveCharacters
        )
        return TaskTurnIntentSnapshot(
            taskID: task.id,
            sourceEventID: nil,
            acceptedTurn: currentTurn,
            inheritedTurn: inheritedTurn,
            activeObjective: activeObjective.isEmpty ? nil : activeObjective,
            attachmentPaths: [],
            pinnedSkillIDs: unique(task.skills.map(\.id)),
            isReferential: referential
        )
    }

    private static func latestPriorUserTurn(
        for task: AgentTask,
        excluding sourceEventID: UUID?
    ) -> String? {
        let hiddenEventIDs = TaskPendingTurnMessageVisibility.pendingMessageEventIDs(for: task)
        return task.events
            .filter {
                $0.id != sourceEventID
                    && !hiddenEventIDs.contains($0.id)
                    && ($0.type == TaskEventTypes.Conversation.userMessage.rawValue
                        || $0.type == TaskPlanConversationEventTypes.userMessage)
            }
            .sorted { $0.timestamp > $1.timestamp }
            .lazy
            .map(\.payload)
            .first { payload in
                let text = bounded(payload, limit: maxTurnCharacters)
                return !text.isEmpty
                    && !TaskContextStateManager.isGeneratedResumeInstruction(text)
                    && !isLowSignalAcknowledgement(text)
            }
    }

    private static func isReferentialTurn(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 180 else { return false }

        let exactPhrases: Set<String> = [
            "try again",
            "retry",
            "continue",
            "keep going",
            "go ahead",
            "please go ahead",
            "proceed",
            "please proceed",
            "do it",
            "do that",
            "please do it",
            "please do that"
        ]
        if exactPhrases.contains(normalized) {
            return true
        }

        let tokens = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let lowSignalTokens: Set<String> = [
            "again", "continue", "retry", "proceed", "please", "now",
            "it", "that", "this", "same", "ahead", "go", "do", "finish",
            "keep", "going", "working", "on", "with", "from", "where",
            "you", "left", "off", "the", "thing", "merge", "and"
        ]
        return !tokens.isEmpty && tokens.count <= 8 && tokens.allSatisfy(lowSignalTokens.contains)
    }

    private static func isLowSignalAcknowledgement(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        let filler: Set<String> = [
            "ok", "okay", "k", "thanks", "thank", "you", "ty", "sure",
            "great", "perfect", "nice", "cool", "done", "lgtm", "sounds", "good"
        ]
        return tokens.allSatisfy(filler.contains)
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit))
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}
