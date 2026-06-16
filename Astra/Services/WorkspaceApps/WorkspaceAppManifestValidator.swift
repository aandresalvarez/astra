import Foundation

struct WorkspaceAppManifestValidationReport: Equatable {
    struct Issue: Equatable {
        enum Severity: String, Equatable {
            case blocker
            case warning
        }

        var severity: Severity
        var path: String
        var message: String
    }

    var issues: [Issue]

    var blockers: [Issue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [Issue] {
        issues.filter { $0.severity == .warning }
    }

    var isValid: Bool {
        blockers.isEmpty
    }
}

enum WorkspaceAppManifestValidator {
    static func validate(_ manifest: WorkspaceAppManifest) -> WorkspaceAppManifestValidationReport {
        var issues: [WorkspaceAppManifestValidationReport.Issue] = []

        if manifest.schemaVersion < 1 {
            issues.append(blocker("/schemaVersion", "Schema version must be at least 1."))
        }
        validateIdentifier(manifest.app.id, path: "/app/id", label: "App ID", issues: &issues)
        if manifest.app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(blocker("/app/name", "App name is required."))
        }

        let requirementIDs = validateRequirements(manifest.requirements, issues: &issues)
        let storageTables = validateStorage(manifest.storage, issues: &issues)
        let sourceIDs = validateSources(manifest.sources, requirementIDs: requirementIDs, issues: &issues)
        let actionIDs = validateActions(
            manifest.actions,
            requirementIDs: requirementIDs,
            sourceIDs: sourceIDs,
            storageTables: storageTables,
            issues: &issues
        )
        validateViews(manifest.views, storageTables: storageTables, actionIDs: actionIDs, issues: &issues)
        validateAutomations(
            manifest.automations,
            actionIDs: actionIDs,
            actionsByID: Dictionary(manifest.actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            issues: &issues
        )
        validatePermissions(manifest.permissions, issues: &issues)

        return WorkspaceAppManifestValidationReport(issues: issues)
    }

