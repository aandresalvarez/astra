import Foundation

/// Phase 4 of the Studio UX redesign: "refine it" chips. Each refinement is a pure, additive,
/// idempotent transform manifest -> manifest, so a builder adjusts an app by tapping a chip instead
/// of re-typing intent. Transforms keep the manifest valid; the caller re-validates after applying.
enum WorkspaceAppStudioRefinement: String, CaseIterable, Identifiable {
    case addChart
    case addApproval
    case weeklySummary
    case connectREDCap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .addChart: return "Add a chart"
        case .addApproval: return "Add an approval step"
        case .weeklySummary: return "Weekly summary"
        case .connectREDCap: return "Connect REDCap"
        }
    }

    var iconSystemName: String {
        switch self {
        case .addChart: return "chart.bar"
        case .addApproval: return "hand.raised"
        case .weeklySummary: return "calendar"
        case .connectREDCap: return "powerplug"
        }
    }

    /// Only offer a refinement when it can apply AND hasn't already been applied (keeps chips honest).
    func isAvailable(for manifest: WorkspaceAppManifest) -> Bool {
        switch self {
        case .addChart:
            return Self.primaryTable(manifest) != nil
                && !manifest.views.flatMap(\.widgets).contains { $0.type == "chart" }
        case .addApproval:
            return !manifest.actions.contains { $0.type == "gate.humanApproval" }
        case .weeklySummary:
            return Self.primaryTable(manifest) != nil
                && !manifest.actions.contains { $0.id == "weekly_summary" }
        case .connectREDCap:
            return !manifest.requirements.contains { $0.contract == "recordProject.write" }
        }
    }

    func apply(to manifest: WorkspaceAppManifest) -> WorkspaceAppManifest {
        guard isAvailable(for: manifest) else { return manifest }
        var updated = manifest
        switch self {
        case .addChart:
            applyAddChart(&updated)
        case .addApproval:
            updated.actions.append(WorkspaceAppActionSpec(
                id: "approve_step", type: "gate.humanApproval", label: "Approve",
                approvalPrompt: "Approve this before continuing?", approvalDecisions: ["approve", "reject"]
            ))
        case .weeklySummary:
            applyWeeklySummary(&updated)
        case .connectREDCap:
            applyConnectREDCap(&updated)
        }
        return updated
    }

    // MARK: - Transforms

    private func applyAddChart(_ manifest: inout WorkspaceAppManifest) {
        guard let table = Self.primaryTable(manifest) else { return }
        let groupField = Self.categoricalColumn(of: table)
        let widget = WorkspaceAppWidgetSpec(
            id: "by_\(groupField)", type: "chart", label: "By \(groupField)",
            groupBy: groupField, aggregation: "count", chartKind: "bar"
        )
        if let dashboardIndex = manifest.views.firstIndex(where: { $0.type == "dashboard" && ($0.table == table.name || $0.table == nil) }) {
            manifest.views[dashboardIndex].widgets.append(widget)
        } else {
            manifest.views.insert(
                WorkspaceAppViewSpec(id: "overview", type: "dashboard", title: "Overview", table: table.name, widgets: [widget]),
                at: 0
            )
        }
    }

    private func applyWeeklySummary(_ manifest: inout WorkspaceAppManifest) {
        guard let table = Self.primaryTable(manifest) else { return }
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "weekly_summary", type: "task.createDraft", label: "Generate weekly summary",
            taskTitle: "Weekly summary", taskGoal: "Summarize this week's \(table.name) records into a short report."
        ))
        if !manifest.actions.contains(where: { $0.type == "artifact.export" }) {
            manifest.actions.append(WorkspaceAppActionSpec(
                id: "export_summary", type: "artifact.export", label: "Export summary", table: table.name, exportFormat: "csv"
            ))
        }
    }

    private func applyConnectREDCap(_ manifest: inout WorkspaceAppManifest) {
        manifest.requirements.append(WorkspaceAppRequirement(
            id: "redcapWrite", contract: "recordProject.write", minVersion: "1.0.0",
            operations: ["prepareCreate", "submitCreate"], providerHint: "redcap", dataClass: "sensitive"
        ))
        manifest.actions.append(WorkspaceAppActionSpec(
            id: "submit_redcap", type: "capability.write", label: "Submit to REDCap",
            requirementRef: "redcapWrite", operation: "submitCreate"
        ))
        if !manifest.permissions.externalWrites.contains("recordProject.write") {
            manifest.permissions.externalWrites.append("recordProject.write")
        }
        // External writes can't run under draft-only/read-only — step up to approval-gated.
        if manifest.permissions.defaultMode == .draftOnly || manifest.permissions.defaultMode == .readOnly {
            manifest.permissions.defaultMode = .approvalRequired
        }
    }

    // MARK: - Helpers

    static func primaryTable(_ manifest: WorkspaceAppManifest) -> WorkspaceAppStorageTable? {
        manifest.storage?.tables.first
    }

    /// Best categorical column for a chart: a status/category/type/stage column, else the first
    /// non-primary-key text column, else "status".
    static func categoricalColumn(of table: WorkspaceAppStorageTable) -> String {
        let preferred = ["status", "category", "type", "stage", "state"]
        if let match = table.columns.first(where: { preferred.contains($0.name.lowercased()) }) {
            return match.name
        }
        if let text = table.columns.first(where: { !$0.primaryKey && $0.type.lowercased() == "text" }) {
            return text.name
        }
        return "status"
    }
}
