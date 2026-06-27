import Foundation

enum ClaudeVisibleToolProjection {
    static func visibleProviderTools(
        from nativeAllowedTools: [String],
        task: AgentTask,
        permissionPolicy: PermissionPolicy
    ) -> [String] {
        guard permissionPolicy != .autonomous else { return [] }

        var visible = Set<String>()
        for tool in nativeAllowedTools {
            if let normalized = visibleProviderToolName(for: tool) {
                visible.insert(normalized)
            }
        }

        if task.useAgentTeam {
            visible.formUnion([
                "Task",
                "TeamCreate",
                "TeamDelete",
                "TaskCreate",
                "TaskGet",
                "TaskList",
                "TaskOutput",
                "TaskStop",
                "TaskUpdate"
            ])
        }

        return visible.sorted()
    }

    private static func visibleProviderToolName(for rawTool: String) -> String? {
        let trimmed = rawTool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let baseName = trimmed
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? trimmed
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "bash", "shell":
            return "Bash"
        case "edit":
            return "Edit"
        case "glob":
            return "Glob"
        case "grep":
            return "Grep"
        case "multiedit":
            return "MultiEdit"
        case "notebookedit":
            return "NotebookEdit"
        case "read":
            return "Read"
        case "webfetch":
            return "WebFetch"
        case "websearch":
            return "WebSearch"
        case "write":
            return "Write"
        default:
            if normalized.hasPrefix("mcp__") {
                return baseName
            }
            return nil
        }
    }
}
