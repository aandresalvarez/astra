import Foundation
import SwiftData
import ASTRAModels

/// Explicit before/after facts prevent omitted destinations from looking like
/// closes, and let restoration record its start before mutating presentation.
struct ScreenTransitionPanelChange: Equatable {
    let previous: String?
    let next: String?

    var fields: [String: String] {
        ["direction": ScreenTransitionDirection.resolve(previousPanel: previous, nextPanel: next),
         "panel_before": previous ?? "none", "panel_after": next ?? "none"]
    }

    static func beforeCanvasChange(current: WorkspaceCanvasItem?, railShown: Bool, next: WorkspaceCanvasItem?,
                                   hidesRail: Bool, hasWorkspace: Bool) -> Self {
        .init(previous: panelName(canvas: current, railShown: railShown, hasWorkspace: hasWorkspace),
              next: panelName(canvas: next, railShown: railShown && !hidesRail, hasWorkspace: hasWorkspace))
    }

    static func panelName(canvas: WorkspaceCanvasItem?, railShown: Bool, hasWorkspace: Bool) -> String? {
        if let canvas { return "shelf_\(canvas.rawValue)" }
        return railShown && hasWorkspace ? "context_rail" : nil
    }
}

enum ScreenTransitionTaskFacts {
    @MainActor
    static func fields(task: AgentTask?, in context: ModelContext) -> [String: String] {
        guard let task else { return [:] }
        var fields = ["input_count": PerformanceTelemetryFields.count(task.inputs.count)]
        let ownerID = task.persistentModelID
        let runs = FetchDescriptor<TaskRun>(predicate: #Predicate { $0.task?.persistentModelID == ownerID })
        if let count = try? context.fetchCount(runs) {
            fields["run_count"] = PerformanceTelemetryFields.count(count)
        }
        return fields
    }
}
