import SwiftUI

/// The interactive surface of a Workspace App — dashboard widgets (metrics/charts/markdown/
/// diagrams), forms, the action-button grid with inline record/gate forms, run history, and the
/// storage tables with inline edit/delete.
///
/// Extracted from `WorkspaceAppDetailView` so BOTH the published detail view and the App Studio
/// full Preview render the EXACT same controls from a `WorkspaceAppDetailDataSnapshot` + an action
/// runner. It owns no disk / `@Query` / `WorkspaceApp` dependency: it renders the injected
/// `snapshot`, routes every action through `onRunAction`, and calls `onReload` after a mutation so
/// the host refreshes the snapshot (the published view reloads from SQLite; the preview reloads
/// from its in-memory sandbox store).
struct WorkspaceAppSurfaceView: View {
    let snapshot: WorkspaceAppDetailDataSnapshot
    let onRunAction: (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult
    /// The ASYNC executor path the bridge uses for `astra.read` (a live connector read is network I/O
    /// `onRunAction` can't await). nil on the preview surface — preview has no real dependency bindings,
    /// so connector reads resolve only on a PUBLISHED app.
    let onCapabilityRead: ((WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult)?
    let onReload: () -> Void
    /// Live, UNCAPPED check for a non-terminal workflow run — the bridge's durable runAction throttle.
    /// Built by the published detail view from the model store (queried each call, not a snapshot);
    /// nil on the preview surface (which has no persisted runs).
    var isWorkflowRunPending: (@MainActor () -> Bool)?

    // Snapshot-derived presentations, computed ONCE in init. SwiftUI does NOT re-run init on
    // @State-driven body re-evaluations (typing in the inline record form mutates recordFormValues
    // on every keystroke), so these no longer recompute per keystroke — only when the host passes a
    // new snapshot after a reload. The costly bits this avoids: mermaid diagram parsing in the
    // native surface builder, and per-table row-action derivation inside the storage ForEach.
    private let surface: WorkspaceAppNativeSurfacePresentation
    private let actionPresentations: [WorkspaceAppDetailActionPresentation]
    private let runHistory: WorkspaceAppRunHistoryPresentation
    private let rowActionsByTable: [String: WorkspaceAppStorageRowActionsPresentation]
    /// Fail-closed gate: a dynamic HTML app renders + gets a bridge ONLY if its (on-disk) manifest
    /// still passes validation. Re-validated here, not trusted from publish time, so a tampered or
    /// stale manifest.json can't reach the WebView/bridge. Computed once per snapshot (not per body).
    private let htmlManifestValid: Bool

    @State private var actionStatusMessage = ""
    @State private var activeRecordAction: WorkspaceAppDetailActionPresentation?
    @State private var activeGateAction: WorkspaceAppDetailActionPresentation?
    @State private var recordFormValues: [String: String] = [:]
    @State private var recordFormError = ""
    @State private var pendingDeleteRecordID: String?

    init(
        snapshot: WorkspaceAppDetailDataSnapshot,
        onRunAction: @escaping (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult,
        onReload: @escaping () -> Void,
        isWorkflowRunPending: (@MainActor () -> Bool)? = nil,
        onCapabilityRead: ((WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult)? = nil
    ) {
        self.snapshot = snapshot
        self.onRunAction = onRunAction
        self.onCapabilityRead = onCapabilityRead
        self.onReload = onReload
        self.isWorkflowRunPending = isWorkflowRunPending
        self.surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: snapshot.manifest,
            storageTables: snapshot.storageTables
        )
        self.actionPresentations = WorkspaceAppDetailActionsPresentation.actions(
            manifest: snapshot.manifest,
            storageTables: snapshot.storageTables
        )
        self.runHistory = WorkspaceAppRunHistoryPresentationBuilder.presentation(runs: snapshot.runs)
        self.rowActionsByTable = Dictionary(
            snapshot.storageTables.map { table in
                (table.name, WorkspaceAppStorageRowActionPresentationBuilder.presentation(
                    manifest: snapshot.manifest,
                    table: table
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Re-validate an HTML app's manifest at render time (fail closed). A native (html == nil)
        // manifest doesn't take the HTML path, so it's vacuously fine here.
        if let manifest = snapshot.manifest, manifest.html != nil {
            self.htmlManifestValid = WorkspaceAppManifestValidator.validate(manifest).isValid
        } else {
            self.htmlManifestValid = true
        }
    }

    var body: some View {
        // HTML is the primary surface. A dynamic HTML app — interactive tools AND (Phase 3) data
        // apps wired to the astra.* bridge — owns the whole surface: render its model/template UI in
        // the CSP-locked WebView. The native `declarativeSurface` below is the LEGACY + governed-
        // WORKFLOW path: it renders only when `manifest.html == nil` (already-published declarative
        // apps + workflow archetypes that need tasks/gates/automations the HTML bridge can't yet
        // express). New data apps no longer take it. Same surface for the live preview + published view.
        if let html = snapshot.manifest?.html,
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if htmlManifestValid {
                WorkspaceAppWebReportView(
                    html: WorkspaceAppWebReportHTML.appDocument(innerHTML: html),
                    allowsJavaScript: true,
                    onBridgeRequest: bridgeHandlers()
                )
                // Bridge eligibility is part of the WebView's IDENTITY: if the app gains or loses its
                // own storage OR its runnable workflow actions, recreate the WebView so the handler is
                // installed/removed accordingly (updateNSView only refreshes a still-present handler,
                // never adds/removes one). This closes the eligibility-flip staleness hole — a page can't
                // keep calling astra.* against an app that no longer grants that surface.
                .id(bridgeEligible)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 600)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("WorkspaceAppHTMLSurface")
            } else {
                // Fail closed: an HTML app whose manifest no longer validates does NOT render its
                // (untrusted) HTML and gets NO bridge — render a notice instead of the WebView.
                WorkspaceAppDetailNotice(
                    title: "App can't run",
                    message: "This app's configuration didn't pass safety validation, so its interface won't load. Rebuild or re-publish it from App Studio.",
                    systemImage: "exclamationmark.shield"
                )
                .accessibilityIdentifier("WorkspaceAppHTMLInvalid")
            }
        } else {
            declarativeSurface
        }
    }

    /// Whether an `astra.*` bridge should be registered for this app's HTML surface (storage /
    /// `capability.read` / runnable workflow action). Single-sourced with `handlers()` via
    /// `WorkspaceAppDataBridge.isBridgeEligible`, and used as the WebView `.id`: when bridge presence
    /// flips (e.g. a read-only connector app is refined/republished into a pure-UI app with no grants),
    /// the WebView is RECREATED so the stale handler + injected `astra.read` script are torn down,
    /// instead of leaving the prior app's read handler callable against its old manifest/bindings.
    private var bridgeEligible: Bool {
        guard let manifest = snapshot.manifest else { return false }
        return WorkspaceAppDataBridge.isBridgeEligible(manifest)
    }

    /// Phase 2/5 bridge: the host closures for a DATA-BACKED or WORKFLOW HTML app. Every `astra.*`
    /// call routes through the SAME governed `onRunAction` the native UI uses, so permission
    /// enforcement + audit are preserved and preview (in-memory) / published (SQLite) parity is
    /// automatic. Built outside the View (in `WorkspaceAppDataBridge.handlers`) so the closures don't
    /// pressure the SwiftUI type-checker. Returns nil for a pure-UI HTML app (no storage, no runnable
    /// actions) so no native bridge is registered at all.
    private func bridgeHandlers() -> WorkspaceAppDataBridge.Handlers? {
        guard let manifest = snapshot.manifest else { return nil }
        return WorkspaceAppDataBridge.handlers(
            manifest: manifest,
            runs: snapshot.runs,
            onRunAction: onRunAction,
            onReload: onReload,
            isWorkflowRunPending: isWorkflowRunPending,
            onCapabilityRead: onCapabilityRead
        )
    }

    private var declarativeSurface: some View {
        VStack(alignment: .leading, spacing: 18) {
            nativeSurfaceSection
            formSection
            actionsSection
            workflowSection
            runHistorySection
            storageSection
        }
    }

    private var surfaceWidgetCount: Int {
        surface.markdowns.count + surface.diagrams.count + surface.metrics.count
            + surface.charts.count + surface.webReports.count
    }

    @ViewBuilder
    private var nativeSurfaceSection: some View {
        if !surface.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Overview")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(surfaceWidgetCount) widgets")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                ForEach(surface.markdowns) { markdown in
                    WorkspaceAppMarkdownCard(markdown: markdown)
                }

                ForEach(surface.diagrams) { diagram in
                    WorkspaceAppDiagramCard(diagram: diagram)
                }

                if !surface.metrics.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(surface.metrics) { metric in
                            WorkspaceAppMetricCard(metric: metric)
                        }
                    }
                }

                ForEach(surface.charts) { chart in
                    WorkspaceAppChartCard(chart: chart)
                }

                ForEach(surface.webReports) { report in
                    WorkspaceAppWebReportCard(report: report)
                }
            }
        }
    }

