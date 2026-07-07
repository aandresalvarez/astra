import Foundation
import SwiftUI
import ASTRAModels

struct WorkspaceAppCardPresentation: Identifiable, Equatable {
    var id: UUID
    var logicalID: String
    var name: String
    var icon: String
    var subtitle: String
    var statusLabel: String
    var statusSystemImage: String
    var dependencyLabel: String?
    var dependencySystemImage: String?
    var lastActivityLabel: String
    var primaryActionTitle: String
}

struct WorkspaceAppDetailPresentation: Equatable {
    var id: UUID
    var logicalID: String
    var name: String
    var icon: String
    var subtitle: String
    var statusLabel: String
    var statusSystemImage: String
    var dependencyLabel: String?
    var dependencySystemImage: String?
    var lastActivityLabel: String
    var permissionLabel: String
    var surfaceTitle: String
    var surfaceSubtitle: String
    var canRunLocalActions: Bool
}

struct WorkspaceAppDetailActionPresentation: Identifiable, Equatable {
    var id: String
    var label: String
    var type: String
    var isEnabled: Bool
    var disabledReason: String?
    var input: WorkspaceAppActionInput
}

struct WorkspaceAppStorageRowActionsPresentation: Equatable {
    var tableName: String
    var primaryKey: String?
    var updateAction: WorkspaceAppDetailActionPresentation?
    var deleteAction: WorkspaceAppDetailActionPresentation?
    var disabledReason: String?

    var hasActions: Bool {
        updateAction != nil || deleteAction != nil
    }
}

struct WorkspaceAppInspectorRowPresentation: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
}

struct WorkspaceAppManifestInspectorPresentation: Equatable {
    var identity: [WorkspaceAppInspectorRowPresentation]
    var sources: [WorkspaceAppInspectorRowPresentation]
    var storage: [WorkspaceAppInspectorRowPresentation]
    var actions: [WorkspaceAppInspectorRowPresentation]
    var automations: [WorkspaceAppInspectorRowPresentation]
    var permissions: [WorkspaceAppInspectorRowPresentation]
}

struct WorkspaceAppNativeSurfacePresentation: Equatable {
    var markdowns: [WorkspaceAppMarkdownPresentation]
    var diagrams: [WorkspaceAppDiagramPresentation]
    var metrics: [WorkspaceAppMetricPresentation]
    var charts: [WorkspaceAppChartPresentation]
    /// `webView`-widget renderers shown in a sandboxed WKWebView (flexible local-app
    /// visualization — Swift builds the HTML from the app's own data; no network, no JS
    /// bridge). Defaulted so existing initializers are unaffected.
    var webReports: [WorkspaceAppWebReportPresentation] = []

    var isEmpty: Bool {
        markdowns.isEmpty && diagrams.isEmpty && metrics.isEmpty && charts.isEmpty && webReports.isEmpty
    }
}

/// A `webView` widget resolved to a self-contained, CSP-locked HTML document (built by
/// Swift from the app's data) for display in a sandboxed WKWebView. The `html` is the
/// final document — the view is a dumb renderer.
struct WorkspaceAppWebReportPresentation: Identifiable, Equatable {
    var id: String
    var label: String
    var html: String
    /// True only for the vetted `chartInteractive` renderer (Swift-authored script). The
    /// static renderers (htmlReport, chartComposite) leave this false so JS stays off.
    var allowsJavaScript = false
}

struct WorkspaceAppRunHistoryPresentation: Equatable {
    var rows: [WorkspaceAppRunHistoryRowPresentation]

    var isEmpty: Bool {
        rows.isEmpty
    }

    // B4: runs paused on an awaited agent task (.waiting) or held for review
    // (.blocked, e.g. budget overrun) form the approval/attention queue.
    var attentionRows: [WorkspaceAppRunHistoryRowPresentation] {
        rows.filter(\.needsAttention)
    }
}

struct WorkspaceAppRunHistoryRowPresentation: Identifiable, Equatable {
    var id: UUID
    var actionID: String
    var statusLabel: String
    var statusSystemImage: String
    var triggerLabel: String
    var timeLabel: String
    var summary: String
    var linkedLabel: String?
    var linkedArtifactPath: String?
    var needsAttention: Bool = false
}

struct WorkspaceAppMetricPresentation: Identifiable, Equatable {
    var id: String
    var label: String
    var value: String
    var detail: String
}

struct WorkspaceAppMarkdownPresentation: Identifiable, Equatable {
    var id: String
    var label: String
    var content: String
}

struct WorkspaceAppDiagramPresentation: Identifiable, Equatable {
    struct Edge: Identifiable, Equatable {
        var id: String { "\(from)->\(to)" }
        var from: String
        var to: String
    }

    var id: String
    var label: String
    var kind: String
    var edges: [Edge]
    var rawContent: String
    var emptyMessage: String
}

