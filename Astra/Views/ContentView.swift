import SwiftUI
import SwiftData
import ASTRACore
import AppKit

/// Layout-level artifacts shown in the docked Shelf column.
/// Future cases can choose wider sizing for browser or file previews.
private enum WorkspaceCanvasItem: Equatable {
    case plan
    case markdown
    case browser
    case query

    var minWidth: CGFloat {
        switch self {
        case .plan: 400
        case .markdown: PanelLayoutGeometry.filesShelfMinReadableWidth
        case .browser: PanelLayoutGeometry.browserShelfMinWidth
        case .query: 460
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .plan: 520
        case .markdown: 620
        case .browser: 440
        case .query: 640
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .plan: 1040
        case .markdown: 980
        case .browser: 1120
        case .query: 1180
        }
    }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .markdown: "Files"
        case .browser: "Browser"
        case .query: "Query"
        }
    }

    var closesWhenDraggedBelowMinimum: Bool {
        self == .markdown
    }
}

private enum WorkspaceRightPanel: Equatable {
    case canvas(WorkspaceCanvasItem)
    case context(UUID)

    var isContext: Bool {
        if case .context = self { return true }
        return false
    }
}

private struct ShelfBoundaryMetrics: Equatable {
    var width: CGFloat = 0
    var isVisible = false
    var isResizing = false

    static let hidden = ShelfBoundaryMetrics()
}

private struct ShelfBoundaryMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = ShelfBoundaryMetrics.hidden

    static func reduce(value: inout ShelfBoundaryMetrics, nextValue: () -> ShelfBoundaryMetrics) {
        let next = nextValue()
        if next.isVisible {
            value = next
        }
    }
}

private struct CompactPanelLayoutObserver: View {
    let width: CGFloat
    let splitVisibility: NavigationSplitViewVisibility
    let activeCanvasItem: WorkspaceCanvasItem?
    let isRightRailVisible: Bool
    let workspaceID: UUID?
    let onWidthChanged: (CGFloat) -> Void
    let onSplitVisibilityChanged: () -> Void
    let onPanelStateChanged: () -> Void

    var body: some View {
        Color.clear
            .onAppear {
                onWidthChanged(width)
            }
            .onChange(of: width) {
                onWidthChanged(width)
            }
            .onChange(of: splitVisibility) {
                onSplitVisibilityChanged()
            }
            .onChange(of: activeCanvasItem) {
                onPanelStateChanged()
            }
            .onChange(of: isRightRailVisible) {
                onPanelStateChanged()
            }
            .onChange(of: workspaceID) {
                onPanelStateChanged()
            }
    }
}

private struct CompactPanelLayoutCoordinator: ViewModifier {
    let splitVisibility: NavigationSplitViewVisibility
    let activeCanvasItem: WorkspaceCanvasItem?
    let isRightRailVisible: Bool
    let workspaceID: UUID?
    let onWidthChanged: (CGFloat) -> Void
    let onSplitVisibilityChanged: () -> Void
    let onPanelStateChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    CompactPanelLayoutObserver(
                        width: proxy.size.width,
                        splitVisibility: splitVisibility,
                        activeCanvasItem: activeCanvasItem,
                        isRightRailVisible: isRightRailVisible,
                        workspaceID: workspaceID,
                        onWidthChanged: onWidthChanged,
                        onSplitVisibilityChanged: onSplitVisibilityChanged,
                        onPanelStateChanged: onPanelStateChanged
                    )
                }
            }
    }
}

private struct ShelfBoundaryOverlayModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ShelfBoundaryMetricsPreferenceKey.self) { metrics in
            ShelfBoundaryOverlay(metrics: metrics)
        }
    }
}

private struct ShelfBoundaryOverlay: View {
    let metrics: ShelfBoundaryMetrics

    var body: some View {
        if metrics.isVisible {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: borderWidth)
                    Spacer(minLength: 0)
                }
                .frame(width: metrics.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all, edges: .top)
            .allowsHitTesting(false)
        }
    }

    private var borderColor: Color {
        metrics.isResizing ? Stanford.lagunita.opacity(0.95) : Color.primary.opacity(0.12)
    }

    private var borderWidth: CGFloat {
        metrics.isResizing ? 3 : 1
    }
}

private extension View {
    func shelfBoundaryOverlay() -> some View {
        modifier(ShelfBoundaryOverlayModifier())
    }
}

struct NewWorkspaceDraft: Equatable {
    var name = ""
    var instructions = ""
    var selectedCapabilityIDs: Set<String> = []
    var capabilityConfiguration = OnboardingCapabilityConfiguration()

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty && capabilitySetupIssues(githubCLIReady: true).isEmpty
    }

    func capabilitySetupIssues(githubCLIReady: Bool) -> [String] {
        OnboardingCapabilitySetup.configurableOptions.flatMap { option -> [String] in
            guard let packageID = option.packageID,
                  selectedCapabilityIDs.contains(packageID) else {
                return []
            }
            return capabilityConfiguration
                .missingRequirements(for: packageID, githubCLIReady: githubCLIReady)
                .map { "\(option.title): \($0)" }
        }
    }

    mutating func clear() {
        name = ""
        instructions = ""
        selectedCapabilityIDs = []
        capabilityConfiguration = OnboardingCapabilityConfiguration()
    }
}

