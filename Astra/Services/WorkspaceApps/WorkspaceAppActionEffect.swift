import Foundation

/// Single source of truth mapping a Workspace App action `type` to its governance effect
/// (read / localWrite / externalWrite / destructive). Shared by `WorkspaceAppActionExecutor`
/// (permission enforcement), `WorkspaceAppPreviewRunner` (sandbox gate replay), and
/// `WorkspaceAppManifestValidator` (label/effect consistency) so all three agree by construction.
enum WorkspaceAppActionEffect {
    static func effect(for actionType: String) -> WorkspaceAppContractEffect {
        switch actionType {
        case "appStorage.query", "capability.read", "task.open", "artifact.open", "artifact.export",
             "url.open", "clipboard.copy", "pipeline.run", "loop.run", "gate.humanApproval",
             "gate.expression", "rows.reduce", "gate.branch", "gate.agentRecommendation":
            return .read
        case "appStorage.insert", "appStorage.update", "notification.show", "task.createDraft":
            return .localWrite
        case "capability.write", "task.createAndRun", "task.fanOut":
            return .externalWrite
        case "appStorage.delete":
            return .destructive
        default:
            return .externalWrite
        }
    }
}
