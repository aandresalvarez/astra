import Foundation

enum SearchPanelOverlayResults {
    static func recentTasks(_ tasks: [AgentTask], workspaces: [Workspace]) -> [AgentTask] {
        PerformanceTelemetry.measure(
            "search_panel_recent_tasks",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: fields(query: nil, tasks: tasks, workspaces: workspaces),
            resultFields: resultFields
        ) {
            Array(tasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(9))
        }
    }

    static func filteredTasks(searchText: String, tasks: [AgentTask], workspaces: [Workspace]) -> [AgentTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return recentTasks(tasks, workspaces: workspaces)
        }
        return PerformanceTelemetry.measure(
            "search_panel_filter_tasks",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: fields(query: query, tasks: tasks, workspaces: workspaces),
            resultFields: resultFields
        ) {
            tasks.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                    $0.goal.localizedCaseInsensitiveContains(query) ||
                    ($0.workspace?.name.localizedCaseInsensitiveContains(query) ?? false) ||
                    ($0.workspace?.primaryPath.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(12)
            .map { $0 }
        }
    }

    static func filteredWorkspaces(searchText: String, workspaces: [Workspace], taskCount: Int) -> [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return PerformanceTelemetry.measure(
            "search_panel_filter_workspaces",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: fields(query: query, taskCount: taskCount, workspaceCount: workspaces.count),
            resultFields: workspaceResultFields
        ) {
            workspaces.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.primaryPath.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private static func fields(query: String?, tasks: [AgentTask], workspaces: [Workspace]) -> [String: String] {
        fields(query: query, taskCount: tasks.count, workspaceCount: workspaces.count)
    }

    private static func fields(query: String?, taskCount: Int, workspaceCount: Int) -> [String: String] {
        var fields = [
            "task_count": PerformanceTelemetryFields.count(taskCount),
            "workspace_count": PerformanceTelemetryFields.count(workspaceCount)
        ]
        if let query {
            fields["query_length"] = PerformanceTelemetryFields.count(query.count)
        }
        return fields
    }

    private static func resultFields(_ tasks: [AgentTask]) -> [String: String] {
        ["result_count": PerformanceTelemetryFields.count(tasks.count)]
    }

    private static func workspaceResultFields(_ workspaces: [Workspace]) -> [String: String] {
        ["result_count": PerformanceTelemetryFields.count(workspaces.count)]
    }
}
