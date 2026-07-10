import Foundation

/// Keeps transition measurement attribution at the ContentView boundary where
/// the final destination and incoming task identity are known.
extension ContentView {
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
            usesSelectedTask: usesSelectedTask
        )
    }

    func beginScreenTransition(
        destination: String,
        source: String,
        taskID: UUID? = nil,
        usesSelectedTask: Bool = true
    ) {
        screenTransitionCoordinator.begin(
            destination: destination,
            source: source,
            taskID: usesSelectedTask ? selectedTask?.id : taskID
        )
    }

    func screenTransitionDestination(_ item: WorkspaceCanvasItem?, baseDestination: String? = nil) -> String {
        item.map { "shelf_\($0.rawValue)" }
            ?? baseDestination
            ?? (selectedTask == nil ? "workspace_home" : "task_chat")
    }
}
