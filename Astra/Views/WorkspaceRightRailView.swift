import ASTRACore
import SwiftData
import SwiftUI
import ASTRAModels
import ASTRAPersistence

private let workspaceRightRailScrollCoordinateSpace = "workspaceRightRailScrollCoordinateSpace"

private enum RightRailScrollShadowEdge {
    case top
    case bottom
}

private struct RightRailScrollMetrics: Equatable {
    var contentMinY: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// Both edges are quantized here rather than in the view so the sink can
    /// store the two booleans instead of the continuous metrics. See the
    /// `onPreferenceChange` that reads them.
    var showsTopShadow: Bool { contentMinY < -2 }

    var showsBottomShadow: Bool {
        guard contentHeight > viewportHeight + 2 else { return false }
        return contentHeight + contentMinY > viewportHeight + 2
    }
}

private struct RightRailScrollMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = RightRailScrollMetrics()

    static func reduce(value: inout RightRailScrollMetrics, nextValue: () -> RightRailScrollMetrics) {
        value = nextValue()
    }
}

/// The inline editors a rail row can expand to; the expansion key for
/// `expandedWorkspaceSetupItems`.
private enum WorkspaceSetupItem: Hashable {
    case instructions
    case memory
    case folders
    case remoteAccess
    case routines

    var section: WorkspaceRailSectionPresentation.Section {
        switch self {
        case .instructions, .memory, .routines: .context
        case .folders, .remoteAccess: .environment
        }
    }
}