    private static func validateRequirements(
        _ requirements: [WorkspaceAppRequirement],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        for (index, requirement) in requirements.enumerated() {
            let path = "/requirements/\(index)"
            validateUniqueIdentifier(
                requirement.id,
                path: "\(path)/id",
                label: "Requirement ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(requirement.contract, path: "\(path)/contract", label: "Contract", issues: &issues)
            if requirement.operations.isEmpty {
                issues.append(blocker("\(path)/operations", "Requirement must declare at least one operation."))
            }
            for (operationIndex, operation) in requirement.operations.enumerated() {
                validateIdentifier(
                    operation,
                    path: "\(path)/operations/\(operationIndex)",
                    label: "Operation",
                    issues: &issues
                )
            }
        }
        return seen
    }

    private static func validateStorage(
        _ storage: WorkspaceAppStorageSchema?,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> [String: Set<String>] {
        guard let storage else { return [:] }
        var tableNames = Set<String>()
        var tables: [String: Set<String>] = [:]
        for (tableIndex, table) in storage.tables.enumerated() {
            let tablePath = "/storage/tables/\(tableIndex)"
            validateUniqueIdentifier(
                table.name,
                path: "\(tablePath)/name",
                label: "Table name",
                seen: &tableNames,
                issues: &issues
            )
            if table.columns.isEmpty {
                issues.append(blocker("\(tablePath)/columns", "Storage table must declare at least one column."))
            }
            var columnNames = Set<String>()
            for (columnIndex, column) in table.columns.enumerated() {
                let columnPath = "\(tablePath)/columns/\(columnIndex)"
                validateUniqueIdentifier(
                    column.name,
                    path: "\(columnPath)/name",
                    label: "Column name",
                    seen: &columnNames,
                    issues: &issues
                )
                validateIdentifier(column.type, path: "\(columnPath)/type", label: "Column type", issues: &issues)
            }
            tables[table.name] = columnNames
        }
        return tables
    }

    private static func validateSources(
        _ sources: [WorkspaceAppSource],
        requirementIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        for (index, source) in sources.enumerated() {
            let path = "/sources/\(index)"
            validateUniqueIdentifier(
                source.id,
                path: "\(path)/id",
                label: "Source ID",
                seen: &seen,
                issues: &issues
            )
            if let requirementRef = source.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Source references unknown requirement '\(requirementRef)'."))
            }
        }
        return seen
    }

    private static func validateViews(
        _ views: [WorkspaceAppViewSpec],
        storageTables: [String: Set<String>],
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (viewIndex, view) in views.enumerated() {
            let path = "/views/\(viewIndex)"
            validateUniqueIdentifier(
                view.id,
                path: "\(path)/id",
                label: "View ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(view.type, path: "\(path)/type", label: "View type", issues: &issues)
            if let table = view.table {
                validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            }

            var widgetIDs = Set<String>()
            for (widgetIndex, widget) in view.widgets.enumerated() {
                let widgetPath = "\(path)/widgets/\(widgetIndex)"
                validateUniqueIdentifier(
                    widget.id,
                    path: "\(widgetPath)/id",
                    label: "Widget ID",
                    seen: &widgetIDs,
                    issues: &issues
                )
                validateIdentifier(widget.type, path: "\(widgetPath)/type", label: "Widget type", issues: &issues)
                if widget.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(blocker("\(widgetPath)/label", "Widget label is required."))
                }
                validateWidgetBinding(
                    widget,
                    path: widgetPath,
                    viewTable: view.table,
                    storageTables: storageTables,
                    actionIDs: actionIDs,
                    issues: &issues
                )
            }
        }
    }

    private static func validateWidgetBinding(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        viewTable: String?,
        storageTables: [String: Set<String>],
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let table = widget.table ?? viewTable
        switch widget.type {
        case "metric", "chart":
            guard let table else {
                issues.append(blocker("\(path)/table", "Storage-backed widget must reference a table."))
                return
            }
            validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            if let field = widget.field {
                validateStorageFieldReference(field, table: table, path: "\(path)/field", storageTables: storageTables, issues: &issues)
            }
            if let groupBy = widget.groupBy {
                validateStorageFieldReference(groupBy, table: table, path: "\(path)/groupBy", storageTables: storageTables, issues: &issues)
            }
        case "markdown":
            if widget.markdownContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/markdownContent", "Markdown widget content is required."))
            }
        case "diagram":
            validateDiagramWidget(widget, path: path, issues: &issues)
        case "webView":
            validateWebViewWidget(widget, path: path, actionIDs: actionIDs, issues: &issues)
        default:
            break
        }
    }

    private static func validateDiagramWidget(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if widget.diagramContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(blocker("\(path)/diagramContent", "Diagram widget content is required."))
        }
        let kind = widget.diagramKind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "flow"
        if !["flow", "pipeline", "entityRelationship"].contains(kind) {
            issues.append(blocker("\(path)/diagramKind", "Diagram kind '\(kind)' is not supported."))
        }
    }

    private static func validateWebViewWidget(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let allowedRenderers = Set(["mermaidDiagram", "htmlReport", "chartComposite"])
        let renderer = widget.webRenderer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if renderer.isEmpty {
            issues.append(blocker("\(path)/webRenderer", "WebView widget must declare an ASTRA-known renderer."))
        } else if !allowedRenderers.contains(renderer) {
            issues.append(blocker("\(path)/webRenderer", "WebView renderer '\(renderer)' is not allowed for Workspace Apps."))
        }

        for (actionIndex, actionID) in widget.allowedActions.enumerated() {
            validateIdentifier(
                actionID,
                path: "\(path)/allowedActions/\(actionIndex)",
                label: "WebView allowed action",
                issues: &issues
            )
            if !actionIDs.contains(actionID) {
                issues.append(blocker("\(path)/allowedActions/\(actionIndex)", "WebView widget references unknown action '\(actionID)'."))
            }
        }

        for (assetIndex, asset) in widget.requiredAssets.enumerated() {
            if !isPortableAssetPath(asset) {
                issues.append(blocker("\(path)/requiredAssets/\(assetIndex)", "WebView asset path must be portable and relative."))
            }
        }
    }