struct ContentView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    let runtime: AppRuntimeController
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @State private var selectedTask: AgentTask?
    @State private var selectedWorkspace: Workspace?
    @State private var showingConfigure = false
    @State private var configureInitialTab: ConfigureTab = .capabilities
    @State private var configureFocusItemID: UUID?
    @State private var configureFocusCapabilityPackageID: String?
    @State private var showingWorkspaceEditor = false
    @State private var showingNewWorkspace = false
    @State private var showingSSHEditor = false
    @State private var editingSSHConnection: SSHConnection?
    @State private var isComposingTask = false
    @State private var sshReloadTrigger = 0
    @State private var newWorkspaceDraft = NewWorkspaceDraft()
    @StateObject private var browserSessionStore = ShelfBrowserSessionStore()
    @StateObject private var markdownSessionStore = ShelfMarkdownSessionStore()
    @StateObject private var querySession = ShelfQuerySession()
    @StateObject private var externalRouteStore = AstraExternalRouteStore.shared
    @State private var showingNewSchedule = false
    @State private var editingSchedule: TaskSchedule?
    @State private var isSearchActive = false
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""
    @State private var linkedScheduleWarning: LinkedScheduleWarning?
    @State private var externalRouteNotice = ""
    @State private var runningTaskCount = 0
    @AppStorage(AppStorageKeys.claudePath) private var claudePath = ""
    @AppStorage(AppStorageKeys.copilotPath) private var copilotPath = ""
    @AppStorage(AppStorageKeys.runtimeProviderSettingsRevision) private var runtimeProviderSettingsRevision = 0
    @AppStorage(AppStorageKeys.defaultRuntimeID) private var defaultRuntimeID = TaskExecutionDefaults.runtime.rawValue
    @AppStorage(AppStorageKeys.defaultModel) private var defaultModel = TaskExecutionDefaults.model
    @AppStorage(AppStorageKeys.defaultTokenBudget) private var defaultBudget = TaskExecutionDefaults.tokenBudget
    @AppStorage(AppStorageKeys.claudeProvider) private var claudeProviderRaw = ClaudeProvider.anthropic.rawValue
    @AppStorage(AppStorageKeys.claudeVertexOpusModel) private var claudeVertexOpusModel = ""
    @AppStorage(AppStorageKeys.claudeVertexSonnetModel) private var claudeVertexSonnetModel = ""
    @AppStorage(AppStorageKeys.claudeVertexHaikuModel) private var claudeVertexHaikuModel = ""
    @AppStorage(AppStorageKeys.timeoutSeconds) private var timeoutSeconds = 600
    @AppStorage("appUIScale") private var uiScale: Double = 1.0
    @AppStorage(AppStorageKeys.validationModel) private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage(AppStorageKeys.workspacesRoot) private var workspacesRoot = ""
    @AppStorage(AppStorageKeys.skipPermissions) private var skipPermissions = false
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @AppStorage(AppStorageKeys.securityGateDefaultedToReview) private var securityGateDefaultedToReview = false
    @AppStorage(AppStorageKeys.browserPinnedToTask) private var isBrowserPinnedToTask = true
    @AppStorage(AppStorageKeys.markdownPinnedToTask) private var isMarkdownPinnedToTask = true
    @AppStorage("lastSelectedWorkspaceID") private var lastSelectedWorkspaceID = ""
    @AppStorage("lastSelectedWorkspacePath") private var lastSelectedWorkspacePath = ""
    @AppStorage("isWorkspaceRightRailVisible") private var isWorkspaceRightRailVisible = true
    @AppStorage(WorkspaceRecoveryService.recoveryNoticeKey) private var recoveryNotice = ""
    @State private var activeWorkspaceCanvasItem: WorkspaceCanvasItem?
    @State private var browserToolbarEngine = ShelfBrowserEngine.embedded
    @State private var splitVisibility: NavigationSplitViewVisibility = .all
    @State private var responsiveLayoutWidth: CGFloat = 0
    @State private var didAutoHideSidebarForCompactPanels = false
    @State private var cachedHasCanvasContent = false
    @State private var generatedHTMLPreviewTask: Task<Void, Never>?
    @State private var generatedMarkdownPreviewTask: Task<Void, Never>?
    @State private var markdownAvailabilityTask: Task<Void, Never>?
    @State private var queryAvailabilityTask: Task<Void, Never>?
    @State private var runtimeModelRefreshTasks: [AgentRuntimeID: Task<Void, Never>] = [:]
    @State private var lastRuntimeModelRefreshSignatures: [AgentRuntimeID: String] = [:]
    @State private var lastGeneratedHTMLPreviewSignature = ""
    @State private var lastGeneratedMarkdownPreviewSignature = ""
    @State private var selectedTaskHasMarkdownShelfContent = false
    @State private var selectedTaskPreferredMarkdownPath = ""
    @State private var selectedTaskHasQueryShelfContent = false
    @State private var selectedTaskPreferredQueryPath = ""
    /// First-run flag. Flips to true once the user finishes the
    /// onboarding wizard. Exposed via Settings → "Show Onboarding Again"
    /// so users can replay the guide on demand.
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    /// Tracks whether the wizard has ever been presented. The first
    /// presentation remains modal; later manual replays can be dismissed.
    @AppStorage(AppStorageKeys.hasPresentedOnboarding) private var hasPresentedOnboarding = false
    @State private var isReplayingOnboarding = false
    /// Shared preflight cache — one instance for the whole app run so the
    /// wizard's provider probe warms the cache for the catalog badges
    /// (and vice versa).

    @MainActor
    init(appUpdateController: AppUpdateController, runtime: AppRuntimeController) {
        self.appUpdateController = appUpdateController
        self.runtime = runtime
    }

    private var effectiveWorkspace: Workspace? {
        sceneCoordinator.effectiveWorkspace
    }

    private var effectiveWorkspaceID: UUID? {
        sceneCoordinator.effectiveWorkspaceID
    }

    private var queryUtilityRuntime: AgentUtilityRuntimeConfiguration {
        let fallbackRuntime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: selectedTask?.runtimeID,
            fallback: fallbackRuntime
        )
        let preferredModel = selectedTask?.model ?? RuntimeModelAvailability.defaultModel(for: runtime)
        return AgentUtilityRuntimeConfiguration(
            runtime: runtime,
            model: RuntimeModelAvailability.normalizedModel(preferredModel, for: runtime),
            providerSettings: providerSettingsSnapshot.providerSettings
        )
    }

    private var providerSettingsSnapshot: ProviderSettingsSnapshot {
        RuntimeSettingsSnapshotStore.providerSnapshot(
            claudePath: claudePath,
            copilotPath: copilotPath,
            providerSettingsRevision: runtimeProviderSettingsRevision,
            claudeProviderRaw: claudeProviderRaw,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: claudeVertexOpusModel,
            vertexSonnetModel: claudeVertexSonnetModel,
            vertexHaikuModel: claudeVertexHaikuModel
        )
    }

    private var workspaceSelectionSignature: String {
        sceneCoordinator.workspaceSelectionSignature
    }

    private var pendingExternalRouteID: UUID? {
        externalRouteStore.pendingRoute?.id
    }

    private var executionSettingsSignature: String {
        [
            providerSettingsSnapshot.signature,
            defaultRuntimeID,
            String(timeoutSeconds),
            validationModel,
            String(skipPermissions),
            defaultAgentPolicyLevelRaw
        ].joined(separator: "|")
    }

    private var selectedTaskBinding: Binding<AgentTask?> {
        Binding(
            get: { selectedTask },
            set: { setSelectedTask($0) }
        )
    }

    private var currentBrowserSession: ShelfBrowserSession {
        browserSessionStore.session(
            for: selectedTask?.id,
            pinnedToTask: isBrowserPinnedToTask,
            enabledBrowserAdapters: enabledBrowserAdapterIDs(for: selectedTask)
        )
    }

    private var currentMarkdownSession: ShelfMarkdownSession {
        markdownSessionStore.session(
            for: selectedTask?.id,
            pinnedToTask: isMarkdownPinnedToTask
        )
    }

    private func enabledBrowserAdapterIDs(for task: AgentTask?) -> [String] {
        guard let task else { return [] }
        return TaskCapabilityResolver(task: task).enabledBrowserAdapters
    }

    private var browserPinnedToTaskBinding: Binding<Bool> {
        Binding(
            get: { isBrowserPinnedToTask },
            set: setBrowserPinnedToTask
        )
    }

    private var markdownPinnedToTaskBinding: Binding<Bool> {
        Binding(
            get: { isMarkdownPinnedToTask },
            set: setMarkdownPinnedToTask
        )
    }

    private var selectedTaskUnreadSignature: String {
        guard let selectedTask else { return "" }
        let unread = selectedTask.unreadAt?.timeIntervalSince1970 ?? 0
        return "\(selectedTask.id.uuidString):\(unread)"
    }

    private var selectedTaskCanvasSignature: String {
        guard let selectedTask else { return "none" }
        let htmlPreviewSignature = selectedTaskHTMLPreviewSignature(for: selectedTask)
        let inputSignature = selectedTask.inputs.joined(separator: "|")
        let latestRun = selectedTask.runs.max { $0.startedAt < $1.startedAt }
        let latestRunSignature = [
            latestRun?.id.uuidString ?? "none",
            latestRun?.status.rawValue ?? "none",
            String(Int(latestRun?.startedAt.timeIntervalSince1970 ?? 0)),
            String(latestRun?.output.count ?? 0),
            String(latestRun?.fileChangesJSON.count ?? 0)
        ].joined(separator: ":")
        return [
            selectedTask.id.uuidString,
            selectedTask.status.rawValue,
            String(Int(selectedTask.updatedAt.timeIntervalSince1970)),
            String(selectedTask.events.count),
            String(selectedTask.runs.count),
            latestRunSignature,
            htmlPreviewSignature,
            inputSignature
        ].joined(separator: "|")
    }

    private func selectedTaskHTMLPreviewSignature(for task: AgentTask) -> String {
        let latestRun = task.runs.max { $0.startedAt < $1.startedAt }
        return [
            task.status.rawValue,
            latestRun?.id.uuidString ?? "none",
            String(latestRun?.fileChangesJSON.count ?? 0)
        ].joined(separator: "|")
    }

    private var hasWorkspaceCanvasContent: Bool { cachedHasCanvasContent }

    private var hasOpenTaskThread: Bool {
        selectedTask != nil || isComposingTask
    }

    private var hasQueryShelfAffordance: Bool {
        activeWorkspaceCanvasItem == .query
            || selectedTaskHasQueryShelfContent
    }

    private var topRightActions: WorkspaceTopRightActions {
        WorkspaceTopRightActions(
            hasWorkspace: effectiveWorkspace != nil,
            canShowPlanShelf: hasOpenTaskThread && hasWorkspaceCanvasContent,
            canShowTextShelf: effectiveWorkspace != nil || activeWorkspaceCanvasItem == .markdown,
            canShowBrowserShelf: hasOpenTaskThread,
            canShowQueryShelf: hasOpenTaskThread && hasQueryShelfAffordance,
            activeCanvasItem: activeWorkspaceCanvasItem,
            browserEngine: browserToolbarEngine,
            isRightRailVisible: isWorkspaceRightRailVisible
        )
    }

    private var isWorkspaceCanvasPresented: Bool {
        activeWorkspaceCanvasItem != nil
    }

    private var compactPanelMutualExclusionWidth: CGFloat {
        PanelLayoutGeometry.compactPanelMutualExclusionWidth
    }

    private var isCompactPanelLayout: Bool {
        PanelLayoutGeometry.isCompactPanelLayout(width: responsiveLayoutWidth)
    }

    private var hasRightSidePanelPresented: Bool {
        activeWorkspaceCanvasItem != nil || (effectiveWorkspace != nil && isWorkspaceRightRailVisible)
    }

    private var shouldUseDetailOnlyCompactLayout: Bool {
        isCompactPanelLayout && hasRightSidePanelPresented
    }

    private var panelTransitionAnimation: Animation? {
        AstraMotion.rightPanel(reduceMotion: reduceMotion)
    }

    private var rightRailInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                effectiveWorkspace != nil && isWorkspaceRightRailVisible
            },
            set: setRightRailPresented
        )
    }

    private var onboardingSheetBinding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding && !isUITestingSeededLaunch },
            set: { isPresented in
                if !isPresented, isReplayingOnboarding {
                    hasCompletedOnboarding = true
                }
            }
        )
    }

    private var compactPanelLayoutCoordinator: CompactPanelLayoutCoordinator {
        CompactPanelLayoutCoordinator(
            splitVisibility: splitVisibility,
            activeCanvasItem: activeWorkspaceCanvasItem,
            isRightRailVisible: isWorkspaceRightRailVisible,
            workspaceID: effectiveWorkspaceID,
            onWidthChanged: handleResponsiveLayoutWidthChanged,
            onSplitVisibilityChanged: handleSplitVisibilityChanged,
            onPanelStateChanged: handleRightSidePanelStateChanged
        )
    }

    @ViewBuilder
    private var rootLayout: some View {
        if shouldUseDetailOnlyCompactLayout {
            detailArea
        } else {
            splitLayout
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            sidebarArea
        } detail: {
            detailArea
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarArea: some View {
        TaskSidebarContainerView(
            selectedTask: selectedTaskBinding,
            taskQueue: runtime.taskQueue,
            workspaces: workspaces,
            selectedWorkspace: $selectedWorkspace,
            onNewTask: startComposingTask,
            onRunQueue: runQueue,
            onRunTask: runSingleTask,
            onToggleDone: toggleDone,
            onCancelTask: cancelTask,
            onRetryTask: retryTask,
            onDeleteTask: requestDeleteTask,
            onNewWorkspace: createWorkspace,
            onEditWorkspace: beginEditingWorkspace,
            onImportWorkspace: importWorkspace,
            onShowConfigure: openCapabilitiesManager,
            onDeleteWorkspace: deleteWorkspace,
            onRenameWorkspace: beginRenamingWorkspace,
            onNewSchedule: showNewSchedule,
            onEditSchedule: beginEditingSchedule,
            isSearchActive: $isSearchActive
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    }

    private var detailArea: some View {
        ContentDetailAreaView(
            selectedTask: selectedTask,
            effectiveWorkspace: effectiveWorkspace,
            isComposingTask: isComposingTask,
            taskQueue: runtime.taskQueue,
            browserSession: currentBrowserSession,
            isBrowserPinnedToTask: browserPinnedToTaskBinding,
            markdownSession: currentMarkdownSession,
            isMarkdownPinnedToTask: markdownPinnedToTaskBinding,
            querySession: querySession,
            queryUtilityRuntime: queryUtilityRuntime,
            sshReloadTrigger: sshReloadTrigger,
            isRightRailPresented: rightRailInspectorBinding,
            activeCanvasItem: $activeWorkspaceCanvasItem,
            isPlanCanvasVisible: activeWorkspaceCanvasItem == .plan,
            onQuickRun: handleQuickRunTask,
            onTaskCreated: handleTaskCreated,
            onAddSSHConnection: { showingSSHEditor = true },
            onManageSkills: openSkillsManager,
            onRunTask: runSingleTask,
            onCancelTask: cancelTask,
            onRetryTask: retryTask,
            onResumeTask: resumeTask,
            onApproveTask: approveTask,
            onOpenPlan: openPlanCanvas,
            onToggleDone: toggleDone,
            onMoveToDraft: moveTaskToDraft,
            onForkTask: setSelectedTask,
            onCreateTask: startComposingTask,
            onOpenTask: openExistingTask,
            onDeleteTask: requestDeleteTask,
            onSetDoneState: setDoneState,
            onRunQueue: runQueue,
            onConfigure: openCapabilitiesManager,
            onNewSchedule: showNewSchedule,
            onEditSchedule: beginEditingSchedule,
            onManageCapabilities: openCapabilitiesManager,
            onEditWorkspace: showWorkspaceEditor,
            onOpenConfigureTab: openConfigureTab,
            onOpenCapabilityPackage: openCapabilityPackage,
            onNewSSHConnection: showSSHConnectionEditor,
            onEditSSHConnection: beginEditingSSHConnection,
            onCreateWorkspace: createWorkspace,
            onImportWorkspace: importWorkspace,
            onOpenGeneratedFile: openGeneratedFile,
            onOpenWorkspaceFile: openWorkspaceFileInShelf
        )
    }

    var body: some View {
        rootLayout
        .frame(minHeight: 600)
        .accessibilityIdentifier("MainContentView")
        .astraWindowChrome()
        .astraHiddenToolbarBackground()
        // Right-rail toggle. Attached to the NavigationSplitView root so
        // .primaryAction lands at the WINDOW's trailing edge — past the
        // inspector column — instead of at the inspector boundary
        // (where attaching to .detail or to the inspector content put it).
        .toolbar {
            if shouldUseDetailOnlyCompactLayout {
                ToolbarItem(placement: .navigation) {
                    AstraToolbarCommandCluster {
                        Button(action: revealSidebarFromCompactLayout) {
                            AstraToolbarCommandIcon(systemImage: "sidebar.left", isActive: false)
                        }
                        .buttonStyle(.plain)
                        .help("Show sidebar and close the right panel")
                        .accessibilityIdentifier("CompactShowSidebarButton")
                        .accessibilityLabel("Show sidebar")
                    }
                }
            }

            ContentToolbar(
                appUpdateController: appUpdateController,
                onCheckForUpdates: appUpdateController.checkForUpdatesFromButton
            )

            if topRightActions.hasWorkspace {
                ToolbarItem(placement: .primaryAction) {
                    WorkspaceTopRightToolbar(
                        actions: topRightActions,
                        onToggleBrowser: toggleBrowserCanvas,
                        onOpenBrowserEngine: openBrowserCanvas,
                        onTogglePlan: toggleWorkspaceCanvas,
                        onToggleText: toggleMarkdownCanvas,
                        onToggleQuery: toggleQueryCanvas,
                        onToggleControlPanel: toggleRightRail
                    )
                }
            }
        }
        .shelfBoundaryOverlay()
        .modifier(compactPanelLayoutCoordinator)
        .overlay {
            if isSearchActive {
                SearchPanelOverlayContainer(
                    workspaces: workspaces,
                    selectedTask: selectedTaskBinding,
                    selectedWorkspace: $selectedWorkspace,
                    isActive: $isSearchActive
                )
            }
        }
        .safeAreaInset(edge: .top) {
            TopNoticeBannersView(
                recoveryNotice: recoveryNotice,
                updateBlockNotice: updateBlockNotice,
                externalRouteNotice: externalRouteNotice,
                onDismissRecoveryNotice: { recoveryNotice = "" },
                onDismissExternalRouteNotice: { externalRouteNotice = "" },
                onCheckForUpdates: appUpdateController.checkForUpdatesFromButton
            )
        }
        .onChange(of: selectedTaskCanvasSignature) {
            handleSelectedTaskCanvasSignatureChanged()
        }
        .onChange(of: hasOpenTaskThread) {
            if !hasOpenTaskThread, activeWorkspaceCanvasItem != nil {
                if activeWorkspaceCanvasItem == .markdown, effectiveWorkspace != nil {
                    return
                }
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
        }
        .onChange(of: activeWorkspaceCanvasItem) {
            syncBrowserPresentation()
        }
        .onReceive(currentBrowserSession.$engine) { engine in
            browserToolbarEngine = engine
        }
        .sheet(isPresented: $showingConfigure) {
            if let ws = effectiveWorkspace {
                ConfigureView(
                    workspace: ws,
                    initialTab: configureInitialTab,
                    focusItemID: configureFocusItemID,
                    focusCapabilityPackageID: configureFocusCapabilityPackageID
                )
            }
        }
        .sheet(isPresented: $showingWorkspaceEditor) {
            if let ws = effectiveWorkspace {
                WorkspaceDetailView(workspace: ws, onDelete: {
                    deleteWorkspace(ws)
                })
            }
        }
        .alert("Rename Workspace", isPresented: Binding(
            get: { renamingWorkspace != nil },
            set: { if !$0 { renamingWorkspace = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingWorkspace = nil }
            Button("Rename") {
                if let ws = renamingWorkspace, !renameText.isEmpty {
                    ws.name = renameText
                    do {
                        try modelContext.save()
                    } catch {
                        AppLogger.audit(.workspaceExported, category: "UI", fields: [
                            "operation": "rename_workspace",
                            "error_type": String(describing: type(of: error))
                        ], level: .error)
                    }
                }
                renamingWorkspace = nil
            }
        }
        .sheet(isPresented: $showingSSHEditor) {
            if let ws = effectiveWorkspace {
                SSHConnectionEditorView(
                    connection: SSHConnection(),
                    onSave: { conn in
                        var connections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
                        connections.append(conn)
                        SSHConnectionManager.save(connections, workspacePath: ws.primaryPath)
                        sshReloadTrigger += 1
                        showingSSHEditor = false
                    },
                    onCancel: { showingSSHEditor = false }
                )
            }
        }
        .sheet(item: $editingSSHConnection) { conn in
            if let ws = effectiveWorkspace {
                SSHConnectionEditorView(
                    connection: conn,
                    onSave: { updated in
                        var connections = SSHConnectionManager.load(workspacePath: ws.primaryPath)
                        if let idx = connections.firstIndex(where: { $0.id == updated.id }) {
                            connections[idx] = updated
                        }
                        SSHConnectionManager.save(connections, workspacePath: ws.primaryPath)
                        sshReloadTrigger += 1
                        editingSSHConnection = nil
                    },
                    onCancel: { editingSSHConnection = nil }
                )
            }
        }
        .sheet(isPresented: $showingNewSchedule) {
            if let ws = effectiveWorkspace {
                ScheduleEditorView(workspace: ws)
            }
        }
        .sheet(item: $editingSchedule) { schedule in
            if let ws = schedule.workspace ?? effectiveWorkspace {
                ScheduleEditorView(workspace: ws, schedule: schedule)
            }
        }
        .sheet(isPresented: $showingNewWorkspace, onDismiss: resetNewWorkspaceDraft) {
            NewWorkspaceSheet(
                draft: $newWorkspaceDraft,
                rootPath: resolvedRoot,
                onCancel: {
                    resetNewWorkspaceDraft()
                    showingNewWorkspace = false
                },
                onCreate: finalizeNewWorkspace
            )
        }
        .alert(item: $linkedScheduleWarning) { warning in
            Alert(
                title: Text(warning.action.alertTitle),
                message: Text(warning.message),
                primaryButton: .destructive(Text(warning.action.confirmLabel)) {
                    pauseSchedulesAndContinue(warning)
                },
                secondaryButton: .cancel()
            )
        }
        .id(uiScale)
        .onAppear {
            handleAppear()
        }
        .onChange(of: executionSettingsSignature) { applySettings() }
        .onChange(of: updateSafetySignature) {
            refreshRunningTaskCount()
            refreshUpdateSafetyHooks()
        }
        .onChange(of: workspaceSelectionSignature) {
            handleWorkspaceSelectionSignatureChanged()
        }
        .onChange(of: pendingExternalRouteID) {
            handlePendingExternalRoute()
        }
        .onChange(of: selectedWorkspace) {
            handleSelectedWorkspaceChanged()
        }
        .onChange(of: selectedTaskUnreadSignature) {
            markSelectedTaskReadIfNeeded()
        }
        .environment(\.preflightCache, runtime.preflightCache)
        // Publish window-scoped actions so File menu commands (New /
        // Import Workspace) can invoke them. See ASTRAApp.swift
        // for the matching FocusedValueKey definitions.
        .focusedSceneValue(\.newWorkspaceAction, { createWorkspace() })
        .focusedSceneValue(\.importWorkspaceAction, { importWorkspace() })
        .sheet(isPresented: onboardingSheetBinding) {
            OnboardingWizardView(
                hasCompletedOnboarding: $hasCompletedOnboarding,
                allowsDismiss: isReplayingOnboarding,
                onDismiss: {
                    hasCompletedOnboarding = true
                },
                onCreateWorkspace: finalizeOnboardingWorkspace
            )
            .environment(\.preflightCache, runtime.preflightCache)
            .interactiveDismissDisabled(!isReplayingOnboarding)
            .onAppear {
                isReplayingOnboarding = hasPresentedOnboarding
                hasPresentedOnboarding = true
            }
        }
    }

    // MARK: - View State

    private var updateBlockNotice: String? {
        if case .blocked(let message) = appUpdateController.status {
            return message
        }
        return nil
    }

    // MARK: - UI Actions

    private func openCapabilitiesManager() {
        configureInitialTab = .capabilities
        configureFocusItemID = nil
        configureFocusCapabilityPackageID = nil
        showingConfigure = true
    }

    private func openSkillsManager() {
        configureInitialTab = .skills
        configureFocusItemID = nil
        configureFocusCapabilityPackageID = nil
        showingConfigure = true
    }

    private func openConfigureTab(_ tab: ConfigureTab, itemID: UUID?) {
        configureInitialTab = tab
        configureFocusItemID = itemID
        configureFocusCapabilityPackageID = nil
        showingConfigure = true
    }

    private func openCapabilityPackage(_ packageID: String) {
        configureInitialTab = .capabilities
        configureFocusItemID = nil
        configureFocusCapabilityPackageID = packageID
        showingConfigure = true
    }

    private func showWorkspaceEditor() {
        showingWorkspaceEditor = true
    }

    private func beginEditingWorkspace(_ workspace: Workspace) {
        selectedWorkspace = workspace
        showingWorkspaceEditor = true
    }

    private func beginRenamingWorkspace(_ workspace: Workspace) {
        renameText = workspace.name
        renamingWorkspace = workspace
    }

    private func showNewSchedule() {
        showingNewSchedule = true
    }

    private func beginEditingSchedule(_ schedule: TaskSchedule) {
        editingSchedule = schedule
    }

    private func showSSHConnectionEditor() {
        showingSSHEditor = true
    }

    private func beginEditingSSHConnection(_ connection: SSHConnection) {
        editingSSHConnection = connection
    }

    private func animatePanelChange(_ changes: () -> Void) {
        withAnimation(panelTransitionAnimation) {
            changes()
        }
    }

    private func handleResponsiveLayoutWidthChanged(_ width: CGFloat) {
        responsiveLayoutWidth = width
        reconcileCompactPanelLayout(for: width)
    }

    private func handleRightSidePanelStateChanged() {
        reconcileCompactPanelLayout()
    }

    private func handleSelectedTaskCanvasSignatureChanged() {
        cachedHasCanvasContent = selectedTask.flatMap { TaskPlanService.reconstruct(for: $0).plan } != nil
        if !cachedHasCanvasContent, activeWorkspaceCanvasItem == .plan {
            activeWorkspaceCanvasItem = nil
        }
        if selectedTask == nil, !isComposingTask, activeWorkspaceCanvasItem == .browser {
            activeWorkspaceCanvasItem = nil
        }
        if selectedTask == nil, !isComposingTask, effectiveWorkspace == nil, activeWorkspaceCanvasItem == .markdown {
            activeWorkspaceCanvasItem = nil
        }
        refreshMarkdownShelfAvailabilityForSelectedTask()
        refreshQueryShelfAvailabilityForSelectedTask()
        previewGeneratedHTMLForSelectedTaskIfNeeded()
        previewGeneratedMarkdownForSelectedTaskIfNeeded()
    }

    private func reconcileCompactPanelLayout(for width: CGFloat? = nil) {
        let currentWidth = width ?? responsiveLayoutWidth
        guard currentWidth > 0 else { return }

        guard currentWidth < compactPanelMutualExclusionWidth else {
            if didAutoHideSidebarForCompactPanels {
                didAutoHideSidebarForCompactPanels = false
                if splitVisibility == .detailOnly {
                    withAnimation(panelTransitionAnimation) {
                        splitVisibility = .all
                    }
                }
            }
            return
        }

        guard hasRightSidePanelPresented else {
            if didAutoHideSidebarForCompactPanels {
                didAutoHideSidebarForCompactPanels = false
                if splitVisibility == .detailOnly {
                    withAnimation(panelTransitionAnimation) {
                        splitVisibility = .all
                    }
                }
            }
            return
        }
        guard splitVisibility != .detailOnly else { return }

        didAutoHideSidebarForCompactPanels = true
        withAnimation(panelTransitionAnimation) {
            splitVisibility = .detailOnly
        }
    }

    private func handleSplitVisibilityChanged() {
        guard isCompactPanelLayout else {
            if splitVisibility != .detailOnly {
                didAutoHideSidebarForCompactPanels = false
            }
            return
        }

        guard splitVisibility != .detailOnly else { return }
        guard hasRightSidePanelPresented else { return }

        didAutoHideSidebarForCompactPanels = false
        hideRightSidePanelsForCompactSidebar()
    }

    private func hideRightSidePanelsForCompactSidebar() {
        animatePanelChange {
            activeWorkspaceCanvasItem = nil
            isWorkspaceRightRailVisible = false
        }
    }

    private func revealSidebarFromCompactLayout() {
        didAutoHideSidebarForCompactPanels = false
        animatePanelChange {
            activeWorkspaceCanvasItem = nil
            isWorkspaceRightRailVisible = false
            splitVisibility = .all
        }
    }

    private func setRightRailPresented(_ isPresented: Bool) {
        if isPresented {
            presentRightRail()
        } else {
            animatePanelChange {
                isWorkspaceRightRailVisible = false
            }
        }
    }

    private func presentRightRail() {
        animatePanelChange {
            activeWorkspaceCanvasItem = nil
            isWorkspaceRightRailVisible = true
        }
    }

    private func presentCanvas(_ item: WorkspaceCanvasItem) {
        animatePanelChange {
            isWorkspaceRightRailVisible = false
            activeWorkspaceCanvasItem = item
        }
    }

    private func toggleRightRail() {
        if activeWorkspaceCanvasItem != nil || !isWorkspaceRightRailVisible {
            presentRightRail()
        } else {
            setRightRailPresented(false)
        }
    }

    private func toggleWorkspaceCanvas() {
        guard hasWorkspaceCanvasContent else {
            animatePanelChange {
                if activeWorkspaceCanvasItem == .plan {
                    activeWorkspaceCanvasItem = nil
                }
            }
            return
        }
        if activeWorkspaceCanvasItem == .plan {
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.plan)
        }
    }

    private func toggleBrowserCanvas() {
        currentBrowserSession.bindToTask(selectedTask?.id)
        if activeWorkspaceCanvasItem == .browser {
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.browser)
        }
    }

    private func openBrowserCanvas(engine: ShelfBrowserEngine) {
        let session = currentBrowserSession
        session.bindToTask(selectedTask?.id)
        if session.engine != engine {
            session.engine = engine
        }
        browserToolbarEngine = engine
        if activeWorkspaceCanvasItem != .browser {
            presentCanvas(.browser)
        }
    }

    private func toggleMarkdownCanvas() {
        guard effectiveWorkspace != nil || selectedTaskHasMarkdownShelfContent || selectedTask != nil || isComposingTask else {
            if activeWorkspaceCanvasItem == .markdown {
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
            return
        }
        currentMarkdownSession.bindToTask(selectedTask?.id)
        if !selectedTaskPreferredMarkdownPath.isEmpty {
            let url = URL(fileURLWithPath: selectedTaskPreferredMarkdownPath)
            if currentMarkdownSession.fileURL?.path != url.path {
                currentMarkdownSession.load(url)
            }
        }
        if activeWorkspaceCanvasItem == .markdown {
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.markdown)
        }
    }

    private func toggleQueryCanvas() {
        guard hasQueryShelfAffordance else {
            if activeWorkspaceCanvasItem == .query {
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
            return
        }
        querySession.bindToTask(selectedTask?.id)
        if !selectedTaskPreferredQueryPath.isEmpty {
            let url = URL(fileURLWithPath: selectedTaskPreferredQueryPath)
            if querySession.selectedDocument?.sourcePath != url.path {
                querySession.loadFile(url)
            }
        }
        if activeWorkspaceCanvasItem == .query {
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.query)
        }
    }

    private func refreshMarkdownShelfAvailabilityForSelectedTask() {
        markdownAvailabilityTask?.cancel()
        guard let selectedTask else {
            selectedTaskHasMarkdownShelfContent = false
            selectedTaskPreferredMarkdownPath = ""
            return
        }

        let taskID = selectedTask.id
        let attachedMarkdownPath = preferredAttachedMarkdownPath(for: selectedTask)
        selectedTaskPreferredMarkdownPath = attachedMarkdownPath ?? ""
        selectedTaskHasMarkdownShelfContent = attachedMarkdownPath != nil

        let taskFolder = TaskWorkspaceAccess(task: selectedTask).taskFolder
        guard !taskFolder.isEmpty else {
            closeMarkdownShelfIfUnavailable()
            return
        }

        markdownAvailabilityTask = Task {
            let files = await TaskGeneratedFiles.filesAsync(in: taskFolder)
            let generatedMarkdownPath = TaskGeneratedFiles.preferredMarkdownFile(in: files, taskFolder: taskFolder)

            await MainActor.run {
                guard !Task.isCancelled,
                      self.selectedTask?.id == taskID else {
                    return
                }

                if let generatedMarkdownPath {
                    selectedTaskPreferredMarkdownPath = generatedMarkdownPath
                    selectedTaskHasMarkdownShelfContent = true
                } else if let attachedMarkdownPath {
                    selectedTaskPreferredMarkdownPath = attachedMarkdownPath
                    selectedTaskHasMarkdownShelfContent = true
                } else {
                    selectedTaskPreferredMarkdownPath = ""
                    selectedTaskHasMarkdownShelfContent = false
                    closeMarkdownShelfIfUnavailable()
                }
            }
        }
    }

    private func preferredAttachedMarkdownPath(for task: AgentTask) -> String? {
        let paths = TaskGeneratedFiles.markdownFiles(inInputs: task.inputs)
        return TaskGeneratedFiles.preferredMarkdownFile(in: paths)
    }

    private func refreshQueryShelfAvailabilityForSelectedTask() {
        queryAvailabilityTask?.cancel()
        guard let selectedTask else {
            selectedTaskHasQueryShelfContent = false
            selectedTaskPreferredQueryPath = ""
            closeQueryShelfIfUnavailable()
            return
        }

        let taskID = selectedTask.id
        let attachedSQLPath = preferredAttachedSQLPath(for: selectedTask)
        let hasQueryIntent = taskHasQueryIntent(selectedTask)
        selectedTaskPreferredQueryPath = attachedSQLPath ?? ""
        selectedTaskHasQueryShelfContent = attachedSQLPath != nil || hasQueryIntent

        let taskFolder = TaskWorkspaceAccess(task: selectedTask).taskFolder
        guard !taskFolder.isEmpty else {
            closeQueryShelfIfUnavailable()
            return
        }

        queryAvailabilityTask = Task {
            let files = await TaskGeneratedFiles.filesAsync(in: taskFolder)
            let generatedSQLPath = TaskGeneratedFiles.preferredSQLFile(in: files, taskFolder: taskFolder)

            await MainActor.run {
                guard !Task.isCancelled,
                      self.selectedTask?.id == taskID else {
                    return
                }

                if let generatedSQLPath {
                    selectedTaskPreferredQueryPath = generatedSQLPath
                    selectedTaskHasQueryShelfContent = true
                } else if let attachedSQLPath {
                    selectedTaskPreferredQueryPath = attachedSQLPath
                    selectedTaskHasQueryShelfContent = true
                } else if hasQueryIntent {
                    selectedTaskPreferredQueryPath = ""
                    selectedTaskHasQueryShelfContent = true
                } else {
                    selectedTaskPreferredQueryPath = ""
                    selectedTaskHasQueryShelfContent = false
                    closeQueryShelfIfUnavailable()
                }
            }
        }
    }

    private func preferredAttachedSQLPath(for task: AgentTask) -> String? {
        let paths = TaskGeneratedFiles.sqlFiles(inInputs: task.inputs)
        return TaskGeneratedFiles.preferredSQLFile(in: paths)
    }

    private func taskHasQueryIntent(_ task: AgentTask) -> Bool {
        let normalized = normalizedQueryIntentText([
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.constraints.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " ")
        ].joined(separator: " "))
        guard !normalized.isEmpty else { return false }

        let tokens = Set(normalized.split(separator: " ").map(String.init))
        let strongQueryTerms: Set<String> = [
            "sql", "bigquery", "bq", "query", "queries",
            "database", "databases", "dataset", "datasets",
            "schema", "schemas", "omop", "cohort"
        ]
        if !tokens.isDisjoint(with: strongQueryTerms) {
            return true
        }

        guard workspaceHasQueryCapability(task.workspace) else { return false }

        let queryVerbs: Set<String> = [
            "count", "list", "check", "inspect", "find", "show",
            "get", "read", "validate", "verify", "summarize"
        ]
        let dataNouns: Set<String> = [
            "table", "tables", "row", "rows", "column", "columns",
            "patient", "patients", "person", "mrn", "record", "records"
        ]
        return !tokens.isDisjoint(with: queryVerbs) && !tokens.isDisjoint(with: dataNouns)
    }

    private func normalizedQueryIntentText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func workspaceHasQueryCapability(_ workspace: Workspace?) -> Bool {
        guard let workspace else { return false }
        return workspace.enabledCapabilityIDs.contains("gcloud-workflow")
            || workspace.installedPluginIDSet.contains("gcloud-workflow")
            || workspace.connectors.contains { connector in
                let serviceType = connector.serviceType.lowercased()
                return serviceType == "gcloud" || serviceType == "bigquery" || serviceType == "database"
            }
            || workspace.localTools.contains { tool in
                tool.command == "bq" || tool.displayCommand.contains("bq ")
            }
    }

    private func closeMarkdownShelfIfUnavailable() {
        guard activeWorkspaceCanvasItem == .markdown, effectiveWorkspace == nil else { return }
        animatePanelChange {
            activeWorkspaceCanvasItem = nil
        }
    }

    private func closeQueryShelfIfUnavailable() {
        guard activeWorkspaceCanvasItem == .query, !selectedTaskHasQueryShelfContent else { return }
        animatePanelChange {
            activeWorkspaceCanvasItem = nil
        }
    }

    private func previewGeneratedHTMLForSelectedTaskIfNeeded() {
        guard isBrowserPinnedToTask else { return }
        guard let selectedTask else {
            generatedHTMLPreviewTask?.cancel()
            return
        }

        let taskID = selectedTask.id
        let taskFolder = TaskWorkspaceAccess(task: selectedTask).taskFolder
        guard !taskFolder.isEmpty else { return }

        generatedHTMLPreviewTask?.cancel()
        generatedHTMLPreviewTask = Task {
            let files = await TaskGeneratedFiles.filesAsync(in: taskFolder)
            guard !Task.isCancelled,
                  let path = TaskGeneratedFiles.preferredHTMLFile(in: files, taskFolder: taskFolder) else {
                return
            }

            let signature = TaskGeneratedFiles.htmlPreviewSignature(for: path, taskID: taskID)
            await MainActor.run {
                guard !Task.isCancelled,
                      self.selectedTask?.id == taskID,
                      lastGeneratedHTMLPreviewSignature != signature else {
                    return
                }

                let session = browserSessionStore.session(for: taskID, pinnedToTask: isBrowserPinnedToTask)
                let shouldLoadPreview = TaskGeneratedFiles.shouldAutoLoadHTMLPreview(
                    currentBrowserURL: session.currentURL,
                    targetPath: path
                )
                lastGeneratedHTMLPreviewSignature = signature
                guard shouldLoadPreview else {
                    logGeneratedHTMLPreview(
                        taskID: taskID,
                        event: "auto_preview_skipped",
                        reason: "browser_has_user_page",
                        targetPath: path,
                        currentURL: session.currentURL
                    )
                    return
                }

                session.load(URL(fileURLWithPath: path), source: "generated_html_preview")
                logGeneratedHTMLPreview(
                    taskID: taskID,
                    event: "auto_preview_loaded",
                    reason: "signature_changed",
                    targetPath: path,
                    currentURL: session.currentURL
                )
                if activeWorkspaceCanvasItem != .browser {
                    presentCanvas(.browser)
                }
                syncBrowserPresentation()
            }
        }
    }

    private func logGeneratedHTMLPreview(
        taskID: UUID,
        event: String,
        reason: String,
        targetPath: String,
        currentURL: String
    ) {
        var fields = ShelfBrowserURLLogFields.fields(for: URL(fileURLWithPath: targetPath), prefix: "target")
        fields.merge(ShelfBrowserURLLogFields.fields(for: currentURL, prefix: "current"), uniquingKeysWith: { current, _ in current })
        fields["event"] = event
        fields["reason"] = reason
        fields["pinned_to_task"] = String(isBrowserPinnedToTask)
        AppLogger.audit(.shelfBrowserPreview, category: "Browser", taskID: taskID, fields: fields)
    }

    private func previewGeneratedMarkdownForSelectedTaskIfNeeded() {
        guard isMarkdownPinnedToTask else { return }
        guard let selectedTask else {
            generatedMarkdownPreviewTask?.cancel()
            return
        }

        let taskID = selectedTask.id
        let taskFolder = TaskWorkspaceAccess(task: selectedTask).taskFolder
        guard !taskFolder.isEmpty else { return }

        generatedMarkdownPreviewTask?.cancel()
        generatedMarkdownPreviewTask = Task {
            let files = await TaskGeneratedFiles.filesAsync(in: taskFolder)
            guard !Task.isCancelled,
                  let path = TaskGeneratedFiles.preferredMarkdownFile(in: files, taskFolder: taskFolder) else {
                return
            }

            let signature = TaskGeneratedFiles.markdownPreviewSignature(for: path, taskID: taskID)
            await MainActor.run {
                guard !Task.isCancelled,
                      self.selectedTask?.id == taskID,
                      lastGeneratedMarkdownPreviewSignature != signature else {
                    return
                }

                lastGeneratedMarkdownPreviewSignature = signature
                selectedTaskPreferredMarkdownPath = path
                selectedTaskHasMarkdownShelfContent = true
                let session = markdownSessionStore.session(for: taskID, pinnedToTask: isMarkdownPinnedToTask)
                session.load(URL(fileURLWithPath: path))
                if activeWorkspaceCanvasItem != .browser {
                    presentCanvas(.markdown)
                }
            }
        }
    }

    private func openGeneratedFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        switch TaskGeneratedFiles.shelfDestination(for: path) {
        case .browser?:
            let taskID = selectedTask?.id
            let session = browserSessionStore.session(for: taskID, pinnedToTask: isBrowserPinnedToTask)
            session.load(url, source: "generated_file")
            if let taskID {
                lastGeneratedHTMLPreviewSignature = TaskGeneratedFiles.htmlPreviewSignature(for: path, taskID: taskID)
            }
            presentCanvas(.browser)
            syncBrowserPresentation()
            return

        case .files?:
            let taskID = selectedTask?.id
            selectedTaskPreferredMarkdownPath = path
            selectedTaskHasMarkdownShelfContent = true
            let session = markdownSessionStore.session(for: taskID, pinnedToTask: isMarkdownPinnedToTask)
            session.load(url)
            if let taskID {
                lastGeneratedMarkdownPreviewSignature = TaskGeneratedFiles.markdownPreviewSignature(for: path, taskID: taskID)
            }
            presentCanvas(.markdown)
            return

        case .query?:
            querySession.bindToTask(selectedTask?.id)
            selectedTaskPreferredQueryPath = path
            selectedTaskHasQueryShelfContent = true
            querySession.loadFile(url)
            presentCanvas(.query)
            return

        case nil:
            NSWorkspace.shared.open(url)
        }
    }

    private func openWorkspaceFileInShelf(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let taskID = selectedTask?.id
        selectedTaskPreferredMarkdownPath = url.path
        selectedTaskHasMarkdownShelfContent = true
        let session = markdownSessionStore.session(for: taskID, pinnedToTask: isMarkdownPinnedToTask)
        session.load(url)
        AppLogger.audit(.gitChangedFileOpenedInShelf, category: "Git", taskID: taskID, fields: [
            "path": url.path,
            "result": FileManager.default.fileExists(atPath: url.path) ? "opened" : "missing"
        ], level: FileManager.default.fileExists(atPath: url.path) ? .info : .warning)
        presentCanvas(.markdown)
    }

    private func syncBrowserPresentation() {
        browserSessionStore.setPresented(
            activeWorkspaceCanvasItem == .browser,
            taskID: selectedTask?.id,
            pinnedToTask: isBrowserPinnedToTask,
            enabledBrowserAdapters: enabledBrowserAdapterIDs(for: selectedTask)
        )
    }

    private func setBrowserPinnedToTask(_ pinnedToTask: Bool) {
        guard isBrowserPinnedToTask != pinnedToTask else { return }

        let previousSession = currentBrowserSession
        let previousAddress = previousSession.currentURL
        isBrowserPinnedToTask = pinnedToTask
        lastGeneratedHTMLPreviewSignature = ""

        let nextSession = currentBrowserSession
        if !previousAddress.isEmpty && nextSession.currentURL.isEmpty {
            nextSession.load(previousAddress)
        }

        syncBrowserPresentation()
        if pinnedToTask {
            previewGeneratedHTMLForSelectedTaskIfNeeded()
        }
    }

    private func setMarkdownPinnedToTask(_ pinnedToTask: Bool) {
        guard isMarkdownPinnedToTask != pinnedToTask else { return }

        let previousSession = currentMarkdownSession
        let previousURL = previousSession.fileURL
        isMarkdownPinnedToTask = pinnedToTask
        lastGeneratedMarkdownPreviewSignature = ""

        let nextSession = currentMarkdownSession
        if let previousURL, !nextSession.hasFile {
            nextSession.load(previousURL)
        }

        if pinnedToTask {
            previewGeneratedMarkdownForSelectedTaskIfNeeded()
        }
    }

    private func startComposingTask() {
        setSelectedTask(nil)
        isComposingTask = true
        presentRightRail()
    }

    private func handleQuickRunTask(_ task: AgentTask) {
        promoteDraftBrowserSessionIfNeeded(to: task)
        setSelectedTask(task)
        isComposingTask = false
        runSingleTask(task)
    }

    private func handleTaskCreated(_ task: AgentTask) {
        promoteDraftBrowserSessionIfNeeded(to: task)
        setSelectedTask(task)
        isComposingTask = false
        presentRightRail()
    }

    private func promoteDraftBrowserSessionIfNeeded(to task: AgentTask) {
        guard selectedTask == nil || isComposingTask else { return }
        let wasPresented = activeWorkspaceCanvasItem == .browser
        let promoted = browserSessionStore.promoteSharedSession(
            to: task.id,
            pinnedToTask: isBrowserPinnedToTask,
            isPresented: wasPresented,
            enabledBrowserAdapters: enabledBrowserAdapterIDs(for: task)
        )
        guard promoted else { return }

        AppLogger.audit(.shelfBrowserPreview, category: "Browser", taskID: task.id, fields: [
            "event": "draft_browser_promoted",
            "source": "new_task_handoff",
            "pinned_to_task": String(isBrowserPinnedToTask),
            "was_presented": String(wasPresented)
        ])
    }

    private func openPlanCanvas(_ task: AgentTask) {
        if selectedTask?.id == task.id {
            guard cachedHasCanvasContent else { return }
        } else {
            guard TaskPlanService.reconstruct(for: task).plan != nil else { return }
        }
        if selectedTask?.id == task.id, activeWorkspaceCanvasItem == .plan {
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
            return
        }
        if selectedTask?.id != task.id {
            setSelectedTask(task)
        }
        isComposingTask = false
        presentCanvas(.plan)
    }

    private func openExistingTask(_ task: AgentTask) {
        setSelectedTask(task)
        isComposingTask = false
    }

    private func handlePendingExternalRoute() {
        guard let route = externalRouteStore.pendingRoute else { return }

        let resolution = externalRouteResolver.resolve(route, workspaces: workspaces)
        applyExternalRouteResolution(resolution)
        externalRouteStore.clear(route)
    }

    private func applyExternalRouteResolution(_ resolution: ContentExternalRouteResolution) {
        externalRouteNotice = resolution.noticeMessage
        switch resolution {
        case .openWorkspace(let workspace):
            openWorkspaceFromExternalRoute(workspace)

        case .openTask(let task):
            openTaskFromExternalRoute(task)

        case .createdTask(let task, let shouldRun):
            openTaskFromExternalRoute(task)
            if shouldRun {
                runSingleTask(task)
            }

        case .unresolved(let message):
            AppLogger.warning(message, category: "AppIntents")
        }
    }

    private func openWorkspaceFromExternalRoute(_ workspace: Workspace) {
        selectedWorkspace = workspace
        setSelectedTask(nil)
        isComposingTask = false
        presentRightRail()
    }

    private func openTaskFromExternalRoute(_ task: AgentTask) {
        setSelectedTask(task)
        isComposingTask = false
        presentRightRail()
    }

    private func moveTaskToDraft(_ task: AgentTask) {
        isComposingTask = false
        setSelectedTask(nil)
        DispatchQueue.main.async {
            setSelectedTask(task)
        }
    }

    // MARK: - Coordinator

    private var coordinator: TaskLifecycleCoordinator {
        TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: runtime.taskQueue)
    }

    private var sceneCoordinator: ContentSceneCoordinator {
        ContentSceneCoordinator(
            workspaces: workspaces,
            selectedTask: selectedTask,
            selectedWorkspace: selectedWorkspace,
            lastSelectedWorkspaceID: lastSelectedWorkspaceID,
            lastSelectedWorkspacePath: lastSelectedWorkspacePath
        )
    }

    private var workspaceActionCoordinator: ContentWorkspaceActionCoordinator {
        ContentWorkspaceActionCoordinator(
            modelContext: modelContext,
            taskQueue: runtime.taskQueue,
            workspacesRoot: workspacesRoot
        )
    }

    private var externalRouteResolver: ContentExternalRouteResolver {
        ContentExternalRouteResolver(
            modelContext: modelContext,
            defaultRuntimeID: defaultRuntimeID,
            defaultModel: defaultModel,
            defaultBudget: defaultBudget
        )
    }

    private var updateSafetySignature: String {
        return [
            String(runtime.taskQueue.isProcessing),
            String(runtime.taskQueue.activeCount),
            String(runtime.taskQueue.activeTasks.count),
            String(runningTaskCount)
        ].joined(separator: "|")
    }

    private var hasUpdateBlockingWork: Bool {
        AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: runtime.taskQueue.isProcessing,
            activeWorkerCount: runtime.taskQueue.activeCount,
            activeTaskCount: runtime.taskQueue.activeTasks.count,
            runningTaskCount: runningTaskCount
        )
    }

    private func isUpdateBlockedNow() -> Bool {
        AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: runtime.taskQueue.isProcessing,
            activeWorkerCount: runtime.taskQueue.activeCount,
            activeTaskCount: runtime.taskQueue.activeTasks.count,
            runningTaskCount: fetchRunningTaskCount()
        )
    }

    private func fetchRunningTaskCount() -> Int {
        PerformanceTelemetry.measure(
            "update_safety_count",
            thresholdMilliseconds: 8
        ) {
            let runningStatus = TaskStatus.running
            let descriptor = FetchDescriptor<AgentTask>(
                predicate: #Predicate<AgentTask> { task in
                    task.status == runningStatus
                }
            )
            return (try? modelContext.fetchCount(descriptor)) ?? 0
        }
    }

    private func refreshRunningTaskCount() {
        runningTaskCount = fetchRunningTaskCount()
    }

    private func refreshUpdateSafetyHooks() {
        appUpdateController.configureSafety(
            isWorkActive: { isUpdateBlockedNow() },
            prepareForInstall: { prepareForAppUpdateInstall() }
        )
    }

    private func prepareForAppUpdateInstall() -> Bool {
        refreshRunningTaskCount()
        guard !hasUpdateBlockingWork else {
            AppLogger.audit(.appUpdateBlocked, category: "Updater", fields: [
                "reason": "active_work_preinstall"
            ], level: .warning)
            return false
        }

        runtime.taskScheduler.stop()
        for workspace in workspaces {
            WorkspacePersistenceCoordinator.flushPendingExport(
                workspace: workspace,
                modelContext: modelContext
            )
        }

        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.appUpdateBlocked, category: "Updater", fields: [
                "reason": "swiftdata_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }

        do {
            try WorkspaceRecoveryService.copyStoreBackup(
                at: WorkspaceRecoveryService.storeURL,
                label: "pre-update"
            )
            return true
        } catch {
            AppLogger.audit(.appUpdateBlocked, category: "Updater", fields: [
                "reason": "store_backup_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
    }

    // MARK: - Workspace Management

    private func createWorkspace() {
        newWorkspaceDraft.clear()
        showingNewWorkspace = true
    }

    private func resetNewWorkspaceDraft() {
        newWorkspaceDraft.clear()
    }

    private func restoreWorkspaceSelection() {
        let restored = sceneCoordinator.restoredWorkspace()
        if let restored {
            if selectedWorkspace?.id != restored.id {
                selectedWorkspace = restored
            }
        } else {
            selectedWorkspace = nil
            setSelectedTask(nil)
            isComposingTask = false
        }
    }

    private func persistWorkspaceSelection() {
        let persistence = sceneCoordinator.persistence(for: selectedWorkspace)
        lastSelectedWorkspaceID = persistence.workspaceID
        lastSelectedWorkspacePath = persistence.workspacePath
    }

    private var resolvedRoot: String {
        workspaceActionCoordinator.resolvedRoot
    }

    private func finalizeNewWorkspace() {
        guard createWorkspace(from: newWorkspaceDraft, source: "workspace_creation") else { return }
        showingNewWorkspace = false
        resetNewWorkspaceDraft()
    }

    @discardableResult
    private func finalizeOnboardingWorkspace(_ draft: NewWorkspaceDraft) -> Bool {
        createWorkspace(from: draft, source: "onboarding")
    }

    @discardableResult
    private func createWorkspace(from draft: NewWorkspaceDraft, source: String) -> Bool {
        guard let result = workspaceActionCoordinator.createWorkspace(from: draft, source: source) else { return false }
        selectedWorkspace = result.workspace
        return true
    }

    private func deleteWorkspace(_ ws: Workspace) {
        if selectedWorkspace?.id == ws.id {
            selectedWorkspace = nil
        }
        let next = coordinator.deleteWorkspace(ws, existingWorkspaces: workspaces)
        if let next {
            selectedWorkspace = next
        }
    }

    private func importWorkspace() {
        let urls = WorkspaceImportPanel.selectedURLs()
        guard !urls.isEmpty else { return }

        let result = workspaceActionCoordinator.importWorkspaces(
            from: urls,
            existingWorkspaces: workspaces,
            askDuplicateAction: WorkspaceDuplicateActionPrompt.ask
        )
        if let selected = result.selectedWorkspace {
            selectedWorkspace = selected
        }
    }

    // MARK: - Task Actions

    private func setSelectedTask(_ task: AgentTask?) {
        let previousTaskID = selectedTask?.id
        let shouldCloseBrowserForTaskChange = isBrowserPinnedToTask
            && activeWorkspaceCanvasItem == .browser
            && previousTaskID != nil
            && previousTaskID != task?.id
        if let taskWorkspace = task?.workspace,
           selectedWorkspace?.id != taskWorkspace.id {
            selectedWorkspace = taskWorkspace
        }
        selectedTask = task
        if previousTaskID != task?.id {
            lastGeneratedHTMLPreviewSignature = ""
            lastGeneratedMarkdownPreviewSignature = ""
            currentBrowserSession.bindToTask(task?.id)
            currentMarkdownSession.bindToTask(task?.id)
            querySession.bindToTask(task?.id)
            if shouldCloseBrowserForTaskChange {
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
            syncBrowserPresentation()
            refreshMarkdownShelfAvailabilityForSelectedTask()
            refreshQueryShelfAvailabilityForSelectedTask()
            previewGeneratedHTMLForSelectedTaskIfNeeded()
            previewGeneratedMarkdownForSelectedTaskIfNeeded()
        }
        if task != nil {
            isComposingTask = false
        }
        markTaskRead(task)
    }

    private func markSelectedTaskReadIfNeeded() {
        markTaskRead(selectedTask)
    }

    private func markTaskRead(_ task: AgentTask?) {
        guard let task, task.unreadAt != nil else { return }
        task.markRead()
        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.taskFailed, category: "UI", taskID: task.id, fields: [
                "operation": "mark_task_read",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private func runQueue() {
        applySettings()
        coordinator.runQueue()
        refreshRunningTaskCount()
    }

    private func runSingleTask(_ task: AgentTask) {
        applySettings()
        coordinator.runSingleTask(task)
        refreshRunningTaskCount()
    }
    private func cancelTask(_ task: AgentTask) {
        coordinator.cancelTask(task)
        refreshRunningTaskCount()
    }

    private func retryTask(_ task: AgentTask) {
        coordinator.retryTask(task)
        refreshRunningTaskCount()
    }

    private func resumeTask(_ task: AgentTask) {
        coordinator.resumeTask(task)
        refreshRunningTaskCount()
    }

    private func approveTask(_ task: AgentTask) {
        coordinator.approveTask(task)
        refreshRunningTaskCount()
    }

    private func deleteTask(_ task: AgentTask) {
        if selectedTask?.id == task.id {
            setSelectedTask(nil)
        }
        _ = coordinator.deleteTask(task)
        refreshRunningTaskCount()
    }

    private func requestDeleteTask(_ task: AgentTask) {
        let linkedSchedules = coordinator.activeSameThreadSchedules(for: task)
        guard !linkedSchedules.isEmpty else {
            deleteTask(task)
            return
        }
        linkedScheduleWarning = LinkedScheduleWarning(task: task, schedules: linkedSchedules, action: .delete)
    }

    private func toggleDone(_ task: AgentTask) {
        setDoneState(task, to: !task.isDone)
    }

    private func setDoneState(_ task: AgentTask, to isDone: Bool) {
        guard task.isDone != isDone else { return }

        if !isDone {
            coordinator.setDoneState(task, to: false)
            refreshRunningTaskCount()
            return
        }

        let linkedSchedules = coordinator.activeSameThreadSchedules(for: task)
        guard !linkedSchedules.isEmpty else {
            coordinator.setDoneState(task, to: true)
            refreshRunningTaskCount()
            return
        }

        linkedScheduleWarning = LinkedScheduleWarning(task: task, schedules: linkedSchedules, action: .markDone)
    }

    private func pauseSchedulesAndContinue(_ warning: LinkedScheduleWarning) {
        coordinator.pauseSchedules(warning.schedules)

        switch warning.action {
        case .markDone:
            coordinator.setDoneState(warning.task, to: true)
            refreshRunningTaskCount()
        case .delete:
            deleteTask(warning.task)
        }
    }

    // MARK: - Migration

    private func migrateConnectorCredentials() {
        coordinator.migrateConnectorCredentials(workspaces: workspaces)
    }

    private func migrateSkillSecrets() {
        let descriptor = FetchDescriptor<Skill>(sortBy: [SortDescriptor(\.name)])
        let skills = (try? modelContext.fetch(descriptor)) ?? []
        coordinator.migrateSkillSecrets(skills: skills)
    }

    private func backfillThreadTitlesIfNeeded() {
        runtime.backfillThreadTitlesIfNeeded(
            coordinator: coordinator,
            claudePath: claudePath,
            copilotPath: copilotPath,
            providerSettings: providerSettingsSnapshot.providerSettings,
            defaultRuntimeID: defaultRuntimeID,
            validationModel: validationModel,
            isUITestingSeededLaunch: isUITestingSeededLaunch
        )
    }

    private func handleSelectedWorkspaceChanged() {
        let selectedWorkspaceID: UUID? = selectedWorkspace?.id
        let taskWorkspaceID: UUID? = selectedTask?.workspace?.id
        if selectedTask != nil, taskWorkspaceID != selectedWorkspaceID {
            setSelectedTask(nil)
        }
        if isUITestingSeededLaunch {
            setSelectedTask(nil)
            isComposingTask = selectedWorkspace != nil
        } else {
            isComposingTask = false
        }
        persistWorkspaceSelection()
    }

    private func handleWorkspaceSelectionSignatureChanged() {
        restoreWorkspaceSelection()
        enterUITestComposerIfNeeded()
        handlePendingExternalRoute()
    }

    private func handleAppear() {
        cachedHasCanvasContent = selectedTask.flatMap { TaskPlanService.reconstruct(for: $0).plan } != nil
        if hasCompletedOnboarding, !hasPresentedOnboarding {
            hasPresentedOnboarding = true
        }
        applySecurityGateDefaultIfNeeded()
        applySettings()
        seedTestDataIfNeeded()
        migrateConnectorCredentials()
        migrateSkillSecrets()
        restoreWorkspaceSelection()
        backfillThreadTitlesIfNeeded()
        refreshProviderModelsInBackground()
        enterUITestComposerIfNeeded()
        runtime.startScheduler(modelContext: modelContext)
        runtime.loadPluginCatalog()
        refreshRunningTaskCount()
        handlePendingExternalRoute()
        refreshUpdateSafetyHooks()
        appUpdateController.probeForUpdatesOnce()
    }

    private func applySecurityGateDefaultIfNeeded() {
        guard !securityGateDefaultedToReview else { return }
        skipPermissions = false
        securityGateDefaultedToReview = true
    }

    // MARK: - Seeding

    private var isUITestingSeededLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments
        let testFlags = ["--uitesting-seed", "--uitesting-phase1", "--uitesting-phase2", "--uitesting-phase3"]
        return args.contains(where: { testFlags.contains($0) })
    }

    private func enterUITestComposerIfNeeded() {
        guard isUITestingSeededLaunch, selectedWorkspace != nil else { return }

        setSelectedTask(nil)
        isComposingTask = true
    }

    private func seedTestDataIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard isUITestingSeededLaunch else { return }

        let phaseDirs: [(String, String)] = [
            ("--uitesting-phase1", "/tmp/uitest_phase1"),
            ("--uitesting-phase2", "/tmp/uitest_phase2"),
            ("--uitesting-phase3", "/tmp/uitest_phase3")
        ]
        for (flag, dir) in phaseDirs {
            if args.contains(flag) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }

        let descriptor = FetchDescriptor<AgentTask>()
        guard (try? modelContext.fetchCount(descriptor)) == 0 else {
            let wsDescriptor = FetchDescriptor<Workspace>()
            if let existing = try? modelContext.fetch(wsDescriptor).first {
                selectedWorkspace = existing
                enterUITestComposerIfNeeded()
            }
            return
        }

        let testPath: String
        if args.contains("--uitesting-phase1") {
            testPath = "/tmp/uitest_phase1"
        } else if args.contains("--uitesting-phase2") {
            testPath = "/tmp/uitest_phase2"
        } else if args.contains("--uitesting-phase3") {
            testPath = "/tmp/uitest_phase3"
        } else {
            testPath = "/tmp"
        }

        let ws = Workspace(name: "Test Workspace", primaryPath: testPath)
        modelContext.insert(ws)
        selectedWorkspace = ws
        enterUITestComposerIfNeeded()

        if args.contains("--uitesting-seed") {
            let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
            let task = AgentTask(
                title: "Seeded Task",
                goal: "UI test task",
                workspace: ws,
                tokenBudget: TaskExecutionDefaults.tokenBudget,
                model: RuntimeModelAvailability.defaultModel(for: runtime),
                runtime: runtime
            )
            task.status = .queued
            modelContext.insert(task)
        }
        try? modelContext.save()
    }

    private func applySettings() {
        runtime.applySettings(
            claudePath: claudePath,
            copilotPath: copilotPath,
            providerSettings: providerSettingsSnapshot.providerSettings,
            defaultRuntimeID: defaultRuntimeID,
            timeoutSeconds: timeoutSeconds,
            validationModel: validationModel,
            skipPermissions: skipPermissions,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw
        )
        refreshProviderModelsInBackground()
    }

    private func refreshProviderModelsInBackground() {
        guard !isUITestingSeededLaunch else { return }
        let providerSettings = providerSettingsSnapshot.providerSettings
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            refreshRuntimeModelsInBackground(runtime, providerSettings: providerSettings)
        }
    }

    private func refreshRuntimeModelsInBackground(
        _ runtime: AgentRuntimeID,
        providerSettings: AgentRuntimeProviderSettings
    ) {
        let resolvedExecutablePath = resolvedRuntimeExecutablePath(
            for: runtime,
            providerSettings: providerSettings
        )
        guard FileManager.default.isExecutableFile(atPath: resolvedExecutablePath) else { return }

        let signature = providerSettingsSnapshot.modelRefreshSignature(
            runtime: runtime,
            executablePath: resolvedExecutablePath,
        )
        guard runtimeModelRefreshTasks[runtime] == nil,
              lastRuntimeModelRefreshSignatures[runtime] != signature else { return }
        lastRuntimeModelRefreshSignatures[runtime] = signature

        var configuration = providerSettingsSnapshot.readinessConfiguration(for: runtime)
        configuration.providerSettings = providerSettings
        runtimeModelRefreshTasks[runtime] = Task {
            _ = await AgentRuntimeAdapterRegistry
                .adapter(for: runtime)
                .modelAvailabilityCheck(configuration: configuration)
            await MainActor.run {
                runtimeModelRefreshTasks[runtime] = nil
            }
        }
    }

    private func resolvedRuntimeExecutablePath(
        for runtime: AgentRuntimeID,
        providerSettings: AgentRuntimeProviderSettings
    ) -> String {
        let configuredPath = providerSettings.executablePath(for: runtime)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuredPath.isEmpty else { return configuredPath }

        switch AgentRuntimeAdapterRegistry.descriptor(for: runtime).executableName {
        case "claude":
            return RuntimePathResolver.detectClaudePath()
        case "copilot":
            return CopilotCLIRuntime.detectPath()
        case let executableName:
            return RuntimePathResolver.detectExecutablePath(named: executableName)
        }
    }
}

private struct WorkspaceTopRightActions: Equatable {
    let hasWorkspace: Bool
    let canShowPlanShelf: Bool
    let canShowTextShelf: Bool
    let canShowBrowserShelf: Bool
    let canShowQueryShelf: Bool
    let activeCanvasItem: WorkspaceCanvasItem?
    let browserEngine: ShelfBrowserEngine
    let isRightRailVisible: Bool

    var isPlanShelfVisible: Bool { activeCanvasItem == .plan }
    var isTextShelfVisible: Bool { activeCanvasItem == .markdown }
    var isBrowserShelfVisible: Bool { activeCanvasItem == .browser }
    var isQueryShelfVisible: Bool { activeCanvasItem == .query }

    var hasShelfControls: Bool {
        canShowPlanShelf || canShowTextShelf || canShowQueryShelf || canShowBrowserShelf
    }
}

private struct WorkspaceTopRightToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let actions: WorkspaceTopRightActions
    let onToggleBrowser: () -> Void
    let onOpenBrowserEngine: (ShelfBrowserEngine) -> Void
    let onTogglePlan: () -> Void
    let onToggleText: () -> Void
    let onToggleQuery: () -> Void
    let onToggleControlPanel: () -> Void

    @State private var browserMenuAnchor: NSView?

    var body: some View {
        HStack(spacing: 18) {
            AstraToolbarCommandCluster {
                shelfControls
            }
            .background(alignment: .leading) {
                shelfActiveIndicator
            }
            .frame(width: shelfClusterWidth, alignment: .trailing)
            .clipped()
            .allowsHitTesting(actions.hasShelfControls)
            .accessibilityHidden(!actions.hasShelfControls)
            .animation(commandAnimation, value: shelfClusterWidth)
            .animation(commandAnimation, value: activeShelfIndicator?.key)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shelf controls")

            AstraToolbarContextCommandCluster {
                toolbarButton(
                    title: actions.isRightRailVisible ? "Hide Workspace Context" : "Show Workspace Context",
                    systemImage: "sidebar.right",
                    isActive: actions.isRightRailVisible,
                    action: onToggleControlPanel
                )
                // Restores the Cmd-Opt-I shortcut that SwiftUI's built-in
                // `.inspector(isPresented:)` modifier used to provide; we
                // dropped that modifier when moving to a custom HStack column.
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(actions.isRightRailVisible ? "Hide Workspace Context (⌥⌘I)" : "Show Workspace Context (⌥⌘I)")
                .accessibilityIdentifier("ControlPanelToolbarButton")
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace Context")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var shelfControls: some View {
        if actions.canShowPlanShelf {
            shelfToolbarButton(
                title: actions.isPlanShelfVisible ? "Hide Plan Shelf" : "Show Plan Shelf",
                label: "Plan",
                systemImage: "list.bullet.clipboard",
                isActive: actions.isPlanShelfVisible,
                action: onTogglePlan
            )
            .accessibilityLabel("Plan shelf")
        }

        if actions.canShowTextShelf {
            shelfToolbarButton(
                title: actions.isTextShelfVisible ? "Hide Files Shelf" : "Show Files Shelf",
                label: "Files",
                systemImage: "folder",
                isActive: actions.isTextShelfVisible,
                action: onToggleText
            )
            .accessibilityLabel("Files shelf")
        }

        if actions.canShowQueryShelf {
            shelfToolbarButton(
                title: actions.isQueryShelfVisible ? "Hide Query Shelf" : "Show Query Shelf",
                label: "Query",
                systemImage: "cylinder.split.1x2",
                isActive: actions.isQueryShelfVisible,
                action: onToggleQuery
            )
            .accessibilityLabel("Query shelf")
        }

        if actions.canShowBrowserShelf {
            browserMenuButton
                .accessibilityLabel("Browser shelf")
        }
    }

    private var browserMenuButton: some View {
        Button {
            presentBrowserMenu()
        } label: {
            AstraToolbarCommandLabel(
                systemImage: "globe",
                text: "Browser",
                isActive: actions.isBrowserShelfVisible,
                showsMenuIndicator: true,
                showsActiveBackground: false
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            ToolbarMenuAnchorView(anchor: $browserMenuAnchor)
        }
        .help("Open Browser Shelf")
        .accessibilityLabel("Browser shelf mode")
    }

    private func presentBrowserMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(
            ToolbarClosureMenuItem(
                title: "Open Embedded Browser",
                systemSymbolName: actions.browserEngine == .embedded ? "checkmark" : "globe"
            ) {
                onOpenBrowserEngine(.embedded)
            }
        )
        menu.addItem(
            ToolbarClosureMenuItem(
                title: "Open Controlled Browser",
                systemSymbolName: actions.browserEngine == .controlled ? "checkmark" : "macwindow"
            ) {
                onOpenBrowserEngine(.controlled)
            }
        )

        if actions.isBrowserShelfVisible {
            menu.addItem(.separator())
            menu.addItem(
                ToolbarClosureMenuItem(
                    title: "Hide Browser Shelf",
                    systemSymbolName: "xmark"
                ) {
                    onToggleBrowser()
                }
            )
        }

        if let browserMenuAnchor {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: browserMenuAnchor.bounds.minY - 4),
                in: browserMenuAnchor
            )
        } else if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    private var shelfClusterWidth: CGFloat {
        guard !shelfControlWidths.isEmpty else { return 0 }
        return shelfControlWidths.reduce(0, +)
            + (CGFloat(shelfControlWidths.count - 1) * AstraToolbarCommandMetrics.clusterSpacing)
            + (AstraToolbarCommandMetrics.clusterHorizontalPadding * 2)
    }

    private var shelfControlWidths: [CGFloat] {
        var widths: [CGFloat] = []
        if actions.canShowPlanShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowTextShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowQueryShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
        if actions.canShowBrowserShelf { widths.append(AstraToolbarCommandMetrics.labeledMenuControlMinWidth) }
        return widths
    }

    private var commandAnimation: Animation? {
        AstraMotion.toolbarCommand(reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private var shelfActiveIndicator: some View {
        if let activeShelfIndicator {
            Capsule()
                .fill(Stanford.lagunita.opacity(AstraToolbarCommandMetrics.activeFillOpacity))
                .frame(
                    width: activeShelfIndicator.width,
                    height: AstraToolbarCommandMetrics.controlHeight
                )
                .offset(x: activeShelfIndicator.offset)
        }
    }

    private var activeShelfIndicator: ShelfActiveIndicator? {
        var offset = AstraToolbarCommandMetrics.clusterHorizontalPadding

        if actions.canShowPlanShelf {
            if actions.isPlanShelfVisible {
                return ShelfActiveIndicator(key: "plan", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowTextShelf {
            if actions.isTextShelfVisible {
                return ShelfActiveIndicator(key: "files", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowQueryShelf {
            if actions.isQueryShelfVisible {
                return ShelfActiveIndicator(key: "query", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

        if actions.canShowBrowserShelf, actions.isBrowserShelfVisible {
            return ShelfActiveIndicator(key: "browser", offset: offset, width: AstraToolbarCommandMetrics.labeledMenuControlMinWidth)
        }

        return nil
    }

    private func shelfToolbarButton(
        title: String,
        label: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AstraToolbarCommandLabel(
                systemImage: systemImage,
                text: label,
                isActive: isActive,
                showsActiveBackground: false
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func toolbarButton(
        title: String,
        label: String? = nil,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let label {
                AstraToolbarCommandLabel(systemImage: systemImage, text: label, isActive: isActive)
            } else {
                AstraToolbarCommandIcon(systemImage: systemImage, isActive: isActive)
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ShelfActiveIndicator: Equatable {
    let key: String
    let offset: CGFloat
    let width: CGFloat
}

private struct ToolbarMenuAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = ToolbarMenuAnchorNSView()
        resolve(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolve(nsView)
    }

    private func resolve(_ nsView: NSView) {
        guard anchor == nil || anchor !== nsView else { return }
        DispatchQueue.main.async {
            if anchor == nil || anchor !== nsView {
                anchor = nsView
            }
        }
    }
}

private final class ToolbarMenuAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ToolbarClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemSymbolName: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(performMenuAction), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performMenuAction() {
        handler()
    }
}

private struct ContentToolbar: ToolbarContent {
    @ObservedObject var appUpdateController: AppUpdateController

    let onCheckForUpdates: () -> Void

    var body: some ToolbarContent {
        if appUpdateController.shouldShowUpdateButton {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onCheckForUpdates) {
                    Label(appUpdateController.buttonTitle, systemImage: "arrow.down.circle")
                }
                .help(appUpdateController.statusMessage ?? "Install the available ASTRA update")
                .accessibilityIdentifier("AppUpdateButton")
            }
        }
    }
}

private struct ContentDetailAreaView: View {
    let selectedTask: AgentTask?
    let effectiveWorkspace: Workspace?
    let isComposingTask: Bool
    let taskQueue: TaskQueue
    @ObservedObject var browserSession: ShelfBrowserSession
    @Binding var isBrowserPinnedToTask: Bool
    @ObservedObject var markdownSession: ShelfMarkdownSession
    @Binding var isMarkdownPinnedToTask: Bool
    @ObservedObject var querySession: ShelfQuerySession
    let queryUtilityRuntime: AgentUtilityRuntimeConfiguration
    let sshReloadTrigger: Int
    @Binding var isRightRailPresented: Bool
    @Binding var activeCanvasItem: WorkspaceCanvasItem?
    let isPlanCanvasVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.planShelfWidth) private var planShelfStoredWidth = Double(WorkspaceCanvasItem.plan.idealWidth)
    @AppStorage(AppStorageKeys.browserShelfWidth) private var browserShelfStoredWidth = Double(WorkspaceCanvasItem.browser.idealWidth)
    @AppStorage(AppStorageKeys.markdownShelfWidth) private var markdownShelfStoredWidth = Double(WorkspaceCanvasItem.markdown.idealWidth)
    @AppStorage(AppStorageKeys.queryShelfWidth) private var queryShelfStoredWidth = Double(WorkspaceCanvasItem.query.idealWidth)
    @AppStorage(AppStorageKeys.rightRailWidth) private var rightRailStoredWidth = 0.0
    @State private var shelfDragStartWidth: CGFloat?
    @State private var shelfTransientWidth: CGFloat?
    @State private var shelfDragShouldDismiss = false
    @State private var resizingShelfItem: WorkspaceCanvasItem?
    @State private var rightRailDragStartWidth: CGFloat?
    @State private var rightRailTransientWidth: CGFloat?
    @State private var isResizingRightRail = false

    let onQuickRun: (AgentTask) -> Void
    let onTaskCreated: (AgentTask) -> Void
    let onAddSSHConnection: () -> Void
    let onManageSkills: () -> Void
    let onRunTask: (AgentTask) -> Void
    let onCancelTask: (AgentTask) -> Void
    let onRetryTask: (AgentTask) -> Void
    let onResumeTask: (AgentTask) -> Void
    let onApproveTask: (AgentTask) -> Void
    let onOpenPlan: (AgentTask) -> Void
    let onToggleDone: (AgentTask) -> Void
    let onMoveToDraft: (AgentTask) -> Void
    let onForkTask: (AgentTask) -> Void
    let onCreateTask: () -> Void
    let onOpenTask: (AgentTask) -> Void
    let onDeleteTask: (AgentTask) -> Void
    let onSetDoneState: (AgentTask, Bool) -> Void
    let onRunQueue: () -> Void
    let onConfigure: () -> Void
    let onNewSchedule: () -> Void
    let onEditSchedule: (TaskSchedule) -> Void
    let onManageCapabilities: () -> Void
    let onEditWorkspace: () -> Void
    let onOpenConfigureTab: (ConfigureTab, UUID?) -> Void
    let onOpenCapabilityPackage: (String) -> Void
    let onNewSSHConnection: () -> Void
    let onEditSSHConnection: (SSHConnection) -> Void
    let onCreateWorkspace: () -> Void
    let onImportWorkspace: () -> Void
    let onOpenGeneratedFile: (String) -> Void
    let onOpenWorkspaceFile: (String) -> Void

    private static let contentMinWidth: CGFloat = 480

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let activePanel = activeRightPanel
            let usesInspectorOverlay = activePanel?.isContext == true
                && PanelLayoutGeometry.shouldOverlayInspector(
                    detailAreaWidth: availableWidth,
                    minimumDetailWidth: Self.contentMinWidth
                )
            let dockedPanelWidth = activePanel.flatMap { panel in
                usesInspectorOverlay ? nil : rightPanelWidth(for: panel, availableWidth: availableWidth, isOverlay: false)
            } ?? 0
            let detailWidth = max(0, proxy.size.width - dockedPanelWidth)

            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    detailContent
                        .frame(width: usesInspectorOverlay ? proxy.size.width : detailWidth, height: proxy.size.height)
                        .clipped()

                    if let activePanel, !usesInspectorOverlay {
                        rightPanel(
                            activePanel,
                            width: dockedPanelWidth,
                            availableWidth: availableWidth,
                            isOverlay: false
                        )
                        .transition(panelSlideTransition)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if let activePanel, usesInspectorOverlay {
                    let overlayWidth = rightPanelWidth(for: activePanel, availableWidth: availableWidth, isOverlay: true)
                    inspectorOverlayScrim
                    rightPanel(
                        activePanel,
                        width: overlayWidth,
                        availableWidth: availableWidth,
                        isOverlay: true
                    )
                    .padding(.trailing, PanelLayoutGeometry.inspectorOverlayHorizontalMargin)
                    .transition(panelSlideTransition)
                    .zIndex(1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Stanford.panelBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(panelAnimation, value: activeRightPanel)
    }

    private var activeRightPanel: WorkspaceRightPanel? {
        if let activeCanvasItem {
            return .canvas(activeCanvasItem)
        }
        if isRightRailPresented, let workspace = effectiveWorkspace {
            return .context(workspace.id)
        }
        return nil
    }

    private func rightPanelWidth(
        for panel: WorkspaceRightPanel,
        availableWidth: CGFloat,
        isOverlay: Bool
    ) -> CGFloat {
        switch panel {
        case .canvas(let item):
            return shelfWidth(for: item, availableWidth: availableWidth)
        case .context:
            if isOverlay {
                return PanelLayoutGeometry.inspectorOverlayWidth(for: availableWidth)
            }
            return rightRailWidth(availableWidth: availableWidth)
        }
    }

    @ViewBuilder
    private func rightPanel(
        _ panel: WorkspaceRightPanel,
        width: CGFloat,
        availableWidth: CGFloat,
        isOverlay: Bool
    ) -> some View {
        switch panel {
        case .canvas(let item):
            shelfPanel(for: item, width: width, availableWidth: availableWidth)
        case .context:
            if let workspace = effectiveWorkspace {
                rightRail(
                    workspace: workspace,
                    width: width,
                    availableWidth: availableWidth,
                    isOverlay: isOverlay
                )
            }
        }
    }

    private func rightRail(
        workspace: Workspace,
        width: CGFloat,
        availableWidth: CGFloat,
        isOverlay: Bool
    ) -> some View {
        WorkspaceRightRailView(
            workspace: workspace,
            selectedTask: selectedTask,
            onConfigure: onConfigure,
            onEditWorkspace: onEditWorkspace,
            onNewSchedule: onNewSchedule,
            onEditSchedule: onEditSchedule,
            onManageCapabilities: onManageCapabilities,
            onOpenConfigureTab: onOpenConfigureTab,
            onOpenCapabilityPackage: onOpenCapabilityPackage,
            onTaskCreated: onTaskCreated,
            onOpenWorkspaceFile: onOpenWorkspaceFile,
            onNewSSHConnection: onNewSSHConnection,
            onEditSSHConnection: onEditSSHConnection,
            sshReloadTrigger: sshReloadTrigger,
            isCompact: isOverlay || width <= PanelLayoutGeometry.inspectorMinColumnWidth + 8,
            onDismiss: isOverlay ? { isRightRailPresented = false } : nil
        )
        .id(workspace.id)
        .frame(width: width)
        .overlay(alignment: .leading) {
            if !isOverlay {
                rightRailResizeHandle(availableWidth: availableWidth)
            }
        }
    }

    private func rightRailWidth(availableWidth: CGFloat) -> CGFloat {
        let storedWidth = CGFloat(rightRailStoredWidth)
        let committedWidth = storedWidth > 0
            ? storedWidth
            : PanelLayoutGeometry.inspectorDockedColumnWidth(for: availableWidth)
        let candidate = isResizingRightRail ? (rightRailTransientWidth ?? committedWidth) : committedWidth
        return clampedRightRailWidth(candidate, availableWidth: availableWidth)
    }

    private func clampedRightRailWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        PanelLayoutGeometry.inspectorResizableColumnWidth(
            width,
            detailAreaWidth: availableWidth,
            minimumDetailWidth: Self.contentMinWidth
        )
    }

    private func storeRightRailWidth(_ width: CGFloat, availableWidth: CGFloat) {
        rightRailStoredWidth = Double(clampedRightRailWidth(width, availableWidth: availableWidth))
    }

    private func rightRailResizeHandle(availableWidth: CGFloat) -> some View {
        ShelfResizeHandle(
            isResizing: isResizingRightRail,
            helpText: "Drag to resize the Workspace Context panel",
            onChanged: { translation in
                if rightRailDragStartWidth == nil || !isResizingRightRail {
                    isResizingRightRail = true
                    rightRailDragStartWidth = rightRailWidth(availableWidth: availableWidth)
                }
                guard let rightRailDragStartWidth else { return }
                let proposedWidth = rightRailDragStartWidth - translation.width
                let next = clampedRightRailWidth(proposedWidth, availableWidth: availableWidth)
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    rightRailTransientWidth = next
                }
            },
            onEnded: {
                if let rightRailTransientWidth {
                    storeRightRailWidth(rightRailTransientWidth, availableWidth: availableWidth)
                }
                rightRailDragStartWidth = nil
                rightRailTransientWidth = nil
                isResizingRightRail = false
            }
        )
    }

    private var inspectorOverlayScrim: some View {
        Color.black.opacity(0.08)
            .ignoresSafeArea(.all, edges: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                isRightRailPresented = false
            }
            .accessibilityHidden(true)
    }

    private var panelAnimation: Animation? {
        AstraMotion.rightPanel(reduceMotion: reduceMotion)
    }

    private var panelSlideTransition: AnyTransition {
        reduceMotion ? .identity : .move(edge: .trailing)
    }

    private func shelfPanel(
        for item: WorkspaceCanvasItem,
        width: CGFloat,
        availableWidth: CGFloat
    ) -> some View {
        let isResizing = resizingShelfItem == item
        return ZStack {
            canvasContent(for: item)
                .id(item)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Keep the shelf material below the titlebar so toolbar commands sit on window chrome.
        .background(.bar)
        .overlay(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)

                shelfResizeHandle(for: item, availableWidth: availableWidth)
            }
        }
        .preference(
            key: ShelfBoundaryMetricsPreferenceKey.self,
            value: ShelfBoundaryMetrics(
                width: width,
                isVisible: true,
                isResizing: isResizing
            )
        )
    }

    private func committedShelfWidth(for item: WorkspaceCanvasItem, availableWidth: CGFloat) -> CGFloat {
        let storedWidth: CGFloat
        switch item {
        case .plan:
            storedWidth = CGFloat(planShelfStoredWidth)
        case .markdown:
            storedWidth = CGFloat(markdownShelfStoredWidth)
        case .browser:
            storedWidth = CGFloat(browserShelfStoredWidth)
        case .query:
            storedWidth = CGFloat(queryShelfStoredWidth)
        }
        return clampedShelfWidth(storedWidth, for: item, availableWidth: availableWidth)
    }

    private func shelfWidth(for item: WorkspaceCanvasItem, availableWidth: CGFloat) -> CGFloat {
        let storedWidth = committedShelfWidth(for: item, availableWidth: availableWidth)
        let candidate = resizingShelfItem == item ? (shelfTransientWidth ?? storedWidth) : storedWidth
        return clampedShelfWidth(candidate, for: item, availableWidth: availableWidth)
    }

    private func clampedShelfWidth(_ width: CGFloat, for item: WorkspaceCanvasItem, availableWidth: CGFloat) -> CGFloat {
        PanelLayoutGeometry.clampedShelfWidth(
            width,
            shelfMinWidth: item.minWidth,
            shelfMaxWidth: item.maxWidth,
            minimumDetailWidth: minimumDetailWidth(for: item),
            availableWidth: availableWidth
        )
    }

    private func minimumDetailWidth(for item: WorkspaceCanvasItem) -> CGFloat {
        item == .browser ? 520 : 420
    }

    private func storeShelfWidth(_ width: CGFloat, for item: WorkspaceCanvasItem, availableWidth: CGFloat) {
        let clampedWidth = clampedShelfWidth(width, for: item, availableWidth: availableWidth)
        switch item {
        case .plan:
            planShelfStoredWidth = Double(clampedWidth)
        case .markdown:
            markdownShelfStoredWidth = Double(clampedWidth)
        case .browser:
            browserShelfStoredWidth = Double(clampedWidth)
        case .query:
            queryShelfStoredWidth = Double(clampedWidth)
        }
    }

    private func shelfResizeHandle(for item: WorkspaceCanvasItem, availableWidth: CGFloat) -> some View {
        ShelfResizeHandle(
            isResizing: resizingShelfItem == item,
            helpText: "Drag to resize the \(item.title) Shelf",
            onChanged: { translation in
                if shelfDragStartWidth == nil || resizingShelfItem != item {
                    resizingShelfItem = item
                    shelfDragStartWidth = shelfWidth(for: item, availableWidth: availableWidth)
                    shelfDragShouldDismiss = false
                }
                guard let shelfDragStartWidth else { return }
                let proposedWidth = shelfDragStartWidth - translation.width
                let next = clampedShelfWidth(proposedWidth, for: item, availableWidth: availableWidth)
                let shouldDismiss = item.closesWhenDraggedBelowMinimum
                    && PanelLayoutGeometry.shouldDismissShelfResize(
                        proposedWidth: proposedWidth,
                        shelfMinWidth: item.minWidth
                    )
                // Bypass any ambient .animation modifier so the panel tracks the cursor 1:1.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    shelfTransientWidth = next
                    shelfDragShouldDismiss = shouldDismiss
                }
            },
            onEnded: {
                let shouldDismiss = resizingShelfItem == item && shelfDragShouldDismiss
                if let shelfTransientWidth, !shouldDismiss {
                    storeShelfWidth(shelfTransientWidth, for: item, availableWidth: availableWidth)
                }
                shelfDragStartWidth = nil
                shelfTransientWidth = nil
                shelfDragShouldDismiss = false
                resizingShelfItem = nil
                if shouldDismiss {
                    activeCanvasItem = nil
                }
            }
        )
    }

    private var detailContent: some View {
        ContentDetailContentView(
            selectedTask: selectedTask,
            effectiveWorkspace: effectiveWorkspace,
            isComposingTask: isComposingTask,
            taskQueue: taskQueue,
            sshReloadTrigger: sshReloadTrigger,
            isPlanCanvasVisible: isPlanCanvasVisible,
            onQuickRun: onQuickRun,
            onTaskCreated: onTaskCreated,
            onAddSSHConnection: onAddSSHConnection,
            onManageSkills: onManageSkills,
            onRunTask: onRunTask,
            onCancelTask: onCancelTask,
            onRetryTask: onRetryTask,
            onResumeTask: onResumeTask,
            onApproveTask: onApproveTask,
            onOpenPlan: onOpenPlan,
            onToggleDone: onToggleDone,
            onMoveToDraft: onMoveToDraft,
            onForkTask: onForkTask,
            onCreateTask: onCreateTask,
            onOpenTask: onOpenTask,
            onDeleteTask: onDeleteTask,
            onSetDoneState: onSetDoneState,
            onRunQueue: onRunQueue,
            onConfigure: onConfigure,
            onNewSchedule: onNewSchedule,
            onEditSchedule: onEditSchedule,
            onManageCapabilities: onManageCapabilities,
            onCreateWorkspace: onCreateWorkspace,
            onImportWorkspace: onImportWorkspace,
            onOpenGeneratedFile: onOpenGeneratedFile
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func canvasContent(for item: WorkspaceCanvasItem) -> some View {
        switch item {
        case .plan:
            WorkspaceCanvasPanelView(
                selectedTask: selectedTask,
                isPresented: canvasPresentedBinding(for: .plan)
            )
        case .markdown:
            ShelfMarkdownPanelView(
                session: markdownSession,
                isPresented: canvasPresentedBinding(for: .markdown),
                isPinnedToTask: $isMarkdownPinnedToTask,
                workspace: effectiveWorkspace,
                task: selectedTask,
                onOpenGeneratedFile: onOpenGeneratedFile
            )
        case .browser:
            ShelfBrowserPanelView(
                session: browserSession,
                isPresented: canvasPresentedBinding(for: .browser),
                isPinnedToTask: $isBrowserPinnedToTask
            )
        case .query:
            ShelfQueryPanelView(
                session: querySession,
                workspace: effectiveWorkspace,
                task: selectedTask,
                utilityRuntime: queryUtilityRuntime,
                isPresented: canvasPresentedBinding(for: .query)
            )
        }
    }

    private func canvasPresentedBinding(for item: WorkspaceCanvasItem) -> Binding<Bool> {
        Binding(
            get: { activeCanvasItem == item },
            set: { isPresented in
                if !isPresented {
                    activeCanvasItem = nil
                } else if activeCanvasItem == nil {
                    activeCanvasItem = item
                }
            }
        )
    }
}

private struct ContentDetailContentView: View {
    let selectedTask: AgentTask?
    let effectiveWorkspace: Workspace?
    let isComposingTask: Bool
    let taskQueue: TaskQueue
    let sshReloadTrigger: Int
    let isPlanCanvasVisible: Bool
    let onQuickRun: (AgentTask) -> Void
    let onTaskCreated: (AgentTask) -> Void
    let onAddSSHConnection: () -> Void
    let onManageSkills: () -> Void
    let onRunTask: (AgentTask) -> Void
    let onCancelTask: (AgentTask) -> Void
    let onRetryTask: (AgentTask) -> Void
    let onResumeTask: (AgentTask) -> Void
    let onApproveTask: (AgentTask) -> Void
    let onOpenPlan: (AgentTask) -> Void
    let onToggleDone: (AgentTask) -> Void
    let onMoveToDraft: (AgentTask) -> Void
    let onForkTask: (AgentTask) -> Void
    let onCreateTask: () -> Void
    let onOpenTask: (AgentTask) -> Void
    let onDeleteTask: (AgentTask) -> Void
    let onSetDoneState: (AgentTask, Bool) -> Void
    let onRunQueue: () -> Void
    let onConfigure: () -> Void
    let onNewSchedule: () -> Void
    let onEditSchedule: (TaskSchedule) -> Void
    let onManageCapabilities: () -> Void
    let onCreateWorkspace: () -> Void
    let onImportWorkspace: () -> Void
    let onOpenGeneratedFile: (String) -> Void

    var body: some View {
        switch ContentDetailPresentation.resolve(
            selectedTask: selectedTask,
            effectiveWorkspace: effectiveWorkspace,
            isComposingTask: isComposingTask
        ) {
        case .draftTask:
            if let task = selectedTask {
                ChatPanelView(
                    taskQueue: taskQueue,
                    workspace: task.workspace ?? effectiveWorkspace,
                    sshReloadTrigger: sshReloadTrigger,
                    draftToLoad: task,
                    onQuickRun: onQuickRun,
                    onTaskCreated: onTaskCreated,
                    onAddSSHConnection: onAddSSHConnection,
                    onManageSkills: onManageSkills,
                    isPlanCanvasVisible: isPlanCanvasVisible,
                    onOpenPlan: onOpenPlan
                )
                .id(task.id)
            }
        case .existingTask:
            if let task = selectedTask {
                TaskMainView(
                    task: task,
                    taskQueue: taskQueue,
                    onRunTask: onRunTask,
                    onCancelTask: onCancelTask,
                    onRetryTask: onRetryTask,
                    onResumeTask: onResumeTask,
                    onApproveTask: onApproveTask,
                    onOpenPlan: onOpenPlan,
                    isPlanCanvasVisible: isPlanCanvasVisible,
                    onToggleDone: onToggleDone,
                    sshReloadTrigger: sshReloadTrigger,
                    onMoveToDraft: onMoveToDraft,
                    onManageSkills: onManageSkills,
                    onForkTask: onForkTask,
                    onOpenGeneratedFile: onOpenGeneratedFile
                )
                .id(task.id)
            }
        case .newTaskComposer:
            ChatPanelView(
                taskQueue: taskQueue,
                workspace: effectiveWorkspace,
                sshReloadTrigger: sshReloadTrigger,
                onQuickRun: onQuickRun,
                onTaskCreated: onTaskCreated,
                onAddSSHConnection: onAddSSHConnection,
                onManageSkills: onManageSkills,
                isPlanCanvasVisible: isPlanCanvasVisible,
                onOpenPlan: onOpenPlan
            )
        case .workspaceHome:
            if let workspace = effectiveWorkspace {
                WorkspaceHomeContainerView(
                    workspace: workspace,
                    taskQueue: taskQueue,
                    onCreateTask: onCreateTask,
                    onOpenTask: onOpenTask,
                    onDeleteTask: onDeleteTask,
                    onSetDoneState: onSetDoneState,
                    onRunQueue: onRunQueue,
                    onConfigure: onConfigure,
                    onNewSchedule: onNewSchedule,
                    onEditSchedule: onEditSchedule,
                    onManageCapabilities: onManageCapabilities
                )
            }
        case .noWorkspace:
            WorkspaceEmptyStateView(
                onCreateWorkspace: onCreateWorkspace,
                onImportWorkspace: onImportWorkspace
            )
        }
    }
}

private struct NewWorkspaceSheet: View {
    @Binding var draft: NewWorkspaceDraft
    let rootPath: String
    let onCancel: () -> Void
    let onCreate: () -> Void

    @State private var validationIssues: [String] = []
    @State private var validationWarnings: [String] = []
    @State private var isShowingValidationWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ScrollView {
                WorkspaceSetupForm(
                    draft: $draft,
                    rootPath: rootPath,
                    mode: .standard,
                    validationIssues: $validationIssues,
                    validationWarnings: $validationWarnings,
                    onSubmit: {
                        if canCreate {
                            attemptCreate()
                        }
                    }
                )
            }
            .scrollIndicators(.visible)
            footer
        }
        .padding(24)
        .frame(width: 620)
        .frame(maxHeight: 760)
        .background(Stanford.panelBackground)
        .alert("Create with unvalidated capabilities?", isPresented: $isShowingValidationWarning) {
            Button("Continue Anyway") {
                onCreate()
            }
            Button("Back", role: .cancel) {}
        } message: {
            Text(validationWarnings.prefix(3).joined(separator: "\n"))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Stanford.lagunita.opacity(0.12))
                Image(systemName: "folder.badge.plus")
                    .font(Stanford.ui(20, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text("New Workspace")
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)

                Text("Create a focused place for a project, team, or recurring workflow.")
                    .font(Stanford.body(14))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canCreate: Bool {
        !draft.trimmedName.isEmpty && validationIssues.isEmpty
    }

    private var footer: some View {
        HStack {
            if let firstIssue = validationIssues.first {
                Label(firstIssue, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let firstWarning = validationWarnings.first {
                Label(firstWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .keyboardShortcut(.cancelAction)

            Button("Create", action: attemptCreate)
                .buttonStyle(StanfordButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.45)
        }
    }

    private func attemptCreate() {
        guard canCreate else { return }
        if validationWarnings.isEmpty {
            onCreate()
        } else {
            isShowingValidationWarning = true
        }
    }
}

enum WorkspaceSetupFormMode {
    case onboarding
    case standard

    var isCapabilityForward: Bool {
        self == .onboarding
    }

    var guidanceDescription: String {
        switch self {
        case .onboarding:
            return "Add persistent context agents should know for this workspace: conventions, usernames, preferred tools, or boundaries."
        case .standard:
            return "Add persistent context agents should know for this workspace. You can edit this later from Workspace Context."
        }
    }

    var guidancePlaceholder: String {
        switch self {
        case .onboarding:
            return "Example: GitHub PR review. Username: alvaro. Prefer concise summaries. Ask before release changes."
        case .standard:
            return "Example: PR review workspace. Prefer concise summaries and ask before release changes."
        }
    }

    var guidanceMinHeight: CGFloat {
        isCapabilityForward ? 104 : 86
    }

    var capabilitiesTitle: String {
        isCapabilityForward ? "Quick-start capabilities" : "Workspace capabilities"
    }

    var capabilitiesDescription: String {
        if isCapabilityForward {
            return "Connect the systems this workspace can use immediately."
        }
        return "None selected · can be added later from Workspace Context."
    }
}

private enum WorkspaceCapabilityValidationState: Equatable {
    case unchecked
    case checking
    case ready(String)
    case failed(String)
}

private struct WorkspaceSetupValidationSecretStore: SecretStore {
    var credentials: [String: String]

    func load(key: String, entityID _: String) -> String? {
        credentials[key] ?? credentials[key.uppercased()]
    }

    @discardableResult
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool {
        false
    }

    @discardableResult
    func delete(key _: String, entityID _: String) -> Bool {
        false
    }

    func deleteAll(entityID _: String) {}

    func exists(key: String, entityID _: String) -> Bool {
        load(key: key, entityID: "") != nil
    }
}

struct WorkspaceSetupForm: View {
    @Environment(\.preflightCache) private var preflightCache
    @Environment(\.scenePhase) private var scenePhase
    @Binding var draft: NewWorkspaceDraft
    @Query(sort: \Workspace.name) private var capabilitySetupSourceWorkspaces: [Workspace]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    let rootPath: String
    let mode: WorkspaceSetupFormMode
    @Binding var validationIssues: [String]
    @Binding var validationWarnings: [String]
    var onSubmit: (() -> Void)?

    @FocusState private var focusedField: Field?
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @State private var isCapabilitiesExpanded: Bool
    @State private var capabilityPreflightStatuses: [String: [String: HealthStatus]] = [:]
    @State private var probingCapabilityPackageIDs: Set<String> = []
    @State private var capabilityValidationStates: [String: WorkspaceCapabilityValidationState] = [:]
    @State private var capabilityValidationSignatures: [String: String] = [:]
    @State private var copiedCapabilitySetup: CapabilitySetupCopySummary?

    private enum Field {
        case name
        case guidance
    }

    init(
        draft: Binding<NewWorkspaceDraft>,
        rootPath: String,
        mode: WorkspaceSetupFormMode,
        validationIssues: Binding<[String]>,
        validationWarnings: Binding<[String]> = .constant([]),
        onSubmit: (() -> Void)? = nil
    ) {
        self._draft = draft
        self.rootPath = rootPath
        self.mode = mode
        self._validationIssues = validationIssues
        self._validationWarnings = validationWarnings
        self.onSubmit = onSubmit
        self._isCapabilitiesExpanded = State(initialValue: mode.isCapabilityForward)
    }

    private var displayedRootPath: String {
        (rootPath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Workspace name")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)

                TextField("Example: GitHub PRs", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(Stanford.body(15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Stanford.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(focusedField == .name ? Stanford.focusRing : Color.secondary.opacity(0.20), lineWidth: 1)
                    )
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        onSubmit?()
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(Stanford.ui(12, weight: .medium))
                        .foregroundStyle(Stanford.lagunita)
                    Text("Workspace guidance")
                        .font(Stanford.caption(13).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text("Optional")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.coolGrey)
                }

                Text(mode.guidanceDescription)
                    .font(Stanford.body(13))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft.instructions)
                        .font(Stanford.body(14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: mode.guidanceMinHeight)
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(focusedField == .guidance ? Stanford.focusRing : Color.secondary.opacity(0.20), lineWidth: 1)
                        )
                        .focused($focusedField, equals: .guidance)

                    if draft.instructions.isEmpty {
                        Text(mode.guidancePlaceholder)
                            .font(Stanford.body(14))
                            .foregroundStyle(Stanford.coolGrey.opacity(0.62))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                }
            }

            capabilitiesSection

            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(Stanford.coolGrey)
                Text("Folder will be created in \(displayedRootPath)")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onAppear {
            focusedField = .name
            applyCapabilityDefaults()
            syncCapabilityValidationSignatures()
            refreshValidationIssues()
            Task {
                await probeCapabilityPrerequisites(forceRefresh: false)
                refreshValidationIssues()
            }
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            Task {
                await probeCapabilityPrerequisites(forceRefresh: true)
                refreshValidationIssues()
            }
        }
        .onChange(of: draft) {
            invalidateChangedCapabilityValidations()
            refreshValidationIssues()
        }
        .onChange(of: capabilityPreflightStatuses) {
            refreshValidationIssues()
        }
        .onChange(of: probingCapabilityPackageIDs) {
            refreshValidationIssues()
        }
        .onChange(of: capabilityValidationStates) {
            refreshValidationIssues()
        }
    }

    private var capabilitiesSection: some View {
        DisclosureGroup(isExpanded: $isCapabilitiesExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if mode.isCapabilityForward {
                    Text("Pick one or more capabilities now so the first task can use them right away. You can change these later in Workspace Context.")
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.coolGrey)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if hasAvailableCapabilityDefaults {
                    availableCapabilityShortcut
                }

                if !copyableCapabilitySetupSourceWorkspaces.isEmpty {
                    copyCapabilitySetupShortcut
                }

                ForEach(OnboardingCapabilitySetup.configurableOptions) { option in
                    workspaceCapabilityRow(option)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(Stanford.ui(12, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.capabilitiesTitle)
                            .font(Stanford.caption(13).weight(.semibold))
                            .foregroundStyle(Stanford.black)
                        Text("Optional")
                            .font(Stanford.caption(11).weight(.medium))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                    Text(selectedCapabilitySummary)
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.coolGrey)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(mode.isCapabilityForward ? Stanford.lagunita.opacity(0.06) : Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(mode.isCapabilityForward ? Stanford.lagunita.opacity(0.24) : Stanford.sandstone.opacity(0.22), lineWidth: 1)
        )
    }

    private var availableCapabilityShortcut: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "wand.and.stars")
                .font(Stanford.ui(10, weight: .medium))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 14)
            Text(availableCapabilityShortcutText)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Select available") {
                selectAvailableCapabilities()
            }
            .font(Stanford.caption(11))
            .buttonStyle(.borderless)
            .tint(Stanford.lagunita)
            .disabled(!hasAvailableCapabilityDefaults)
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private var copyCapabilitySetupShortcut: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: copiedCapabilitySetup == nil ? "square.on.square" : "checkmark.circle.fill")
                .font(Stanford.ui(10, weight: .medium))
                .foregroundStyle(copiedCapabilitySetup == nil ? Stanford.lagunita : Stanford.paloAltoGreen)
                .frame(width: 14)
            Text(copyCapabilitySetupText)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Menu {
                ForEach(copyableCapabilitySetupSourceWorkspaces, id: \.id) { workspace in
                    Button(copyMenuTitle(for: workspace)) {
                        copyCapabilitySetup(from: workspace)
                    }
                }
            } label: {
                Label("Copy From", systemImage: "arrow.down.doc")
                    .font(Stanford.caption(11).weight(.medium))
            }
            .menuStyle(.button)
            .fixedSize()
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private func workspaceCapabilityRow(_ option: OnboardingCapabilityOption) -> some View {
        let packageID = option.packageID
        let isSelected = packageID.map { draft.selectedCapabilityIDs.contains($0) } ?? false

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: option.icon)
                    .font(Stanford.ui(14, weight: .semibold))
                    .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.coolGrey)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(Stanford.black)
                    Text(capabilityOutcomeSubtitle(for: option))
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.coolGrey)
                        .lineLimit(1)
                }

                Spacer()

                if let packageID {
                    Text(capabilityStatusText(for: packageID))
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(capabilityStatusColor(for: packageID))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(capabilityStatusColor(for: packageID).opacity(0.1))
                        .clipShape(Capsule())

                    Toggle("", isOn: capabilityBinding(for: packageID))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Stanford.lagunita)
                        .accessibilityLabel(option.title)
                }
            }

            if let packageID, isSelected {
                capabilitySetupFields(for: packageID)
                if let issue = capabilityIssue(for: packageID) {
                    capabilityInlineMessage(
                        icon: "exclamationmark.triangle.fill",
                        message: issue,
                        tint: Stanford.poppy
                    )
                }
                capabilityValidationControls(for: packageID)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(isSelected ? Stanford.lagunita.opacity(0.08) : Stanford.fog.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? Stanford.lagunita.opacity(0.22) : Stanford.sandstone.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func capabilitySetupFields(for packageID: String) -> some View {
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            VStack(alignment: .leading, spacing: 8) {
                capabilityTextField("Base URL", prompt: "https://company.atlassian.net", text: $draft.capabilityConfiguration.jiraBaseURL)
                capabilityTextField("Email", prompt: "you@example.com", text: $draft.capabilityConfiguration.jiraEmail)
                capabilitySecureField("API token", prompt: "Stored in Keychain", text: $draft.capabilityConfiguration.jiraAPIToken)
                capabilityTextField("Project keys", prompt: "ENG, OPS", text: $draft.capabilityConfiguration.jiraProjects)
            }
        case OnboardingCapabilitySetup.githubPackageID:
            capabilityPrerequisitesView(
                for: packageID,
                readyMessage: "Uses the authenticated gh CLI from the environment check."
            )
        case OnboardingCapabilitySetup.gcloudPackageID:
            VStack(alignment: .leading, spacing: 8) {
                capabilityPrerequisitesView(
                    for: packageID,
                    readyMessage: "gcloud is installed and authenticated."
                )

                HStack {
                    Text("Project defaults")
                        .font(Stanford.caption(10).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                        .textCase(.uppercase)
                    Spacer()
                    if hasVertexDefaults {
                        Button("Use Vertex Settings") {
                            applyCapabilityDefaults()
                        }
                        .font(Stanford.caption(11))
                    }
                }
                capabilityTextField("GCP project", prompt: "my-gcp-project", text: $draft.capabilityConfiguration.gcpProject)
                capabilityTextField("Region", prompt: OnboardingCapabilityConfiguration.defaultGCPRegion, text: $draft.capabilityConfiguration.gcpRegion)
            }
        case OnboardingCapabilitySetup.redcapPackageID:
            VStack(alignment: .leading, spacing: 8) {
                capabilityTextField("API URL", prompt: OnboardingCapabilityConfiguration.defaultRedcapAPIURL, text: $draft.capabilityConfiguration.redcapAPIURL)
                capabilitySecureField("API token", prompt: "Stored in Keychain", text: $draft.capabilityConfiguration.redcapAPIToken)
            }
        default:
            EmptyView()
        }
    }

    private func capabilityInlineMessage(icon: String, message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .padding(.top, 1)
            Text(message)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func capabilityValidationControls(for packageID: String) -> some View {
        let state = capabilityValidationState(for: packageID)
        let blocked = capabilityIssue(for: packageID) != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await validateCapability(packageID) }
                } label: {
                    HStack(spacing: 6) {
                        if case .checking = state {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.shield")
                        }
                        Text(state == .checking ? "Testing" : "Test Connection")
                    }
                }
                .font(Stanford.caption(11).weight(.semibold))
                .disabled(blocked || state == .checking)
                .help(blocked ? "Complete setup fields before testing this capability." : "Run the checks ASTRA uses before task execution.")

                Text(capabilityValidationSummary(for: packageID))
                    .font(Stanford.caption(11))
                    .foregroundStyle(capabilityValidationColor(for: packageID))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }

            if let message = capabilityValidationDetail(for: packageID), !blocked {
                capabilityInlineMessage(
                    icon: capabilityValidationIcon(for: packageID),
                    message: message,
                    tint: capabilityValidationColor(for: packageID)
                )
            }
        }
    }

    private func capabilityOutcomeSubtitle(for option: OnboardingCapabilityOption) -> String {
        switch option.packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            return "Create, update, and summarize Jira tickets"
        case OnboardingCapabilitySetup.githubPackageID:
            return "Review PRs, issues, and CI"
        case OnboardingCapabilitySetup.gcloudPackageID:
            return "Query BigQuery and work with GCP resources"
        case OnboardingCapabilitySetup.redcapPackageID:
            return "Talk to REDCap projects and metadata"
        default:
            return option.subtitle
        }
    }

    private func capabilityReadyMessage(for packageID: String) -> String {
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            return "Ready: tasks in this workspace can use Jira."
        case OnboardingCapabilitySetup.githubPackageID:
            return "Ready: tasks in this workspace can use GitHub."
        case OnboardingCapabilitySetup.gcloudPackageID:
            return "Ready: tasks in this workspace can use Google Cloud and BigQuery."
        case OnboardingCapabilitySetup.redcapPackageID:
            return "Ready: tasks in this workspace can use REDCap."
        default:
            return "Ready: tasks in this workspace can use this capability."
        }
    }

    private func capabilityTextField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(Stanford.coolGrey)
                .textCase(.uppercase)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.ui(12))
        }
    }

    private func capabilitySecureField(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Stanford.caption(10).weight(.semibold))
                .foregroundStyle(Stanford.coolGrey)
                .textCase(.uppercase)
            SecureField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.ui(12))
        }
    }

    private var selectedCapabilitySummary: String {
        let names = OnboardingCapabilitySetup.selectedDisplayNames(from: draft.selectedCapabilityIDs)
        if names.isEmpty {
            return mode.capabilitiesDescription
        }
        let label = names.count == 1 ? "1 selected" : "\(names.count) selected"
        return "\(label): \(names.joined(separator: ", "))"
    }

    private var capabilityIssues: [String] {
        draft.capabilitySetupIssues(githubCLIReady: true)
    }

    private var capabilityWarnings: [String] {
        OnboardingCapabilitySetup.configurableOptions.compactMap { option -> String? in
            guard let packageID = option.packageID,
                  draft.selectedCapabilityIDs.contains(packageID),
                  configurationIssue(for: packageID) == nil else {
                return nil
            }

            if let issue = capabilityPrerequisiteIssue(for: packageID) {
                return "\(option.title): \(issue)"
            }

            switch capabilityValidationState(for: packageID) {
            case .ready:
                return nil
            case .checking:
                return "\(option.title): connection test is still running"
            case .failed(let message):
                return "\(option.title): \(message)"
            case .unchecked:
                return "\(option.title): connection has not been tested"
            }
        }
    }

    private func refreshValidationIssues() {
        validationIssues = capabilityIssues
        validationWarnings = capabilityWarnings
    }

    private func configurationIssue(for packageID: String) -> String? {
        guard draft.selectedCapabilityIDs.contains(packageID) else { return nil }
        let githubReady = capabilityPrerequisitesReady(for: OnboardingCapabilitySetup.githubPackageID)
        return draft.capabilityConfiguration
            .missingRequirements(for: packageID, githubCLIReady: githubReady)
            .first
    }

    private func capabilityIssue(for packageID: String) -> String? {
        if let configurationIssue = configurationIssue(for: packageID) {
            return configurationIssue
        }
        return nil
    }

    private func capabilityIsReady(for packageID: String) -> Bool {
        guard draft.selectedCapabilityIDs.contains(packageID),
              capabilityIssue(for: packageID) == nil,
              capabilityPrerequisiteIssue(for: packageID) == nil,
              case .ready = capabilityValidationState(for: packageID) else {
            return false
        }
        return true
    }

    private var isGitHubHealthy: Bool {
        capabilityPrerequisitesReady(for: OnboardingCapabilitySetup.githubPackageID)
    }

    private var hasVertexDefaults: Bool {
        !claudeVertexProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !claudeVertexRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableCapabilityNames: [String] {
        var names: [String] = []
        if isGitHubHealthy {
            names.append("GitHub")
        }
        if hasVertexDefaults && capabilityPrerequisitesReady(for: OnboardingCapabilitySetup.gcloudPackageID) {
            names.append("Google Cloud")
        }
        return names
    }

    private var hasAvailableCapabilityDefaults: Bool {
        !availableCapabilityNames.isEmpty
    }

    private var availableCapabilityShortcutText: String {
        let names = availableCapabilityNames
        let prefix = names.count == 1 ? "1 available now" : "\(names.count) available now"
        return "\(prefix): \(names.joined(separator: ", "))"
    }

    private var copyableCapabilitySetupSourceWorkspaces: [Workspace] {
        capabilitySetupSourceWorkspaces.filter { workspace in
            let summary = CapabilitySetupCopier().copySetup(from: workspace, globalConnectors: globalConnectors)
            return !summary.selectedPackageIDs.isEmpty && !summary.inputsByPackageID.isEmpty
        }
    }

    private var copyCapabilitySetupText: String {
        guard let copiedCapabilitySetup else {
            return "Reuse setup from another workspace"
        }
        let label = copiedCapabilitySetup.packageCount == 1 ? "1 capability" : "\(copiedCapabilitySetup.packageCount) capabilities"
        return "Copied \(label) from \(copiedCapabilitySetup.sourceWorkspaceName)"
    }

    private func copyMenuTitle(for workspace: Workspace) -> String {
        let names = OnboardingCapabilitySetup.selectedDisplayNames(
            from: CapabilitySetupCopier().copySetup(from: workspace, globalConnectors: globalConnectors).selectedPackageIDs
        )
        guard !names.isEmpty else { return workspace.name }
        return "\(workspace.name) - \(names.joined(separator: ", "))"
    }

    private func copyCapabilitySetup(from workspace: Workspace) {
        let summary = CapabilitySetupCopier().copySetup(from: workspace, globalConnectors: globalConnectors)
        guard !summary.selectedPackageIDs.isEmpty, !summary.inputsByPackageID.isEmpty else { return }

        draft.selectedCapabilityIDs = summary.selectedPackageIDs
        draft.capabilityConfiguration = OnboardingCapabilityConfiguration()
        draft.capabilityConfiguration.applyCopiedInputs(summary.inputsByPackageID)
        copiedCapabilitySetup = summary
        syncCapabilityValidationSignatures()
        refreshValidationIssues()
        Task {
            await probeCapabilityPrerequisites(forceRefresh: false)
            refreshValidationIssues()
        }
    }

    private func capabilityStatusText(for packageID: String) -> String {
        if draft.selectedCapabilityIDs.contains(packageID) {
            if capabilityIssue(for: packageID) != nil { return "Setup needed" }
            if let (prerequisite, status) = firstUnreadyPrerequisite(for: packageID) {
                return prerequisiteStatusLabel(prerequisite, status: status)
            }
            switch capabilityValidationState(for: packageID) {
            case .unchecked:
                return "Unchecked"
            case .checking:
                return "Checking"
            case .ready:
                return "Ready"
            case .failed:
                return "Error"
            }
        }

        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            if isProbingCapability(packageID) { return "Checking" }
            return isGitHubHealthy ? "Available" : "Setup needed"
        case OnboardingCapabilitySetup.gcloudPackageID:
            if isProbingCapability(packageID) { return "Checking" }
            let project = draft.capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !project.isEmpty, capabilityPrerequisitesReady(for: packageID) { return "Available" }
            if hasVertexDefaults, capabilityPrerequisitesReady(for: packageID) { return "Available" }
            return "Setup needed"
        case OnboardingCapabilitySetup.jiraPackageID, OnboardingCapabilitySetup.redcapPackageID:
            return "Setup needed"
        default:
            return "Optional"
        }
    }

    private func capabilityStatusColor(for packageID: String) -> Color {
        if draft.selectedCapabilityIDs.contains(packageID) {
            if capabilityIssue(for: packageID) != nil { return Stanford.coolGrey }
            if firstUnreadyPrerequisite(for: packageID) != nil { return Stanford.poppy }
            switch capabilityValidationState(for: packageID) {
            case .ready:
                return Stanford.paloAltoGreen
            case .failed:
                return Stanford.poppy
            case .checking, .unchecked:
                return Stanford.coolGrey
            }
        }

        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            return Stanford.coolGrey
        case OnboardingCapabilitySetup.gcloudPackageID:
            return Stanford.coolGrey
        default:
            return Stanford.coolGrey
        }
    }

    private func capabilityBinding(for packageID: String) -> Binding<Bool> {
        Binding(
            get: { draft.selectedCapabilityIDs.contains(packageID) },
            set: { enabled in
                copiedCapabilitySetup = nil
                if enabled {
                    draft.selectedCapabilityIDs.insert(packageID)
                    capabilityValidationSignatures[packageID] = capabilityValidationSignature(for: packageID)
                    capabilityValidationStates[packageID] = .unchecked
                    if packageID == OnboardingCapabilitySetup.gcloudPackageID {
                        applyCapabilityDefaults()
                        capabilityValidationSignatures[packageID] = capabilityValidationSignature(for: packageID)
                    }
                    Task { await probeCapabilityPrerequisites(for: packageID, forceRefresh: false) }
                } else {
                    draft.selectedCapabilityIDs.remove(packageID)
                    capabilityValidationStates.removeValue(forKey: packageID)
                    capabilityValidationSignatures.removeValue(forKey: packageID)
                }
                refreshValidationIssues()
            }
        )
    }

    private func applyCapabilityDefaults() {
        _ = draft.capabilityConfiguration.applyEnvironmentDefaults(
            gcpProject: claudeVertexProjectID,
            gcpRegion: claudeVertexRegion
        )
    }

    private func selectAvailableCapabilities() {
        copiedCapabilitySetup = nil
        applyCapabilityDefaults()
        if isGitHubHealthy {
            draft.selectedCapabilityIDs.insert(OnboardingCapabilitySetup.githubPackageID)
        }
        if !draft.capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           capabilityPrerequisitesReady(for: OnboardingCapabilitySetup.gcloudPackageID) {
            draft.selectedCapabilityIDs.insert(OnboardingCapabilitySetup.gcloudPackageID)
        }
        syncCapabilityValidationSignatures()
        refreshValidationIssues()
    }

    private func syncCapabilityValidationSignatures() {
        let selected = draft.selectedCapabilityIDs
        for packageID in selected {
            capabilityValidationSignatures[packageID] = capabilityValidationSignature(for: packageID)
            capabilityValidationStates[packageID] = capabilityValidationStates[packageID] ?? .unchecked
        }
        for packageID in Array(capabilityValidationStates.keys) where !selected.contains(packageID) {
            capabilityValidationStates.removeValue(forKey: packageID)
            capabilityValidationSignatures.removeValue(forKey: packageID)
        }
    }

    private func invalidateChangedCapabilityValidations() {
        let selected = draft.selectedCapabilityIDs
        for packageID in selected {
            let signature = capabilityValidationSignature(for: packageID)
            guard capabilityValidationSignatures[packageID] != signature else { continue }
            capabilityValidationSignatures[packageID] = signature
            capabilityValidationStates[packageID] = .unchecked
        }
        for packageID in Array(capabilityValidationStates.keys) where !selected.contains(packageID) {
            capabilityValidationStates.removeValue(forKey: packageID)
            capabilityValidationSignatures.removeValue(forKey: packageID)
        }
    }

    private func capabilityValidationSignature(for packageID: String) -> String {
        let config = draft.capabilityConfiguration
        switch packageID {
        case OnboardingCapabilitySetup.jiraPackageID:
            return [
                config.jiraBaseURL,
                config.jiraEmail,
                config.jiraAPIToken,
                config.jiraProjects
            ].map(trimmed).joined(separator: "|")
        case OnboardingCapabilitySetup.githubPackageID:
            return packageID
        case OnboardingCapabilitySetup.gcloudPackageID:
            return [
                config.gcpProject,
                config.gcpRegion
            ].map(trimmed).joined(separator: "|")
        case OnboardingCapabilitySetup.redcapPackageID:
            return [
                config.redcapAPIURL,
                config.redcapAPIToken
            ].map(trimmed).joined(separator: "|")
        default:
            return packageID
        }
    }

    private func capabilityValidationState(for packageID: String) -> WorkspaceCapabilityValidationState {
        capabilityValidationStates[packageID] ?? .unchecked
    }

    private func capabilityValidationSummary(for packageID: String) -> String {
        switch capabilityValidationState(for: packageID) {
        case .unchecked:
            return "Not tested yet"
        case .checking:
            return "Checking now..."
        case .ready:
            return "Connection verified"
        case .failed:
            return "Needs attention"
        }
    }

    private func capabilityValidationDetail(for packageID: String) -> String? {
        switch capabilityValidationState(for: packageID) {
        case .unchecked:
            return "Run Test Connection to verify this setup before the first task uses it."
        case .checking:
            return "ASTRA is checking this capability with a bounded timeout."
        case .ready(let message):
            return message.isEmpty ? capabilityReadyMessage(for: packageID) : message
        case .failed(let message):
            return message.isEmpty ? "Connection test failed." : message
        }
    }

    private func capabilityValidationIcon(for packageID: String) -> String {
        switch capabilityValidationState(for: packageID) {
        case .ready:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .checking:
            return "clock"
        case .unchecked:
            return "info.circle"
        }
    }

    private func capabilityValidationColor(for packageID: String) -> Color {
        switch capabilityValidationState(for: packageID) {
        case .ready:
            return Stanford.paloAltoGreen
        case .failed:
            return Stanford.poppy
        case .checking, .unchecked:
            return Stanford.coolGrey
        }
    }

    @MainActor
    private func validateCapability(_ packageID: String) async {
        guard draft.selectedCapabilityIDs.contains(packageID),
              capabilityIssue(for: packageID) == nil else {
            refreshValidationIssues()
            return
        }

        let signature = capabilityValidationSignature(for: packageID)
        capabilityValidationSignatures[packageID] = signature
        capabilityValidationStates[packageID] = .checking
        refreshValidationIssues()

        let result = await runCapabilityValidation(for: packageID)
        guard capabilityValidationSignature(for: packageID) == signature else {
            capabilityValidationStates[packageID] = .unchecked
            refreshValidationIssues()
            return
        }

        capabilityValidationStates[packageID] = result
        refreshValidationIssues()
    }

    private func runCapabilityValidation(for packageID: String) async -> WorkspaceCapabilityValidationState {
        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            await probeCapabilityPrerequisites(for: packageID, forceRefresh: true)
            if let issue = capabilityPrerequisiteIssue(for: packageID) {
                return .failed(issue)
            }
            return .ready("GitHub CLI is installed and authenticated.")
        case OnboardingCapabilitySetup.gcloudPackageID:
            await probeCapabilityPrerequisites(for: packageID, forceRefresh: true)
            if let issue = capabilityPrerequisiteIssue(for: packageID) {
                return .failed(issue)
            }
            return await validateGCloudProject()
        case OnboardingCapabilitySetup.jiraPackageID:
            return await validateConnectorCapability(
                packageID: packageID,
                connector: jiraValidationConnector(),
                credentials: [
                    "JIRA_EMAIL": draft.capabilityConfiguration.jiraEmail,
                    "JIRA_API_TOKEN": draft.capabilityConfiguration.jiraAPIToken
                ]
            )
        case OnboardingCapabilitySetup.redcapPackageID:
            return await validateConnectorCapability(
                packageID: packageID,
                connector: redcapValidationConnector(),
                credentials: [
                    "REDCAP_API_TOKEN": draft.capabilityConfiguration.redcapAPIToken
                ]
            )
        default:
            return .ready("No connection test is required for this capability.")
        }
    }

    private func validateConnectorCapability(
        packageID: String,
        connector: Connector,
        credentials: [String: String]
    ) async -> WorkspaceCapabilityValidationState {
        let traceID = AuditTrace.make("workspace-capability-validate")
        let result = await connector.testConnection(
            store: WorkspaceSetupValidationSecretStore(credentials: credentials),
            source: mode.isCapabilityForward ? "onboarding_workspace_validation" : "new_workspace_validation",
            packageID: packageID,
            traceID: traceID
        )
        return result.0 ? .ready(result.1) : .failed(result.1)
    }

    private func jiraValidationConnector() -> Connector {
        let config = draft.capabilityConfiguration
        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            icon: "list.bullet.clipboard",
            connectorDescription: "Atlassian Jira REST API v3",
            baseURL: trimmed(config.jiraBaseURL),
            authMethod: "basic"
        )
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.credentialValues = ["", ""]
        connector.configKeys = ["JIRA_PROJECTS"]
        connector.configValues = [trimmed(config.jiraProjects)]
        return connector
    }

    private func redcapValidationConnector() -> Connector {
        let config = draft.capabilityConfiguration
        let connector = Connector(
            name: "REDCap",
            serviceType: "redcap",
            icon: "tablecells",
            connectorDescription: "Stanford REDCap API",
            baseURL: trimmed(config.redcapAPIURL),
            authMethod: "api_key"
        )
        connector.credentialKeys = ["REDCAP_API_TOKEN"]
        connector.credentialValues = [""]
        connector.testHTTPMethod = "POST"
        return connector
    }

    private func validateGCloudProject() async -> WorkspaceCapabilityValidationState {
        let project = trimmed(draft.capabilityConfiguration.gcpProject)
        guard !project.isEmpty else {
            return .failed("Add a GCP project before testing.")
        }
        guard let gcloudPath = healthyPrerequisitePath(for: OnboardingCapabilitySetup.gcloudPackageID, binary: "gcloud") else {
            return .failed("Google Cloud CLI path was not resolved.")
        }

        let result = await ProcessBinaryRunner().run(
            path: gcloudPath,
            args: ["projects", "describe", project, "--format=value(projectId)"],
            timeout: 10,
            environment: nil
        )
        if result.isSuccess {
            let verifiedProject = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ready(verifiedProject.isEmpty
                ? "gcloud can access the configured project."
                : "gcloud can access project \(verifiedProject).")
        }
        return .failed("gcloud could not access \(project): \(runResultMessage(result))")
    }

    private func healthyPrerequisitePath(for packageID: String, binary: String) -> String? {
        let statuses = capabilityPreflightStatuses[packageID] ?? [:]
        for prerequisite in prerequisites(for: packageID) where prerequisite.binary == binary {
            if case .healthy(let path, _) = statuses[prerequisite.id] {
                return path
            }
        }
        return nil
    }

    private func runResultMessage(_ result: RunResult) -> String {
        let output = result.stderr.isEmpty ? result.stdout : result.stderr
        let cleaned = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned.count > 140 ? String(cleaned.prefix(140)) : cleaned
        }
        switch result.outcome {
        case .exited(let code):
            return "exit \(code)"
        case .timedOut:
            return "timed out after 10s"
        case .cancelled:
            return "cancelled"
        case .launchFailed(let reason):
            return reason
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func capabilityPrerequisitesView(for packageID: String, readyMessage: String) -> some View {
        let prerequisites = prerequisites(for: packageID)
        if !prerequisites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: capabilityPrerequisiteSymbol(for: packageID))
                        .font(Stanford.ui(12))
                        .foregroundStyle(capabilityPrerequisiteColor(for: packageID))
                    Text(capabilityPrerequisiteMessage(for: packageID, readyMessage: readyMessage))
                        .font(Stanford.caption(11))
                        .foregroundStyle(Stanford.coolGrey)
                    Spacer(minLength: 8)
                    Button {
                        Task { await probeCapabilityPrerequisites(for: packageID, forceRefresh: true) }
                    } label: {
                        if isProbingCapability(packageID) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Re-check", systemImage: "arrow.clockwise")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(Stanford.caption(11))
                    .disabled(isProbingCapability(packageID))
                }

                ForEach(prerequisites, id: \.id) { prerequisite in
                    if let status = prerequisiteStatus(for: prerequisite, packageID: packageID),
                       case .healthy(let path, _) = status {
                        Text("\(prerequisite.displayName): \(path)")
                            .font(Stanford.mono(10))
                            .foregroundStyle(Stanford.coolGrey)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func probeCapabilityPrerequisites(forceRefresh: Bool) async {
        for option in OnboardingCapabilitySetup.configurableOptions {
            guard let packageID = option.packageID else { continue }
            await probeCapabilityPrerequisites(for: packageID, forceRefresh: forceRefresh)
        }
    }

    private func probeCapabilityPrerequisites(for packageID: String, forceRefresh: Bool) async {
        let prerequisites = prerequisites(for: packageID)
        guard !prerequisites.isEmpty else { return }
        probingCapabilityPackageIDs.insert(packageID)
        defer { probingCapabilityPackageIDs.remove(packageID) }

        if forceRefresh {
            for binary in Set(prerequisites.map(\.binary)) {
                await preflightCache.invalidate(binary: binary)
            }
        }

        var statuses = capabilityPreflightStatuses[packageID] ?? [:]
        for prerequisite in prerequisites {
            statuses[prerequisite.id] = await preflightCache.status(for: prerequisite)
        }
        capabilityPreflightStatuses[packageID] = statuses
        refreshValidationIssues()
    }

    private func prerequisites(for packageID: String) -> [CLIPrerequisite] {
        PluginCatalog.builtInPackages.first { $0.id == packageID }?.prerequisites ?? []
    }

    private func isProbingCapability(_ packageID: String) -> Bool {
        probingCapabilityPackageIDs.contains(packageID)
    }

    private func capabilityPrerequisitesReady(for packageID: String) -> Bool {
        let prerequisites = prerequisites(for: packageID)
        guard !prerequisites.isEmpty else { return true }
        return prerequisites.allSatisfy { prerequisite in
            guard let status = prerequisiteStatus(for: prerequisite, packageID: packageID),
                  case .healthy = status else {
                return false
            }
            return true
        }
    }

    private func firstUnreadyPrerequisite(for packageID: String) -> (CLIPrerequisite, HealthStatus?)? {
        for prerequisite in prerequisites(for: packageID) {
            guard let status = prerequisiteStatus(for: prerequisite, packageID: packageID) else {
                return (prerequisite, nil)
            }
            if case .healthy = status {
                continue
            }
            return (prerequisite, status)
        }
        return nil
    }

    private func prerequisiteStatus(
        for prerequisite: CLIPrerequisite,
        packageID: String
    ) -> HealthStatus? {
        capabilityPreflightStatuses[packageID]?[prerequisite.id]
    }

    private func capabilityPrerequisiteIssue(for packageID: String) -> String? {
        guard let (prerequisite, status) = firstUnreadyPrerequisite(for: packageID) else {
            return nil
        }
        switch status {
        case .healthy:
            return nil
        case .missingBinary:
            return "\(prerequisite.displayName) is not installed"
        case .unauthenticated(let detail):
            return "\(prerequisite.displayName) needs login (\(detail))"
        case .unresponsive(let detail):
            return "\(prerequisite.displayName) failed (\(detail))"
        case .none:
            return isProbingCapability(packageID)
                ? "Checking \(prerequisite.displayName)"
                : "\(prerequisite.displayName) not checked"
        }
    }

    private func prerequisiteStatusLabel(
        _ prerequisite: CLIPrerequisite,
        status: HealthStatus?
    ) -> String {
        switch status {
        case .healthy:
            return "Ready"
        case .missingBinary:
            return "Needs \(prerequisite.binary)"
        case .unauthenticated:
            return "Needs login"
        case .unresponsive:
            return "Check CLI"
        case .none:
            return "Check"
        }
    }

    private func capabilityPrerequisiteMessage(for packageID: String, readyMessage: String) -> String {
        if isProbingCapability(packageID) {
            return "Checking local prerequisites..."
        }
        guard let (prerequisite, status) = firstUnreadyPrerequisite(for: packageID) else {
            return readyMessage
        }
        switch status {
        case .healthy:
            return readyMessage
        case .missingBinary:
            return "\(prerequisite.displayName) is not installed. \(prerequisite.installHint)"
        case .unauthenticated(let detail):
            return "\(prerequisite.displayName) needs authentication: \(detail). \(prerequisite.authHint ?? "")"
        case .unresponsive(let detail):
            return "\(prerequisite.displayName) did not respond: \(detail)"
        case .none:
            return "Re-check \(prerequisite.displayName)."
        }
    }

    private func capabilityPrerequisiteSymbol(for packageID: String) -> String {
        if capabilityPrerequisitesReady(for: packageID) {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private func capabilityPrerequisiteColor(for packageID: String) -> Color {
        capabilityPrerequisitesReady(for: packageID) ? Stanford.paloAltoGreen : Stanford.poppy
    }
}

private struct TopNoticeBannersView: View {
    let recoveryNotice: String
    let updateBlockNotice: String?
    let externalRouteNotice: String
    let onDismissRecoveryNotice: () -> Void
    let onDismissExternalRouteNotice: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        if !recoveryNotice.isEmpty || updateBlockNotice != nil || !externalRouteNotice.isEmpty {
            VStack(spacing: 0) {
                if !recoveryNotice.isEmpty {
                    RecoveryNoticeBanner(
                        message: recoveryNotice,
                        onDismiss: onDismissRecoveryNotice
                    )
                }
                if !externalRouteNotice.isEmpty {
                    ExternalRouteNoticeBanner(
                        message: externalRouteNotice,
                        onDismiss: onDismissExternalRouteNotice
                    )
                }
                if let updateBlockNotice {
                    UpdateNoticeBanner(
                        message: updateBlockNotice,
                        onCheckForUpdates: onCheckForUpdates
                    )
                }
            }
        }
    }
}

private struct RecoveryNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        NoticeBanner(
            systemImage: "externaldrive.badge.checkmark",
            imageColor: Stanford.paloAltoGreen,
            message: message,
            buttonTitle: "Dismiss",
            buttonAction: onDismiss
        )
    }
}

private struct ExternalRouteNoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        NoticeBanner(
            systemImage: "exclamationmark.triangle.fill",
            imageColor: Stanford.poppy,
            message: message,
            buttonTitle: "Dismiss",
            buttonAction: onDismiss
        )
    }
}

