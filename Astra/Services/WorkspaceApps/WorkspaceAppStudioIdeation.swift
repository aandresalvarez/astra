import Foundation

struct WorkspaceAppStudioIdea: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var problem: String
    var requiredSources: [String]
    var appStorage: [String]
    var mainViews: [String]
    var actions: [String]
    var automation: [String]
    var riskMode: WorkspaceAppPermissionMode
    var accelerationRationale: String
}

struct WorkspaceAppStudioIdeationContext: Sendable, Equatable {
    var userRequest: String
    var conversationExcerpts: [String]
    var capabilityNames: [String]

    init(
        userRequest: String,
        conversationExcerpts: [String] = [],
        capabilityNames: [String] = []
    ) {
        self.userRequest = userRequest
        self.conversationExcerpts = conversationExcerpts
        self.capabilityNames = capabilityNames
    }
}

enum WorkspaceAppStudioIdeator {
    static func proposals(
        for context: WorkspaceAppStudioIdeationContext,
        limit: Int = 3
    ) -> [WorkspaceAppStudioIdea] {
        let text = ([context.userRequest] + context.conversationExcerpts + context.capabilityNames)
            .joined(separator: " ")
            .lowercased()
        let ideas: [WorkspaceAppStudioIdea]
        if text.contains("redcap") || text.contains("bigquery") || text.contains("reconcil") {
            ideas = reconciliationIdeas()
        } else if text.contains("agent") || text.contains("orchestrat") {
            ideas = agenticWorkflowIdeas()
        } else if text.contains("pipeline") || text.contains("speed") || text.contains("process") {
            ideas = pipelineIdeas()
        } else if text.contains("report") {
            ideas = reportIdeas()
        } else {
            ideas = localDatabaseIdeas()
        }
        return Array(ideas.prefix(max(1, min(limit, ideas.count))))
    }

    private static func agenticWorkflowIdeas() -> [WorkspaceAppStudioIdea] {
        [
            WorkspaceAppStudioIdea(
                id: "agentic-workflow",
                name: "Agentic Workflow",
                problem: "Describe a problem and run a governed workflow of ASTRA agents that analyze, get reviewed, and implement a solution with approvals and run history.",
                requiredSources: ["Workspace conversation", "App storage run history"],
                appStorage: ["workflow_runs"],
                mainViews: ["Workflow", "Run History"],
                actions: ["Run workflow", "Analyze (agent task)", "Agent review gate", "Human approval", "Implement (agent task)"],
                automation: ["Manual run; bounded loop until done"],
                riskMode: .approvalRequired,
                accelerationRationale: "Turns a repeated multi-step process into a reusable app that orchestrates ASTRA agents with explicit agent and human approval gates instead of ad hoc task chains."
            )
        ]
    }

    private static func reconciliationIdeas() -> [WorkspaceAppStudioIdea] {
        [
            WorkspaceAppStudioIdea(
                id: "bq-redcap-reconciliation",
                name: "BigQuery REDCap Reconciliation",
                problem: "Compare recent warehouse records with REDCap records and surface missing or ambiguous matches.",
                requiredSources: ["BigQuery table", "REDCap project", "App storage review queue"],
                appStorage: ["review_items"],
                mainViews: ["Reconciliation Dashboard", "Exceptions"],
                actions: ["Refresh", "Create Review Task", "Export Missing Records"],
                automation: ["Daily refresh disabled until approved"],
                riskMode: .readOnly,
                accelerationRationale: "Turns repeated record checks into a reusable dashboard with exception handling and task handoff."
            ),
            WorkspaceAppStudioIdea(
                id: "pipeline-review-queue",
                name: "Missing Record Review Queue",
                problem: "Track missing records, owners, status, and follow-up steps from reconciliation work.",
                requiredSources: ["Workspace conversation", "App storage review queue"],
                appStorage: ["pipeline_items"],
                mainViews: ["Pipeline Overview", "Approval Queue"],
                actions: ["Run Pipeline", "Create Follow-up Task"],
                automation: ["Weekday monitor disabled until approved"],
                riskMode: .draftOnly,
                accelerationRationale: "Makes exceptions durable so follow-up can move through a repeatable queue instead of ad hoc notes."
            ),
            reportIdea()
        ]
    }