struct WorkspaceAppChartPresentation: Identifiable, Equatable {
    struct Bar: Identifiable, Equatable {
        var id: String { label }
        var label: String
        var value: Double
        var displayValue: String
        var fraction: Double
    }

    var id: String
    var label: String
    var kind: String = "bar"   // bar | line | pie
    var bars: [Bar]
    var emptyMessage: String
}

struct WorkspaceAppStorageFormField: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var type: String
    var isRequired: Bool
}

enum WorkspaceAppStorageRecordDraftError: LocalizedError, Equatable {
    case missingRequiredField(String)
    case invalidValue(field: String, type: String, value: String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredField(let field):
            return "\(field) is required."
        case .invalidValue(let field, let type, let value):
            return "\(field) must be \(type), not '\(value)'."
        }
    }
}

enum WorkspaceAppStorageRecordDraftBuilder {
    static func fields(for table: WorkspaceAppStorageTable) -> [WorkspaceAppStorageFormField] {
        table.columns.compactMap { column in
            if column.primaryKey && column.type == "uuid" {
                return nil
            }
            return WorkspaceAppStorageFormField(
                name: column.name,
                type: column.type,
                isRequired: column.required
            )
        }
    }

    static func record(
        for table: WorkspaceAppStorageTable,
        values: [String: String],
        uuid: () -> UUID = UUID.init
    ) throws -> [String: WorkspaceAppStorageValue] {
        var record: [String: WorkspaceAppStorageValue] = [:]
        for column in table.columns {
            let rawValue = values[column.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if rawValue.isEmpty {
                if column.primaryKey && column.type == "uuid" {
                    record[column.name] = .text(uuid().uuidString)
                } else if column.required {
                    throw WorkspaceAppStorageRecordDraftError.missingRequiredField(column.name)
                }
                continue
            }
            record[column.name] = try storageValue(rawValue, column: column)
        }
        return record
    }

    private static func storageValue(
        _ rawValue: String,
        column: WorkspaceAppStorageColumn
    ) throws -> WorkspaceAppStorageValue {
        switch column.type {
        case "bool":
            switch rawValue.lowercased() {
            case "true", "yes", "1":
                return .bool(true)
            case "false", "no", "0":
                return .bool(false)
            default:
                throw WorkspaceAppStorageRecordDraftError.invalidValue(
                    field: column.name,
                    type: column.type,
                    value: rawValue
                )
            }
        case "integer":
            guard let value = Int64(rawValue) else {
                throw WorkspaceAppStorageRecordDraftError.invalidValue(
                    field: column.name,
                    type: column.type,
                    value: rawValue
                )
            }
            return .integer(value)
        case "double", "real":
            guard let value = Double(rawValue) else {
                throw WorkspaceAppStorageRecordDraftError.invalidValue(
                    field: column.name,
                    type: column.type,
                    value: rawValue
                )
            }
            return .real(value)
        case "date", "datetime", "json", "text", "uuid":
            return .text(rawValue)
        default:
            return .text(rawValue)
        }
    }
}

enum WorkspaceAppStorageRowActionPresentationBuilder {
    static func presentation(
        manifest: WorkspaceAppManifest?,
        table: WorkspaceAppStorageTableSnapshot
    ) -> WorkspaceAppStorageRowActionsPresentation {
        guard let manifest,
              let tableSchema = manifest.storage?.tables.first(where: { $0.name == table.name }) else {
            return WorkspaceAppStorageRowActionsPresentation(
                tableName: table.name,
                primaryKey: nil,
                updateAction: nil,
                deleteAction: nil,
                disabledReason: "Storage schema is unavailable."
            )
        }

        guard let primaryKey = tableSchema.columns.first(where: \.primaryKey)?.name else {
            return WorkspaceAppStorageRowActionsPresentation(
                tableName: table.name,
                primaryKey: nil,
                updateAction: nil,
                deleteAction: nil,
                disabledReason: "This table does not declare a primary key."
            )
        }

        return WorkspaceAppStorageRowActionsPresentation(
            tableName: table.name,
            primaryKey: primaryKey,
            updateAction: rowAction(type: "appStorage.update", manifest: manifest, tableName: table.name),
            deleteAction: rowAction(type: "appStorage.delete", manifest: manifest, tableName: table.name),
            disabledReason: nil
        )
    }

    static func formValues(
        for row: [String: WorkspaceAppStorageValue],
        table: WorkspaceAppStorageTable
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: table.columns.map { column in
            (column.name, displayValue(row[column.name]))
        })
    }

    static func primaryKeyRecord(
        for row: [String: WorkspaceAppStorageValue],
        primaryKey: String
    ) -> [String: WorkspaceAppStorageValue]? {
        guard let value = row[primaryKey], value != .null else {
            return nil
        }
        return [primaryKey: value]
    }

