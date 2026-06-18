import Foundation

/// Per-archetype deterministic recipes for FREE-TEXT generation. Replaces the old binary
/// "is it a database?" branch so an arbitrary intent ("build a rubik's cube solver") routes to a
/// usable app instead of a read-only dashboard shell. Each recipe produces a manifest that passes
/// `WorkspaceAppManifestValidator` — including the usability invariant (every shown table has a
/// populating path). Recipes build on the shared `localDatabaseManifest` / `operationalSurfaceManifest`
/// templates and augment them with archetype-specific primitives, so the populating path is reused.
enum WorkspaceAppStudioRecipes {
    static func manifest(for archetype: WorkspaceAppArchetype, intent: String) -> WorkspaceAppManifest {
        switch archetype {
        case .localDatabase:
            // The fixed grocery template only for genuinely grocery intents; any other
            // "track X / database / inventory" intent gets a generic records database named from
            // the intent (so "track lab samples" is a samples app, not groceries).
            return WorkspaceAppStudioBuilder.isGroceryIntent(intent)
                ? WorkspaceAppStudioBuilder.localDatabaseManifest(intent: intent)
                : WorkspaceAppStudioBuilder.genericDatabaseManifest(intent: intent)
        case .pipeline:
            return pipelineManifest(intent: intent)
        case .reportGenerator:
            return reportManifest(intent: intent)
        case .reviewQueue:
            return reviewQueueManifest(intent: intent)
        case .dataEntry, .dashboard, .monitor:
            // The operational-surface template is a usable single-subject records app
            // (table + Add/Update/Delete + dashboard). Label it per the chosen archetype.
            var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
            manifest.app.archetypes = [archetype.label]
            return manifest
        }
    }

    /// A multi-step process: list → human-approval gate, surfaced as a runnable pipeline with run
    /// history. Built on the usable operational-surface base (keeps its Add/Update/Delete path).
    private static func pipelineManifest(intent: String) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
        manifest.app.archetypes = ["Pipeline", "Action Panel"]
        let gate = WorkspaceAppActionSpec(
            id: "approve_batch",
            type: "gate.humanApproval",
            label: "Approve Batch",
            approvalPrompt: "Proceed with the reviewed items?",
            approvalDecisions: ["approve", "reject"]
        )
        let pipeline = WorkspaceAppActionSpec(
            id: "run_pipeline",
            type: "pipeline.run",
            label: "Run Pipeline",
            steps: ["list_review_items", "approve_batch"]
        )
        manifest.actions.append(contentsOf: [gate, pipeline])
        return manifest
    }

    /// Collect records and produce an exportable report artifact (task drafts the narrative,
    /// artifact.export emits the file). Built on the usable operational-surface base.
    private static func reportManifest(intent: String) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
        manifest.app.archetypes = ["Report Generator", "Dashboard"]
        let export = WorkspaceAppActionSpec(
            id: "export_report",
            type: "artifact.export",
            label: "Export Report",
            table: "review_items",
            exportFormat: "csv"
        )
        manifest.actions.append(export)
        return manifest
    }

    /// A triage queue: the operational-surface base already provides the table, Add/Update/Delete,
    /// and a draft-task action; relabel it as a review queue.
    private static func reviewQueueManifest(intent: String) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
        manifest.app.archetypes = ["Review Queue", "Action Panel"]
        return manifest
    }
}