    private static func pipelineIdeas() -> [WorkspaceAppStudioIdea] {
        [
            WorkspaceAppStudioIdea(
                id: "pipeline-review-queue",
                name: "Pipeline Review Queue",
                problem: "Capture repeated process steps, blockers, and approvals in a durable operational surface.",
                requiredSources: ["Workspace conversation", "Task artifacts", "App storage"],
                appStorage: ["pipeline_items"],
                mainViews: ["Pipeline Overview", "Approval Queue"],
                actions: ["Run Pipeline", "Create Follow-up Task"],
                automation: ["Weekday monitor disabled until approved"],
                riskMode: .draftOnly,
                accelerationRationale: "Converts recurring manual steps into a tracked pipeline with clear handoffs and review points."
            ),
            reportIdea(),
            WorkspaceAppStudioIdea(
                id: "bq-redcap-reconciliation",
                name: "Source System Reconciliation",
                problem: "Compare records across two systems and track exceptions in app storage.",
                requiredSources: ["Primary source", "Target source", "App storage"],
                appStorage: ["review_items"],
                mainViews: ["Reconciliation Dashboard", "Exceptions"],
                actions: ["Refresh", "Create Review Task", "Export Missing Records"],
                automation: ["Scheduled refresh disabled until approved"],
                riskMode: .readOnly,
                accelerationRationale: "Automates the highest-friction check while keeping writes disabled until explicitly added."
            )
        ]
    }

    private static func reportIdeas() -> [WorkspaceAppStudioIdea] {
        [
            reportIdea(),
            WorkspaceAppStudioIdea(
                id: "pipeline-review-queue",
                name: "Report Input Review Queue",
                problem: "Collect report inputs, review status, and missing evidence before report generation.",
                requiredSources: ["Task artifacts", "Workspace files", "App storage"],
                appStorage: ["pipeline_items"],
                mainViews: ["Pipeline Overview", "Approval Queue"],
                actions: ["Run Pipeline", "Create Follow-up Task"],
                automation: ["Weekly monitor disabled until approved"],
                riskMode: .draftOnly,
                accelerationRationale: "Prevents report generation from starting before required source material is ready."
            )
        ]
    }

    private static func localDatabaseIdeas() -> [WorkspaceAppStudioIdea] {
        [
            WorkspaceAppStudioIdea(
                id: "local-database-tracker",
                name: "Local Database Tracker",
                problem: "Store and review lightweight app-owned records without requiring an external connector.",
                requiredSources: ["Manual user input", "App storage"],
                appStorage: ["items", "shopping_lists", "purchases"],
                mainViews: ["Items", "Shopping List", "Spend Metrics"],
                actions: ["Add Item", "Create Shopping Task", "Export Items"],
                automation: [],
                riskMode: .draftOnly,
                accelerationRationale: "Provides a durable local app surface for repeated data entry, metrics, and exports."
            ),
            reportIdea()
        ]
    }

    private static func reportIdea() -> WorkspaceAppStudioIdea {
        WorkspaceAppStudioIdea(
            id: "weekly-report-generator",
            name: "Weekly Report Generator",
            problem: "Collect task outputs and app records into a repeatable report workflow.",
            requiredSources: ["Task artifacts", "Workspace context", "App storage"],
            appStorage: ["report_runs"],
            mainViews: ["Report Dashboard", "Report History"],
            actions: ["Draft Report Task", "Export Report Runs"],
            automation: ["Weekly report disabled until approved"],
            riskMode: .draftOnly,
            accelerationRationale: "Moves recurring reporting from one-off prompts into a reusable app with run history and exports."
        )
    }
}
