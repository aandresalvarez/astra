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
            // Phase 3: a record-tracking data app is now a DATA-BACKED HTML app (a CRUD UI over the
            // app's own storage via the astra.* bridge), not the static native records shell. The
            // curated multi-table grocery reference stays native (multi-table HTML is a later
            // enhancement); every other "track/list/store X" intent becomes dynamic HTML.
            return WorkspaceAppStudioBuilder.isGroceryIntent(intent)
                ? WorkspaceAppStudioBuilder.localDatabaseManifest(intent: intent)
                : WorkspaceAppStudioBuilder.dataBackedHTMLManifest(intent: intent)
        case .dataEntry:
            // Phase 3: plain record capture is a data-backed HTML CRUD app (a real add/edit UI over
            // the app's own storage via astra.*), not a native table shell. Dashboard + review queue
            // stay native below — they need charts / a triage-approval gate the CRUD template can't
            // express yet, and their native refinement chips (add chart / approval) only apply to
            // native apps.
            return WorkspaceAppStudioBuilder.dataBackedHTMLManifest(intent: intent)
        case .pipeline:
            // Phase 5: a workflow app is a WORKFLOW HTML app — records CRUD + a runnable pipeline
            // whose human-approval gate suspends to the native attention queue. The astra workflow
            // bridge triggers the pipeline; the executor still gates/audits every step.
            return WorkspaceAppStudioBuilder.pipelineHTMLManifest(intent: intent)
        case .reportGenerator:
            return WorkspaceAppStudioBuilder.reportHTMLManifest(intent: intent)
        case .reviewQueue:
            return WorkspaceAppStudioBuilder.reviewQueueHTMLManifest(intent: intent)
        case .agenticWorkflow:
            return WorkspaceAppStudioBuilder.agenticWorkflowHTMLManifest(intent: intent)
        case .dashboard:
            // Phase 5: a dashboard is a DATA + chart HTML app — records CRUD + count metrics + a
            // by-status bar chart computed client-side from astra.query. No native widgets needed.
            return WorkspaceAppStudioBuilder.dashboardHTMLManifest(intent: intent)
        case .monitor:
            // Monitor needs scheduled automations (time-triggered, not a UI action) the workflow
            // bridge can't express → the SOLE remaining native workflow archetype. (The curated
            // multi-table grocery reference under .localDatabase also stays native by choice.)
            var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
            manifest.app.archetypes = [archetype.label]
            return manifest
        case .htmlApp:
            // An interactive tool the data vocabulary can't express. The model normally authors
            // the UI; this deterministic scaffold is the fallback when the model is unavailable.
            return WorkspaceAppStudioBuilder.htmlAppScaffoldManifest(intent: intent)
        }
    }
}