    static func displayValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .null, nil:
            ""
        case .text(let text):
            text
        case .integer(let integer):
            "\(integer)"
        case .real(let real):
            real.formatted(.number.precision(.fractionLength(0...2)))
        case .bool(let bool):
            bool ? "true" : "false"
        }
    }

    private static func rowAction(
        type: String,
        manifest: WorkspaceAppManifest,
        tableName: String
    ) -> WorkspaceAppDetailActionPresentation? {
        guard let action = manifest.actions.first(where: { action in
            action.type == type && (action.table == nil || action.table == tableName)
        }) else {
            return nil
        }

        let label = action.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceAppDetailActionPresentation(
            id: action.id,
            label: label?.isEmpty == false ? label! : action.id,
            type: action.type,
            isEnabled: true,
            disabledReason: nil,
            input: WorkspaceAppActionInput(table: tableName)
        )
    }
}

enum WorkspaceAppManifestInspectorPresentationBuilder {
    static func presentation(
        manifest: WorkspaceAppManifest,
        validationReport: WorkspaceAppManifestValidationReport
    ) -> WorkspaceAppManifestInspectorPresentation {
        WorkspaceAppManifestInspectorPresentation(
            identity: identityRows(manifest: manifest, validationReport: validationReport),
            sources: sourceRows(manifest.sources),
            storage: storageRows(manifest.storage),
            actions: actionRows(manifest.actions),
            automations: automationRows(manifest.automations),
            permissions: permissionRows(manifest.permissions)
        )
    }

    private static func identityRows(
        manifest: WorkspaceAppManifest,
        validationReport: WorkspaceAppManifestValidationReport
    ) -> [WorkspaceAppInspectorRowPresentation] {
        [
            WorkspaceAppInspectorRowPresentation(
                id: "app-id",
                title: "App ID",
                detail: manifest.app.id
            ),
            WorkspaceAppInspectorRowPresentation(
                id: "app-name",
                title: "Name",
                detail: manifest.app.name
            ),
            WorkspaceAppInspectorRowPresentation(
                id: "schema-version",
                title: "Schema",
                detail: "v\(manifest.schemaVersion)"
            ),
            WorkspaceAppInspectorRowPresentation(
                id: "validation",
                title: "Validation",
                detail: validationReport.isValid
                    ? "Ready to publish"
                    : "\(validationReport.blockers.count) blockers, \(validationReport.warnings.count) warnings"
            )
        ]
    }

    private static func sourceRows(_ sources: [WorkspaceAppSource]) -> [WorkspaceAppInspectorRowPresentation] {
        sources.map { source in
            WorkspaceAppInspectorRowPresentation(
                id: source.id,
                title: source.id,
                detail: joinedDetails([
                    "mode \(source.mode)",
                    optionalDetail("requirement", source.requirementRef),
                    optionalDetail("operation", source.operation),
                    optionalDetail("project", source.projectRef),
                    optionalDetail("table", source.tableRef),
                    optionalDetail("source", source.sourceRef),
                    optionalDetail("query", source.query)
                ])
            )
        }
    }

    private static func storageRows(_ storage: WorkspaceAppStorageSchema?) -> [WorkspaceAppInspectorRowPresentation] {
        storage?.tables.map { table in
            let primaryKey = table.columns.first(where: \.primaryKey)?.name ?? "none"
            return WorkspaceAppInspectorRowPresentation(
                id: table.name,
                title: table.name,
                detail: "\(table.columns.count) columns, primary key \(primaryKey)"
            )
        } ?? []
    }

    private static func actionRows(_ actions: [WorkspaceAppActionSpec]) -> [WorkspaceAppInspectorRowPresentation] {
        actions.map { action in
            WorkspaceAppInspectorRowPresentation(
                id: action.id,
                title: action.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? action.label!
                    : action.id,
                detail: joinedDetails([
                    action.type,
                    optionalDetail("table", action.table),
                    optionalDetail("requirement", action.requirementRef),
                    optionalDetail("operation", action.operation),
                    optionalDetail("export", action.exportFormat),
                    optionalDetail("task", action.taskTitle)
                ])
            )
        }
    }

    private static func automationRows(_ automations: [WorkspaceAppAutomationSpec]) -> [WorkspaceAppInspectorRowPresentation] {
        automations.map { automation in
            WorkspaceAppInspectorRowPresentation(
                id: automation.id,
                title: automation.id,
                detail: joinedDetails([
                    automation.type,
                    automation.enabledByDefault ? "enabled on import" : "disabled until enabled",
                    optionalDetail("action", automation.action)
                ])
            )
        }
    }

