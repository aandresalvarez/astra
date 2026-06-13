import Foundation

enum WorkspaceAppStudioDraftSupport {
    static let titlePrefix = "Design Workspace App:"
    static let contextInputPrefix = "Workspace App Studio context:"

    struct ConversationMetadata: Equatable {
        var title: String
        var goal: String
    }

    static func isWorkspaceAppStudioDraft(_ task: AgentTask?) -> Bool {
        guard let task,
              task.status == .draft,
              task.title.hasPrefix(titlePrefix),
              task.goal.localizedCaseInsensitiveContains("Workspace App Studio"),
              task.inputs.contains(where: { $0.contains(contextInputPrefix) }) else {
            return false
        }
        return true
    }

    static func conversationContext(for task: AgentTask?) -> String? {
        guard isWorkspaceAppStudioDraft(task), let task else { return nil }

        let inputs = task.inputs.joined(separator: "\n\n")
        let constraints = bulletSection(title: "Constraints", values: task.constraints)
        let acceptance = bulletSection(title: "Acceptance criteria", values: task.acceptanceCriteria)

        return [
            """
            Workspace App Studio draft:
            \(task.goal)
            """,
            """
            Attached generation context:
            \(inputs)
            """,
            """
            Available ASTRA action after the design is ready:
            Use Build App to create the implementation task from this App Studio design. Do not tell the user to click Create Task.
            """,
            constraints,
            acceptance
        ]
        .compactMap { section in
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: "\n\n")
    }

    static func inputsAfterConversationUpdate(task: AgentTask, attachedFiles: [String]) -> [String] {
        guard isWorkspaceAppStudioDraft(task) else {
            return attachedFiles
        }

        var merged = task.inputs
        for file in attachedFiles where !merged.contains(file) {
            merged.append(file)
        }
        return merged
    }

    static func metadataAfterConversationUpdate(task: AgentTask, firstMessage: String?) -> ConversationMetadata {
        guard !isWorkspaceAppStudioDraft(task) else {
            return ConversationMetadata(title: task.title, goal: task.goal)
        }
        let message = firstMessage ?? "Draft"
        return ConversationMetadata(
            title: String(message.prefix(60)),
            goal: firstMessage ?? task.goal
        )
    }

    static func workspaceName(for task: AgentTask?) -> String {
        guard let task else { return "Workspace" }
        let titleName = task.title
            .replacingOccurrences(of: titlePrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleName.isEmpty {
            return titleName
        }
        let workspaceName = task.workspace?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return workspaceName.isEmpty ? "Workspace" : workspaceName
    }

    static func defaultPlanningPrompt(for task: AgentTask?) -> String {
        "Draft the app plan for \(workspaceName(for: task)) from the attached Workspace App Studio context."
    }

    static func shouldShowBuildAction(
        task: AgentTask?,
        hasConversation: Bool,
        hasPendingPlan: Bool,
        hasApprovedPlan: Bool,
        showSpecCard: Bool
    ) -> Bool {
        isWorkspaceAppStudioDraft(task)
            && hasConversation
            && !hasPendingPlan
            && !hasApprovedPlan
            && !showSpecCard
    }

    private static func bulletSection(title: String, values: [String]) -> String {
        let bullets = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "- \($0)" }
            .joined(separator: "\n")
        guard !bullets.isEmpty else { return "" }
        return "\(title):\n\(bullets)"
    }
}
