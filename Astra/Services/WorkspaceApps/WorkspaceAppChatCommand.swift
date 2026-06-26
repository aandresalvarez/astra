import Foundation
import SwiftData

/// Slice 1b: the `/app` chat command — generate + publish a Workspace App from a one-line
/// description, reusing the SAME deterministic builder + logical-id dedup + version-snapshot path
/// as the Studio's Publish button. Returns the assistant chat message to show. Kept out of the
/// (large) chat view so the command's logic lives behind a focused boundary.
enum WorkspaceAppChatCommand {
    /// The assistant reply for a raw `/app …` message: parses the description, validates a
    /// workspace is selected, and generates the app. Keeps the chat view's handler to two lines.
    @MainActor
    static func reply(input: String, workspace: Workspace?, modelContext: ModelContext) -> String {
        let intent = (input.hasPrefix("/app") ? String(input.dropFirst(4)) : input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty else {
            return "Describe the app after `/app`, e.g. `/app track lab samples with status and owner`."
        }
        guard let workspace else {
            return "Select a workspace first — Workspace Apps are workspace-scoped."
        }
        return generate(intent: intent, workspace: workspace, modelContext: modelContext)
    }

    @MainActor
    static func generate(intent: String, workspace: Workspace, modelContext: ModelContext) -> String {
        let draft = WorkspaceAppStudioBuilder.draft(intent: intent, workspace: workspace)
        let existingIDs = Set(
            ((try? modelContext.fetch(FetchDescriptor<WorkspaceApp>())) ?? [])
                .filter { $0.workspaceID == workspace.id }
                .map(\.logicalID)
        )
        let manifest = WorkspaceAppStudioBuilder.manifestForPublishing(draft.manifest, existingLogicalIDs: existingIDs)
        do {
            let result = try WorkspaceAppService().createApp(
                manifest: manifest, in: workspace, modelContext: modelContext, status: .published
            )
            if let data = try? WorkspaceAppService.encodeManifest(manifest) {
                try? WorkspaceAppVersionService().recordPublish(
                    app: result.app, manifestData: data, validated: true,
                    workspacePath: workspace.primaryPath, modelContext: modelContext
                )
            }
            return "Workspace App **\(manifest.app.name)** created from your description — \(manifest.storage?.tables.count ?? 0) tables, \(manifest.actions.count) actions. Open it from the workspace home, or refine it in App Studio (⌘⇧A)."
        } catch {
            return "Couldn't create the app: \(error.localizedDescription)"
        }
    }
}