private struct UpdateNoticeBanner: View {
    let message: String
    let onCheckForUpdates: () -> Void

    var body: some View {
        NoticeBanner(
            systemImage: "arrow.down.circle",
            imageColor: Stanford.cardinalRed,
            message: message,
            buttonTitle: "Check Again",
            buttonAction: onCheckForUpdates
        )
    }
}

private struct NoticeBanner: View {
    let systemImage: String
    let imageColor: Color
    let message: String
    let buttonTitle: String
    let buttonAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(imageColor)
            Text(message)
                .font(Stanford.body(13))
                .foregroundStyle(Stanford.black)
            Spacer()
            Button(buttonTitle, action: buttonAction)
                .font(Stanford.body(12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Stanford.fog)
        .overlay(alignment: .bottom) {
            SoftHorizontalTransition(height: 12)
                .rotationEffect(.degrees(180))
                .offset(y: 8)
        }
    }
}

private struct WorkspaceEmptyStateView: View {
    let onCreateWorkspace: () -> Void
    let onImportWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(Stanford.ui(48))
                .foregroundStyle(Stanford.cardinalRed)

            VStack(spacing: 8) {
                Text("Pick a Workspace")
                    .font(Stanford.heading(24))
                    .foregroundStyle(Stanford.black)

                Text("Tasks always belong to a workspace. Create a new one or import an existing folder — ASTRA will reopen it automatically next time.")
                    .font(Stanford.body(15))
                    .foregroundStyle(Stanford.coolGrey)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                Button {
                    onCreateWorkspace()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .buttonStyle(StanfordButtonStyle())
                .accessibilityIdentifier("OnboardingNewWorkspaceButton")

                Button {
                    onImportWorkspace()
                } label: {
                    Label("Import Workspace", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: false))

                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Stanford.panelBackground)
    }
}