struct WorkspaceRightRailView: View {
    let workspace: Workspace
    var selectedTask: AgentTask?
    let onConfigure: () -> Void
    let onEditWorkspace: () -> Void
    var onNewSchedule: (() -> Void)?
    var onEditSchedule: ((TaskSchedule) -> Void)?
    var onManageCapabilities: (() -> Void)?
    var onOpenConfigureTab: ((ConfigureTab, UUID?) -> Void)?
    var onOpenCapabilityPackage: ((String) -> Void)?
    var onTaskCreated: ((AgentTask) -> Void)?
    var onOpenWorkspaceFile: ((String) -> Void)?
    /// Opens a task output in the shelf that renders its kind (HTML in the
    /// browser, tables in Query, everything else in Files).
    var onOpenGeneratedFile: ((String) -> Void)?
    var onNewSSHConnection: (() -> Void)?
    var onEditSSHConnection: ((SSHConnection) -> Void)?
    var sshReloadTrigger: Int = 0
    var isConfigurationPresented: Bool = false
    var isCompact = false
    var onDismiss: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]

    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]

    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var sshConnections: [SSHConnection] = []
    @State private var newMemoryText = ""
    @State private var isMemoryComposerVisible = false
    @State private var draftWorkspaceInstructions = ""
    @State private var draftWorkspaceInstructionsWorkspaceID: UUID?
    @State private var didRecentlySaveWorkspaceInstructions = false
    @State private var expandedWorkspaceSetupItems: Set<WorkspaceSetupItem> = []
    // Removing a configured folder or saved memory is destructive and was
    // previously one stray tap away with no undo — gate both behind a confirm.
    @State private var pendingRailDeletion: PendingRailDeletion?
    @State private var approvedCapabilityPackages: [PluginPackage] = PluginCatalog.builtInPackages
    @State private var approvedCapabilityRecords: [CapabilityApprovalRecord] = []
    @State private var approvedCapabilityPackPolicy = PackResolvedPolicy.empty
    @State private var approvedCapabilityRefreshID = UUID()
    @State private var capabilityRailSnapshotCache = CapabilityRailSnapshotCache()
    @State private var capabilityError: String?
    @State private var folderRefusal: String?
    @State private var prerequisiteScan = PrerequisiteScanSnapshot()
    private var capabilityPrerequisiteStatuses: [String: HealthStatus] { prerequisiteScan.statuses }
    @StateObject private var repairs = PluginRepairCoordinator()
    @StateObject private var gitViewModel = WorkspaceGitViewModel()
    @StateObject private var dockerViewModel = WorkspaceDockerViewModel()
    /// The selected task's file facts, read off the main actor from their
    /// persisted owner (runs' file changes and the task folder), as the task
    /// header does. Keyed by scope so a stale task never shows another's files.
    @State private var outputFilesCache: (scope: TaskAttachmentHistoryScope, files: TaskHeaderFilesReader.Facts)?
    @State private var isLoadingOutputs = false
    @State private var outputsRefreshTick = 0
    @State private var showsTopRailScrollShadow = false
    @State private var showsBottomRailScrollShadow = false
    /// Boxes the user collapsed in this workspace; every box starts expanded.
    @State private var collapsedBoxes: Set<WorkspaceRailSectionPresentation.Section> = []
    @State private var hasGitRepositories = false
    @State private var hasDockerEnvironments = false

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var capabilities: WorkspaceCapabilities {
        // Inject the catalog already cached in view state so `body`-path
        // capability resolution never re-scans the Capabilities directory.
        WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packageDefinitions: approvedCapabilityPackages,
            packPolicy: approvedCapabilityPackPolicy
        )
    }

    private var catalogPolicyContext: CapabilityCatalogPolicyContext {
        // Reads from the records cached in view state — see
        // refreshApprovedCapabilities — so policy resolution does not scan the
        // CapabilityApprovals directory on every body re-evaluation.
        CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: approvedCapabilityRecords,
            packPolicy: approvedCapabilityPackPolicy
        )
    }

    private var workspaceSkills: [Skill] {
        capabilities.workspaceSkills
    }

    private var enabledGlobalSkills: [Skill] {
        capabilities.enabledGlobalSkills
    }

    private var enabledGlobalConnectors: [Connector] {
        capabilities.enabledGlobalConnectors
    }

    private var templates: [TaskTemplate] {
        workspace.templates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if workspace.isLive { liveBody } else { Color.clear }
    }

    private var liveBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            overlayCloseBar

            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: contentListSpacing) {
                        configurePanel
                            .padding(.horizontal, contentPadding)
                            .padding(.top, isCompact ? 6 : 8)
                            .padding(.bottom, contentPadding)
                    }
                    .background {
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: RightRailScrollMetricsPreferenceKey.self,
                                value: RightRailScrollMetrics(
                                    contentMinY: contentProxy.frame(in: .named(workspaceRightRailScrollCoordinateSpace)).minY,
                                    contentHeight: contentProxy.size.height,
                                    viewportHeight: viewport.size.height
                                )
                            )
                        }
                    }
                }
                .coordinateSpace(name: workspaceRightRailScrollCoordinateSpace)
                // Quantize before storing. `metrics` moves on every scroll tick
                // and only these two booleans are ever read from it, so keeping
                // the raw value in `@State` invalidated this whole body — the
                // capability panels included — from a preference this body
                // publishes, on every tick. Writing only on a threshold
                // crossing removes the edge for the scroll itself; the shadows
                // are overlays, so the remaining crossing cannot resize the
                // content that produced the metrics.
                .onPreferenceChange(RightRailScrollMetricsPreferenceKey.self) { metrics in
                    if showsTopRailScrollShadow != metrics.showsTopShadow {
                        showsTopRailScrollShadow = metrics.showsTopShadow
                    }
                    if showsBottomRailScrollShadow != metrics.showsBottomShadow {
                        showsBottomRailScrollShadow = metrics.showsBottomShadow
                    }
                }
                .overlay(alignment: .top) {
                    rightRailScrollShadow(edge: .top)
                        .opacity(showsTopRailScrollShadow ? 1 : 0)
                }
                .overlay(alignment: .bottom) {
                    rightRailScrollShadow(edge: .bottom)
                        .opacity(showsBottomRailScrollShadow ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No background — system inspector material extends behind toolbar; custom fill creates a visible seam.
    }

    private var contentPadding: CGFloat {
        isCompact ? CapabilityRailLayout.compactContentPadding : CapabilityRailLayout.regularContentPadding
    }

    private var contentListSpacing: CGFloat {
        isCompact ? 8 : Stanford.railListSpacing
    }

    private var disclosureAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private func rightRailScrollShadow(edge: RightRailScrollShadowEdge) -> some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.11),
                Color.black.opacity(0.04),
                Color.clear
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: 18)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsTopRailScrollShadow)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsBottomRailScrollShadow)
    }

    // MARK: - Overlay close

    /// The rail has no header: the toolbar button names and toggles it, and
    /// the sidebar carries the workspace name. In overlay mode a thin bar
    /// keeps only the close control.
    @ViewBuilder
    private var overlayCloseBar: some View {
        if let onDismiss {
            HStack {
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Stanford.ui(10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Workspace Context")
                .accessibilityLabel("Close Workspace Context")
            }
            .padding(.top, 8)
            .padding(.horizontal, isCompact ? 14 : 12)
        }
    }

    // MARK: - Unified Configure Panel

    private var configurePanel: some View {
        let signature = capabilityRailSnapshotSignature
        let baseSnapshot = capabilityRailSnapshotCache.snapshot(for: signature) ?? .empty
        let permissionAwareItems = CapabilityRuntimePermissionAttention.applying(
            CapabilityRuntimePermissionAttention.pending(for: selectedTask),
            to: baseSnapshot.items,
            connectors: CapabilityRuntimePermissionAttention.ownershipConnectors(
                workspaceConnectors: capabilities.workspaceConnectors,
                availableGlobalConnectors: capabilities.availableGlobalConnectors
            )
        )
        let snapshot = CapabilityRailSnapshot(
            items: permissionAwareItems,
            isDraft: isDraftCapability
        )

        let boxes = railBoxes(snapshot)
        let capabilityItemsByID = Dictionary(
            snapshot.items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return railContent(boxes: boxes, capabilityItems: capabilityItemsByID)
        .tint(Stanford.lagunita)
        .modifier(WorkspaceRailEnvironmentLifecycle(
            git: gitViewModel, docker: dockerViewModel, workspace: workspace,
            selectedTask: selectedTask, hasGitRepositories: hasGitRepositories,
            hasDockerEnvironments: showsDockerEnvironment
        ))
        .onDisappear { repairs.cancelAll() }
        .onAppear {
            loadSSHConnections()
            refreshApprovedCapabilities()
            refreshCapabilityPrerequisiteStatuses()
            rebuildCapabilityRailSnapshot(for: capabilityRailSnapshotSignature)
            applyConfigureDefaults()
            checkGitRepositories()
            checkDockerEnvironments()
        }
        .task(id: signature) { rebuildCapabilityRailSnapshot(for: signature) }
        .task(id: outputsSignature) { await recomputeOutputFiles() }
        .onChange(of: workspace.resolvedWorkingPath) { _, _ in refreshCapabilityPrerequisiteStatuses() } // one checkout's repairs
        .onChange(of: isConfigurationPresented) { _, presented in
            if !presented { refreshCapabilityPrerequisiteStatuses() }
        }
        .rescansPrerequisitesOnActivation { refreshCapabilityPrerequisiteStatuses() } // CLI state changed outside ASTRA
        .onChange(of: workspace.primaryPath) {
            loadSSHConnections()
            checkGitRepositories()
            checkDockerEnvironments()
        }
        .onChange(of: workspace.id) {
            syncInstructionDraftFromWorkspace()
        }
        .onChange(of: workspace.instructions) { oldValue, newValue in
            guard !WorkspaceInstructionEditorPresentation.hasUnsavedChanges(
                localDraft: draftWorkspaceInstructions,
                persisted: oldValue,
                isSynced: isWorkspaceInstructionDraftSynced
            ) else { return }
            draftWorkspaceInstructions = newValue
            draftWorkspaceInstructionsWorkspaceID = workspace.id
            didRecentlySaveWorkspaceInstructions = false
        }
        .onChange(of: workspace.additionalPaths) {
            checkGitRepositories()
            checkDockerEnvironments()
        }
        .onChange(of: workspace.enabledPackIDs) {
            refreshApprovedCapabilities()
            rebuildCapabilityRailSnapshot(for: capabilityRailSnapshotSignature)
        }
        .onChange(of: workspace.activeExecutionEnvironmentJSON) {
            checkDockerEnvironments()
        }
        .onChange(of: sshReloadTrigger) {
            loadSSHConnections()
            if !sshConnections.isEmpty {
                expandDetail(.remoteAccess)
            }
        }
        // Approval state is cached into @State (see refreshApprovedCapabilities)
        // to keep it off the per-body filesystem path. Re-sync when an approval
        // is written from any surface (catalog/configure) while the rail stays
        // mounted, so policy visibility decisions never go stale.
        .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged)) { _ in
            DispatchQueue.main.async {
                refreshApprovedCapabilities()
            }
        }
        .alert("Capability could not be updated", isPresented: capabilityErrorBinding) {
            Button("OK", role: .cancel) { capabilityError = nil }
        } message: {
            Text(capabilityError ?? "")
        }
        .workspaceFolderRefusalAlert($folderRefusal)
    }

    /// The cards and boxes themselves; the panel's lifecycle modifiers hang
    /// off `configurePanel`.
    private func railContent(boxes: [Rail.Box], capabilityItems: [String: RailCapabilityItem]) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceRailSectionPresentation.Layout.boxSpacing) {
            ForEach(boxes, id: \.section) { box in
                railBox(box, capabilityItems: capabilityItems)
            }

            railAddChip(boxes)
        }
        .confirmationDialog(
            pendingRailDeletion?.title ?? "",
            isPresented: pendingRailDeletionBinding,
            titleVisibility: .visible,
            presenting: pendingRailDeletion
        ) { deletion in
            Button(deletion.confirmTitle, role: .destructive) {
                deletion.perform()
                pendingRailDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRailDeletion = nil
            }
        } message: { deletion in
            Text(deletion.message)
        }
    }

    private var pendingRailDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingRailDeletion != nil },
            set: { presented in if !presented { pendingRailDeletion = nil } }
        )
    }

    private var capabilityErrorBinding: Binding<Bool> {
        Binding(
            get: { capabilityError != nil },
            set: { if !$0 { capabilityError = nil } }
        )
    }

    private var floatingSectionFill: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.052)
            : Color.primary.opacity(0.035)
    }

    private var floatingSectionStroke: Color {
        Stanford.borderRest
    }

    // MARK: - Rail boxes

    private typealias Rail = WorkspaceRailSectionPresentation

    private var showsDockerEnvironment: Bool {
        WorkspaceRailEnvironmentLifecycle.needsContainerRows(
            workspaceHasContainers: hasDockerEnvironments, task: selectedTask
        )
    }

    private var environmentFacts: Rail.EnvironmentFacts {
        var facts = Rail.EnvironmentFacts(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths,
            remoteServerNames: sshConnections.map { $0.name.isEmpty ? $0.host : $0.name }
        )
        if hasGitRepositories, gitViewModel.selectedRepository != nil {
            facts.repositoryName = gitViewModel.selectedRepositoryName
            facts.repositoryPath = gitViewModel.selectedRepositoryFullPath
            facts.hasMultipleRepositories = gitViewModel.repositories.count > 1
            let branch = gitViewModel.currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            facts.branch = branch.isEmpty || branch == "unknown" ? nil : branch
            facts.changedFileCount = gitViewModel.statusFiles.count
            facts.aheadCount = gitViewModel.pushableCommitCount
            facts.behindCount = gitViewModel.behind
            facts.openPullRequestLabel = gitViewModel.openPullRequest.map {
                "#\($0.number)" + ($0.isDraft ? " · draft" : "")
            }
        }
        if showsDockerEnvironment, dockerViewModel.selectedEnvironment.isContainerized {
            facts.executionEnvironment = .container(name: dockerViewModel.selectedEnvironment.displayName)
        }
        return facts
    }

    private var contextFacts: Rail.ContextFacts {
        Rail.ContextFacts(
            instructions: workspace.instructions,
            memoryCount: workspace.memories.count,
            routineTitles: workspace.schedules.sorted { $0.name < $1.name }.map(\.name)
        )
    }

    private func capabilityFacts(_ items: [RailCapabilityItem]) -> [Rail.CapabilityFacts] {
        items.map { item in
            Rail.CapabilityFacts(
                id: item.id,
                name: capabilityDisplayName(item.name),
                isBlocked: item.readiness.level == .needsAttention,
                blockedVerb: item.repair?.verb,
                isDraft: isDraftCapability(item)
            )
        }
    }

    /// The boxes the rail renders, in the model's fixed order.
    private func railBoxes(_ snapshot: CapabilityRailSnapshot) -> [Rail.Box] {
        Rail.boxes(
            environment: environmentFacts,
            context: contextFacts,
            capabilities: capabilityFacts(snapshot.items),
            outputs: outputFacts
        )
    }

    // MARK: Outputs

    /// What the selected task produced: its file facts minus the inputs the
    /// user attached and any folder, newest first as the reader lists them.
    private var outputFacts: Rail.OutputFacts {
        guard let selectedTask,
              let cache = outputFilesCache,
              cache.scope == TaskAttachmentHistoryScope(task: selectedTask) else {
            return Rail.OutputFacts()
        }
        return WorkspaceRailOutputPresentation.facts(from: cache.files)
    }

    private var outputsSignature: WorkspaceRailOutputPresentation.ReadKey {
        .init(task: selectedTask, refreshTick: outputsRefreshTick)
    }

    private func recomputeOutputFiles() async {
        guard let task = selectedTask else {
            outputFilesCache = nil
            return
        }
        let inputs = task.inputs
        let access = TaskWorkspaceAccess(task: task)
        let taskFolder = access.taskFolder
        let workspacePath = access.effectiveWorkspacePath
        let scope = TaskAttachmentHistoryScope(task: task)
        let container = modelContext.container
        isLoadingOutputs = true
        defer { isLoadingOutputs = false }
        let read = Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try TaskHeaderFilesReader.facts(
                scope: scope, inputs: inputs, taskFolder: taskFolder,
                workspacePath: workspacePath, modelContext: context
            )
        }
        do {
            let items = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
            guard !Task.isCancelled, let current = selectedTask, scope == TaskAttachmentHistoryScope(task: current) else { return }
            outputFilesCache = (scope, items)
        } catch is CancellationError {
            return
        } catch {
            AppLogger.error("Task outputs could not be read: \(error.localizedDescription)", category: "UI")
        }
    }

    private func openOutput(_ path: String) {
        (onOpenGeneratedFile ?? onOpenWorkspaceFile)?(path)
    }

    private func railBox(_ box: Rail.Box, capabilityItems: [String: RailCapabilityItem]) -> some View {
        let isExpanded = isBoxExpanded(box)
        return railBoxSection {
            VStack(alignment: .leading, spacing: 0) {
                RailBoxHeader(
                    title: box.title,
                    isExpanded: isExpanded,
                    collapsedSummary: box.collapsedSummary,
                    addActions: availableAddActions(box.addActions),
                    isBusy: boxIsBusy(box.section),
                    onRefresh: boxRefreshAction(box.section),
                    onToggle: { toggleBox(box.section) },
                    onAdd: { perform($0) }
                )

                if isExpanded {
                    if box.section == .environment {
                        environmentRows(box)
                    } else {
                        ForEach(box.rows) { row in
                            railRow(row, capabilityItems: capabilityItems)
                        }
                    }
                    if box.section == .context,
                       isMemoryComposerVisible,
                       !box.rows.contains(where: { $0.kind == .memory }) {
                        firstMemoryComposerRow
                    }
                }
            }
        }
    }

    /// Where it is (folders, remote), where it runs (the container rows, or a
    /// plain `Local`), then source control, whose verbs footer closes the box.
    /// The model's repository, branch and pull-request rows are rendered by
    /// the git row group, which owns their pickers and sheets.
    @ViewBuilder
    private func environmentRows(_ box: Rail.Box) -> some View {
        folderRows(box.rows)
        ForEach(box.rows.filter { $0.kind != .folder }) { row in
            switch row.kind {
            case .folder:
                EmptyView()
            case .remote:
                detailRow(row, item: .remoteAccess) { remoteAccessSetupDetails }
            case .runsIn:
                if !showsDockerEnvironment {
                    RailKeyValueRow(row: row)
                }
            case .repository, .branch, .pullRequest, .instructions, .memory, .routines, .capability, .output, .outputsOverflow:
                EmptyView()
            }
        }

        if showsDockerEnvironment {
            WorkspaceDockerSectionView(
                viewModel: dockerViewModel,
                workspace: workspace,
                selectedTask: selectedTask,
                isCompact: isCompact
            )
        }

        if hasGitRepositories {
            WorkspaceGitSectionView(
                viewModel: gitViewModel,
                workspace: workspace,
                selectedTask: selectedTask,
                isCompact: isCompact,
                onTaskCreated: onTaskCreated,
                onOpenWorkspaceFile: onOpenWorkspaceFile
            )
        }
    }

    private var environmentIsRefreshing: Bool {
        (hasGitRepositories && gitViewModel.isSyncing) || (showsDockerEnvironment && dockerViewModel.isRefreshing)
    }

    private func boxIsBusy(_ section: Rail.Section) -> Bool {
        switch section {
        case .environment: environmentIsRefreshing
        case .outputs: isLoadingOutputs
        case .context, .capabilities: false
        }
    }

    /// Boxes whose facts come from scans carry a refresh control; the others'
    /// facts are the workspace's own and stay current by themselves.
    private func boxRefreshAction(_ section: Rail.Section) -> (() -> Void)? {
        switch section {
        case .environment: return environmentRefreshAction
        case .outputs: return { outputsRefreshTick += 1 }
        case .context, .capabilities: return nil
        }
    }

    /// Re-reads the facts that come from scans; nil when the box holds only
    /// folders, which the workspace itself keeps current.
    private var environmentRefreshAction: (() -> Void)? {
        guard hasGitRepositories || showsDockerEnvironment else { return nil }
        return {
            Task {
                if hasGitRepositories { await gitViewModel.scanRepositories() }
                if showsDockerEnvironment { await dockerViewModel.refresh() }
            }
        }
    }

    private func railBoxSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.railCompactCardCornerRadius, style: .continuous)
        return content()
            .padding(.top, Rail.Layout.boxPaddingTop)
            .padding(.horizontal, Rail.Layout.boxPaddingHorizontal)
            .padding(.bottom, Rail.Layout.boxPaddingBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(floatingSectionFill))
            .overlay { shape.stroke(floatingSectionStroke, lineWidth: 1) }
    }

    @ViewBuilder
    private func railRow(_ row: Rail.Row, capabilityItems: [String: RailCapabilityItem]) -> some View {
        switch row.kind {
        case .capability(let id):
            if let item = capabilityItems[id] {
                capabilityRailRow(item)
            }
        case .folder:
            RailKeyValueRow(row: row)
        case .remote:
            detailRow(row, item: .remoteAccess) { remoteAccessSetupDetails }
        case .instructions:
            detailRow(row, item: .instructions, onAction: { expandDetail(.instructions) }) { instructionsSetupDetails }
        case .memory:
            detailRow(row, item: .memory) { memorySetupDetails }
        case .routines:
            detailRow(row, item: .routines) { routinesSetupDetails }
        case .output(let path):
            RailKeyValueRow(row: row, help: path, onTap: { openOutput(path) })
        case .outputsOverflow(_, let firstHiddenPath):
            RailKeyValueRow(row: row, help: "Open the Files shelf", onTap: { onOpenWorkspaceFile?(firstHiddenPath) })
        case .repository, .branch, .runsIn, .pullRequest:
            RailKeyValueRow(row: row)
        }
    }

    /// A key/value row that expands in place to one of the inline editors.
    private func detailRow<Details: View>(
        _ row: Rail.Row,
        item: WorkspaceSetupItem,
        onAction: (() -> Void)? = nil,
        @ViewBuilder details: () -> Details
    ) -> some View {
        let isExpanded = expandedWorkspaceSetupItems.contains(item)
        return VStack(alignment: .leading, spacing: isExpanded ? 6 : 0) {
            RailKeyValueRow(
                row: row,
                isExpanded: isExpanded,
                help: rowHelp(row),
                onTap: { toggleWorkspaceSetupItem(item) },
                onAction: onAction ?? { toggleWorkspaceSetupItem(item) }
            )
            if isExpanded {
                details()
                    .padding(.leading, Self.detailLeadingPadding)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
            }
        }
    }

    private static var detailLeadingPadding: CGFloat {
        Rail.Layout.leadingIconFrame + 8 + 6
    }

    private func rowHelp(_ row: Rail.Row) -> String? { row.representedPath }

    private func folderRows(_ rows: [Rail.Row]) -> some View {
        RailFolderRows(
            rows: rows.filter { $0.kind == .folder },
            isExpanded: expandedWorkspaceSetupItems.contains(.folders),
            onToggle: { toggleWorkspaceSetupItem(.folders) }
        ) { foldersSetupDetails }
    }

    /// The first memory is composed under a transient Memory row, since the
    /// row itself appears only once a memory exists.
    private var firstMemoryComposerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            RailKeyValueRow(row: Rail.Row(kind: .memory, systemImage: "text.badge.checkmark", title: "Memory"))
            memoryComposer
                .padding(.leading, Self.detailLeadingPadding)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
        }
    }

    private func capabilityRailRow(_ item: RailCapabilityItem) -> some View {
        let repairPhase = item.repair.flatMap { repairs.phase(for: $0, owner: item.id) }
        let isBlocked = item.readiness.level == .needsAttention && !isDraftCapability(item)
        // The repair verb is the whole signal for a blocked capability; one
        // without a repair of its own opens its details under "Set up".
        let repairVerb: String? = isBlocked ? (item.repair?.verb ?? Rail.defaultBlockedVerb) : nil

        return CapabilityRailRow(
            icon: WorkspaceContextIconography.capabilityIcon(name: item.name, fallback: item.icon),
            brand: item.brand,
            title: capabilityDisplayName(item.name),
            subtitle: capabilityListSubtitle(for: item),
            readiness: item.readiness,
            statusLabel: capabilityBadgeTitle(for: item),
            isEnabled: item.isEnabled,
            isCompact: isCompact,
            repairVerb: repairVerb,
            repairGuidance: CapabilityRailRow.repairGuidance(for: item.repair),
            repairStatus: item.repair.flatMap { repairs.statusText(for: $0, owner: item.id) },
            repairIsChecking: repairPhase == .waiting,
            onRepair: {
                if let repair = item.repair {
                    repairs.start(repair, owner: item.id) { refreshCapabilityPrerequisiteStatuses() }
                } else {
                    openCapabilityConfiguration(item)
                }
            },
            contextualRepair: contextualRepair(for: item),
            onOpen: { openCapabilityConfiguration(item) }
        )
        .id(CapabilityRailRepair.confirmationIdentity(for: item.repair, owner: item.id))
    }

    // MARK: Box disclosure

    private func isBoxExpanded(_ box: Rail.Box) -> Bool {
        box.forcesExpansion || !collapsedBoxes.contains(box.section)
    }

    private func toggleBox(_ section: Rail.Section) {
        withAnimation(disclosureAnimation) {
            if collapsedBoxes.contains(section) {
                collapsedBoxes.remove(section)
            } else {
                collapsedBoxes.insert(section)
            }
        }
        RailDisclosureStore.setBool(
            !collapsedBoxes.contains(section),
            workspaceDisclosureID,
            Self.disclosureToggle(for: section)
        )
    }

    private static func disclosureToggle(for section: Rail.Section) -> RailDisclosureStore.Toggle {
        switch section {
        case .environment: .environmentExpanded
        case .context: .contextExpanded
        case .capabilities: .capabilitiesExpanded
        case .outputs: .outputsExpanded
        }
    }

    /// Opens an inline editor, and the box that holds it.
    private func expandDetail(_ item: WorkspaceSetupItem) {
        withAnimation(disclosureAnimation) {
            collapsedBoxes.remove(item.section)
            _ = expandedWorkspaceSetupItems.insert(item)
        }
    }

    // MARK: Adds

    private func availableAddActions(_ actions: [Rail.AddAction]) -> [Rail.AddAction] {
        actions.filter { addHandler(for: $0) != nil }
    }

    private func perform(_ action: Rail.AddAction) {
        addHandler(for: action)?()
    }

    /// `runInContainer` has no handler until the Environment box absorbs the
    /// Container card, so it is left out of every menu.
    private func addHandler(for action: Rail.AddAction) -> (() -> Void)? {
        switch action {
        case .addCapability:
            return onManageCapabilities
        case .addMemory:
            return { showMemoryComposer() }
        case .newRoutine:
            return onNewSchedule
        case .addFolder:
            return {
                expandDetail(.folders)
                addExtraFolder()
            }
        case .connectServer:
            return onNewSSHConnection
        case .runInContainer:
            return nil
        }
    }

    private func showMemoryComposer() {
        expandDetail(.memory)
        isMemoryComposerVisible = true
    }

    /// The rail-level `Add…`: absent boxes' adds first, then the present
    /// boxes' adds, so the first capability is one tap away with no box.
    @ViewBuilder
    private func railAddChip(_ boxes: [Rail.Box]) -> some View {
        let actions = availableAddActions(Rail.railAddActions(for: boxes))
        if !actions.isEmpty {
            HStack {
                RailAddMenuButton(actions: actions, style: .chip, onAdd: perform)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
    }

    private func isDraftCapability(_ item: RailCapabilityItem) -> Bool {
        item.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("New Skill") == .orderedSame
    }

    private func capabilityDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveCompare("New Skill") == .orderedSame {
            return "Untitled Capability"
        }
        return trimmed
            .replacingOccurrences(of: " (Restored)", with: "")
            .replacingOccurrences(of: "(Restored)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A passive trailing label. Blocked state is carried by the repair
    /// button, never by a label, so only drafts and restored items get one.
    private func capabilityBadgeTitle(for item: RailCapabilityItem) -> String? {
        if item.name.localizedCaseInsensitiveContains("(Restored)") {
            return "Restored"
        }
        if isDraftCapability(item) {
            return Rail.draftLabel
        }
        return nil
    }

    private func capabilityListSubtitle(for item: RailCapabilityItem) -> String {
        if item.runtimePermissionAttention != nil {
            return item.presentation.rowSubtitle
        }
        let source = isWorkspaceAuthoredCapability(item) ? "Custom" : "Built-in"
        let composition = WorkspaceRightRailPresentation.compositionSummary(for: item)
        return "\(source): \(composition)"
    }

    private func isWorkspaceAuthoredCapability(_ item: RailCapabilityItem) -> Bool {
        switch item.source {
        case .package(let package):
            let kind = package.sourceMetadata?.kind
            return kind == "workspace" || kind == "shared"
        case .skill:
            return true
        }
    }

    private var capabilityRailSnapshotSignature: CapabilityRailSnapshotSignature {
        CapabilityRailSnapshotSignature(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packages: approvedCapabilityPackages,
            approvalRecords: approvedCapabilityRecords,
            packPolicy: approvedCapabilityPackPolicy,
            prerequisiteStatuses: capabilityPrerequisiteStatuses
        )
    }

    private var capabilityRailTelemetryFields: [String: String] {
        [
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(workspace.id),
            "package_count": PerformanceTelemetryFields.count(approvedCapabilityPackages.count)
        ]
    }

    private func rebuildCapabilityRailSnapshot(for signature: CapabilityRailSnapshotSignature) {
        guard signature == capabilityRailSnapshotSignature else { return }
        guard !capabilityRailSnapshotCache.matches(signature) else { return }

        let snapshot = PerformanceTelemetry.measure(
            "right_rail_capability_snapshot",
            thresholdMilliseconds: 20,
            fields: capabilityRailTelemetryFields.merging(["cache_state": "miss"], uniquingKeysWith: { _, new in new })
        ) {
            makeCapabilityRailSnapshot()
        }
        capabilityRailSnapshotCache.store(snapshot, for: signature)
    }

    private func makeCapabilityRailSnapshot() -> CapabilityRailSnapshot {
        let telemetryFields = capabilityRailTelemetryFields
        let currentCapabilities = capabilities
        let resourceIndex = PerformanceTelemetry.measure(
            "right_rail_capability_resources",
            thresholdMilliseconds: 20,
            fields: telemetryFields
        ) {
            CapabilityRailWorkspaceResourceIndex(
                workspace: workspace,
                capabilities: currentCapabilities
            )
        }
        var cachedStates: [String: CapabilityRailPackageSnapshotState] = [:]

        func state(for package: PluginPackage) -> CapabilityRailPackageSnapshotState {
            if let cached = cachedStates[package.id] {
                return cached
            }
            let state = PerformanceTelemetry.measure(
                "right_rail_capability_package",
                thresholdMilliseconds: 20,
                fields: telemetryFields.merging(["package_id": package.id], uniquingKeysWith: { _, new in new })
            ) {
                CapabilityRailPackageSnapshotState(
                    package: package,
                    index: resourceIndex
                )
            }
            cachedStates[package.id] = state
            return state
        }

        let catalogPackages = PerformanceTelemetry.measure(
            "right_rail_capability_catalog",
            thresholdMilliseconds: 20,
            fields: telemetryFields
        ) {
            CapabilityCatalogInventory.packages(
                catalogPackages: approvedCapabilityPackages,
                capabilities: currentCapabilities,
                policyContext: catalogPolicyContext
            )
        }

        let items = PerformanceTelemetry.measure(
            "right_rail_capability_items",
            thresholdMilliseconds: 20,
            fields: telemetryFields,
            resultFields: { ["item_count": PerformanceTelemetryFields.count($0.count)] }
        ) {
            catalogPackages
                .compactMap { package -> RailCapabilityItem? in
                    let packageState = state(for: package)
                    guard packageState.isEnabled else { return nil }
                    return makePackageCapabilityItem(
                        package,
                        state: packageState,
                        prerequisiteStatuses: capabilityPrerequisiteStatuses
                    )
                }
                .sorted(by: sortRailCapabilityItems)
        }

        return CapabilityRailSnapshot(
            items: items,
            isDraft: isDraftCapability
        )
    }

    private func sortRailCapabilityItems(_ lhs: RailCapabilityItem, _ rhs: RailCapabilityItem) -> Bool {
        let lhsNeedsSetup = lhs.readiness.level == .needsAttention
        let rhsNeedsSetup = rhs.readiness.level == .needsAttention
        if lhsNeedsSetup != rhsNeedsSetup { return lhsNeedsSetup && !rhsNeedsSetup }

        let lhsPriority = railCapabilityPriority(lhs)
        let rhsPriority = railCapabilityPriority(rhs)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func contextualRepair(for item: RailCapabilityItem) -> AnyView? {
        guard case .package(let package) = item.source,
              CapabilityRailRepair.needsRepositoryAccessRepair(for: package, statuses: capabilityPrerequisiteStatuses)
        else { return nil }
        return AnyView(GitHubRepositoryAccessRepairButton(workingDirectory: workspace.resolvedWorkingPath) {
            refreshCapabilityPrerequisiteStatuses()
        })
    }

    private func railCapabilityPriority(_ item: RailCapabilityItem) -> Int {
        let normalizedID: String? = {
            if case .package(let package) = item.source {
                return package.id.lowercased()
            }
            return nil
        }()
        let normalizedName = item.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        if normalizedID == "jira-workflow" || normalizedName.contains("jira") { return 0 }
        if normalizedID == "github-workflow" || normalizedName.contains("github") { return 1 }
        if normalizedID == "gcloud-workflow" || normalizedName.contains("google-cloud") || normalizedName.contains("gcloud") { return 2 }
        if normalizedName.contains("claude") { return 3 }
        if normalizedID == "redcap-workflow" || normalizedName.contains("redcap") { return 4 }
        if normalizedName.contains("bigquery") { return 5 }
        return 100
    }

    private func makePackageCapabilityItem(
        _ package: PluginPackage,
        state: CapabilityRailPackageSnapshotState,
        prerequisiteStatuses: [String: HealthStatus]
    ) -> RailCapabilityItem {
        let packageSummary = CapabilityPackageResourceSummary(package: package)
        let sharedResourceCount = state.linkedSkills.filter(\.isGlobal).count
            + state.linkedConnectors.filter(\.isGlobal).count
            + state.linkedTools.filter(\.isGlobal).count
        let workspaceResourceCount = state.linkedSkills.filter { !$0.isGlobal }.count
            + state.linkedConnectors.filter { !$0.isGlobal }.count
            + state.linkedTools.filter { !$0.isGlobal }.count
        let readiness = CapabilityRailRepair.readiness(
            for: package, stateReadiness: state.readiness, prerequisiteStatuses: prerequisiteStatuses
        )
        let presentation = CapabilityRailPackagePresentation.make(
            isEnabled: state.isEnabled,
            readinessLevel: readiness.level,
            workspaceName: workspace.name,
            sharedResourceCount: sharedResourceCount,
            workspaceResourceCount: workspaceResourceCount,
            declaredResourceCount: packageSummary.declaredResourceCount,
            contentSummary: packageSummary.contentSummary(separator: ", ")
        )

        return RailCapabilityItem(
            id: "package:\(package.id)",
            name: package.name,
            icon: package.icon,
            summary: package.description.isEmpty ? package.contentSummary : package.description,
            color: Stanford.lagunita,
            isEnabled: state.isEnabled,
            readiness: readiness,
            presentation: presentation,
            source: .package(package),
            skillNames: RailStringList.uniqueSorted(package.skills.map(\.name) + state.linkedSkills.map(\.name)),
            connectorNames: RailStringList.uniqueSorted(package.connectors.map(\.name) + state.linkedConnectors.map { $0.name.isEmpty ? "Untitled Connector" : $0.name }),
            toolNames: RailStringList.uniqueSorted(package.localTools.map(\.name) + state.linkedTools.map { $0.name.isEmpty ? "Untitled Tool" : $0.name }),
            mcpServerNames: packageSummary.mcpServerNames,
            browserAdapterNames: RailStringList.uniqueSorted(package.browserAdapters.map(browserAdapterDisplayName)),
            templateNames: RailStringList.uniqueSorted(package.templates.map(\.name)),
            requirementNames: RailStringList.uniqueSorted(package.prerequisites.map(\.displayName)),
            repair: CapabilityRailRepair.repair(for: package, statuses: prerequisiteStatuses)
        )
    }

    private func linkedConnectors(for package: PluginPackage, linkedSkills: [Skill]) -> [Connector] {
        let packageNames = Set(package.connectors.map(\.name))
        let active = capabilities.activeConnectors.filter { packageNames.contains($0.name) }
        return uniqueConnectors(active + linkedSkills.flatMap(\.connectors))
    }

    private func linkedTools(for package: PluginPackage, linkedSkills: [Skill]) -> [LocalTool] {
        let packageNames = Set(package.localTools.map(\.name))
        let active = capabilities.activeTools.filter { packageNames.contains($0.name) }
        return uniqueTools(active + linkedSkills.flatMap(\.localTools))
    }

    private func openCapabilityConfiguration(_ item: RailCapabilityItem) {
        switch item.source {
        case .package(let package):
            if item.readiness.level == .needsAttention,
               let onOpenConfigureTab {
                let state = CapabilityPackageState(
                    package: package,
                    workspace: workspace,
                    capabilities: capabilities
                )
                let connectors = state.connectorsNeedingAttention
                if item.readiness == state.readiness, connectors.count == 1 {
                    onOpenConfigureTab(.connectors, connectors[0].id)
                    return
                }
            }
            if let onOpenCapabilityPackage {
                onOpenCapabilityPackage(package.id)
            } else {
                onOpenConfigureTab?(.capabilities, nil)
            }
        case .skill(let skill):
            onOpenConfigureTab?(.skills, skill.id)
        }
    }

    private func refreshApprovedCapabilities() {
        let refreshID = UUID()
        let enabledPackIDs = workspace.enabledPackIDs
        approvedCapabilityRefreshID = refreshID

        Task { @MainActor in
            let snapshot = await Task.detached(priority: .userInitiated) {
                PerformanceTelemetry.measure(
                    "right_rail_capability_load",
                    thresholdMilliseconds: 20
                ) {
                    ApprovedCapabilitiesSnapshot(
                        packages: CapabilityLibrary().installedPackages(),
                        records: CapabilityApprovalStore().records(),
                        packPolicy: PackWorkspacePolicyProvider.resolvedPolicy(enabledPackIDs: enabledPackIDs)
                    )
                }
            }.value

            guard !Task.isCancelled, approvedCapabilityRefreshID == refreshID else { return }
            let refreshPlan = WorkspaceRightRailApprovedCapabilityRefreshPlan.make(
                previousPackageIDs: approvedCapabilityPackages.map(\.id),
                nextPackageIDs: snapshot.packages.map(\.id),
                previousApprovalRecords: approvedCapabilityRecords,
                nextApprovalRecords: snapshot.records,
                previousPolicy: approvedCapabilityPackPolicy,
                nextPolicy: snapshot.packPolicy
            )
            approvedCapabilityPackages = snapshot.packages.isEmpty ? PluginCatalog.builtInPackages : snapshot.packages
            approvedCapabilityRecords = snapshot.records
            approvedCapabilityPackPolicy = snapshot.packPolicy
            if refreshPlan.shouldRefreshPrerequisites {
                refreshCapabilityPrerequisiteStatuses()
            }
            if refreshPlan.shouldRebuildSnapshot {
                rebuildCapabilityRailSnapshot(for: capabilityRailSnapshotSignature)
            }
        }
    }

    private func refreshCapabilityPrerequisiteStatuses() {
        let currentCapabilities = capabilities
        let packages = approvedCapabilityPackages.filter { package in
            guard !package.prerequisites.isEmpty else { return false }
            return CapabilityPackageState(
                package: package,
                workspace: workspace,
                capabilities: currentCapabilities
            ).isEnabled
        }
        let generation = prerequisiteScan.begin()
        Task { @MainActor in
            let cache = PreflightCache()
            var statuses: [String: HealthStatus] = [:]
            for package in packages {
                let packageStatuses = await CapabilityHealthService.prerequisiteStatuses(
                    for: package,
                    cache: cache,
                    workingDirectory: workspace.resolvedWorkingPath
                )
                statuses.merge(packageStatuses) { _, new in new }
            }
            prerequisiteScan.complete(statuses, generation: generation)
        }
    }

    private func browserAdapterDisplayName(_ adapter: String) -> String {
        switch BrowserSiteAdapterID.normalized(adapter) {
        case BrowserSiteAdapterID.googleDrive:
            return "Google Drive browser"
        case BrowserSiteAdapterID.github:
            return "GitHub browser"
        case .some(let normalized):
            return normalized
        case .none:
            return adapter.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func toggleWorkspaceSetupItem(_ item: WorkspaceSetupItem) {
        withAnimation(disclosureAnimation) {
            if expandedWorkspaceSetupItems.contains(item) {
                expandedWorkspaceSetupItems.remove(item)
            } else {
                expandedWorkspaceSetupItems.insert(item)
            }
        }
    }

    private var instructionsSetupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if effectiveDraftWorkspaceInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add guidance for how tasks in this workspace should run...")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }

                TextEditor(text: draftWorkspaceInstructionsBinding)
                    .font(Stanford.caption(12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 78, maxHeight: 140)
                    .padding(5)
            }
            .background(setupInlineControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                    .stroke(Stanford.borderRest, lineWidth: 1)
            )

            HStack(spacing: 8) {
                let hasUnsavedChanges = hasUnsavedWorkspaceInstructions

                Text(WorkspaceInstructionEditorPresentation.includedInPromptHint)
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let statusTitle = workspaceInstructionStatusTitle {
                    Text(statusTitle)
                        .font(Stanford.caption(10).weight(.medium))
                        .foregroundStyle(hasUnsavedChanges ? Stanford.poppy : Stanford.paloAltoGreen)
                        .lineLimit(1)
                }

                Button {
                    saveWorkspaceInstructions()
                } label: {
                    Text(WorkspaceInstructionEditorPresentation.saveActionTitle)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(hasUnsavedChanges ? Stanford.lagunita : Stanford.sandstone)
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges)
                .help(hasUnsavedChanges ? "Save workspace instructions" : "Workspace instructions are saved")
                .accessibilityLabel("Save workspace instructions")

                if shouldShowClearWorkspaceInstructionsAction {
                    Button {
                        clearDraftWorkspaceInstructions()
                    } label: {
                        Text(WorkspaceInstructionEditorPresentation.clearActionTitle)
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear instruction draft")
                }
            }
        }
    }

    private var memorySetupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.memories.isEmpty {
                setupEmptyDetail("No saved memory details yet.")
            } else {
                ForEach(Array(workspace.memories.indices), id: \.self) { index in
                    editableMemoryRow(index)
                }
            }

            if isMemoryComposerVisible {
                memoryComposer
                    .padding(.top, 2)
            }
        }
    }

    private var foldersSetupDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            let isWorkspaceRootMissing = WorkspaceFolderPresentation
                .shouldShowWorkspaceRootMissingMessage(primaryPath: workspace.primaryPath)
            let rootDescriptor = WorkspacePathPresentation.descriptors(
                primaryPath: workspace.primaryPath,
                additionalPaths: []
            ).first
            let additionalDescriptors = WorkspaceFolderPresentation
                .userConfiguredFolderDescriptors(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                )

            if isWorkspaceRootMissing {
                setupEmptyDetail(WorkspaceFolderPresentation.missingWorkspaceRootSubtitle)
            }

            if !isWorkspaceRootMissing, let rootDescriptor {
                setupFolderRow(
                    WorkspaceFolderPresentation.folderDetailRow(for: rootDescriptor),
                    removeAction: nil
                )
            }

            ForEach(additionalDescriptors) { descriptor in
                setupFolderRow(
                    WorkspaceFolderPresentation.folderDetailRow(for: descriptor),
                    removeAction: { removeAdditionalPaths(matching: descriptor.path) }
                )
            }

            Button {
                addExtraFolder()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(Stanford.ui(10, weight: .semibold))
                    Text(WorkspaceFolderPresentation.addFolderActionTitle)
                        .font(Stanford.caption(11).weight(.medium))
                }
                .foregroundStyle(Stanford.lagunita)
            }
            .buttonStyle(.plain)
        }
    }

    private var remoteAccessSetupDetails: some View {
        let limit = WorkspaceRightRailPresentation.detailPreviewLimit
        let visibleConnections = Array(sshConnections.prefix(limit))

        return VStack(alignment: .leading, spacing: 7) {
            if visibleConnections.isEmpty {
                setupEmptyDetail("No remote servers configured.")
            } else {
                ForEach(visibleConnections) { connection in
                    setupDetailItem(
                        title: connection.name.isEmpty ? connection.host : connection.name,
                        detail: remoteConnectionDetail(connection),
                        isMonospaced: true,
                        lineLimit: 1
                    )
                    .help(remoteConnectionDetail(connection))
                }

                setupOverflowDetail(
                    total: sshConnections.count,
                    visible: visibleConnections.count,
                    singular: "remote server",
                    plural: "remote servers"
                )
            }
        }
    }

    private var routinesSetupDetails: some View {
        let sortedSchedules = workspace.schedules.sorted { $0.name < $1.name }
        let limit = WorkspaceRightRailPresentation.detailPreviewLimit
        let visibleSchedules = Array(sortedSchedules.prefix(limit))

        return VStack(alignment: .leading, spacing: 7) {
            if visibleSchedules.isEmpty {
                setupEmptyDetail("No routines configured.")
            } else {
                ForEach(visibleSchedules) { schedule in
                    setupDetailItem(
                        title: schedule.name,
                        detail: "\(schedule.frequencySummary) - \(schedule.isEnabled ? "Enabled" : "Paused")",
                        lineLimit: 1
                    )
                }

                setupOverflowDetail(
                    total: sortedSchedules.count,
                    visible: visibleSchedules.count,
                    singular: "routine",
                    plural: "routines"
                )
            }
        }
    }

    private func remoteConnectionDetail(_ connection: SSHConnection) -> String {
        let target = "\(connection.user)@\(connection.host):\(connection.port)"
        let remotePath = connection.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return remotePath.isEmpty ? target : "\(target)  \(remotePath)"
    }

    private var draftWorkspaceInstructionsBinding: Binding<String> {
        Binding(
            get: { effectiveDraftWorkspaceInstructions },
            set: { value in
                draftWorkspaceInstructions = value
                draftWorkspaceInstructionsWorkspaceID = workspace.id
                didRecentlySaveWorkspaceInstructions = false
            }
        )
    }

    private func memoryBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard workspace.memories.indices.contains(index) else { return "" }
                return workspace.memories[index]
            },
            set: { value in
                guard workspace.memories.indices.contains(index) else { return }
                workspace.memories[index] = value
                markWorkspaceConfigurationChanged()
            }
        )
    }

    private func editableMemoryRow(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            TextField("Saved detail", text: memoryBinding(at: index), axis: .vertical)
                .font(Stanford.caption(12))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(setupInlineControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                        .stroke(Stanford.borderRest, lineWidth: 1)
                )

            Button {
                requestMemoryDeletion(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 24)
            }
            .buttonStyle(.plain)
            .help("Remove memory")
        }
    }

    private func setupFolderRow(
        _ row: WorkspaceFolderDetailRowPresentation,
        removeAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.title)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(row.subtitle)
                        .font(Stanford.caption(9).weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if row.showsPathInBody {
                    Text(compactPath(row.path))
                        .font(Stanford.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            .help(row.path)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(Stanford.ui(10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .help(row.copyPathHelp)

            if row.canRemove, let removeAction {
                Button {
                    pendingRailDeletion = PendingRailDeletion(
                        title: "Remove folder?",
                        message: "\(compactPath(row.path)) will no longer be available to the agent. The folder itself is not deleted.",
                        confirmTitle: "Remove",
                        perform: removeAction
                    )
                } label: {
                    Image(systemName: "trash")
                        .font(Stanford.ui(11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
                .help("Remove folder")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(setupInlineControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous))
    }

    private func setupDetailItem(
        title: String,
        detail: String,
        isMonospaced: Bool = false,
        lineLimit: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(detail)
                .font(isMonospaced ? Stanford.mono(10) : Stanford.caption(11))
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .truncationMode(isMonospaced ? .middle : .tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setupEmptyDetail(_ text: String) -> some View {
        Text(text)
            .font(Stanford.caption(11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupInlineControlBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035)
    }

    @ViewBuilder
    private func setupOverflowDetail(
        total: Int,
        visible: Int,
        singular: String,
        plural: String
    ) -> some View {
        if let summary = WorkspaceRightRailPresentation.overflowSummary(
            total: total,
            visible: visible,
            singular: singular,
            plural: plural
        ) {
            Text(summary)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
        }
    }

    private func markWorkspaceConfigurationChanged() {
        workspace.updatedAt = Date()
        WorkspacePersistenceCoordinator.scheduleAutoExport(workspace: workspace, modelContext: modelContext)
    }

    private func syncInstructionDraftFromWorkspace() {
        draftWorkspaceInstructions = workspace.instructions
        draftWorkspaceInstructionsWorkspaceID = workspace.id
        didRecentlySaveWorkspaceInstructions = false
    }

    private var isWorkspaceInstructionDraftSynced: Bool {
        draftWorkspaceInstructionsWorkspaceID == workspace.id
    }

    private var effectiveDraftWorkspaceInstructions: String {
        WorkspaceInstructionEditorPresentation.effectiveDraft(
            localDraft: draftWorkspaceInstructions,
            persisted: workspace.instructions,
            isSynced: isWorkspaceInstructionDraftSynced
        )
    }

    private var hasUnsavedWorkspaceInstructions: Bool {
        WorkspaceInstructionEditorPresentation.hasUnsavedChanges(
            localDraft: draftWorkspaceInstructions,
            persisted: workspace.instructions,
            isSynced: isWorkspaceInstructionDraftSynced
        )
    }

    private var workspaceInstructionStatusTitle: String? {
        WorkspaceInstructionEditorPresentation.statusTitle(
            localDraft: draftWorkspaceInstructions,
            persisted: workspace.instructions,
            isSynced: isWorkspaceInstructionDraftSynced,
            didRecentlySave: didRecentlySaveWorkspaceInstructions
        )
    }

    private var shouldShowClearWorkspaceInstructionsAction: Bool {
        WorkspaceInstructionEditorPresentation.shouldShowClearAction(
            localDraft: draftWorkspaceInstructions,
            persisted: workspace.instructions,
            isSynced: isWorkspaceInstructionDraftSynced
        )
    }

    private func saveWorkspaceInstructions() {
        let savedInstructions = WorkspaceInstructionEditorPresentation.persistedInstructions(
            fromDraft: effectiveDraftWorkspaceInstructions
        )
        guard savedInstructions != workspace.instructions.trimmingCharacters(in: .whitespacesAndNewlines) else {
            draftWorkspaceInstructions = savedInstructions
            draftWorkspaceInstructionsWorkspaceID = workspace.id
            didRecentlySaveWorkspaceInstructions = true
            return
        }

        workspace.instructions = savedInstructions
        draftWorkspaceInstructions = savedInstructions
        draftWorkspaceInstructionsWorkspaceID = workspace.id
        didRecentlySaveWorkspaceInstructions = true
        markWorkspaceConfigurationChanged()

        expandDetail(.instructions)
    }

    private func clearDraftWorkspaceInstructions() {
        draftWorkspaceInstructions = ""
        draftWorkspaceInstructionsWorkspaceID = workspace.id
        didRecentlySaveWorkspaceInstructions = false
    }

    private func removeAdditionalPaths(matching path: String) {
        let remaining = WorkspaceFolderPresentation.remainingAdditionalPaths(
            afterRemovingFolderMatching: path,
            from: workspace.additionalPaths
        )
        guard remaining.count != workspace.additionalPaths.count else { return }
        workspace.additionalPaths = remaining
        markWorkspaceConfigurationChanged()
    }

    private func loadSSHConnections() {
        guard !workspace.primaryPath.isEmpty else {
            sshConnections = []
            return
        }
        sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
    }

    private func checkGitRepositories() {
        let inputs = WorkspaceGitRepositoryScanInputs(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        Task {
            let repos = await GitService.shared.scanForGitRepositories(
                primaryPath: inputs.primaryPath,
                additionalPaths: inputs.additionalPaths
            )
            await MainActor.run {
                guard inputs.matches(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                ) else { return }
                self.hasGitRepositories = !repos.isEmpty
            }
        }
    }

    private func checkDockerEnvironments() {
        let inputs = WorkspaceGitRepositoryScanInputs(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        let isContainerized = ExecutionEnvironmentStore
            .decode(workspace.activeExecutionEnvironmentJSON)
            .isContainerized
        hasDockerEnvironments = isContainerized
        // Discovery stats every workspace path and reads the xattrs of any
        // Dockerfile it finds. A path the filesystem is slow to answer for — a
        // TCC-gated folder, a sync provider's placeholder — can hold that call
        // indefinitely, and it used to hold it on the main thread from
        // `.onAppear`: the window wedged mid-layout and never drew. Detached,
        // not `Task {}`, because the scan is synchronous and a task inherited
        // from this view would run it right back on the main actor.
        Task.detached {
            let candidates = DockerWorkspaceDiscoveryService.candidates(
                primaryPath: inputs.primaryPath,
                additionalPaths: inputs.additionalPaths
            )
            await MainActor.run {
                guard inputs.matches(
                    primaryPath: workspace.primaryPath,
                    additionalPaths: workspace.additionalPaths
                ) else { return }
                self.hasDockerEnvironments = isContainerized || !candidates.isEmpty
            }
        }
    }

    private var workspaceDisclosureID: String {
        workspace.id.uuidString
    }

    private func applyConfigureDefaults() {
        isMemoryComposerVisible = false
        syncInstructionDraftFromWorkspace()
        expandedWorkspaceSetupItems = []

        // Restore the box expand/collapse choices the user made last time in
        // this workspace, so the rail does not forget its layout every session.
        collapsedBoxes = Set(Rail.sectionOrder.filter { section in
            !RailDisclosureStore.bool(workspaceDisclosureID, Self.disclosureToggle(for: section), default: true)
        })
    }

    private func addExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder the agent can also read from or execute in"
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url {
            let outcome = WorkspaceConfiguredRoots.addAdditionalPaths([url.path], to: workspace)
            folderRefusal = outcome.refusalMessage
            if outcome == .updated { markWorkspaceConfigurationChanged() }
        }
    }

    private func addMemory() {
        let text = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        workspace.memories.append(text)
        markWorkspaceConfigurationChanged()
        newMemoryText = ""
        isMemoryComposerVisible = false
    }

    private func requestMemoryDeletion(at index: Int) {
        guard workspace.memories.indices.contains(index) else { return }
        let detail = workspace.memories[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = detail.isEmpty ? "This saved detail" : "“\(detail.prefix(80))”"
        pendingRailDeletion = PendingRailDeletion(
            title: "Remove memory?",
            message: "\(shown) will be removed from this workspace's memory.",
            confirmTitle: "Remove",
            perform: { removeMemory(at: index) }
        )
    }

    private func removeMemory(at index: Int) {
        guard workspace.memories.indices.contains(index) else { return }
        workspace.memories.remove(at: index)
        markWorkspaceConfigurationChanged()
    }

    private var memoryComposer: some View {
        HStack(spacing: 6) {
            TextField("Remember something about this workspace...", text: $newMemoryText, axis: .vertical)
                .font(Stanford.caption(12))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { addMemory() }

            Button {
                addMemory()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(Stanford.ui(14))
                    .foregroundStyle(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Stanford.sandstone : Stanford.lagunita)
            }
            .buttonStyle(.plain)
            .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Save memory")
            .accessibilityLabel("Save memory")

            Button {
                newMemoryText = ""
                isMemoryComposerVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel adding memory")
        }
    }

    private var hasWorkspaceInstructions: Bool {
        !workspace.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func compactPath(_ path: String) -> String {
        let abbreviated = abbreviatePath(path)
        let parts = abbreviated
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard parts.count > 3 else { return abbreviated }

        let leaf = parts[parts.count - 1]
        let parent = parts[parts.count - 2]

        if abbreviated.hasPrefix("~/") {
            return "~/.../\(parent)/\(leaf)"
        }
        if abbreviated.hasPrefix("/") {
            return "/.../\(parent)/\(leaf)"
        }
        return ".../\(parent)/\(leaf)"
    }

    // MARK: - Inspector Helpers

    private func uniqueTools(_ tools: [LocalTool]) -> [LocalTool] {
        Dictionary(grouping: tools, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func uniqueConnectors(_ connectors: [Connector]) -> [Connector] {
        Dictionary(grouping: connectors, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

}

struct WorkspaceGitRepositoryScanInputs: Equatable, Sendable {
    let primaryPath: String
    let additionalPaths: [String]

    func matches(primaryPath: String, additionalPaths: [String]) -> Bool {
        self.primaryPath == primaryPath && self.additionalPaths == additionalPaths
    }
}

/// A staged destructive removal awaiting confirmation. Carries its own copy so
/// the confirm dialog can describe exactly what it will delete and run the
/// removal only on an explicit second tap.
private struct PendingRailDeletion: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void
}
