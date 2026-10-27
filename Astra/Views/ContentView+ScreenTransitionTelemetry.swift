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
        usesSelectedTask: Bool = true,
        hidesRail: Bool = false
    ) {
        let panels = ScreenTransitionPanelChange.beforeCanvasChange(current: activeWorkspaceCanvasItem, railShown: isWorkspaceRightRailVisible, next: item,
            hidesRail: hidesRail, hasWorkspace: effectiveWorkspace != nil)
        guard activeWorkspaceCanvasItem != item || panels.previous != panels.next else { return }
        beginScreenTransition(
            destination: screenTransitionDestination(item, baseDestination: baseDestination),
            source: source,
            taskID: taskID,
            usesSelectedTask: usesSelectedTask,
            panels: panels
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
            panels: .init(previous: currentRightPanelName, next: isPresenting ? Self.contextRailDestination : nil)
        )
    }

    /// The right-side panel on screen now: a shelf, the context rail, or none.
    var currentRightPanelName: String? {
        rightPanelName(afterCanvasChange: activeWorkspaceCanvasItem)
    }

    private func rightPanelName(afterCanvasChange item: WorkspaceCanvasItem?) -> String? {
        ScreenTransitionPanelChange.panelName(canvas: item, railShown: isWorkspaceRightRailVisible,
                                             hasWorkspace: effectiveWorkspace != nil)
    }

    func beginScreenTransition(
        destination: String,
        source: String,
        taskID: UUID? = nil,
        usesSelectedTask: Bool = true,
        panels: ScreenTransitionPanelChange
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
            context: panels.fields.merging(ScreenTransitionTaskFacts.fields(task: affectedTask, in: modelContext)) { _, taskValue in taskValue }
        )
    }

    func screenTransitionDestination(_ item: WorkspaceCanvasItem?, baseDestination: String? = nil) -> String {
        item.map { "shelf_\($0.rawValue)" }
            ?? baseDestination
            ?? (selectedTask == nil ? "workspace_home" : "task_chat")
    }
}