    private static func permissionRows(_ permissions: WorkspaceAppPermissions) -> [WorkspaceAppInspectorRowPresentation] {
        [
            WorkspaceAppInspectorRowPresentation(
                id: "permission-mode",
                title: "Mode",
                detail: permissions.defaultMode.rawValue
            ),
            WorkspaceAppInspectorRowPresentation(
                id: "permission-reads",
                title: "Reads",
                detail: permissions.reads.isEmpty ? "none" : permissions.reads.sorted().joined(separator: ", ")
            ),
            WorkspaceAppInspectorRowPresentation(
                id: "permission-writes",
                title: "Writes",
                detail: permissions.writes.isEmpty ? "none" : permissions.writes.sorted().joined(separator: ", ")
            ),
            WorkspaceAppInspectorRowPresentation(
                id: "permission-external-writes",
                title: "External writes",
                detail: permissions.externalWrites.isEmpty ? "none" : permissions.externalWrites.sorted().joined(separator: ", ")
            )
        ]
    }

    private static func optionalDetail(_ label: String, _ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : "\(label) \(trimmed)"
    }

    private static func joinedDetails(_ details: [String?]) -> String {
        let values = details.compactMap { detail -> String? in
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? "None" : values.joined(separator: ", ")
    }
}

enum WorkspaceAppRunHistoryPresentationBuilder {
    static func presentation(
        runs: [WorkspaceAppRunSnapshot],
        now: Date = Date()
    ) -> WorkspaceAppRunHistoryPresentation {
        WorkspaceAppRunHistoryPresentation(
            rows: runs.map { run in
                WorkspaceAppRunHistoryRowPresentation(
                    id: run.id,
                    actionID: run.actionID,
                    statusLabel: statusLabel(run.status),
                    statusSystemImage: statusSystemImage(run.status),
                    triggerLabel: triggerLabel(run.trigger),
                    timeLabel: relativeTime(from: run.startedAt, now: now),
                    summary: summary(for: run),
                    linkedLabel: linkedLabel(for: run),
                    linkedArtifactPath: run.linkedArtifactPath,
                    needsAttention: run.status == .waiting || run.status == .blocked
                )
            }
        )
    }

