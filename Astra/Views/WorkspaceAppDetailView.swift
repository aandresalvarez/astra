import SwiftData
import SwiftUI

struct WorkspaceAppDetailView: View {
    let app: WorkspaceApp
    let workspace: Workspace?
    /// Edit in Studio, seeded with the app's current manifest so the conversation continues
    /// from it (nil if the manifest hasn't loaded yet — the Studio then starts fresh).
    let onOpenStudio: (WorkspaceAppManifest?) -> Void
    let onRefresh: () -> Void
    let onExportPackage: () throws -> URL
    let onRunAction: (WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult
    /// Called after this app is permanently deleted, so the parent clears the selection (the
    /// detail view must not linger on a now-deleted app).
    let onDeleted: () -> Void

    @Query(sort: \WorkspaceAppDependencyBinding.requirementID) private var dependencyBindings: [WorkspaceAppDependencyBinding]
    @Query(sort: \WorkspaceAppAutomationState.automationID) private var automationStates: [WorkspaceAppAutomationState]
    @Query(sort: \WorkspaceAppRun.startedAt, order: .reverse) private var appRuns: [WorkspaceAppRun]
    @State private var dataSnapshot = WorkspaceAppDetailDataSnapshot.empty
    @State private var packageStatusMessage = ""
    @Environment(\.modelContext) private var modelContext
    @State private var versionEntries: [WorkspaceAppVersionService.Index.Entry] = []
    @State private var versionStatusMessage = ""
    @State private var showDeleteConfirmation = false
    /// HTML apps render the interactive surface as the hero (filling the pane); the supporting chrome
    /// (dependencies/automations/versions/metadata) lives in this collapsed-by-default footer so it
    /// doesn't steal space from the app.
    @State private var isDetailsExpanded = false

    private var presentation: WorkspaceAppDetailPresentation {
        WorkspaceAppsPresentation.detail(for: app)
    }

    /// A dynamic HTML app owns its whole surface and scrolls internally, so it gets the app-first
    /// layout (`htmlAppLayout`) where the WebView fills the pane. A native declarative app keeps the
    /// scrolling, sectioned column.
    private var isHTMLApp: Bool {
        !(dataSnapshot.manifest?.html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// One-line context under the app title. Leads with the app's description (folding the old, bulky
    /// "App surface" blurb up into the header) and appends the permission mode; falls back to the
    /// workspace name when there's no description.
    private var headerSubtitle: String {
        let description = presentation.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return workspace?.name ?? "Workspace app" }
        let permission = presentation.permissionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return permission.isEmpty ? description : "\(description) · \(permission)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if isHTMLApp {
                htmlAppLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        appSurface
                        attentionSection
                        dependencySection
                        automationSection
                        appSurfaceView
                        versionsSection
                        metadataRows
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Stanford.panelBackground)
        .accessibilityIdentifier("WorkspaceAppDetailView-\(presentation.logicalID)")
        .onAppear(perform: loadDataSnapshot)
        .onChange(of: workspace?.id) {
            loadDataSnapshot()
        }
        .onChange(of: app.updatedAt) {
            loadDataSnapshot()
        }
    }

    /// The interactive app surface (HTML WebView or native widgets), shared by both layouts.
    private var appSurfaceView: some View {
        WorkspaceAppSurfaceView(
            snapshot: dataSnapshot,
            onRunAction: onRunAction,
            onReload: loadDataSnapshot,
            isWorkflowRunPending: makeWorkflowPendingCheck(),
            onCapabilityRead: makeCapabilityReadRunner()
        )
    }

    /// App-first layout for a dynamic HTML app: the surface FILLS the pane; the only chrome above it
    /// is pending approvals (conditional) and a permission/package warning when relevant. Everything
    /// else — dependencies, automations, version history, metadata — sits in a collapsed Details footer.
    @ViewBuilder
    private var htmlAppLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                attentionSection
                if !presentation.canRunLocalActions {
                    Text(presentation.surfaceSubtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !packageStatusMessage.isEmpty {
                    Text(packageStatusMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                appSurfaceView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)

            // The footer is anchored at the bottom, so it expands UPWARD: the content sits ABOVE the
            // toggle bar (a downward-expanding disclosure here would render off-screen), and the app
            // surface above shrinks to make room only while it's open.
            if isDetailsExpanded {
                detailsContent
            }
            detailsToggleBar
        }
    }

    /// The always-visible bottom bar that toggles the Details drawer. Collapsed by default so the app
    /// surface keeps the full pane.
    private var detailsToggleBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isDetailsExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isDetailsExpanded ? "chevron.down" : "chevron.right")
                    .font(Stanford.caption(10).weight(.semibold))
                Text("Details")
                    .font(Stanford.ui(13, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Stanford.cardBackground)
        .overlay(Divider(), alignment: .top)
    }

    /// The app's secondary chrome — dependencies, automations, version history, metadata — shown in a
    /// bounded, scrollable drawer above the toggle bar so it never permanently steals space from the app.
    private var detailsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dependencySection
                automationSection
                versionsSection
                metadataRows
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(maxHeight: 260)
        .background(Stanford.panelBackground)
        .overlay(Divider(), alignment: .top)
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

                Text(headerSubtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(headerSubtitle)
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

            Button(action: refreshDetail) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh app data")

            Button(action: { onOpenStudio(dataSnapshot.manifest) }) {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Open in App Studio")

            Menu {
                Button(action: performDuplicate) {
                    Label("Save as a Copy", systemImage: "plus.square.on.square")
                }
                Button(action: exportPackage) {
                    Label("Export ASTRA App Package", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete App…", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Export this app, or delete it from this workspace")
            .confirmationDialog(
                "Delete “\(presentation.name)”?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete App", role: .destructive, action: performDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes the app, its local data, and its run history from this workspace. This can't be undone.")
            }
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
                        WorkspaceAppAutomationStateCard(
                            automation: automation,
                            onSetEnabled: { setAutomationEnabled(automation.automationID, $0) }
                        )
                    }
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

                Text("Workflow runs paused on an agent task or awaiting your approval.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                ForEach(approvalWaitingRuns, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(approvalPrompt(for: run))
                            .font(Stanford.caption(12))
                            .foregroundStyle(.primary)
                        HStack(spacing: 8) {
                            Button("Approve") { resolveApproval(run, approved: true) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Reject") { resolveApproval(run, approved: false) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Stanford.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

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

    private var approvalWaitingRuns: [WorkspaceAppRun] {
        appRuns.filter { $0.appID == app.id && $0.status == .waiting && $0.pendingApprovalActionID != nil }
    }

    /// The HTML bridge's DURABLE runAction throttle: a closure that, each call, runs a LIVE, UNCAPPED
    /// store query for any non-terminal run of this app. Captures the `ModelContext` (a class, so it
    /// stays live) + the app id — never a snapshot, so a hostile page can't clear it by pushing its
    /// waiting run out of the capped run history.
    private func makeWorkflowPendingCheck() -> @MainActor () -> Bool {
        let appID = app.id
        let context = modelContext
        return {
            let waiting = WorkspaceAppRunStatus.waiting.rawValue
            let running = WorkspaceAppRunStatus.running.rawValue
            var descriptor = FetchDescriptor<WorkspaceAppRun>(
                predicate: #Predicate { $0.appID == appID && ($0.statusRaw == waiting || $0.statusRaw == running) }
            )
            descriptor.fetchLimit = 1
            // Fail CLOSED: if the store query errors, treat the app as pending (deny) rather than
            // letting an unmeasurable state open the gate.
            do { return try context.fetchCount(descriptor) > 0 } catch { return true }
        }
    }

    /// Builds the ASYNC executor closure the bridge uses for `astra.read`. Captures this app + its own
    /// (appID-scoped) dependency bindings, then routes through `executeAsync` — the only path bound to
    /// the live native source client. nil with no workspace (a connector read needs one). Re-derived on
    /// each body eval, so a freshly-mapped binding propagates to the WebView on the next `updateNSView`.
    private func makeCapabilityReadRunner()
    -> ((WorkspaceAppActionSpec, WorkspaceAppManifest, WorkspaceAppActionInput) async throws -> WorkspaceAppActionExecutionResult)? {
        guard let workspace else { return nil }
        let app = self.app
        let context = modelContext
        let appID = app.id
        let bindings = dependencyBindings.filter { $0.appID == appID }
        return { action, manifest, input in
            try await WorkspaceAppActionExecutor().executeAsync(
                actionID: action.id, app: app, workspace: workspace, manifest: manifest,
                dependencyBindings: bindings, input: input, bridgeSurface: .published, modelContext: context
            )
        }
    }

    private func approvalPrompt(for run: WorkspaceAppRun) -> String {
        guard let gateID = run.pendingApprovalActionID,
              let action = dataSnapshot.manifest?.actions.first(where: { $0.id == gateID }) else {
            return "Approval required to continue this workflow."
        }
        return action.approvalPrompt ?? "Approve to continue '\(action.label ?? gateID)'?"
    }

    private func resolveApproval(_ run: WorkspaceAppRun, approved: Bool) {
        guard let workspace, let manifest = dataSnapshot.manifest else { return }
        _ = try? WorkspaceAppActionExecutor().resumeWithApproval(
            run: run, approved: approved, app: app, workspace: workspace,
            manifest: manifest, dependencyBindings: dependencyBindings, modelContext: modelContext
        )
        loadDataSnapshot()
    }

    private func setAutomationEnabled(_ automationID: String, _ isEnabled: Bool) {
        do {
            try WorkspaceAppService().setAutomationEnabled(
                app: app,
                automationID: automationID,
                isEnabled: isEnabled,
                workspace: workspace,
                modelContext: modelContext
            )
            loadDataSnapshot()
        } catch {
            AppLogger.error("Toggle automation \(automationID) failed: \(error)", category: "WorkspaceApps")
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
        // Load the published version history once per snapshot (avoids a per-body FS scan).
        if let workspace {
            versionEntries = WorkspaceAppVersionService().listVersions(appID: app.logicalID, workspacePath: workspace.primaryPath)
        } else {
            versionEntries = []
        }
    }

    private func refreshDetail() {
        loadDataSnapshot()
        onRefresh()
    }

    @ViewBuilder
    private var versionsSection: some View {
        if !versionEntries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Versions")
                        .font(Stanford.ui(15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(versionEntries.count)")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if versionEntries.count >= 2, workspace != nil {
                        Button(action: revertToPreviousVersion) {
                            Label("Revert to previous", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !versionStatusMessage.isEmpty {
                    Text(versionStatusMessage)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                ForEach(versionEntries.sorted { $0.number > $1.number }, id: \.number) { entry in
                    HStack(spacing: 8) {
                        Text("v\(entry.number)")
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(.primary)
                        if entry.number == app.latestVersionNumber {
                            Text("current")
                                .font(Stanford.caption(10).weight(.semibold))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        Spacer()
                        Text(entry.validated ? "validated" : "unvalidated")
                            .font(Stanford.caption(10))
                            .foregroundStyle(.secondary)
                        Text(String(entry.digest.prefix(8)))
                            .font(Stanford.caption(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func revertToPreviousVersion() {
        guard let workspace else { return }
        do {
            let restored = try WorkspaceAppVersionService().revertToPreviousPublished(
                app: app, in: workspace, modelContext: modelContext
            )
            versionStatusMessage = "Reverted to version \(restored)."
            loadDataSnapshot()
            onRefresh()
        } catch {
            versionStatusMessage = "Revert failed: \(error.localizedDescription)"
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

    private func performDelete() {
        do {
            try WorkspaceAppService().deleteApp(app, in: workspace, modelContext: modelContext)
            onDeleted()
        } catch {
            packageStatusMessage = "Couldn't delete the app: \(error.localizedDescription)"
        }
    }

    /// Explicit fork: branch this app into a separate new app (its own logicalID + database). The
    /// deliberate counterpart to editing-in-place, which now versions THIS app rather than forking.
    private func performDuplicate() {
        guard let workspace else { return }
        do {
            let copy = try WorkspaceAppService().duplicateApp(app, in: workspace, modelContext: modelContext)
            packageStatusMessage = "Saved a copy: “\(copy.app.name)”."
        } catch {
            packageStatusMessage = "Couldn't save a copy: \(error.localizedDescription)"
        }
    }
}

struct WorkspaceAppMarkdownCard: View {
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

struct WorkspaceAppDiagramCard: View {
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
                WorkspaceAppDiagramGraph(edges: diagram.edges)
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

struct WorkspaceAppMetricCard: View {
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

struct WorkspaceAppChartCard: View {
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
                switch chart.kind {
                case "line":
                    WorkspaceAppLineChart(chart: chart)
                case "pie":
                    WorkspaceAppPieChart(chart: chart)
                default:
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chart.bars) { bar in
                            WorkspaceAppChartBarRow(bar: bar)
                        }
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

struct WorkspaceAppRunHistoryRow: View {
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
                    if let path = row.linkedArtifactPath, !path.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Label(linkedLabel, systemImage: "arrow.up.forward.app")
                                .font(Stanford.caption(11))
                                .foregroundStyle(Stanford.lagunita)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    } else {
                        Label(linkedLabel, systemImage: "link")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

struct WorkspaceAppChartBarRow: View {
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

struct WorkspaceAppStorageRecordForm: View {
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

struct WorkspaceAppActionButton: View {
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

struct WorkspaceAppMetadataRow: View {
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

struct WorkspaceAppDependencyBindingCard: View {
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

struct WorkspaceAppAutomationStateCard: View {
    let automation: WorkspaceAppAutomationStateSnapshot
    var onSetEnabled: ((Bool) -> Void)? = nil

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

            if automation.isEnabled, let nextRunAt = automation.nextRunAt {
                Text("Next run \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Schedule governance: an explicit enable/disable that the user controls.
            // Blocked automations can't be enabled until their dependency resolves.
            if let onSetEnabled, automation.status != .blocked {
                Button(automation.isEnabled ? "Disable" : "Enable") {
                    onSetEnabled(!automation.isEnabled)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(automation.isEnabled
                    ? "Stop this schedule from running."
                    : "Enable this schedule. It runs under the app's permission mode and still respects approvals.")
            }
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

struct WorkspaceAppStorageTableView: View {
    let table: WorkspaceAppStorageTableSnapshot
    let rowActions: WorkspaceAppStorageRowActionsPresentation
    let pendingDeleteRecordID: String?
    let onEdit: (WorkspaceAppDetailActionPresentation, String, [String: WorkspaceAppStorageValue]) -> Void
    let onDelete: (WorkspaceAppDetailActionPresentation, String, [String: WorkspaceAppStorageValue]) -> Void

    @State private var expanded = false
    @State private var filterText = ""
    @State private var sortColumn: String?
    @State private var sortAscending = true
    private let collapsedRowLimit = 5

    private var displayedRows: [[String: WorkspaceAppStorageValue]] {
        WorkspaceAppTablePresentation.displayRows(
            table.rows,
            searchableColumns: table.columns,
            filter: filterText,
            sortColumn: sortColumn,
            ascending: sortAscending
        )
    }

    private func toggleSort(_ column: String) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    var body: some View {
        let rows = displayedRows
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(table.name)
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(filterText.isEmpty ? "\(table.rowCount) rows" : "\(rows.count) of \(table.rowCount)")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if !table.rows.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(Stanford.caption(10))
                            .foregroundStyle(.secondary)
                        TextField("Filter", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(Stanford.caption(11))
                            .frame(width: 110)
                        if !filterText.isEmpty {
                            Button { filterText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(Stanford.caption(10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                }
            }

            if let errorMessage = table.errorMessage {
                WorkspaceAppDetailNotice(
                    title: "Table unavailable",
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle"
                )
            } else if table.rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                        Text("No records yet")
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    Text("Use an Add action above to create the first record.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WorkspaceAppStorageHeaderRow(
                        columns: table.columns,
                        hasActions: rowActions.hasActions,
                        sortColumn: sortColumn,
                        ascending: sortAscending,
                        onSort: toggleSort
                    )
                    if rows.isEmpty {
                        Text("No rows match “\(filterText)”")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        let visibleRows = expanded ? rows : Array(rows.prefix(collapsedRowLimit))
                        ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
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
                        if rows.count > collapsedRowLimit {
                            Button(expanded ? "Show fewer" : "Show all \(rows.count) rows") {
                                expanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(Stanford.lagunita)
                            .padding(.top, 2)
                        }
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

struct WorkspaceAppStorageHeaderRow: View {
    let columns: [String]
    let hasActions: Bool
    var sortColumn: String? = nil
    var ascending: Bool = true
    var onSort: ((String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(columns.prefix(4), id: \.self) { column in
                Button { onSort?(column) } label: {
                    HStack(spacing: 3) {
                        Text(column)
                            .font(Stanford.caption(11).weight(.semibold))
                            .foregroundStyle(sortColumn == column ? Stanford.lagunita : .secondary)
                            .lineLimit(1)
                        if sortColumn == column {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(Stanford.caption(8).weight(.bold))
                                .foregroundStyle(Stanford.lagunita)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onSort == nil)
                .help(onSort == nil ? "" : "Sort by \(column)")
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

struct WorkspaceAppStorageRecordRow: View {
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