private struct LinkedScheduleWarning: Identifiable {
    enum Action {
        case markDone
        case delete

        var alertTitle: String {
            switch self {
            case .markDone:
                return "Pause linked routines before closing task?"
            case .delete:
                return "Pause linked routines before deleting?"
            }
        }

        var confirmLabel: String {
            switch self {
            case .markDone:
                return "Pause Routines and Close Task"
            case .delete:
                return "Pause Routines and Delete"
            }
        }
    }

    let id = UUID()
    let task: AgentTask
    let schedules: [TaskSchedule]
    let action: Action

    var message: String {
        let names = schedules.map(\.name).joined(separator: ", ")
        return "This task is the same-thread conversation source for active routines: \(names). Continuing will pause those routines first so future runs do not lose their thread."
    }
}

// Resize handle for the canvas shelf (Plan / Browser).
//
// The hit area is a 14pt-wide invisible rectangle straddling the panel's leading edge
// (offset -7) so the cursor changes a few pixels before and after the visible boundary —
// this is what makes the divider feel "sticky." On hover and during drag we paint a
// thin lagunita line at the boundary so the user has a clear visual to lock onto.
//
// Cursor management uses AppKit's window-level cursor rect (addCursorRect via
// CursorRectView) instead of NSCursor.push/pop on hover. push/pop is fragile during
// SwiftUI gestures because the hover state ends when the drag begins, popping the
// cursor mid-drag. A registered cursor rect keeps the resize cursor for the entire
// time the pointer is over the area, including throughout drags.
private struct ShelfResizeHandle: View {
    let isResizing: Bool
    let helpText: String
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Visible divider accent — hidden at rest, lagunita on hover, brighter while dragging.
            Rectangle()
                .fill(Stanford.lagunita.opacity(indicatorOpacity))
                .frame(width: 2)
                .offset(x: 6) // center the 2pt bar on the canvas's leading edge
                .allowsHitTesting(false)