    private static func statusLabel(_ status: WorkspaceAppRunStatus) -> String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .blocked: "Blocked"
        case .cancelled: "Cancelled"
        case .waiting: "Waiting"
        }
    }

    private static func statusSystemImage(_ status: WorkspaceAppRunStatus) -> String {
        switch status {
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .blocked: "hand.raised"
        case .cancelled: "minus.circle"
        case .waiting: "clock.arrow.circlepath"
        }
    }

    private static func triggerLabel(_ trigger: WorkspaceAppRunTrigger) -> String {
        switch trigger {
        case .user: "Manual"
        case .automation: "Automation"
        case .importReview: "Import review"
        case .test: "Test"
        }
    }

    private static func summary(for run: WorkspaceAppRunSnapshot) -> String {
        let candidates = [run.outputSummary, run.errorMessage ?? ""]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "No output summary yet."
    }

    private static func linkedLabel(for run: WorkspaceAppRunSnapshot) -> String? {
        if run.linkedTaskID != nil {
            return "Linked task"
        }
        if let artifact = run.linkedArtifactPath,
           !artifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: artifact).lastPathComponent
        }
        return nil
    }

    private static func relativeTime(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

enum WorkspaceAppNativeSurfaceBuilder {
    static func presentation(
        manifest: WorkspaceAppManifest?,
        storageTables: [WorkspaceAppStorageTableSnapshot]
    ) -> WorkspaceAppNativeSurfacePresentation {
        guard let manifest else {
            return WorkspaceAppNativeSurfacePresentation(markdowns: [], diagrams: [], metrics: [], charts: [])
        }

        let tablesByName = Dictionary(uniqueKeysWithValues: storageTables.map { ($0.name, $0) })
        var markdowns: [WorkspaceAppMarkdownPresentation] = []
        var diagrams: [WorkspaceAppDiagramPresentation] = []
        var metrics: [WorkspaceAppMetricPresentation] = []
        var charts: [WorkspaceAppChartPresentation] = []
        var webReports: [WorkspaceAppWebReportPresentation] = []

        for view in manifest.views {
            for widget in view.widgets {
                switch widget.type {
                case "markdown":
                    if let markdown = markdown(widget: widget) {
                        markdowns.append(markdown)
                    }
                case "diagram":
                    if let diagram = diagram(widget: widget) {
                        diagrams.append(diagram)
                    }
                case "metric":
                    if let table = table(for: widget, view: view, tablesByName: tablesByName) {
                        metrics.append(metric(widget: widget, table: table))
                    }
                case "chart":
                    if let table = table(for: widget, view: view, tablesByName: tablesByName) {
                        charts.append(chart(widget: widget, table: table))
                    }
                case "webView":
                    if let report = webReport(widget: widget, table: table(for: widget, view: view, tablesByName: tablesByName)) {
                        webReports.append(report)
                    }
                default:
                    continue
                }
            }
        }

        return WorkspaceAppNativeSurfacePresentation(
            markdowns: markdowns,
            diagrams: diagrams,
            metrics: metrics,
            charts: charts,
            webReports: webReports
        )
    }

    /// Build a sandboxed HTML report for a `webView` widget. Only the ASTRA-known
    /// `htmlReport` renderer is supported today; the HTML is assembled by Swift from the
    /// bound table's data (escaped) — never from imported/arbitrary content.
    private static func webReport(
        widget: WorkspaceAppWidgetSpec,
        table: WorkspaceAppStorageTableSnapshot?
    ) -> WorkspaceAppWebReportPresentation? {
        let renderer = widget.webRenderer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch renderer {
        case "htmlReport":
            let html = WorkspaceAppWebReportHTML.html(
                title: widget.label,
                columns: table?.columns ?? [],
                rows: table?.rows ?? []
            )
            return WorkspaceAppWebReportPresentation(id: widget.id, label: widget.label, html: html)
        case "chartComposite":
            guard let table else { return nil }
            let html = WorkspaceAppWebReportHTML.chartHTML(title: widget.label, bars: chart(widget: widget, table: table).bars)
            return WorkspaceAppWebReportPresentation(id: widget.id, label: widget.label, html: html)
        case "chartInteractive":
            guard let table else { return nil }
            let html = WorkspaceAppWebReportHTML.interactiveChartHTML(title: widget.label, bars: chart(widget: widget, table: table).bars)
            // The only renderer that opts into JavaScript (a vetted Swift-authored script).
            return WorkspaceAppWebReportPresentation(id: widget.id, label: widget.label, html: html, allowsJavaScript: true)
        default:
            return nil
        }
    }

    private static func table(
        for widget: WorkspaceAppWidgetSpec,
        view: WorkspaceAppViewSpec,
        tablesByName: [String: WorkspaceAppStorageTableSnapshot]
    ) -> WorkspaceAppStorageTableSnapshot? {
        let tableName = widget.table ?? view.table
        guard let tableName, let table = tablesByName[tableName], table.errorMessage == nil else {
            return nil
        }
        return table
    }

    private static func markdown(widget: WorkspaceAppWidgetSpec) -> WorkspaceAppMarkdownPresentation? {
        let content = widget.markdownContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { return nil }
        return WorkspaceAppMarkdownPresentation(
            id: widget.id,
            label: widget.label,
            content: content
        )
    }

    private static func diagram(widget: WorkspaceAppWidgetSpec) -> WorkspaceAppDiagramPresentation? {
        let content = widget.diagramContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { return nil }
        return WorkspaceAppDiagramPresentation(
            id: widget.id,
            label: widget.label,
            kind: widget.diagramKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? widget.diagramKind! : "flow",
            edges: diagramEdges(from: content),
            rawContent: content,
            emptyMessage: "No diagram edges found."
        )
    }

    private static func diagramEdges(from content: String) -> [WorkspaceAppDiagramPresentation.Edge] {
        var aliases: [String: String] = [:]
        var edges: [WorkspaceAppDiagramPresentation.Edge] = []
        for line in content.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("flowchart"),
                      !trimmed.hasPrefix("graph") else {
                    continue
                }
                let separators = ["-->", "->"]
                guard let separator = separators.first(where: { trimmed.contains($0) }) else {
                    continue
                }
                let parts = trimmed.components(separatedBy: separator)
                guard parts.count >= 2 else { continue }
                let fromNode = diagramNode(parts[0])
                let toNode = diagramNode(parts[1])
                if let label = fromNode.label {
                    aliases[fromNode.id] = label
                }
                if let label = toNode.label {
                    aliases[toNode.id] = label
                }
                let from = fromNode.label ?? aliases[fromNode.id] ?? fromNode.id
                let to = toNode.label ?? aliases[toNode.id] ?? toNode.id
                guard !from.isEmpty, !to.isEmpty else { continue }
                edges.append(WorkspaceAppDiagramPresentation.Edge(from: from, to: to))
            }
        return edges
    }

    private static func diagramNode(_ raw: String) -> (id: String, label: String?) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commentRange = value.range(of: "%%") {
            value = String(value[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let bracketStart = value.firstIndex(where: { ["[", "(", "{"].contains($0) }),
           let bracketEnd = value.lastIndex(where: { ["]", ")", "}"].contains($0) }),
           bracketStart < bracketEnd {
            let id = String(value[..<bracketStart]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let label = String(value[value.index(after: bracketStart)..<bracketEnd])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return (id: id, label: label.isEmpty ? nil : label)
        }
        let id = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .replacingOccurrences(of: "|", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (id: id, label: nil)
    }

    private static func metric(
        widget: WorkspaceAppWidgetSpec,
        table: WorkspaceAppStorageTableSnapshot
    ) -> WorkspaceAppMetricPresentation {
        switch widget.aggregation ?? "count" {
        case "sum":
            let value = table.rows.reduce(0) { partial, row in
                partial + numericValue(row[widget.field ?? ""])
            }
            return WorkspaceAppMetricPresentation(
                id: widget.id,
                label: widget.label,
                value: formattedNumber(value),
                detail: "\(table.name).\(widget.field ?? "value")"
            )
        default:
            return WorkspaceAppMetricPresentation(
                id: widget.id,
                label: widget.label,
                value: "\(table.rowCount)",
                detail: "\(table.name) records"
            )
        }
    }

    private static func chart(
        widget: WorkspaceAppWidgetSpec,
        table: WorkspaceAppStorageTableSnapshot
    ) -> WorkspaceAppChartPresentation {
        let groupBy = widget.groupBy ?? widget.field
        guard let groupBy else {
            return WorkspaceAppChartPresentation(
                id: widget.id,
                label: widget.label,
                bars: [],
                emptyMessage: "Chart needs a grouping field."
            )
        }

        var grouped: [String: Double] = [:]
        for row in table.rows {
            let label = displayValue(row[groupBy])
            let increment: Double
            if widget.aggregation == "sum", let field = widget.field {
                increment = numericValue(row[field])
            } else {
                increment = 1
            }
            grouped[label, default: 0] += increment
        }

        let maxValue = max(grouped.values.max() ?? 0, 1)
        let bars = grouped
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(8)
            .map { label, value in
                WorkspaceAppChartPresentation.Bar(
                    label: label,
                    value: value,
                    displayValue: formattedNumber(value),
                    fraction: min(max(value / maxValue, 0), 1)
                )
            }

        let kind = ["bar", "line", "pie"].contains(widget.chartKind) ? (widget.chartKind ?? "bar") : "bar"
        return WorkspaceAppChartPresentation(
            id: widget.id,
            label: widget.label,
            kind: kind,
            bars: bars,
            emptyMessage: "No chart data yet."
        )
    }

    private static func numericValue(_ value: WorkspaceAppStorageValue?) -> Double {
        switch value {
        case .integer(let integer):
            Double(integer)
        case .real(let real):
            real
        case .bool(let bool):
            bool ? 1 : 0
        case .text(let text):
            Double(text) ?? 0
        case .null, nil:
            0
        }
    }

    private static func displayValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .text(let text):
            text.isEmpty ? "Blank" : text
        case .integer(let integer):
            "\(integer)"
        case .real(let real):
            formattedNumber(real)
        case .bool(let bool):
            bool ? "true" : "false"
        case .null, nil:
            "Blank"
        }
    }

    private static func formattedNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

enum WorkspaceAppDetailActionsPresentation {
    static func actions(
        manifest: WorkspaceAppManifest?,
        storageTables: [WorkspaceAppStorageTableSnapshot]
    ) -> [WorkspaceAppDetailActionPresentation] {
        guard let manifest else { return [] }
        return manifest.actions.map { action in
            presentation(for: action, storageTables: storageTables)
        }
    }

    private static func presentation(
        for action: WorkspaceAppActionSpec,
        storageTables: [WorkspaceAppStorageTableSnapshot]
    ) -> WorkspaceAppDetailActionPresentation {
        let label = action.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.type {
        case "appStorage.query":
            guard let table = action.table ?? storageTables.first?.name else {
                return WorkspaceAppDetailActionPresentation(
                    id: action.id,
                    label: label?.isEmpty == false ? label! : action.id,
                    type: action.type,
                    isEnabled: false,
                    disabledReason: "No app storage table is available.",
                    input: WorkspaceAppActionInput()
                )
            }
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput(table: table)
            )

        case "appStorage.insert":
            guard let table = action.table ?? storageTables.first?.name else {
                return WorkspaceAppDetailActionPresentation(
                    id: action.id,
                    label: label?.isEmpty == false ? label! : action.id,
                    type: action.type,
                    isEnabled: false,
                    disabledReason: "No app storage table is available.",
                    input: WorkspaceAppActionInput()
                )
            }
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput(table: table)
            )

        case "appStorage.update", "appStorage.delete":
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: false,
                disabledReason: "This action needs record selection before it can run.",
                input: WorkspaceAppActionInput()
            )

        case "task.createDraft":
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput(
                    taskTitle: action.taskTitle,
                    taskGoal: action.taskGoal
                )
            )

        case "artifact.export":
            guard let table = action.table ?? storageTables.first?.name else {
                return WorkspaceAppDetailActionPresentation(
                    id: action.id,
                    label: label?.isEmpty == false ? label! : action.id,
                    type: action.type,
                    isEnabled: false,
                    disabledReason: "No app storage table is available.",
                    input: WorkspaceAppActionInput()
                )
            }
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput(
                    table: table,
                    exportFormat: action.exportFormat ?? "csv"
                )
            )

        case "task.createAndRun":
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput(
                    taskTitle: action.taskTitle,
                    taskGoal: action.taskGoal
                )
            )

        case "pipeline.run", "loop.run":
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput()
            )

        case "gate.humanApproval", "gate.agentRecommendation", "gate.expression":
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: true,
                disabledReason: nil,
                input: WorkspaceAppActionInput()
            )

        default:
            return WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: label?.isEmpty == false ? label! : action.id,
                type: action.type,
                isEnabled: false,
                disabledReason: "This action type is not wired into the app renderer yet.",
                input: WorkspaceAppActionInput()
            )
        }
    }
}

