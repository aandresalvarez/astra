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
            return pipelineManifest(intent: intent)
        case .reportGenerator:
            return reportManifest(intent: intent)
        case .reviewQueue:
            return reviewQueueManifest(intent: intent)
        case .agenticWorkflow:
            return agenticWorkflowManifest(intent: intent)
        case .dashboard, .monitor:
            // Dashboard (metric/chart widgets) and monitor (scheduled automations) need governed
            // primitives the HTML data bridge can't express, and the native refinement chips only
            // apply to native apps → stay native. Convert once an HTML dashboard/chart template +
            // a workflow bridge exist (future phase).
            var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
            manifest.app.archetypes = [archetype.label]
            return manifest
        case .htmlApp:
            // An interactive tool the data vocabulary can't express. The model normally authors
            // the UI; this deterministic scaffold is the fallback when the model is unavailable.
            return WorkspaceAppStudioBuilder.htmlAppScaffoldManifest(intent: intent)
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
    /// and a draft-task action; relabel it as a review queue. Stays native (the triage + approval
    /// flow needs governed primitives the CRUD HTML template can't express yet).
    private static func reviewQueueManifest(intent: String) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
        manifest.app.archetypes = ["Review Queue", "Action Panel"]
        return manifest
    }

    /// An AI workflow: the operational-surface base (table + Add/Update/Delete + dashboard) plus a
    /// governed agent pipeline — an analysis task whose answer is captured, an agent-recommendation
    /// gate, a human-approval gate, and an implementation task that receives the analysis findings —
    /// chained by a `pipeline.run`. This is the recipe behind the "AI workflow" type: the app hands
    /// its records to an AI agent, the agent's answer is fed forward, and a human gates the action.
    private static func agenticWorkflowManifest(intent: String) -> WorkspaceAppManifest {
        var manifest = WorkspaceAppStudioBuilder.operationalSurfaceManifest(intent: intent)
        manifest.app.icon = "cpu"
        manifest.app.archetypes = ["Agentic Workflow", "Action Panel"]
        // The workflow drafts and runs agent tasks, so it must be governed: step a draft-only/read-only
        // base up to approval-gated, and record that it now produces task runs.
        if manifest.permissions.defaultMode == .draftOnly || manifest.permissions.defaultMode == .readOnly {
            manifest.permissions.defaultMode = .approvalRequired
        }
        if !manifest.permissions.writes.contains("task.runs") {
            manifest.permissions.writes.append("task.runs")
        }
        let analyze = WorkspaceAppActionSpec(
            id: "analyze",
            type: "task.createAndRun",
            label: "Analyze",
            taskTitle: "Analyze the records",
            taskGoal: "Analyze the app's review items and produce findings the implementation step can act on.",
            // Capture the analysis answer so the later steps can see it (the app⇄agent memory round-trip).
            outputBinding: WorkspaceAppActionOutputBinding(field: "summary", capture: "text", table: nil)
        )
        let agentReview = WorkspaceAppActionSpec(
            id: "agent_review",
            type: "gate.agentRecommendation",
            label: "Agent review",
            agentPrompt: "Review the analysis and recommend whether to continue to implementation, revise, or stop.",
            agentDecisions: ["continue", "revise", "stop"],
            agentPolicyMode: "approvalRequired",
            agentTokenBudget: 20_000,
            agentRequiresApproval: true
        )
        let humanApproval = WorkspaceAppActionSpec(
            id: "human_approval",
            type: "gate.humanApproval",
            label: "Human approval",
            approvalPrompt: "Approve the agent's recommendation before the workflow acts?",
            approvalDecisions: ["approve", "reject"]
        )
        let implement = WorkspaceAppActionSpec(
            id: "implement",
            type: "task.createAndRun",
            label: "Implement",
            taskTitle: "Implement the approved plan",
            taskGoal: "Implement the approved plan from the analysis and record the outcome.",
            // Inject the prior analysis findings into this agent's goal so it sees what to implement.
            inputBinding: WorkspaceAppActionInputBinding(source: "boundRows", table: nil, label: "Analysis findings", limit: nil)
        )
        let runWorkflow = WorkspaceAppActionSpec(
            id: "run_workflow",
            type: "pipeline.run",
            label: "Run workflow",
            steps: ["list_review_items", "analyze", "agent_review", "human_approval", "implement"]
        )
        manifest.actions.append(contentsOf: [analyze, agentReview, humanApproval, implement, runWorkflow])
        return manifest
    }
}