            // Invisible hit target.
            //
            // coordinateSpace: .global is critical. With the default .local space, translation
            // is measured against the handle's own coord space — but the handle is anchored to
            // the canvas's leading edge, which moves as the panel resizes. That creates a
            // feedback loop: panel grows → handle moves with it → translation collapses back
            // to 0 → panel shrinks → translation reappears → panel grows… visible as a
            // side-to-side shake. Measuring translation against the screen breaks the loop.
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)
                .contentShape(Rectangle())
                .background(CursorRectView(cursor: .resizeLeftRight))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in onChanged(value.translation) }
                        .onEnded { _ in onEnded() }
                )
        }
        .frame(maxHeight: .infinity)
        .offset(x: -7) // straddle the boundary: 7pt outside panel, 7pt inside
        .onContinuousHover { phase in
            switch phase {
            case .active: isHovered = true
            case .ended: isHovered = false
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isResizing)
        .help(helpText)
    }

    private var indicatorOpacity: Double {
        if isResizing { return 0.55 }
        if isHovered { return 0.30 }
        return 0
    }
}

// AppKit-backed cursor rect — survives SwiftUI drags. Unlike NSCursor.push/pop on
// SwiftUI's onHover (which ends the moment a drag begins), addCursorRect registers
// the cursor at the window level so macOS keeps showing it for as long as the
// pointer is in the rect, regardless of what gesture is active.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        CursorRectNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CursorRectNSView else { return }
        if view.cursor !== cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

private final class CursorRectNSView: NSView {
    var cursor: NSCursor

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // Don't intercept mouse events — the SwiftUI DragGesture above handles them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