enum WorkspaceAppsPresentation {
    static let cardCornerRadius: CGFloat = 8

    static func cards(
        for apps: [WorkspaceApp],
        now: Date = Date()
    ) -> [WorkspaceAppCardPresentation] {
        apps
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { card(for: $0, now: now) }
    }

    static func shouldShowSection(apps: [WorkspaceApp]) -> Bool {
        !apps.isEmpty
    }

    static func detail(for app: WorkspaceApp, now: Date = Date()) -> WorkspaceAppDetailPresentation {
        WorkspaceAppDetailPresentation(
            id: app.id,
            logicalID: app.logicalID,
            name: normalizedName(for: app),
            icon: normalizedIcon(for: app),
            subtitle: subtitle(for: app),
            statusLabel: statusLabel(for: app.lifecycleStatus),
            statusSystemImage: statusSystemImage(for: app.lifecycleStatus),
            dependencyLabel: dependencyLabel(for: app.dependencyStatus),
            dependencySystemImage: dependencySystemImage(for: app.dependencyStatus),
            lastActivityLabel: lastActivityLabel(for: app, now: now),
            permissionLabel: permissionLabel(for: app.permissionMode),
            surfaceTitle: surfaceTitle(for: app),
            surfaceSubtitle: surfaceSubtitle(for: app),
            canRunLocalActions: app.lifecycleStatus != .disabled && app.dependencyStatus == .ready
        )
    }

