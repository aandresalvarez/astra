import Foundation

/// The Workspace App archetypes the Studio can generate, framed (per the product spec) as
/// "recipes" assembled from primitives — NOT hardcoded layouts. Used to route free-text intent
/// to the right deterministic recipe (`WorkspaceAppStudioRecipes`) and to steer the model prompt
/// (`promptMenu`) so generation stops collapsing every intent into a read-only dashboard.
enum WorkspaceAppArchetype: String, CaseIterable, Sendable {
    /// App-owned multi-table database with CRUD + dashboard (e.g. a grocery/inventory tracker).
    case localDatabase
    /// Single-subject records app: enter rows, see metrics. The safe default for an unknown intent.
    case dataEntry
    /// Triage/approve a queue of records with status actions.
    case reviewQueue
    /// Read + summarize stored data into metrics/charts (still needs a way to fill the data).
    case dashboard
    /// Multi-step process with actions, gates, and run history.
    case pipeline
    /// Collect records and produce an exportable report artifact.
    case reportGenerator
    /// Watch data and surface threshold/attention conditions.
    case monitor

    var label: String {
        switch self {
        case .localDatabase: return "Local Database App"
        case .dataEntry: return "Data Entry App"
        case .reviewQueue: return "Review Queue"
        case .dashboard: return "Dashboard"
        case .pipeline: return "Pipeline"
        case .reportGenerator: return "Report Generator"
        case .monitor: return "Monitor"
        }
    }

    /// Sentence-case, user-facing name for the type picker (vs. `label`, the manifest metadata value).
    var displayName: String {
        switch self {
        case .localDatabase: return "Local database"
        case .dataEntry: return "Data entry app"
        case .reviewQueue: return "Review queue"
        case .dashboard: return "Dashboard"
        case .pipeline: return "Pipeline"
        case .reportGenerator: return "Report generator"
        case .monitor: return "Monitor"
        }
    }

    /// SF Symbol shown on the identity card + type picker.
    var iconSystemName: String {
        switch self {
        case .localDatabase: return "tablecells"
        case .dataEntry: return "square.and.pencil"
        case .reviewQueue: return "checklist"
        case .dashboard: return "chart.bar"
        case .pipeline: return "arrow.triangle.branch"
        case .reportGenerator: return "doc.text"
        case .monitor: return "gauge"
        }
    }

    /// One-line, plain-language "what it does" for the type picker.
    var tagline: String {
        switch self {
        case .localDatabase: return "Store and manage records in tables"
        case .dataEntry: return "Capture records and see metrics"
        case .reviewQueue: return "Triage items through statuses"
        case .dashboard: return "Metrics and charts over your data"
        case .pipeline: return "Run a multi-step process with gates"
        case .reportGenerator: return "Collect records and export a report"
        case .monitor: return "Watch data and flag thresholds"
        }
    }

    /// A concrete example intent that pre-fills the box when the type is picked.
    var exampleIntent: String {
        switch self {
        case .localDatabase: return "Track lab equipment by location and status"
        case .dataEntry: return "Log site visits with date, owner, and notes"
        case .reviewQueue: return "Triage incoming issues by status"
        case .dashboard: return "A dashboard of enrollment counts by site"
        case .pipeline: return "A multi-step intake approval pipeline"
        case .reportGenerator: return "A weekly enrollment summary report"
        case .monitor: return "Alert when a sample is older than 30 days"
        }
    }

    /// Map a manifest's stored archetype label (including curated labels like "Reconciliation App"
    /// or "Agentic Workflow") back to an archetype, for choosing an icon. Returns nil when no case
    /// fits — the caller falls back to a generic icon while still showing the real label.
    static func from(label: String) -> WorkspaceAppArchetype? {
        let normalized = label.lowercased()
        if let exact = allCases.first(where: { $0.label.lowercased() == normalized || $0.displayName.lowercased() == normalized }) {
            return exact
        }
        if normalized.contains("review") || normalized.contains("queue") || normalized.contains("reconcil") { return .reviewQueue }
        if normalized.contains("agentic") || normalized.contains("workflow") || normalized.contains("pipeline") { return .pipeline }
        if normalized.contains("report") { return .reportGenerator }
        if normalized.contains("dashboard") { return .dashboard }
        if normalized.contains("monitor") { return .monitor }
        if normalized.contains("database") || normalized.contains("action panel") { return .localDatabase }
        return nil
    }

    /// Classify a free-text intent into the best-fitting archetype. Specific archetypes win over
    /// general ones; an unrecognized intent falls to `.dataEntry` (a usable records app) rather
    /// than a read-only dashboard shell.
    static func classify(_ intent: String) -> WorkspaceAppArchetype {
        let text = intent.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if has(["pipeline", "workflow", "automate", "automation", "multi-step", "multistep", "orchestrate", "approval chain", "process steps"]) {
            return .pipeline
        }
        if has(["report", "summarize", "summary", "digest", "weekly report", "generate a report"]) {
            return .reportGenerator
        }
        if has(["monitor", "alert", "watch for", "threshold", "notify when", "flag when"]) {
            return .monitor
        }
        if has(["review", "triage", "queue", "approve", "moderation", "moderate", "inbox", "backlog"]) {
            return .reviewQueue
        }
        if has(["dashboard", "metrics", "analytics", "kpi", "overview of", "at a glance"]) {
            return .dashboard
        }
        if has(["database", "store my", "grocery", "groceries", "tracker", "track ", "inventory", "catalog", "collection", "ledger", "crm", "records of", "log of"]) {
            return .localDatabase
        }
        // Forms/intake and everything unrecognized → a usable single-subject records app.
        return .dataEntry
    }

    /// A labeled menu the generation prompt embeds so the model explicitly chooses an archetype
    /// and assembles the matching primitives instead of imitating the dashboard few-shot.
    static var promptMenu: String {
        """
        - localDatabase: app-owned tables + CRUD actions (insert/update/delete) + a metrics dashboard.
        - dataEntry: one records table + an Add (appStorage.insert) action + a dashboard. Default when unsure.
        - reviewQueue: a records table + status/triage actions + an Add action.
        - dashboard: metrics/charts over a table — MUST still include an Add action or form so the table can be filled.
        - pipeline: a records table + a pipeline.run action chaining steps + gates + run history.
        - reportGenerator: a records table + a task action that drafts the report + an artifact.export action.
        - monitor: a records table + threshold metrics + an Add action (schedules stay disabled until enabled).
        """
    }
}
