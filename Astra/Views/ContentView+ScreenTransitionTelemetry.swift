import Foundation
import SwiftData
import ASTRAModels

/// Keeps transition measurement attribution at the ContentView boundary where
/// the final destination and incoming task identity are known.
extension ContentView {
    static let contextRailDestination = "context_rail"

    func beginScreenTransitionIfNeeded(
        to item: WorkspaceCanvasItem?,
        source: String,
        baseDestination: String? = nil,
        taskID: UUID? = nil,
        usesSelectedTask: Bool = true
    ) {
        guard activeWorkspaceCanvasItem != item else { return }
        beginScreenTransition(
            destination: screenTransitionDestination(item, baseDestination: baseDestination),
            source: source,
            taskID: taskID,
            usesSelectedTask: usesSelectedTask,
            nextPanel: item.map { "shelf_\($0.rawValue)" }
        )
    }

    /// The context rail opens and closes through the same lifecycle as the
    /// shelves, so one event (`screen_transition_to_view_ready`) measures every
    /// right-side panel with the same fields.
    func beginRightRailTransition(isPresenting: Bool, source: String) {
        guard isPresenting != (activeWorkspaceCanvasItem == nil && isWorkspaceRightRailVisible) else { return }
        beginScreenTransition(
            destination: isPresenting ? Self.contextRailDestination : screenTransitionDestination(nil),
            source: source,
            nextPanel: isPresenting ? Self.contextRailDestination : nil
        )
    }

    /// The right-side panel on screen now: a shelf, the context rail, or none.
    var currentRightPanelName: String? {
        if let activeWorkspaceCanvasItem { return "shelf_\(activeWorkspaceCanvasItem.rawValue)" }
        return isWorkspaceRightRailVisible && effectiveWorkspace != nil ? Self.contextRailDestination : nil
    }

    func beginScreenTransition(
        destination: String,
        source: String,
        taskID: UUID? = nil,
        usesSelectedTask: Bool = true,
        nextPanel: String? = nil
    ) {
        if destination == "shelf_markdown" {
            let workspace = selectedTask?.workspace ?? effectiveWorkspace
            FilesShelfResponsivenessTelemetry.begin(
                source: source,
                taskID: usesSelectedTask ? selectedTask?.id : taskID,
                workspaceID: workspace?.id,
                scope: taskOpenResponsivenessScope
            )
        } else {
            FilesShelfResponsivenessTelemetry.cancel(
                scope: taskOpenResponsivenessScope,
                reason: "destination_changed"
            )
        }
        let affectedTask = usesSelectedTask ? selectedTask : nil
        screenTransitionCoordinator.begin(
            destination: destination,
            source: source,
            taskID: usesSelectedTask ? selectedTask?.id : taskID,
            context: screenTransitionContext(nextPanel: nextPanel, task: affectedTask)
        )
    }

    /// Facts a slow transition is read against: which way the panel moved and
    /// how big the task whose transcript reflowed is. Sizes come from cheap
    /// reads (a stored array, one SQL count), never from faulting
    /// relationships on the main thread.
    func screenTransitionContext(nextPanel: String?, task: AgentTask?) -> [String: String] {
        var context = [
            "direction": ScreenTransitionDirection.resolve(previousPanel: currentRightPanelName, nextPanel: nextPanel),
            "panel_before": currentRightPanelName ?? "none",
            "panel_after": nextPanel ?? "none"
        ]
        guard let task else { return context }
        context["input_count"] = PerformanceTelemetryFields.count(task.inputs.count)
        let taskID = task.id
        let runs = FetchDescriptor<TaskRun>(predicate: #Predicate { $0.task?.id == taskID })
        if let runCount = try? modelContext.fetchCount(runs) {
            context["run_count"] = PerformanceTelemetryFields.count(runCount)
        }
        return context
    }

    func screenTransitionDestination(_ item: WorkspaceCanvasItem?, baseDestination: String? = nil) -> String {
        item.map { "shelf_\($0.rawValue)" }
            ?? baseDestination
            ?? (selectedTask == nil ? "workspace_home" : "task_chat")
    }
}