    private static func card(for app: WorkspaceApp, now: Date) -> WorkspaceAppCardPresentation {
        WorkspaceAppCardPresentation(
            id: app.id,
            logicalID: app.logicalID,
            name: normalizedName(for: app),
            icon: normalizedIcon(for: app),
            subtitle: subtitle(for: app),
            statusLabel: statusLabel(for: app.lifecycleStatus),
            statusSystemImage: statusSystemImage(for: app.lifecycleStatus),
            dependencyLabel: dependencyLabel(for: app.dependencyStatus),
            dependencySystemImage: dependencySystemImage(for: app.dependencyStatus),
            lastActivityLabel: lastActivityLabel(for: app, now: now),
            primaryActionTitle: primaryActionTitle(for: app.lifecycleStatus)
        )
    }

    private static func normalizedName(for app: WorkspaceApp) -> String {
        let trimmed = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? app.logicalID : trimmed
    }

    private static func normalizedIcon(for app: WorkspaceApp) -> String {
        app.icon.isEmpty ? "square.grid.2x2" : app.icon
    }

    private static func subtitle(for app: WorkspaceApp) -> String {
        let trimmed = app.appDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Workspace app" : trimmed
    }

    private static func statusLabel(for status: WorkspaceAppLifecycleStatus) -> String {
        switch status {
        case .draft:
            "Draft"
        case .published:
            "Published"
        case .disabled:
            "Disabled"
        case .blocked:
            "Blocked"
        }
    }

    private static func statusSystemImage(for status: WorkspaceAppLifecycleStatus) -> String {
        switch status {
        case .draft:
            "pencil"
        case .published:
            "checkmark.circle"
        case .disabled:
            "pause.circle"
        case .blocked:
            "exclamationmark.triangle"
        }
    }

    private static func dependencyLabel(for status: WorkspaceAppDependencyStatus) -> String? {
        switch status {
        case .ready:
            nil
        case .unresolved:
            "Needs mapping"
        case .missingRequired:
            "Missing dependency"
        case .blocked:
            "Dependency blocked"
        }
    }

    private static func dependencySystemImage(for status: WorkspaceAppDependencyStatus) -> String? {
        switch status {
        case .ready:
            nil
        case .unresolved:
            "link.badge.plus"
        case .missingRequired:
            "exclamationmark.triangle"
        case .blocked:
            "nosign"
        }
    }

    private static func primaryActionTitle(for status: WorkspaceAppLifecycleStatus) -> String {
        switch status {
        case .draft:
            "Open draft"
        case .published:
            "Open"
        case .disabled:
            "Disabled"
        case .blocked:
            "Review"
        }
    }

