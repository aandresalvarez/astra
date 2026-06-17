import Foundation

enum SidebarTaskIndexInvalidation {
    static func signature(for tasks: [AgentTask], searchText: String = "") -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        let includesSearchableText = !searchText.isEmpty
        var workspaceIDs = Set<UUID>()
        let signature = tasks.reduce(into: 0) { acc, task in
            acc ^= task.id.hashValue
            if let workspaceID = task.workspace?.id {
                workspaceIDs.insert(workspaceID)
                acc ^= workspaceID.hashValue
            }
            if includesSearchableText {
                acc ^= task.title.hashValue
                acc ^= task.goal.hashValue
            }
            acc ^= task.status.rawValue.hashValue
            acc ^= task.isPinned ? 1 : 0
            acc ^= task.isDone ? 2 : 0
            acc ^= task.shouldShowUnread ? 4 : 0
            acc &+= Int(task.updatedAt.timeIntervalSince1970)
            acc &+= Int(task.unreadAt?.timeIntervalSince1970 ?? 0)
        }
        PerformanceTelemetry.logIfNeeded(
            "sidebar_index_signature",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_count": PerformanceTelemetryFields.count(tasks.count),
                "workspace_count": PerformanceTelemetryFields.count(workspaceIDs.count),
                "search_active": PerformanceTelemetryFields.bool(includesSearchableText)
            ]
        )
        return signature
    }
}
