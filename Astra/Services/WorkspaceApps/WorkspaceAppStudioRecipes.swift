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
        case .agenticWorkflow:
            return agenticWorkflowManifest(intent: intent)
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