    private static func permissionLabel(for mode: WorkspaceAppPermissionMode) -> String {
        switch mode {
        case .readOnly:
            "Read only"
        case .draftOnly:
            "Draft only"
        case .approvalRequired:
            "Approval required"
        case .preApproved:
            "Pre-approved"
        }
    }

    private static func surfaceTitle(for app: WorkspaceApp) -> String {
        switch app.lifecycleStatus {
        case .draft:
            "Draft app surface"
        case .published:
            "App surface"
        case .disabled:
            "App disabled"
        case .blocked:
            "Review required"
        }
    }

    private static func surfaceSubtitle(for app: WorkspaceApp) -> String {
        if app.dependencyStatus != .ready {
            return "Resolve dependencies before running live actions."
        }
        switch app.permissionMode {
        case .readOnly:
            return "This app can read workspace data and show results."
        case .draftOnly:
            return "This draft is available for design and review."
        case .approvalRequired:
            return "This app asks for approval before running write actions."
        case .preApproved:
            return "This app can run pre-approved actions inside its capability contract."
        }
    }

    private static func lastActivityLabel(for app: WorkspaceApp, now: Date) -> String {
        if let lastRunAt = app.lastRunAt {
            return "Run \(relativeTime(from: lastRunAt, to: now))"
        }
        if let lastRefreshedAt = app.lastRefreshedAt {
            return "Refreshed \(relativeTime(from: lastRefreshedAt, to: now))"
        }
        if let lastOpenedAt = app.lastOpenedAt {
            return "Opened \(relativeTime(from: lastOpenedAt, to: now))"
        }
        return "Created \(relativeTime(from: app.createdAt, to: now))"
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        return "\(days)d ago"
    }
}

/// Pure sort + filter for a storage table's rows, so the table view's column-header
/// sorting and search box stay thin renderers over tested logic. Numeric columns sort
/// numerically, empty/null values sort last, and ties keep input order (stable).
enum WorkspaceAppTablePresentation {
    static func displayRows(
        _ rows: [[String: WorkspaceAppStorageValue]],
        searchableColumns: [String],
        filter: String,
        sortColumn: String?,
        ascending: Bool
    ) -> [[String: WorkspaceAppStorageValue]] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? rows : rows.filter { row in
            searchableColumns.contains { column in
                WorkspaceAppStorageRowActionPresentationBuilder.displayValue(row[column])
                    .lowercased()
                    .contains(query)
            }
        }
        guard let sortColumn else { return filtered }
        // Empty/null values always sort last, independent of direction — so partition
        // them out, sort the present values by direction (stable on ties), then append.
        func isEmpty(_ row: [String: WorkspaceAppStorageValue]) -> Bool {
            WorkspaceAppStorageRowActionPresentationBuilder.displayValue(row[sortColumn])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        let indexed = Array(filtered.enumerated())
        let present = indexed.filter { !isEmpty($0.element) }
        let empties = indexed.filter { isEmpty($0.element) }
        let sortedPresent = present.sorted { lhs, rhs in
            let order = compare(lhs.element[sortColumn], rhs.element[sortColumn])
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        return sortedPresent.map(\.element) + empties.map(\.element)
    }

    /// Empty/null sorts last; numeric when both parse as numbers; else
    /// case/diacritic-insensitive natural order.
    static func compare(_ a: WorkspaceAppStorageValue?, _ b: WorkspaceAppStorageValue?) -> ComparisonResult {
        let sa = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(a)
        let sb = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(b)
        if sa.isEmpty || sb.isEmpty {
            if sa.isEmpty && sb.isEmpty { return .orderedSame }
            return sa.isEmpty ? .orderedDescending : .orderedAscending
        }
        if let da = Double(sa), let db = Double(sb) {
            if da == db { return .orderedSame }
            return da < db ? .orderedAscending : .orderedDescending
        }
        return sa.localizedStandardCompare(sb)
    }
}

/// Pure per-field validation for a form draft: required fields must be present, and
/// `number` / `date` fields must parse. Returns field-name → message; empty == valid.
enum WorkspaceAppFormValidation {
    static func errors(
        fields: [WorkspaceAppFormFieldPresentation],
        values: [String: WorkspaceAppStorageValue]
    ) -> [String: String] {
        var errors: [String: String] = [:]
        for field in fields where !field.readOnly {
            let raw = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(values[field.name])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                if field.required { errors[field.name] = "Required." }
                continue
            }
            switch field.fieldType {
            case "number":
                if Double(raw) == nil { errors[field.name] = "Enter a number." }
            case "date":
                if !isISODate(raw) { errors[field.name] = "Use YYYY-MM-DD." }
            default:
                break
            }
        }
        return errors
    }

    /// Strict `yyyy-MM-dd` calendar validity (rejects 2026-13-40), POSIX locale.
    static func isISODate(_ text: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text) != nil
    }
}