    @ViewBuilder
    private var formSection: some View {
        if let manifest = snapshot.manifest {
            let formViews = manifest.views.filter { $0.type == "form" && !$0.formFields.isEmpty }
            ForEach(formViews, id: \.id) { view in
                WorkspaceAppFormView(
                    view: view,
                    submitBlockedReasons: manifest.submitBlockedReasons ?? [],
                    onSubmit: { values in submitForm(view: view, manifest: manifest, values: values) }
                )
            }
        }
    }

    private func submitForm(view: WorkspaceAppViewSpec, manifest: WorkspaceAppManifest, values: [String: WorkspaceAppStorageValue]) {
        // Route the draft through the declared write action (capability.write submitCreate) so it
        // goes through the governed, approval-gated path — never a direct write.
        guard let submit = manifest.actions.first(where: { $0.type == "capability.write" && ($0.table == nil || $0.table == view.table) }) else { return }
        _ = try? onRunAction(
            submit,
            manifest,
            WorkspaceAppActionInput(table: view.table, record: values, confirmedApproval: true)
        )
        onReload()
    }

    @ViewBuilder
    private var actionsSection: some View {
        let actions = actionPresentations
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Actions")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(actions.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(actions) { action in
                        WorkspaceAppActionButton(
                            action: action,
                            onRun: { handleAction(action) }
                        )
                    }
                }

                if let activeRecordAction,
                   let table = storageTable(for: activeRecordAction) {
                    WorkspaceAppStorageRecordForm(
                        action: activeRecordAction,
                        table: table,
                        values: $recordFormValues,
                        errorMessage: recordFormError,
                        onCancel: clearRecordForm,
                        onSubmit: { submitRecordAction(activeRecordAction, table: table) }
                    )
                }

                if let activeGateAction, let spec = gateSpec(for: activeGateAction) {
                    gateDecisionForm(action: activeGateAction, spec: spec)
                }

                if !actionStatusMessage.isEmpty {
                    Text(actionStatusMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var workflowSection: some View {
        let workflows = (snapshot.manifest?.actions ?? []).filter { $0.type == "pipeline.run" || $0.type == "loop.run" }
        if !workflows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Workflows")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(workflows.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(workflows, id: \.id) { workflow in
                    WorkspaceAppWorkflowCard(workflow: workflow, manifest: snapshot.manifest)
                }
            }
        }
    }

    @ViewBuilder
    private var runHistorySection: some View {
        let history = runHistory
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Run History")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(history.rows.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(history.rows) { row in
                        WorkspaceAppRunHistoryRow(row: row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        if let errorMessage = snapshot.errorMessage {
            WorkspaceAppDetailNotice(
                title: "Storage unavailable",
                message: errorMessage,
                systemImage: "exclamationmark.triangle"
            )
        } else if !snapshot.storageTables.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Storage")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(snapshot.storageTables.count) tables")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                ForEach(snapshot.storageTables, id: \.name) { table in
                    WorkspaceAppStorageTableView(
                        table: table,
                        rowActions: rowActionsByTable[table.name]
                            ?? WorkspaceAppStorageRowActionsPresentation(tableName: table.name, primaryKey: nil, updateAction: nil, deleteAction: nil, disabledReason: nil),
                        pendingDeleteRecordID: pendingDeleteRecordID,
                        onEdit: editRecord,
                        onDelete: deleteRecord
                    )
                }
            }
        }
    }

    // MARK: - Action handling

    private func handleAction(_ action: WorkspaceAppDetailActionPresentation) {
        switch action.type {
        case "appStorage.insert":
            showRecordForm(for: action)
        case "gate.humanApproval", "gate.agentRecommendation":
            showGateForm(for: action)
        default:
            runAction(action)
        }
    }

    private func showGateForm(for action: WorkspaceAppDetailActionPresentation) {
        clearRecordForm()
        activeGateAction = action
    }

    private func clearGateForm() {
        activeGateAction = nil
    }

    private func gateSpec(for action: WorkspaceAppDetailActionPresentation) -> WorkspaceAppActionSpec? {
        snapshot.manifest?.actions.first { $0.id == action.id }
    }

    private func runGate(
        _ action: WorkspaceAppDetailActionPresentation,
        spec: WorkspaceAppActionSpec,
        decision: String
    ) {
        let input: WorkspaceAppActionInput
        if spec.type == "gate.agentRecommendation" {
            input = WorkspaceAppActionInput(
                confirmedApproval: true,
                agentRecommendationDecision: decision
            )
        } else {
            input = WorkspaceAppActionInput(confirmedApproval: true)
        }
        clearGateForm()
        runAction(
            WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: action.label,
                type: action.type,
                isEnabled: action.isEnabled,
                disabledReason: action.disabledReason,
                input: input
            )
        )
    }

    @ViewBuilder
    private func gateDecisionForm(
        action: WorkspaceAppDetailActionPresentation,
        spec: WorkspaceAppActionSpec
    ) -> some View {
        let isAgentGate = spec.type == "gate.agentRecommendation"
        let prompt = (isAgentGate ? spec.agentPrompt : spec.approvalPrompt) ?? ""
        let decisions = isAgentGate ? spec.agentDecisions : spec.approvalDecisions
        VStack(alignment: .leading, spacing: 8) {
            Text(action.label)
                .font(Stanford.body(13).weight(.semibold))
                .foregroundStyle(Stanford.black)
            if !prompt.isEmpty {
                Text(prompt)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(decisions, id: \.self) { decision in
                    Button(decision) {
                        runGate(action, spec: spec, decision: decision)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button("Cancel", action: clearGateForm)
                    .buttonStyle(.plain)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Stanford.fog.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func showRecordForm(for action: WorkspaceAppDetailActionPresentation) {
        activeGateAction = nil
        activeRecordAction = action
        recordFormValues = [:]
        recordFormError = ""
        pendingDeleteRecordID = nil
    }

    private func editRecord(
        action: WorkspaceAppDetailActionPresentation,
        tableName: String,
        row: [String: WorkspaceAppStorageValue]
    ) {
        guard let table = snapshot.manifest?.storage?.tables.first(where: { $0.name == tableName }) else {
            actionStatusMessage = "Storage schema is unavailable."
            return
        }
        activeRecordAction = action
        recordFormValues = WorkspaceAppStorageRowActionPresentationBuilder.formValues(for: row, table: table)
        recordFormError = ""
        pendingDeleteRecordID = nil
    }

    private func deleteRecord(
        action: WorkspaceAppDetailActionPresentation,
        primaryKey: String,
        row: [String: WorkspaceAppStorageValue]
    ) {
        guard let record = WorkspaceAppStorageRowActionPresentationBuilder.primaryKeyRecord(
            for: row,
            primaryKey: primaryKey
        ) else {
            actionStatusMessage = "Delete needs a selected record primary key."
            return
        }

        let recordID = deleteRecordID(table: action.input.table, primaryKey: primaryKey, row: row)
        guard pendingDeleteRecordID == recordID else {
            pendingDeleteRecordID = recordID
            activeRecordAction = nil
            recordFormError = ""
            actionStatusMessage = "Confirm delete for this record."
            return
        }

        pendingDeleteRecordID = nil
        runAction(
            WorkspaceAppDetailActionPresentation(
                id: action.id,
                label: action.label,
                type: action.type,
                isEnabled: action.isEnabled,
                disabledReason: action.disabledReason,
                input: WorkspaceAppActionInput(
                    table: action.input.table,
                    record: record,
                    confirmedDestructive: true
                )
            )
        )
    }

    private func clearRecordForm() {
        activeRecordAction = nil
        recordFormValues = [:]
        recordFormError = ""
    }

    private func storageTable(for action: WorkspaceAppDetailActionPresentation) -> WorkspaceAppStorageTable? {
        guard let tableName = action.input.table else { return nil }
        return snapshot.manifest?.storage?.tables.first { $0.name == tableName }
    }

    private func submitRecordAction(
        _ action: WorkspaceAppDetailActionPresentation,
        table: WorkspaceAppStorageTable
    ) {
        do {
            let record = try WorkspaceAppStorageRecordDraftBuilder.record(
                for: table,
                values: recordFormValues
            )
            runAction(
                WorkspaceAppDetailActionPresentation(
                    id: action.id,
                    label: action.label,
                    type: action.type,
                    isEnabled: action.isEnabled,
                    disabledReason: action.disabledReason,
                    input: WorkspaceAppActionInput(table: table.name, record: record)
                )
            )
            clearRecordForm()
        } catch {
            recordFormError = error.localizedDescription
        }
    }

    private func deleteRecordID(
        table: String?,
        primaryKey: String,
        row: [String: WorkspaceAppStorageValue]
    ) -> String {
        let value = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(row[primaryKey])
        return "\(table ?? ""):\(primaryKey):\(value)"
    }

    private func runAction(_ action: WorkspaceAppDetailActionPresentation) {
        guard let manifest = snapshot.manifest,
              let actionSpec = manifest.actions.first(where: { $0.id == action.id }) else {
            actionStatusMessage = "Action is unavailable."
            return
        }

        do {
            let result = try onRunAction(actionSpec, manifest, action.input)
            actionStatusMessage = result.outputSummary
            onReload()
        } catch {
            actionStatusMessage = String(describing: error)
        }
    }
}