    private static func validateStorageTableReference(
        _ table: String,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if storageTables[table] == nil {
            issues.append(blocker(path, "References unknown storage table '\(table)'."))
        }
    }

    private static func validateStorageFieldReference(
        _ field: String,
        table: String,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let columns = storageTables[table] else { return }
        if !columns.contains(field) {
            issues.append(blocker(path, "References unknown field '\(field)' on storage table '\(table)'."))
        }
    }

    private static func validateActions(
        _ actions: [WorkspaceAppActionSpec],
        requirementIDs: Set<String>,
        sourceIDs: Set<String>,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        var actionIDs = Set<String>()
        let actionsByID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, action) in actions.enumerated() {
            let path = "/actions/\(index)"
            validateUniqueIdentifier(
                action.id,
                path: "\(path)/id",
                label: "Action ID",
                seen: &seen,
                issues: &issues
            )
            if !action.id.isEmpty {
                actionIDs.insert(action.id)
            }
            validateIdentifier(action.type, path: "\(path)/type", label: "Action type", issues: &issues)
            if let requirementRef = action.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Action references unknown requirement '\(requirementRef)'."))
            }
            if let table = action.table {
                validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            }
            if action.type == "capability.read" {
                if action.sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/sourceRef", "Capability read action must declare a source reference."))
                } else if let sourceRef = action.sourceRef,
                          !sourceIDs.contains(sourceRef) {
                    issues.append(blocker("\(path)/sourceRef", "Capability read action references unknown source '\(sourceRef)'."))
                }
            }
            if action.type == "capability.write" {
                if action.requirementRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/requirementRef", "Capability write action must declare a requirement reference."))
                } else if let requirementRef = action.requirementRef,
                          !requirementIDs.contains(requirementRef) {
                    issues.append(blocker("\(path)/requirementRef", "Capability write action references unknown requirement '\(requirementRef)'."))
                }
                if action.operation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/operation", "Capability write action must declare an operation."))
                }
            }
            if action.type == "artifact.export",
               let format = action.exportFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !format.isEmpty,
               !["csv", "json"].contains(format) {
                issues.append(blocker("\(path)/exportFormat", "Artifact export format must be csv or json."))
            }
            if action.type == "url.open" {
                let targetURL = action.targetURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if targetURL.isEmpty {
                    issues.append(blocker("\(path)/targetURL", "URL open action must declare a target URL."))
                } else if let url = URL(string: targetURL),
                          let scheme = url.scheme?.lowercased(),
                          ["https", "http"].contains(scheme),
                          url.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    // URL is supported.
                } else {
                    issues.append(blocker("\(path)/targetURL", "URL open action must use an http or https URL."))
                }
            }
            if action.type == "clipboard.copy",
               action.clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/clipboardText", "Clipboard copy action must declare text to copy."))
            }
            if action.type == "notification.show" {
                let title = action.notificationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = action.notificationBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if title.isEmpty && body.isEmpty {
                    issues.append(blocker("\(path)/notificationTitle", "Notification action must declare a title or body."))
                }
            }
            if ["task.createDraft", "task.createAndRun"].contains(action.type),
               action.taskGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/taskGoal", "Task action must declare a task goal."))
            }
            if action.type == "gate.humanApproval" {
                if action.approvalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/approvalPrompt", "Human approval gate must declare an approval prompt."))
                }
                if action.approvalDecisions.isEmpty {
                    issues.append(blocker("\(path)/approvalDecisions", "Human approval gate must declare available decisions."))
                }
                for (decisionIndex, decision) in action.approvalDecisions.enumerated() {
                    validateIdentifier(
                        decision,
                        path: "\(path)/approvalDecisions/\(decisionIndex)",
                        label: "Approval decision",
                        issues: &issues
                    )
                }
            }
            if action.type == "gate.expression" {
                if action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/gateField", "Expression gate must declare a field to evaluate."))
                }
                let normalizedOperator = action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if normalizedOperator.isEmpty {
                    issues.append(blocker("\(path)/gateOperator", "Expression gate must declare an operator."))
                } else if !WorkspaceAppExpressionGateOperator.allRawValues.contains(normalizedOperator) {
                    issues.append(blocker("\(path)/gateOperator", "Expression gate operator '\(normalizedOperator)' is not supported."))
                }
                if WorkspaceAppExpressionGateOperator.requiresExpectedValue(normalizedOperator),
                   action.gateValue == nil {
                    issues.append(blocker("\(path)/gateValue", "Expression gate operator '\(normalizedOperator)' must declare a comparison value."))
                }
            }
            if action.type == "gate.agentRecommendation" {
                validateAgentRecommendationGate(action, path: path, issues: &issues)
            }
            if action.type == "rows.reduce" {
                validateReduceAction(action, path: path, issues: &issues)
            }
            if action.type == "gate.branch" {
                validateBranchAction(action, actionsByID: actionsByID, path: path, issues: &issues)
            }
            if action.type == "task.fanOut" {
                validateFanOutAction(action, actionsByID: actionsByID, path: path, issues: &issues)
            }
        }

        for (index, action) in actions.enumerated() where action.type == "pipeline.run" || action.type == "loop.run" || action.type == "gate.branch" {
            let path = "/actions/\(index)"
            if action.steps.isEmpty {
                issues.append(blocker("\(path)/steps", "\(action.type == "loop.run" ? "Loop" : "Pipeline") action must declare at least one step."))
            }
            for (stepIndex, stepID) in action.steps.enumerated() {
                let stepPath = "\(path)/steps/\(stepIndex)"
                validateIdentifier(stepID, path: stepPath, label: "Pipeline step action ID", issues: &issues)
                if stepID == action.id {
                    issues.append(blocker(stepPath, "\(action.type == "loop.run" ? "Loop" : "Pipeline") action cannot include itself as a step."))
                } else if !actionIDs.contains(stepID) {
                    issues.append(blocker(stepPath, "\(action.type == "loop.run" ? "Loop" : "Pipeline") step references unknown action '\(stepID)'."))
                }
                // task.fanOut suspends on a barrier and is only resumable as a direct
                // pipeline.run step; a loop cannot suspend/resume mid-iteration.
                if action.type == "loop.run", actionsByID[stepID]?.type == "task.fanOut" {
                    issues.append(blocker(stepPath, "Loop step '\(stepID)' is a task.fanOut, which is only supported as a direct pipeline step."))
                }
            }
            if action.type == "loop.run" {
                validateLoopAction(action, path: path, issues: &issues)
            }
        }
        validateCompositeActionCycles(actions, issues: &issues)
        return actionIDs
    }

    private static func validateCompositeActionCycles(
        _ actions: [WorkspaceAppActionSpec],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        let actionIndexes = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($0.element.id, $0.offset) })

        for action in actions where isCompositeAction(action) {
            guard let actionIndex = actionIndexes[action.id] else { continue }
            for (stepIndex, stepID) in action.steps.enumerated() where stepID != action.id {
                if compositeAction(stepID, reaches: action.id, actionsByID: actionsByID, visited: []) {
                    issues.append(blocker(
                        "/actions/\(actionIndex)/steps/\(stepIndex)",
                        "Workflow step introduces a cycle back to action '\(action.id)'."
                    ))
                }
            }
        }
    }

    private static func compositeAction(
        _ actionID: String,
        reaches targetID: String,
        actionsByID: [String: WorkspaceAppActionSpec],
        visited: Set<String>
    ) -> Bool {
        guard !visited.contains(actionID),
              let action = actionsByID[actionID],
              isCompositeAction(action) else {
            return false
        }
        let edges = compositeEdges(action)
        if edges.contains(targetID) {
            return true
        }
        var visited = visited
        visited.insert(actionID)
        return edges.contains {
            compositeAction($0, reaches: targetID, actionsByID: actionsByID, visited: visited)
        }
    }

    private static func isCompositeAction(_ action: WorkspaceAppActionSpec) -> Bool {
        action.type == "pipeline.run" || action.type == "loop.run"
            || action.type == "gate.branch" || action.type == "task.fanOut"
    }

    // The child action ids a composite action can reach: its steps plus a fan-out's
    // single child template.
    private static func compositeEdges(_ action: WorkspaceAppActionSpec) -> [String] {
        action.steps + (action.fanOutStep.map { [$0] } ?? [])
    }

    // True if `actionID` is, or can transitively reach, an async task action
    // (task.createAndRun / task.fanOut). A gate.branch target runs inline and must
    // never be able to suspend, so its whole reachable subtree must be async-free.
    private static func reachesAsyncTask(
        _ actionID: String,
        actionsByID: [String: WorkspaceAppActionSpec],
        visited: Set<String>
    ) -> Bool {
        guard !visited.contains(actionID), let action = actionsByID[actionID] else { return false }
        if action.type == "task.createAndRun" || action.type == "task.fanOut" { return true }
        guard isCompositeAction(action) else { return false }
        var visited = visited
        visited.insert(actionID)
        return compositeEdges(action).contains {
            reachesAsyncTask($0, actionsByID: actionsByID, visited: visited)
        }
    }

    private static func validateFanOutAction(
        _ action: WorkspaceAppActionSpec,
        actionsByID: [String: WorkspaceAppActionSpec],
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let child = action.fanOutStep?.trimmingCharacters(in: .whitespacesAndNewlines), !child.isEmpty else {
            issues.append(blocker("\(path)/fanOutStep", "Fan-out action must declare a child task step."))
            return
        }
        validateIdentifier(child, path: "\(path)/fanOutStep", label: "Fan-out child action ID", issues: &issues)
        if child == action.id {
            issues.append(blocker("\(path)/fanOutStep", "Fan-out action cannot reference itself."))
        } else if let childAction = actionsByID[child] {
            if childAction.type != "task.createAndRun" {
                issues.append(blocker("\(path)/fanOutStep", "Fan-out child '\(child)' must be a task.createAndRun action."))
            }
        } else {
            issues.append(blocker("\(path)/fanOutStep", "Fan-out child references unknown action '\(child)'."))
        }
    }

    private static func validateBranchAction(
        _ action: WorkspaceAppActionSpec,
        actionsByID: [String: WorkspaceAppActionSpec],
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        // Predicate reuses the expression-gate operator vocabulary.
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if field.isEmpty {
            issues.append(blocker("\(path)/gateField", "Branch action must declare a field to evaluate."))
        }
        let op = action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if op.isEmpty {
            issues.append(blocker("\(path)/gateOperator", "Branch action must declare an operator."))
        } else if !WorkspaceAppExpressionGateOperator.allRawValues.contains(op) {
            issues.append(blocker("\(path)/gateOperator", "Branch operator '\(op)' is not supported."))
        } else if WorkspaceAppExpressionGateOperator.requiresExpectedValue(op), action.gateValue == nil {
            issues.append(blocker("\(path)/gateValue", "Branch operator '\(op)' must declare a comparison value."))
        }
        // Targets: at least one of then/else, each a known non-async action listed in steps.
        if action.thenStep == nil && action.elseStep == nil {
            issues.append(blocker("\(path)/thenStep", "Branch action must declare a thenStep or elseStep."))
        }
        for (key, target) in [("thenStep", action.thenStep), ("elseStep", action.elseStep)] {
            guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { continue }
            if target == action.id {
                issues.append(blocker("\(path)/\(key)", "Branch action cannot target itself."))
            } else if !action.steps.contains(target) {
                issues.append(blocker("\(path)/\(key)", "Branch target '\(target)' must also be listed in steps."))
            }
            if reachesAsyncTask(target, actionsByID: actionsByID, visited: []) {
                issues.append(blocker("\(path)/\(key)", "Branch cannot target an action that can launch an async task ('\(target)') in this version."))
            }
        }
    }

    private static func validateReduceAction(
        _ action: WorkspaceAppActionSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let strategy = action.reduceStrategy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let supported = ["count", "sum", "concat", "first", "last"]
        if strategy.isEmpty {
            issues.append(blocker("\(path)/reduceStrategy", "Reduce action must declare a strategy."))
        } else if !supported.contains(strategy) {
            issues.append(blocker("\(path)/reduceStrategy", "Reduce strategy '\(strategy)' is not supported."))
        }
        // `count` can fold without a column; every other strategy folds a specific column.
        if strategy != "count" {
            let column = action.reduceColumn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if column.isEmpty {
                issues.append(blocker("\(path)/reduceColumn", "Reduce strategy '\(strategy)' must declare a column to fold over."))
            } else {
                validateIdentifier(column, path: "\(path)/reduceColumn", label: "Reduce column", issues: &issues)
            }
        }
    }

    private static func validateLoopAction(
        _ action: WorkspaceAppActionSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if (action.maxIterations ?? 0) <= 0 {
            issues.append(blocker("\(path)/maxIterations", "Loop action must declare a positive maximum iteration count."))
        }
        if (action.timeoutSeconds ?? 0) <= 0 {
            issues.append(blocker("\(path)/timeoutSeconds", "Loop action must declare a positive timeout."))
        }
        if let delaySeconds = action.delaySeconds, delaySeconds < 0 {
            issues.append(blocker("\(path)/delaySeconds", "Loop action delay cannot be negative."))
        }
        if action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(blocker("\(path)/gateField", "Loop action must declare a stop-condition field."))
        }
        let normalizedOperator = action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedOperator.isEmpty {
            issues.append(blocker("\(path)/gateOperator", "Loop action must declare a stop-condition operator."))
        } else if !WorkspaceAppExpressionGateOperator.allRawValues.contains(normalizedOperator) {
            issues.append(blocker("\(path)/gateOperator", "Loop stop-condition operator '\(normalizedOperator)' is not supported."))
        }
        if WorkspaceAppExpressionGateOperator.requiresExpectedValue(normalizedOperator),
           action.gateValue == nil {
            issues.append(blocker("\(path)/gateValue", "Loop stop-condition operator '\(normalizedOperator)' must declare a comparison value."))
        }
    }

    private static func validateAgentRecommendationGate(
        _ action: WorkspaceAppActionSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if action.agentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(blocker("\(path)/agentPrompt", "Agent recommendation gate must declare an agent prompt."))
        }
        if action.agentDecisions.isEmpty {
            issues.append(blocker("\(path)/agentDecisions", "Agent recommendation gate must declare available decisions."))
        }
        for (decisionIndex, decision) in action.agentDecisions.enumerated() {
            validateIdentifier(
                decision,
                path: "\(path)/agentDecisions/\(decisionIndex)",
                label: "Agent recommendation decision",
                issues: &issues
            )
        }
        for (bindingIndex, binding) in action.agentInputBindings.enumerated() {
            validateIdentifier(
                binding,
                path: "\(path)/agentInputBindings/\(bindingIndex)",
                label: "Agent recommendation input binding",
                issues: &issues
            )
        }
        let policyMode = action.agentPolicyMode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if policyMode.isEmpty {
            issues.append(blocker("\(path)/agentPolicyMode", "Agent recommendation gate must declare a policy mode."))
        } else if !["advisory", "blocking", "approvalRequired"].contains(policyMode) {
            issues.append(blocker("\(path)/agentPolicyMode", "Agent recommendation policy mode '\(policyMode)' is not supported."))
        }
        if let tokenBudget = action.agentTokenBudget {
            if tokenBudget <= 0 {
                issues.append(blocker("\(path)/agentTokenBudget", "Agent recommendation token budget must be positive."))
            }
        } else {
            issues.append(blocker("\(path)/agentTokenBudget", "Agent recommendation gate must declare a token budget."))
        }
    }

    private static func validateAutomations(
        _ automations: [WorkspaceAppAutomationSpec],
        actionIDs: Set<String>,
        actionsByID: [String: WorkspaceAppActionSpec],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (index, automation) in automations.enumerated() {
            let path = "/automations/\(index)"
            validateUniqueIdentifier(
                automation.id,
                path: "\(path)/id",
                label: "Automation ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(automation.type, path: "\(path)/type", label: "Automation type", issues: &issues)
            if automation.enabledByDefault {
                issues.append(blocker("\(path)/enabledByDefault", "Imported or generated automations must default disabled."))
            }
            if let action = automation.action {
                if !actionIDs.contains(action) {
                    issues.append(blocker("\(path)/action", "Automation references unknown action '\(action)'."))
                } else if actionsByID[action]?.type == "task.fanOut" {
                    issues.append(blocker("\(path)/action", "Automation cannot run a task.fanOut directly; it is only supported as a pipeline step."))
                }
            }
            validateAutomationSchedule(automation, path: path, issues: &issues)
        }
    }

    private static func validateAutomationSchedule(
        _ automation: WorkspaceAppAutomationSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard automation.type == "schedule" || automation.type == "monitor" else { return }
        guard let scheduleType = automation.scheduleType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scheduleType.isEmpty else {
            return
        }
        switch scheduleType {
        case "interval":
            if (automation.intervalSeconds ?? 0) <= 0 {
                issues.append(blocker("\(path)/intervalSeconds", "Interval automation must declare positive interval seconds."))
            }
        case "daily":
            validateHourMinute(automation, path: path, issues: &issues)
        case "weekly":
            validateHourMinute(automation, path: path, issues: &issues)
            guard let weekday = automation.weeklyDayOfWeek, (1...7).contains(weekday) else {
                issues.append(blocker("\(path)/weeklyDayOfWeek", "Weekly automation day must be 1 through 7."))
                return
            }
        default:
            issues.append(blocker("\(path)/scheduleType", "Automation schedule type '\(scheduleType)' is not supported."))
        }
    }

    private static func validateHourMinute(
        _ automation: WorkspaceAppAutomationSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let hour = automation.dailyHour, (0...23).contains(hour) else {
            issues.append(blocker("\(path)/dailyHour", "Scheduled automation hour must be 0 through 23."))
            return
        }
        guard let minute = automation.dailyMinute, (0...59).contains(minute) else {
            issues.append(blocker("\(path)/dailyMinute", "Scheduled automation minute must be 0 through 59."))
            return
        }
    }

    private static func validatePermissions(
        _ permissions: WorkspaceAppPermissions,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if !permissions.externalWrites.isEmpty,
           permissions.defaultMode == .readOnly || permissions.defaultMode == .draftOnly {
            issues.append(warning(
                "/permissions/defaultMode",
                "External writes are declared but the default mode prevents submitting them."
            ))
        }
    }

    private static func validateUniqueIdentifier(
        _ value: String,
        path: String,
        label: String,
        seen: inout Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        validateIdentifier(value, path: path, label: label, issues: &issues)
        guard !value.isEmpty else { return }
        if !seen.insert(value).inserted {
            issues.append(blocker(path, "\(label) '\(value)' is duplicated."))
        }
    }

    private static func validateIdentifier(
        _ value: String,
        path: String,
        label: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            issues.append(blocker(path, "\(label) is required."))
            return
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            issues.append(blocker(path, "\(label) may contain only letters, numbers, dot, underscore, or hyphen."))
        }
    }

    private static func isPortableAssetPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("..")
            && !path.contains("\\")
    }

    private static func blocker(_ path: String, _ message: String) -> WorkspaceAppManifestValidationReport.Issue {
        WorkspaceAppManifestValidationReport.Issue(severity: .blocker, path: path, message: message)
    }

    private static func warning(_ path: String, _ message: String) -> WorkspaceAppManifestValidationReport.Issue {
        WorkspaceAppManifestValidationReport.Issue(severity: .warning, path: path, message: message)
    }
}
