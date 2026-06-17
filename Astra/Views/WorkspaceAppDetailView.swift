import SwiftData
import SwiftUI

struct WorkspaceAppDetailView: View {
    let app: WorkspaceApp
    let workspace: Workspace?
    let onOpenStudio: () -> Void
    let onRefresh: () -> Void
    let onExportPackage: () throws -> URL
    let onRunAction: (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult

    @Query(sort: \WorkspaceAppDependencyBinding.requirementID) private var dependencyBindings: [WorkspaceAppDependencyBinding]
    @Query(sort: \WorkspaceAppAutomationState.automationID) private var automationStates: [WorkspaceAppAutomationState]
    @Query(sort: \WorkspaceAppRun.startedAt, order: .reverse) private var appRuns: [WorkspaceAppRun]
    @State private var dataSnapshot = WorkspaceAppDetailDataSnapshot.empty
    @State private var actionStatusMessage = ""
    @State private var packageStatusMessage = ""
    @State private var activeRecordAction: WorkspaceAppDetailActionPresentation?
    @State private var activeGateAction: WorkspaceAppDetailActionPresentation?
    @State private var recordFormValues: [String: String] = [:]
    @State private var recordFormError = ""
    @State private var pendingDeleteRecordID: String?

    private var presentation: WorkspaceAppDetailPresentation {
        WorkspaceAppsPresentation.detail(for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appSurface
                    attentionSection
                    dependencySection
                    automationSection
                    nativeSurfaceSection
                    formSection
                    actionsSection
                    runHistorySection
                    storageSection
                    metadataRows
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppDetailView-\(presentation.logicalID)")
        .onAppear(perform: loadDataSnapshot)
        .onChange(of: app.updatedAt) {
            loadDataSnapshot()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: presentation.icon)
                .font(Stanford.ui(20, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.name)
                    .font(Stanford.ui(18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(workspace?.name ?? "Workspace app")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            WorkspaceAppStatusPill(
                label: presentation.statusLabel,
                systemImage: presentation.statusSystemImage
            )

            if let dependencyLabel = presentation.dependencyLabel,
               let dependencySystemImage = presentation.dependencySystemImage {
                WorkspaceAppStatusPill(
                    label: dependencyLabel,
                    systemImage: dependencySystemImage,
                    isWarning: true
                )
            }

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh app data")

            Button(action: onOpenStudio) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Open in App Studio")

            Menu {
                Button(action: exportPackage) {
                    Label("Export ASTRA App Package", systemImage: "square.and.arrow.up")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .help("Share this app with another ASTRA workspace")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Stanford.cardBackground)
    }

    private var appSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(presentation.surfaceTitle)
                    .font(Stanford.ui(16, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(presentation.permissionLabel)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(presentation.subtitle)
                .font(Stanford.ui(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.surfaceSubtitle)
                .font(Stanford.ui(13))
                .foregroundStyle(presentation.canRunLocalActions ? .secondary : Stanford.statusWarn)
                .fixedSize(horizontal: false, vertical: true)

            if !packageStatusMessage.isEmpty {
                Text(packageStatusMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var metadataRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceAppMetadataRow(label: "Identifier", value: presentation.logicalID)
            WorkspaceAppMetadataRow(label: "Manifest", value: app.manifestRelativePath)
            WorkspaceAppMetadataRow(label: "Storage", value: app.appDirectoryRelativePath)
            WorkspaceAppMetadataRow(label: "Activity", value: presentation.lastActivityLabel)
        }
        .font(Stanford.caption(12))
    }

    @ViewBuilder
    private var dependencySection: some View {
        if !dataSnapshot.dependencyBindings.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Dependencies")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(dataSnapshot.dependencyBindings.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(dataSnapshot.dependencyBindings, id: \.requirementID) { binding in
                        WorkspaceAppDependencyBindingCard(binding: binding)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var automationSection: some View {
        if !dataSnapshot.automationStates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Automations")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(dataSnapshot.automationStates.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(dataSnapshot.automationStates, id: \.automationID) { automation in
                        WorkspaceAppAutomationStateCard(automation: automation)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var nativeSurfaceSection: some View {
        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: dataSnapshot.manifest,
            storageTables: dataSnapshot.storageTables
        )
        if !surface.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Overview")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(surface.markdowns.count + surface.diagrams.count + surface.metrics.count + surface.charts.count) widgets")
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
            }
        }
    }

    @ViewBuilder
    private var formSection: some View {
        if let manifest = dataSnapshot.manifest {
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
    }

    @ViewBuilder
    private var actionsSection: some View {
        let actions = WorkspaceAppDetailActionsPresentation.actions(
            manifest: dataSnapshot.manifest,
            storageTables: dataSnapshot.storageTables
        )
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
    private var attentionSection: some View {
        let attention = WorkspaceAppRunHistoryPresentationBuilder
            .presentation(runs: dataSnapshot.runs)
            .attentionRows
        if !attention.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Needs attention", systemImage: "clock.badge.exclamationmark")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                    Text("\(attention.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text("Workflow runs paused on an agent task or held for review.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(attention) { row in
                        WorkspaceAppRunHistoryRow(row: row)
                    }
                }
            }
            .padding(12)
            .background(Stanford.lagunita.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var runHistorySection: some View {
        let history = WorkspaceAppRunHistoryPresentationBuilder.presentation(runs: dataSnapshot.runs)
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
        if let errorMessage = dataSnapshot.errorMessage {
            WorkspaceAppDetailNotice(
                title: "Storage unavailable",
                message: errorMessage,
                systemImage: "exclamationmark.triangle"
            )
        } else if !dataSnapshot.storageTables.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Storage")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(dataSnapshot.storageTables.count) tables")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                ForEach(dataSnapshot.storageTables, id: \.name) { table in
                    WorkspaceAppStorageTableView(
                        table: table,
                        rowActions: WorkspaceAppStorageRowActionPresentationBuilder.presentation(
                            manifest: dataSnapshot.manifest,
                            table: table
                        ),
                        pendingDeleteRecordID: pendingDeleteRecordID,
                        onEdit: editRecord,
                        onDelete: deleteRecord
                    )
                }
            }
        }
    }

    private func loadDataSnapshot() {
        dataSnapshot = WorkspaceAppDetailDataLoader().load(
            app: app,
            workspace: workspace,
            dependencyBindings: dependencyBindings,
            automationStates: automationStates,
            runs: appRuns
        )
    }

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
        dataSnapshot.manifest?.actions.first { $0.id == action.id }
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
        guard let table = dataSnapshot.manifest?.storage?.tables.first(where: { $0.name == tableName }) else {
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
        return dataSnapshot.manifest?.storage?.tables.first { $0.name == tableName }
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
        guard let manifest = dataSnapshot.manifest,
              let actionSpec = manifest.actions.first(where: { $0.id == action.id }) else {
            actionStatusMessage = "Action is unavailable."
            return
        }

        do {
            let result = try onRunAction(actionSpec, manifest, action.input)
            actionStatusMessage = result.outputSummary
            loadDataSnapshot()
        } catch {
            actionStatusMessage = String(describing: error)
        }
    }

    private func exportPackage() {
        do {
            let url = try onExportPackage()
            packageStatusMessage = "Exported ASTRA app package to \(url.lastPathComponent)."
        } catch {
            packageStatusMessage = String(describing: error)
        }
    }
}

private struct WorkspaceAppMarkdownCard: View {
    let markdown: WorkspaceAppMarkdownPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(markdown.label)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(attributedContent)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var attributedContent: AttributedString {
        (try? AttributedString(
            markdown: markdown.content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown.content)
    }
}

private struct WorkspaceAppDiagramCard: View {
    let diagram: WorkspaceAppDiagramPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(diagram.label)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(diagram.kind)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if diagram.edges.isEmpty {
                Text(diagram.emptyMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diagram.edges) { edge in
                        WorkspaceAppDiagramEdgeRow(edge: edge)
                    }
                }
            }

            Text(diagram.rawContent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct WorkspaceAppDiagramEdgeRow: View {
    let edge: WorkspaceAppDiagramPresentation.Edge

    var body: some View {
        HStack(spacing: 8) {
            Text(edge.from)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Image(systemName: "arrow.right")
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(edge.to)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WorkspaceAppMetricCard: View {
    let metric: WorkspaceAppMetricPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.label)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(metric.value)
                .font(Stanford.ui(24, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(metric.detail)
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help("Storage-backed metric: \(metric.detail)")
    }
}

private struct WorkspaceAppChartCard: View {
    let chart: WorkspaceAppChartPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chart.label)
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if chart.bars.isEmpty {
                Text(chart.emptyMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chart.bars) { bar in
                        WorkspaceAppChartBarRow(bar: bar)
                    }
                }
            }
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct WorkspaceAppRunHistoryRow: View {
    let row: WorkspaceAppRunHistoryRowPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.statusSystemImage)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.actionID)
                        .font(Stanford.ui(13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(row.statusLabel)
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    Text(row.triggerLabel)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(row.timeLabel)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(row.summary)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let linkedLabel = row.linkedLabel {
                    Label(linkedLabel, systemImage: "link")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch row.statusLabel {
        case "Completed":
            Stanford.paloAltoGreen.opacity(0.92)
        case "Failed":
            Stanford.cardinalRed.opacity(0.92)
        case "Blocked":
            Stanford.poppy.opacity(0.92)
        default:
            .secondary
        }
    }
}

private struct WorkspaceAppChartBarRow: View {
    let bar: WorkspaceAppChartPresentation.Bar

    var body: some View {
        HStack(spacing: 10) {
            Text(bar.label)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(Stanford.lagunita.opacity(0.78))
                        .frame(width: max(proxy.size.width * bar.fraction, 3))
                }
            }
            .frame(height: 8)

            Text(bar.displayValue)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 52, alignment: .trailing)
        }
        .frame(minHeight: 20)
    }
}

private struct WorkspaceAppStorageRecordForm: View {
    let action: WorkspaceAppDetailActionPresentation
    let table: WorkspaceAppStorageTable
    @Binding var values: [String: String]
    let errorMessage: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    private var fields: [WorkspaceAppStorageFormField] {
        WorkspaceAppStorageRecordDraftBuilder.fields(for: table)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(action.label)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(table.name)
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if fields.isEmpty {
                Text("This table has no editable fields.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Text(field.name)
                                    .font(Stanford.caption(11).weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if field.isRequired {
                                    Text("required")
                                        .font(Stanford.caption(10).weight(.semibold))
                                        .foregroundStyle(Stanford.statusWarn)
                                }
                            }

                            TextField(field.type, text: binding(for: field.name))
                                .textFieldStyle(.roundedBorder)
                                .font(Stanford.caption(12))
                        }
                    }
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusWarn)
            }

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)

                Button(action: onSubmit) {
                    Label("Save Record", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func binding(for field: String) -> Binding<String> {
        Binding(
            get: { values[field] ?? "" },
            set: { values[field] = $0 }
        )
    }
}

private struct WorkspaceAppActionButton: View {
    let action: WorkspaceAppDetailActionPresentation
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .font(Stanford.ui(14, weight: .semibold))
                    Text(action.label)
                        .font(Stanford.ui(13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(action.disabledReason ?? action.type)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(action.isEnabled ? Stanford.lagunita : .secondary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Color.primary.opacity(action.isEnabled ? 0.025 : 0.015))
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(action.isEnabled ? 0.08 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .help(action.disabledReason ?? "Run \(action.label)")
    }
}

private struct WorkspaceAppMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct WorkspaceAppDependencyBindingCard: View {
    let binding: WorkspaceAppDependencyBindingSnapshot

    private var statusLabel: String {
        switch binding.status {
        case .mapped:
            "Mapped"
        case .optionalMissing:
            "Optional missing"
        case .missingRequired:
            "Needs mapping"
        }
    }

    private var statusIcon: String {
        switch binding.status {
        case .mapped:
            "checkmark.circle"
        case .optionalMissing:
            "minus.circle"
        case .missingRequired:
            "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        binding.status == .mapped ? Stanford.statusHealthy : Stanford.statusWarn
    }

    private var targetLabel: String {
        if let provider = binding.provider, let transport = binding.transport {
            return "\(provider) via \(transport.rawValue)"
        }
        return binding.optional ? "Optional dependency is not mapped." : "Required dependency is not mapped."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(binding.requirementID)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Label(statusLabel, systemImage: statusIcon)
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Text(binding.contract)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(targetLabel)
                .font(Stanford.caption(12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(binding.operations.isEmpty ? "No operations declared" : binding.operations.joined(separator: ", "))
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help("\(binding.contract): \(targetLabel)")
    }
}

private struct WorkspaceAppAutomationStateCard: View {
    let automation: WorkspaceAppAutomationStateSnapshot

    private var statusLabel: String {
        switch automation.status {
        case .disabled:
            "Disabled"
        case .enabled:
            "Enabled"
        case .blocked:
            "Blocked"
        }
    }

    private var statusIcon: String {
        switch automation.status {
        case .disabled:
            "pause.circle"
        case .enabled:
            "play.circle"
        case .blocked:
            "exclamationmark.octagon"
        }
    }

    private var statusColor: Color {
        switch automation.status {
        case .disabled:
            .secondary
        case .enabled:
            Stanford.statusHealthy
        case .blocked:
            Stanford.statusWarn
        }
    }

    private var actionLabel: String {
        automation.actionID.map { "Runs \($0)" } ?? "No action bound"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(automation.automationID)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Label(statusLabel, systemImage: statusIcon)
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Text(automation.automationType)
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(actionLabel)
                .font(Stanford.caption(12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(automation.isEnabled ? "Runs only after local approval." : "Installed disabled by default.")
                .font(Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help("\(automation.automationType): \(statusLabel)")
    }
}

private struct WorkspaceAppStorageTableView: View {
    let table: WorkspaceAppStorageTableSnapshot
    let rowActions: WorkspaceAppStorageRowActionsPresentation
    let pendingDeleteRecordID: String?
    let onEdit: (WorkspaceAppDetailActionPresentation, String, [String: WorkspaceAppStorageValue]) -> Void
    let onDelete: (WorkspaceAppDetailActionPresentation, String, [String: WorkspaceAppStorageValue]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(table.name)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(table.rowCount) rows")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if let errorMessage = table.errorMessage {
                WorkspaceAppDetailNotice(
                    title: "Table unavailable",
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle"
                )
            } else if table.rows.isEmpty {
                Text("No records yet")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WorkspaceAppStorageHeaderRow(columns: table.columns, hasActions: rowActions.hasActions)
                    ForEach(Array(table.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        WorkspaceAppStorageRecordRow(
                            columns: table.columns,
                            row: row,
                            rowActions: rowActions,
                            isPendingDelete: isPendingDelete(row),
                            onEdit: { action in
                                onEdit(action, table.name, row)
                            },
                            onDelete: { action, primaryKey in
                                onDelete(action, primaryKey, row)
                            }
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func isPendingDelete(_ row: [String: WorkspaceAppStorageValue]) -> Bool {
        guard let primaryKey = rowActions.primaryKey else { return false }
        let value = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(row[primaryKey])
        return pendingDeleteRecordID == "\(table.name):\(primaryKey):\(value)"
    }
}

private struct WorkspaceAppStorageHeaderRow: View {
    let columns: [String]
    let hasActions: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.prefix(4), id: \.self) { column in
                Text(column)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
            if hasActions {
                Text("Actions")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
                    .lineLimit(1)
            }
        }
    }
}

private struct WorkspaceAppStorageRecordRow: View {
    let columns: [String]
    let row: [String: WorkspaceAppStorageValue]
    let rowActions: WorkspaceAppStorageRowActionsPresentation
    let isPendingDelete: Bool
    let onEdit: (WorkspaceAppDetailActionPresentation) -> Void
    let onDelete: (WorkspaceAppDetailActionPresentation, String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.prefix(4), id: \.self) { column in
                Text(displayValue(row[column]))
                    .font(Stanford.caption(12))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if rowActions.hasActions {
                HStack(spacing: 6) {
                    if let updateAction = rowActions.updateAction {
                        Button(action: { onEdit(updateAction) }) {
                            Image(systemName: "pencil")
                                .font(Stanford.caption(11).weight(.semibold))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .help("Edit record")
                    }

                    if let deleteAction = rowActions.deleteAction,
                       let primaryKey = rowActions.primaryKey {
                        Button(role: .destructive, action: { onDelete(deleteAction, primaryKey) }) {
                            Image(systemName: isPendingDelete ? "checkmark" : "trash")
                                .font(Stanford.caption(11).weight(.semibold))
                                .frame(width: 24, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .help(isPendingDelete ? "Confirm delete" : "Delete record")
                    }
                }
                .frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .frame(height: 1)
        }
    }

    private func displayValue(_ value: WorkspaceAppStorageValue?) -> String {
        let displayValue = WorkspaceAppStorageRowActionPresentationBuilder.displayValue(value)
        return displayValue.isEmpty ? "-" : displayValue
    }
}

struct WorkspaceAppDetailNotice: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.statusWarn)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Stanford.statusWarn.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: WorkspaceAppsPresentation.cardCornerRadius, style: .continuous))
    }
}
