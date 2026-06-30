import SwiftUI
import SwiftData
import ASTRACore
import AppKit

// `WorkspaceCanvasItem`, `WorkspaceRightPanel`, and the shelf-boundary metrics live in
// WorkspaceCanvasItem.swift (extracted to keep this file within its line budget).

// The shelf-boundary overlay views live in WorkspaceCanvasItem.swift (extracted for budget).

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
    // F7: Workspace App surfaces. selectedWorkspaceApp renders the app detail;
    // isComposingWorkspaceApp renders the App Studio builder. Mutually exclusive
    // with task selection (set/cleared together).
    @State private var selectedWorkspaceApp: WorkspaceApp?
    @State private var isComposingWorkspaceApp = false
    @State private var showingConfigure = false
    @State private var configureInitialTab: ConfigureTab = .capabilities
    @State private var configureFocusItemID: UUID?
    @State private var configureFocusCapabilityPackageID: String?
    @State private var pendingMCPInstallRequest: MCPInstallChatRequest?
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
    // App Studio is a conversation (center) + a docked live preview (the .appPreview shelf);
    // both observe this one session, so a chat turn updates the preview.
    @StateObject private var workspaceAppStudioSession = WorkspaceAppStudioSession()
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
    // MARK: Sidebar Presentation
    /// The single owner of sidebar visibility — docked column, floating overlay
    /// drawer, or collapsed. Replaces the former `splitVisibility` @State plus the
    /// responsive/reveal-settling flags; every width probe and the AppKit split
    /// guard now *propose* changes through this model instead of racing on
    /// `splitVisibility` directly.
    @StateObject private var presentation = SidebarPresentationModel()
    private let sidebarTitlebarCommands = SidebarTitlebarCommandBridge.shared
    /// Hover state of the show-sidebar toggle, which drives the transient
    /// hover-preview of the overlay drawer (`SidebarPeekContainer`).
    @State private var isSidebarToggleHovered = false
    @State private var cachedHasCanvasContent = false
    /// Run-once guard for the deferred Sparkle update probe. handleAppear can
    /// fire on more than one .onAppear for the same view instance; this keeps
    /// the ~3s deferral scheduled exactly once. (The controller also guards the
    /// actual probe via hasProbedForUpdates, so this is belt-and-suspenders.)
    @State private var didScheduleUpdateProbe = false
    @State private var didLogStoreScaleSnapshot = false
    @State private var generatedHTMLDiscoveryTask: Task<Void, Never>?
    @State private var markdownAvailabilityTask: Task<Void, Never>?
    @State private var queryAvailabilityTask: Task<Void, Never>?
    @State private var runtimeModelRefreshTasks: [AgentRuntimeID: Task<Void, Never>] = [:]
    @State private var lastRuntimeModelRefreshSignatures: [AgentRuntimeID: String] = [:]
    @State private var lastGeneratedHTMLDiscoverySignature = ""
    @State private var selectedTaskPreferredHTMLPath = ""
    @State private var selectedTaskHasMarkdownShelfContent = false
    @State private var selectedTaskPreferredMarkdownPath = ""
    @State private var selectedTaskHasQueryShelfContent = false
    @State private var selectedTaskPreferredQueryPath = ""
    @State private var rememberedWorkspaceCanvasItemsRaw = WorkspaceCanvasItemPreferenceStore.load()
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

    private var workspaceAppStudioWorkspace: Workspace? {
        guard let workspaceID = workspaceAppStudioSession.workspaceID else {
            return effectiveWorkspace
        }
        return sceneCoordinator.workspace(id: workspaceID)
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

    private var selectedWorkspaceBinding: Binding<Workspace?> {
        Binding(
            get: { selectedWorkspace },
            set: { selectWorkspaceFromSidebar($0) }
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
        // Compute the latest run once (was scanned twice — here and in the
        // HTML-preview helper). Deliberately exclude `output.count`: it is an
        // O(output-length) walk that re-runs every body pass while output
        // streams, and the canvas only reflects file changes, not raw output.
        let latestRun = selectedTask.runs.max { $0.startedAt < $1.startedAt }
        let inputSignature = selectedTask.inputs.joined(separator: "|")
        let htmlPreviewSignature = [
            selectedTask.status.rawValue,
            latestRun?.id.uuidString ?? "none",
            String(latestRun?.fileChangesJSON.count ?? 0)
        ].joined(separator: "|")
        let latestRunSignature = [
            latestRun?.id.uuidString ?? "none",
            latestRun?.status.rawValue ?? "none",
            String(Int(latestRun?.startedAt.timeIntervalSince1970 ?? 0)),
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
            canShowAppPreviewShelf: isComposingWorkspaceApp,
            activeCanvasItem: activeWorkspaceCanvasItem,
            browserEngine: browserToolbarEngine,
            isRightRailVisible: isWorkspaceRightRailVisible
        )
    }

    private var isWorkspaceCanvasPresented: Bool {
        activeWorkspaceCanvasItem != nil
    }

    /// Whether a right-side panel (the workspace inspector rail or a canvas shelf)
    /// is currently presented. Fed into `SidebarPresentationModel` so it can decide
    /// whether the sidebar docks alongside it or presents as an overlay drawer.
    private var hasRightSidePanelPresented: Bool {
        activeWorkspaceCanvasItem != nil || (effectiveWorkspace != nil && isWorkspaceRightRailVisible)
    }

    private var panelTransitionAnimation: Animation? {
        AstraMotion.rightPanel(reduceMotion: reduceMotion)
    }

    private var sidebarCollapseAnimation: Animation? {
        SidebarColumnLayout.collapseAnimation(reduceMotion: reduceMotion)
    }

    private var sidebarCollapseTransition: AnyTransition {
        SidebarColumnLayout.collapseTransition(reduceMotion: reduceMotion)
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

    /// Feeds window width and right-panel presence into the presentation model.
    /// The model is the only thing that turns those inputs into sidebar visibility.
    private var sidebarLayoutObserver: SidebarLayoutObserver {
        SidebarLayoutObserver(
            hasRightSidePanel: hasRightSidePanelPresented,
            onWidthChanged: { presentation.setResponsiveWidth($0) },
            onRightSidePanelChanged: { presentation.setHasRightSidePanel($0) }
        )
    }

    /// The split view is ALWAYS mounted — the sidebar is hidden by collapsing the
    /// column (`columnVisibility`), never by swapping the whole layout out. That
    /// keeps the `NavigationSplitView` (the sole renderer of the column-visibility
    /// binding) live at all times, so a "show sidebar" can never be a dead write.
    private var rootLayout: some View {
        splitLayout
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: presentation.columnVisibilityBinding()) {
            sidebarArea
        } detail: {
            detailArea
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// The sidebar's content, free of any `NavigationSplitView` sizing modifiers,
    /// so it can be reused verbatim by both the docked column (`sidebarArea`) and
    /// the floating overlay drawer (`SidebarPeekContainer`) — both wrapping it in
    /// the same `SidebarSurface` so the two never diverge in style.
    private var sidebarContent: some View {
        TaskSidebarContainerView(
            selectedTask: selectedTaskBinding,
            taskQueue: runtime.taskQueue,
            workspaces: workspaces,
            selectedWorkspace: selectedWorkspaceBinding,
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
            onNewApp: { startWorkspaceAppStudio() },
            onOpenWorkspaceApp: setSelectedWorkspaceApp,
            selectedWorkspaceApp: selectedWorkspaceApp
        )
    }

    private var sidebarArea: some View {
        SidebarSurface(style: .docked) {
            sidebarContent
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        presentation.noteColumnWidth(proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) {
                        presentation.noteColumnWidth(proxy.size.width)
                    }
            }
            SidebarSplitViewGuard(
                minimumExpandedWidth: SidebarColumnLayout.expandedMinimumWidth,
                isRevealInProgress: presentation.isSettling,
                onReadableWidth: { presentation.noteReadableSplitSubviewWidth($0) },
                onCollapse: { presentation.proposeCompressedCollapse() }
            )
            .frame(width: 0, height: 0)
        }
        .clipped()
        // The leading titlebar accessory (AstraLeadingCommandBar) owns the only
        // sidebar toggle; drop NavigationSplitView's built-in one.
        .toolbar(removing: .sidebarToggle)
        .transition(sidebarCollapseTransition)
        .animation(sidebarCollapseAnimation, value: presentation.columnVisibility)
        // MUST stay the outermost modifier on the column root: with `.clipped()`
        // interposed between this and `.toolbar(removing:)`, NavigationSplitView
        // drops the whole min/ideal/max spec — the divider then drags to any
        // width and the sub-minimum guard collapse fires mid-drag.
        .navigationSplitViewColumnWidth(
            min: SidebarColumnLayout.expandedMinimumWidth,
            ideal: SidebarColumnLayout.expandedIdealWidth,
            max: SidebarColumnLayout.expandedMaximumWidth
        )
    }

    @ViewBuilder
    private var detailArea: some View {
        switch detailPresentation {
        case .workspaceApp:
            if let app = selectedWorkspaceApp {
                workspaceAppDetailArea(app: app)
            } else {
                taskAndHomeDetailArea
            }
        default:
            taskAndHomeDetailArea
        }
    }

    private var detailPresentation: ContentDetailPresentation {
        ContentDetailPresentation.resolve(
            selectedTask: selectedTask,
            effectiveWorkspace: sceneCoordinator.workspace(for: selectedWorkspaceApp) ?? effectiveWorkspace,
            isComposingTask: isComposingTask,
            selectedWorkspaceApp: selectedWorkspaceApp,
            isComposingWorkspaceApp: isComposingWorkspaceApp
        )
    }

    private var taskAndHomeDetailArea: some View {
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
            activeCanvasItem: workspaceCanvasItemBinding,
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
            onOpenWorkspaceApp: setSelectedWorkspaceApp,
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
            onOpenWorkspaceFile: openWorkspaceFileInShelf,
            isComposingWorkspaceApp: isComposingWorkspaceApp,
            studioSession: workspaceAppStudioSession,
            onStartWorkspaceAppStudio: { prompt in startWorkspaceAppStudio(initialPrompt: prompt) },
            onStartMCPInstallReview: { request in pendingMCPInstallRequest = request },
            onPublishApp: { seed in publishWorkspaceAppFromStudio(seedSampleData: seed) },
            onDraftChanged: { WorkspaceAppStudioDraftAutosaveCoordinator.autosave(session: workspaceAppStudioSession, preferredWorkspace: effectiveWorkspace, modelContext: modelContext) },
            onCancelStudio: { cancelWorkspaceAppStudio() }
        )
    }

    // MARK: - F7 Workspace App surfaces

    @ViewBuilder
    private func workspaceAppDetailArea(app: WorkspaceApp) -> some View {
        let appWorkspace = sceneCoordinator.workspace(for: app)
        WorkspaceAppDetailView(
            app: app,
            workspace: appWorkspace,
            onOpenStudio: { manifest in startWorkspaceAppStudio(existingManifest: manifest, workspace: appWorkspace) },
            onRefresh: {},
            onExportPackage: {
                guard let workspace = appWorkspace else { throw WorkspaceAppUIError.exportUnavailableFromDetail }
                return try WorkspaceAppPackageExporter().exportTemplatePackage(app: app, workspace: workspace).packageURL
            },
            onRunAction: { action, manifest, input in
                try runWorkspaceAppAction(app: app, action: action, manifest: manifest, input: input)
            }, onDeleted: { selectedWorkspaceApp = nil }
        )
        .id(app.id)
    }

    private func startWorkspaceAppStudio(
        existingManifest: WorkspaceAppManifest? = nil,
        initialPrompt: String? = nil,
        workspace targetWorkspace: Workspace? = nil
    ) {
        if let targetWorkspace { selectedWorkspace = targetWorkspace }
        selectedTask = nil
        selectedWorkspaceApp = nil
        isComposingTask = false
        isComposingWorkspaceApp = true
        isWorkspaceRightRailVisible = false
        if let workspace = targetWorkspace ?? effectiveWorkspace {
            workspaceAppStudioSession.reset(for: workspace, existingManifest: existingManifest, initialPrompt: initialPrompt)
        }
        setActiveWorkspaceCanvasItem(.appPreview, remember: false)
    }

    /// Leave the Studio without publishing: drop the composer, collapse the preview, cancel gen.
    private func cancelWorkspaceAppStudio() {
        workspaceAppStudioSession.cancelGeneration()
        isComposingWorkspaceApp = false
        if activeWorkspaceCanvasItem == .appPreview {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
    }

    private func toggleAppPreviewCanvas() {
        if activeWorkspaceCanvasItem == .appPreview {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, remember: false)
            }
        } else {
            animatePanelChange {
                isWorkspaceRightRailVisible = false
                setActiveWorkspaceCanvasItem(.appPreview, remember: false)
            }
        }
    }

    /// Publish the session's current draft (called from the chat header's Publish button).
    private func publishWorkspaceAppFromStudio(seedSampleData: Bool) {
        guard let workspace = workspaceAppStudioWorkspace,
              let draft = workspaceAppStudioSession.draft else { return }
        do {
            try publishWorkspaceApp(draft, seedSampleData: seedSampleData, workspace: workspace)
        } catch {
            AppLogger.error("App Studio publish failed: \(error)", category: "WorkspaceApps")
            workspaceAppStudioSession.notePublishFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func setSelectedWorkspaceApp(_ app: WorkspaceApp?) {
        let draftResolution = WorkspaceAppStudioDraftOpenResolver.resolve(app: app, workspaces: workspaces, fallbackWorkspace: effectiveWorkspace)
        if case .routed(let route) = draftResolution {
            startWorkspaceAppStudio(existingManifest: route.manifest, workspace: route.workspace)
            return
        }
        if case .failed(let failure) = draftResolution {
            selectedTask = nil
            selectedWorkspaceApp = nil
            isComposingTask = false
            isComposingWorkspaceApp = false
            if let workspace = failure.workspace ?? effectiveWorkspace {
                startWorkspaceAppStudio(workspace: workspace)
                workspaceAppStudioSession.noteDraftOpenFailure(appName: app?.name ?? "this draft app", detail: failure.detail)
            } else if activeWorkspaceCanvasItem == .appPreview {
                setActiveWorkspaceCanvasItem(nil, remember: false)
            }
            return
        }
        selectedTask = nil
        isComposingTask = false
        isComposingWorkspaceApp = false
        if activeWorkspaceCanvasItem == .appPreview {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
        selectedWorkspaceApp = app
    }

    private func runWorkspaceAppAction(
        app: WorkspaceApp,
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppActionExecutionResult {
        guard let workspace = sceneCoordinator.workspace(for: app) else {
            throw WorkspaceAppUIError.noWorkspace
        }
        let appID = app.id
        let bindings = (try? modelContext.fetch(
            FetchDescriptor<WorkspaceAppDependencyBinding>()
        ))?.filter { $0.appID == appID } ?? []
        return try WorkspaceAppActionExecutor().execute(
            actionID: action.id,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: bindings,
            input: input,
            modelContext: modelContext
        )
    }

    private func publishWorkspaceApp(_ draft: WorkspaceAppStudioDraft, seedSampleData: Bool = false, workspace: Workspace) throws {
        let allApps = (try? modelContext.fetch(FetchDescriptor<WorkspaceApp>())) ?? []
        let service = WorkspaceAppService()
        let result: WorkspaceAppCreationResult
        let isNewApp: Bool
        let target: Workspace   // the workspace the published app actually lives in
        if let editingID = workspaceAppStudioSession.editingAppLogicalID {
            // Editing: update the app IN ITS OWN workspace (found by logical id, preferring the
            // session's workspace) — NOT the currently-selected one, which may differ. Version in place,
            // no forked sibling. If it's truly gone, fail loudly rather than recreating it empty.
            let sessionWS = workspaceAppStudioSession.workspaceID
            guard let existing = allApps.first(where: { $0.logicalID == editingID && $0.workspaceID == sessionWS }) ?? allApps.first(where: { $0.logicalID == editingID }),
                  let appWorkspace = ((try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []).first(where: { $0.id == existing.workspaceID }) else {
                throw WorkspaceAppServiceError.fileOperationFailed("The app you were editing no longer exists. Use Save as a Copy to keep your changes.")
            }
            let isDraftFirstPublish = existing.lifecycleStatus == .draft && existing.latestVersionNumber == 0
            target = appWorkspace
            result = try service.updateApp(existing, manifest: draft.manifest, in: appWorkspace, modelContext: modelContext, status: .published)
            isNewApp = isDraftFirstPublish
        } else {
            // New app: create in the selected workspace, deduping the logical id within it.
            target = workspace
            let manifest = WorkspaceAppStudioBuilder.manifestForPublishing(draft.manifest, existingLogicalIDs: Set(allApps.filter { $0.workspaceID == workspace.id }.map(\.logicalID)))
            result = try service.createApp(manifest: manifest, in: workspace, modelContext: modelContext, status: .published)
            isNewApp = true
        }
        // Flush the build journal + snapshot the version (best-effort) into the app's OWN workspace.
        WorkspaceAppStudioJournalService().save(workspaceAppStudioSession.journal, appID: result.app.logicalID, workspacePath: target.primaryPath)
        workspaceAppStudioSession.cancelGeneration()
        do {
            let publishedData = try WorkspaceAppService.encodeManifest(result.manifest)
            try WorkspaceAppVersionService().recordPublish(app: result.app, manifestData: publishedData, validated: true, workspacePath: target.primaryPath, modelContext: modelContext)
        } catch { AppLogger.error("Workspace app published but version snapshot failed: \(error)", category: "WorkspaceApps") }
        if seedSampleData, isNewApp { WorkspaceAppSampleSeeder.seed(manifest: result.manifest, workspacePath: target.primaryPath, appID: result.app.logicalID) }
        isComposingWorkspaceApp = false
        setSelectedWorkspaceApp(result.app)
    }

    /// Keeps ⌘F toggling search even though the visible search button lives in
    /// the leading titlebar accessory (`AstraLeadingCommandBar`), which sits
    /// outside the window's key responder chain where a `.keyboardShortcut`
    /// can't fire. The button stays in the SwiftUI hierarchy (so the shortcut
    /// registers) but is made invisible with a zero-size clear label + opacity(0).
    private var searchHotkey: some View {
        Button(action: { isSearchActive.toggle() }) { Color.clear.frame(width: 0, height: 0) }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // F7: ⌘⇧A opens the Workspace App Studio (New App). Hidden hotkey mirroring
    // searchHotkey so it registers without threading a button through the detail
    // view hierarchy; only active when a workspace is selected.
    private var newWorkspaceAppHotkey: some View {
        Button(action: { if effectiveWorkspace != nil { startWorkspaceAppStudio() } }) {
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .opacity(0)
        .accessibilityHidden(true)
    }

    // Split out of `body` so each modifier chain stays small enough for the
    // SwiftUI type-checker. `body` adds only the .onChange / .sheet tail.
    private var rootLayoutWithChrome: some View {
        rootLayout
        .frame(minHeight: 600)
        .accessibilityIdentifier("MainContentView")
        // Installs the leading titlebar accessory (AstraLeadingCommandBar):
        // sidebar toggle + search pinned beside the traffic lights in every layout.
        .astraWindowChrome(
            isSearchActive: $isSearchActive,
            sidebarCommands: sidebarTitlebarCommands,
            isSidebarToggleHovered: $isSidebarToggleHovered,
            isSidebarHidden: presentation.isSidebarHidden
        )
        .background(searchHotkey)
        .background(newWorkspaceAppHotkey)
        .astraHiddenToolbarBackground()
        // Right-rail toggle. Attached to the NavigationSplitView root so
        // .primaryAction lands at the WINDOW's trailing edge — past the
        // inspector column — instead of at the inspector boundary
        // (where attaching to .detail or to the inspector content put it).
        .toolbar {
            // Sidebar toggle + search live in the leading titlebar accessory
            // (AstraLeadingCommandBar, installed by astraWindowChrome) — pinned
            // beside the traffic lights in every layout. It feeds the hover-to-peek
            // state (isSidebarToggleHovered); the native split-view toggle is
            // suppressed on `sidebarArea` via `.toolbar(removing: .sidebarToggle)`.
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
                        onToggleAppPreview: toggleAppPreviewCanvas,
                        onToggleControlPanel: toggleRightRail
                    )
                }
            }
        }
        .shelfBoundaryOverlay()
        .modifier(sidebarLayoutObserver)
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
        .overlay(alignment: .topLeading) {
            SidebarPeekContainer(
                mode: presentation.mode,
                isTriggerHovered: isSidebarToggleHovered,
                width: presentation.sidebarWidth,
                reduceMotion: reduceMotion,
                onDismiss: { presentation.dismissOverlay() }
            ) {
                sidebarContent
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
    }

    var body: some View {
        rootLayoutWithChrome
        .onChange(of: selectedTaskCanvasSignature) {
            handleSelectedTaskCanvasSignatureChanged()
        }
        .onChange(of: hasOpenTaskThread) {
            if !hasOpenTaskThread, activeWorkspaceCanvasItem != nil {
                if activeWorkspaceCanvasItem == .markdown, effectiveWorkspace != nil {
                    return
                }
                // The live preview belongs to the App Studio composer, not a task
                // thread. "New App" nils the selected task (collapsing the thread)
                // right after docking .appPreview — don't let that close it.
                if activeWorkspaceCanvasItem == .appPreview, isComposingWorkspaceApp {
                    return
                }
                animatePanelChange {
                    setActiveWorkspaceCanvasItem(nil, remember: false)
                }
            }
            // Opening a task while the sidebar is a too-narrow overlay drawer
            // dismisses the drawer so the detail area is visible (no-op when the
            // sidebar is docked or already collapsed).
            if hasOpenTaskThread {
                presentation.handleSelectionCommitted()
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
        .mcpInstallReviewSheet(
            request: $pendingMCPInstallRequest,
            workspace: effectiveWorkspace,
            onInstalled: openCapabilityPackage
        )
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
            sidebarTitlebarCommands.installSidebarToggleHandler {
                handleSidebarToggle()
            }
            handleAppear()
        }
        .onDisappear {
            sidebarTitlebarCommands.clearSidebarToggleHandler()
        }
        .onChange(of: executionSettingsSignature) { applySettings() }
        .background {
            UpdateSafetyObserver(
                taskQueue: runtime.taskQueue,
                runningTaskCount: runningTaskCount,
                onChange: {
                    refreshRunningTaskCount()
                    refreshUpdateSafetyHooks()
                }
            )
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

    private func handleSidebarToggle() {
        guard presentation.shouldClearRightSidePanelBeforeReveal else {
            presentation.toggle()
            return
        }

        animatePanelChange {
            setActiveWorkspaceCanvasItem(nil, remember: true)
            isWorkspaceRightRailVisible = false
            presentation.revealAfterClearingRightSidePanel()
        }
    }

    private func handleSelectedTaskCanvasSignatureChanged() {
        cachedHasCanvasContent = selectedTask.flatMap { TaskPlanService.reconstruct(for: $0).plan } != nil
        if !cachedHasCanvasContent, activeWorkspaceCanvasItem == .plan {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
        if selectedTask == nil, !isComposingTask, activeWorkspaceCanvasItem == .browser {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
        if selectedTask == nil, !isComposingTask, effectiveWorkspace == nil, activeWorkspaceCanvasItem == .markdown {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
        refreshMarkdownShelfAvailabilityForSelectedTask()
        refreshQueryShelfAvailabilityForSelectedTask()
        refreshGeneratedHTMLAvailabilityForSelectedTask()
        restoreRememberedWorkspaceCanvasItemIfAvailable()
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

    private func presentRightRail(rememberShelfState: Bool = true) {
        animatePanelChange {
            setActiveWorkspaceCanvasItem(nil, remember: rememberShelfState)
            isWorkspaceRightRailVisible = true
        }
    }

    private func presentCanvas(_ item: WorkspaceCanvasItem) {
        animatePanelChange {
            isWorkspaceRightRailVisible = false
            setActiveWorkspaceCanvasItem(item, remember: true)
        }
    }

    private var workspaceCanvasItemBinding: Binding<WorkspaceCanvasItem?> {
        Binding(
            get: { activeWorkspaceCanvasItem },
            set: { setActiveWorkspaceCanvasItem($0, remember: true) }
        )
    }

    private var selectedWorkspaceCanvasConversationID: String? {
        selectedTask?.id.uuidString
    }

    private var rememberedWorkspaceCanvasItem: WorkspaceCanvasItem? {
        WorkspaceCanvasItemPreference.item(
            in: rememberedWorkspaceCanvasItemsRaw,
            for: selectedWorkspaceCanvasConversationID
        )
    }

    private func setActiveWorkspaceCanvasItem(_ item: WorkspaceCanvasItem?, remember: Bool) {
        activeWorkspaceCanvasItem = item
        let currentStorage = rememberedWorkspaceCanvasItemsRaw
        let updatedStorage = WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: currentStorage,
            conversationID: selectedWorkspaceCanvasConversationID,
            item: item,
            remember: remember
        )
        rememberedWorkspaceCanvasItemsRaw = updatedStorage
        WorkspaceCanvasItemPreferenceStore.saveIfChanged(
            currentRawValue: currentStorage,
            updatedRawValue: updatedStorage
        )
    }

    private func restoreRememberedWorkspaceCanvasItemIfAvailable() {
        let rememberedItem = rememberedWorkspaceCanvasItem
        guard WorkspaceCanvasItemPreference.shouldRestoreRememberedItem(
            activeItem: activeWorkspaceCanvasItem,
            isRightRailVisible: isWorkspaceRightRailVisible,
            rememberedItem: rememberedItem,
            canPresentRememberedItem: rememberedItem.map(canPresentWorkspaceCanvasItem) ?? false
        ), let item = rememberedItem else {
            return
        }

        isWorkspaceRightRailVisible = false
        prepareWorkspaceCanvasItemForPresentation(item, source: "remembered_shelf_restore")
        setActiveWorkspaceCanvasItem(item, remember: false)
    }

    private func canPresentWorkspaceCanvasItem(_ item: WorkspaceCanvasItem) -> Bool {
        switch item {
        case .plan:
            return hasOpenTaskThread && hasWorkspaceCanvasContent
        case .markdown:
            return effectiveWorkspace != nil || selectedTaskHasMarkdownShelfContent || selectedTask != nil || isComposingTask
        case .browser:
            return hasOpenTaskThread
        case .query:
            return hasOpenTaskThread && hasQueryShelfAffordance
        case .appPreview:
            return isComposingWorkspaceApp
        }
    }

    private func prepareWorkspaceCanvasItemForPresentation(_ item: WorkspaceCanvasItem, source: String) {
        switch item {
        case .plan:
            return
        case .markdown:
            currentMarkdownSession.bindToTask(selectedTask?.id)
            guard !selectedTaskPreferredMarkdownPath.isEmpty else { return }
            let url = URL(fileURLWithPath: selectedTaskPreferredMarkdownPath)
            if currentMarkdownSession.fileURL?.path != url.path {
                currentMarkdownSession.load(url)
            }
        case .browser:
            currentBrowserSession.bindToTask(selectedTask?.id)
            loadPreferredGeneratedHTMLForBrowserShelfIfNeeded(source: source)
        case .query:
            querySession.bindToTask(selectedTask?.id)
            guard !selectedTaskPreferredQueryPath.isEmpty else { return }
            let url = URL(fileURLWithPath: selectedTaskPreferredQueryPath)
            if querySession.selectedDocument?.sourcePath != url.path {
                querySession.loadFile(url)
            }
        case .appPreview:
            // The studio session is already bound when the Studio opens — nothing to prepare.
            return
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
                    setActiveWorkspaceCanvasItem(nil, remember: true)
                }
            }
            return
        }
        if activeWorkspaceCanvasItem == .plan {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, remember: true)
            }
        } else {
            presentCanvas(.plan)
        }
    }

    private func toggleBrowserCanvas() {
        currentBrowserSession.bindToTask(selectedTask?.id)
        if activeWorkspaceCanvasItem == .browser {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, remember: true)
            }
        } else {
            loadPreferredGeneratedHTMLForBrowserShelfIfNeeded(source: "browser_shelf_open")
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
        loadPreferredGeneratedHTMLForBrowserShelfIfNeeded(source: "browser_shelf_open")
        if activeWorkspaceCanvasItem != .browser {
            presentCanvas(.browser)
        }
    }

    private func toggleMarkdownCanvas() {
        guard effectiveWorkspace != nil || selectedTaskHasMarkdownShelfContent || selectedTask != nil || isComposingTask else {
            if activeWorkspaceCanvasItem == .markdown {
                animatePanelChange {
                    setActiveWorkspaceCanvasItem(nil, remember: true)
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
                setActiveWorkspaceCanvasItem(nil, remember: true)
            }
        } else {
            presentCanvas(.markdown)
        }
    }

    private func toggleQueryCanvas() {
        guard hasQueryShelfAffordance else {
            if activeWorkspaceCanvasItem == .query {
                animatePanelChange {
                    setActiveWorkspaceCanvasItem(nil, remember: true)
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
                setActiveWorkspaceCanvasItem(nil, remember: true)
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
                restoreRememberedWorkspaceCanvasItemIfAvailable()
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
                restoreRememberedWorkspaceCanvasItemIfAvailable()
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
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
    }

    private func closeQueryShelfIfUnavailable() {
        guard activeWorkspaceCanvasItem == .query, !selectedTaskHasQueryShelfContent else { return }
        animatePanelChange {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
    }

    private func clearGeneratedHTMLDiscoveryState() {
        selectedTaskPreferredHTMLPath = GeneratedHTMLDiscoveryState.empty.preferredPath
        lastGeneratedHTMLDiscoverySignature = GeneratedHTMLDiscoveryState.empty.signature
    }

    private func refreshGeneratedHTMLAvailabilityForSelectedTask() {
        guard isBrowserPinnedToTask else { return }
        guard let selectedTask else {
            generatedHTMLDiscoveryTask?.cancel()
            clearGeneratedHTMLDiscoveryState()
            return
        }

        let taskID = selectedTask.id
        let taskFolder = TaskWorkspaceAccess(task: selectedTask).taskFolder
        guard !taskFolder.isEmpty else {
            generatedHTMLDiscoveryTask?.cancel()
            clearGeneratedHTMLDiscoveryState()
            return
        }

        generatedHTMLDiscoveryTask?.cancel()
        generatedHTMLDiscoveryTask = Task {
            let files = await TaskGeneratedFiles.filesAsync(in: taskFolder)
            guard !Task.isCancelled,
                  let path = TaskGeneratedFiles.preferredHTMLFile(in: files, taskFolder: taskFolder) else {
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.selectedTask?.id == taskID else {
                        return
                    }
                    clearGeneratedHTMLDiscoveryState()
                }
                return
            }

            let discoveryState = GeneratedHTMLDiscoveryState.discovered(preferredPath: path, taskID: taskID)
            await MainActor.run {
                // Compare against the signature already computed off-main above
                // rather than calling shouldApplyDiscovery(), which would re-run
                // an attributesOfItem stat on the main actor for the same path.
                // See the UI responsiveness audit (Cluster 2).
                guard !Task.isCancelled,
                      self.selectedTask?.id == taskID,
                      lastGeneratedHTMLDiscoverySignature != discoveryState.signature else {
                    return
                }

                selectedTaskPreferredHTMLPath = discoveryState.preferredPath
                lastGeneratedHTMLDiscoverySignature = discoveryState.signature
                logGeneratedHTMLDiscovery(
                    taskID: taskID,
                    event: "artifact_discovered",
                    reason: "explicit_open_required",
                    targetPath: discoveryState.preferredPath
                )
                restoreRememberedWorkspaceCanvasItemIfAvailable()
            }
        }
    }

    private func loadPreferredGeneratedHTMLForBrowserShelfIfNeeded(source: String) {
        guard !selectedTaskPreferredHTMLPath.isEmpty else { return }

        let taskID = selectedTask?.id
        let session = browserSessionStore.session(
            for: taskID,
            pinnedToTask: isBrowserPinnedToTask,
            enabledBrowserAdapters: enabledBrowserAdapterIDs(for: selectedTask)
        )
        guard TaskGeneratedFiles.shouldLoadGeneratedHTMLOnUserOpen(
            currentBrowserURL: session.currentURL,
            targetPath: selectedTaskPreferredHTMLPath
        ) else {
            return
        }

        session.load(URL(fileURLWithPath: selectedTaskPreferredHTMLPath), source: source)
        if let taskID {
            let discoveryState = GeneratedHTMLDiscoveryState.discovered(
                preferredPath: selectedTaskPreferredHTMLPath,
                taskID: taskID
            )
            selectedTaskPreferredHTMLPath = discoveryState.preferredPath
            lastGeneratedHTMLDiscoverySignature = discoveryState.signature
        }
        syncBrowserPresentation()
    }

    private func logGeneratedHTMLDiscovery(
        taskID: UUID,
        event: String,
        reason: String,
        targetPath: String
    ) {
        var fields = ShelfBrowserURLLogFields.fields(for: URL(fileURLWithPath: targetPath), prefix: "target")
        fields["event"] = event
        fields["reason"] = reason
        fields["pinned_to_task"] = String(isBrowserPinnedToTask)
        AppLogger.audit(.shelfBrowserPreview, category: "Browser", taskID: taskID, fields: fields)
    }

    private func openGeneratedFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        switch TaskGeneratedFiles.shelfDestination(for: path) {
        case .browser?:
            let taskID = selectedTask?.id
            let session = browserSessionStore.session(
                for: taskID,
                pinnedToTask: isBrowserPinnedToTask,
                enabledBrowserAdapters: enabledBrowserAdapterIDs(for: selectedTask)
            )
            session.load(url, source: "generated_file")
            if let taskID {
                let discoveryState = GeneratedHTMLDiscoveryState.discovered(preferredPath: path, taskID: taskID)
                selectedTaskPreferredHTMLPath = discoveryState.preferredPath
                lastGeneratedHTMLDiscoverySignature = discoveryState.signature
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
        clearGeneratedHTMLDiscoveryState()

        let nextSession = currentBrowserSession
        if !previousAddress.isEmpty && nextSession.currentURL.isEmpty {
            nextSession.load(previousAddress)
        }

        syncBrowserPresentation()
        if pinnedToTask { refreshGeneratedHTMLAvailabilityForSelectedTask() }
    }

    private func setMarkdownPinnedToTask(_ pinnedToTask: Bool) {
        guard isMarkdownPinnedToTask != pinnedToTask else { return }

        let previousSession = currentMarkdownSession
        let previousURL = previousSession.fileURL
        isMarkdownPinnedToTask = pinnedToTask

        let nextSession = currentMarkdownSession
        if let previousURL, !nextSession.hasFile {
            nextSession.load(previousURL)
        }

        if pinnedToTask { refreshMarkdownShelfAvailabilityForSelectedTask() }
    }

    private func selectWorkspaceFromSidebar(_ workspace: Workspace?) {
        selectedWorkspace = workspace
        clearWorkspaceAppSurfaceSelection()
    }

    private func clearWorkspaceAppSurfaceSelection() {
        selectedWorkspaceApp = nil
        if isComposingWorkspaceApp {
            cancelWorkspaceAppStudio()
        } else if activeWorkspaceCanvasItem == .appPreview {
            setActiveWorkspaceCanvasItem(nil, remember: false)
        }
    }

    private func startComposingTask() {
        clearWorkspaceAppSurfaceSelection()
        setSelectedTask(nil)
        isComposingTask = true
        presentRightRail(rememberShelfState: false)
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
        presentRightRail(rememberShelfState: false)
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
                setActiveWorkspaceCanvasItem(nil, remember: true)
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
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.open(workspace: workspace))
    }

    private func openTaskFromExternalRoute(_ task: AgentTask) {
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.open(task: task))
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

    private var workspaceSelectionCoordinator: ContentWorkspaceSelectionCoordinator {
        ContentWorkspaceSelectionCoordinator(
            selectedTask: selectedTask,
            selectedWorkspace: selectedWorkspace,
            isComposingTask: isComposingTask
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
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.restore(workspace: restored))
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
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.create(workspace: result.workspace))
        return true
    }

    private func deleteWorkspace(_ ws: Workspace) {
        let next = coordinator.deleteWorkspace(ws, existingWorkspaces: workspaces)
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.delete(workspace: ws, nextWorkspace: next))
    }

    private func importWorkspace() {
        let urls = WorkspaceImportPanel.selectedURLs()
        guard !urls.isEmpty else { return }

        let result = workspaceActionCoordinator.importWorkspaces(
            from: urls,
            existingWorkspaces: workspaces,
            askDuplicateAction: WorkspaceDuplicateActionPrompt.ask
        )
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.importWorkspace(result.selectedWorkspace))
    }

    private func applyWorkspaceSelectionUpdate(_ update: ContentWorkspaceSelectionUpdate) {
        if selectedWorkspace?.id != update.selectedWorkspace?.id {
            selectedWorkspace = update.selectedWorkspace
        }
        if selectedTask?.id != update.selectedTask?.id {
            setSelectedTask(update.selectedTask)
        } else {
            selectedTask = update.selectedTask
        }
        isComposingTask = update.isComposingTask
        if update.shouldPresentRightRail {
            presentRightRail(
                rememberShelfState: update.shouldRememberShelfStateWhenPresentingRightRail
            )
        }
    }

    // MARK: - Task Actions

    private func setSelectedTask(_ task: AgentTask?) {
        let previousTaskID = selectedTask?.id
        if previousTaskID != task?.id {
            let nextCanvasItem = WorkspaceCanvasItemSelectionTransition.itemAfterTaskSelectionChange(
                currentItem: activeWorkspaceCanvasItem,
                previousTaskID: previousTaskID,
                nextTaskID: task?.id,
                isComposingTask: isComposingTask
            )
            if nextCanvasItem != activeWorkspaceCanvasItem {
                setActiveWorkspaceCanvasItem(nextCanvasItem, remember: false)
            }
        }
        if let taskWorkspace = task?.workspace,
           selectedWorkspace?.id != taskWorkspace.id {
            selectedWorkspace = taskWorkspace
        }
        if task != nil {
            // Workspace App surfaces and task selection are mutually exclusive.
            selectedWorkspaceApp = nil
            isComposingWorkspaceApp = false
        }
        selectedTask = task
        if previousTaskID != task?.id {
            clearGeneratedHTMLDiscoveryState()
            currentBrowserSession.bindToTask(task?.id)
            currentMarkdownSession.bindToTask(task?.id)
            querySession.bindToTask(task?.id)
            syncBrowserPresentation()
            refreshMarkdownShelfAvailabilityForSelectedTask()
            refreshQueryShelfAvailabilityForSelectedTask()
            refreshGeneratedHTMLAvailabilityForSelectedTask()
            restoreRememberedWorkspaceCanvasItemIfAvailable()
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
        let deletedTaskID = task.id
        if selectedTask?.id == task.id {
            setSelectedTask(nil)
        }
        _ = coordinator.deleteTask(task)
        // Release the task's browser (WebContent process + bridge listener) and
        // markdown sessions; otherwise they leak until the window closes.
        browserSessionStore.releaseSession(for: deletedTaskID)
        markdownSessionStore.releaseSession(for: deletedTaskID)
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

    private func runStoreMaintenanceIfNeeded() {
        runtime.runStoreMaintenanceIfNeeded(
            modelContext: modelContext,
            isUITestingSeededLaunch: isUITestingSeededLaunch
        )
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
        // Switching workspaces exits App Studio (its session is bound to the start workspace).
        clearWorkspaceAppSurfaceSelection()
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
        // Run the destructive store maintenance (draft prune + import dedup)
        // BEFORE restoring selection, so it can never delete the task that
        // `restoreWorkspaceSelection` is about to point `selectedTask` at.
        runStoreMaintenanceIfNeeded()
        logStoreScaleSnapshotIfNeeded()
        restoreWorkspaceSelection()
        refreshMarkdownShelfAvailabilityForSelectedTask()
        refreshQueryShelfAvailabilityForSelectedTask()
        refreshGeneratedHTMLAvailabilityForSelectedTask()
        restoreRememberedWorkspaceCanvasItemIfAvailable()
        backfillThreadTitlesIfNeeded()
        refreshProviderModelsInBackground()
        enterUITestComposerIfNeeded()
        runtime.startScheduler(modelContext: modelContext)
        runtime.loadPluginCatalog()
        refreshRunningTaskCount()
        handlePendingExternalRoute()
        refreshUpdateSafetyHooks()
        // Defer Sparkle's network probe ~3s after first appear so it doesn't
        // compete with launch I/O. Non-development channels only (dev already
        // disables updates in AppUpdateController.disabledReason). Scheduled
        // once per view instance; the controller's hasProbedForUpdates guard
        // keeps the actual probe single-fire regardless.
        if !didScheduleUpdateProbe, AppChannel.current != .development {
            didScheduleUpdateProbe = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                appUpdateController.probeForUpdatesOnce()
            }
        }
        // Post-launch chores moved off ASTRAApp.init() so they don't block the
        // first frame. Wrapped in a Task so they run on a later runloop turn,
        // after this frame is presented. Run-once-guarded inside.
        Task { @MainActor in
            ASTRAApp.runDeferredStartupWork(modelContext: modelContext)
            refreshRunningTaskCount()
        }
    }

    private func logStoreScaleSnapshotIfNeeded() {
        guard !didLogStoreScaleSnapshot else { return }
        didLogStoreScaleSnapshot = true
        Task { @MainActor in
            await Task.yield()
            StoreScalePerformanceSnapshot.log(modelContext: modelContext)
        }
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
    let canShowAppPreviewShelf: Bool
    let activeCanvasItem: WorkspaceCanvasItem?
    let browserEngine: ShelfBrowserEngine
    let isRightRailVisible: Bool

    var isPlanShelfVisible: Bool { activeCanvasItem == .plan }
    var isTextShelfVisible: Bool { activeCanvasItem == .markdown }
    var isBrowserShelfVisible: Bool { activeCanvasItem == .browser }
    var isQueryShelfVisible: Bool { activeCanvasItem == .query }
    var isAppPreviewShelfVisible: Bool { activeCanvasItem == .appPreview }

    var hasShelfControls: Bool {
        canShowPlanShelf || canShowTextShelf || canShowQueryShelf || canShowBrowserShelf || canShowAppPreviewShelf
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
    let onToggleAppPreview: () -> Void
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
        if actions.canShowAppPreviewShelf {
            shelfToolbarButton(
                title: actions.isAppPreviewShelfVisible ? "Hide Live Preview" : "Show Live Preview",
                label: "Preview",
                systemImage: "play.rectangle",
                isActive: actions.isAppPreviewShelfVisible,
                action: onToggleAppPreview
            )
            .accessibilityLabel("Live preview shelf")
        }

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
        if actions.canShowAppPreviewShelf { widths.append(AstraToolbarCommandMetrics.labeledControlMinWidth) }
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

        if actions.canShowAppPreviewShelf {
            if actions.isAppPreviewShelfVisible {
                return ShelfActiveIndicator(key: "appPreview", offset: offset, width: AstraToolbarCommandMetrics.labeledControlMinWidth)
            }
            offset += AstraToolbarCommandMetrics.labeledControlMinWidth + AstraToolbarCommandMetrics.clusterSpacing
        }

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
    @AppStorage(AppStorageKeys.appPreviewShelfWidth) private var appPreviewShelfStoredWidth = Double(WorkspaceCanvasItem.appPreview.idealWidth)
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
    var onOpenWorkspaceApp: ((WorkspaceApp) -> Void)?
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
    let isComposingWorkspaceApp: Bool
    @ObservedObject var studioSession: WorkspaceAppStudioSession
    let onStartWorkspaceAppStudio: (String?) -> Void
    let onStartMCPInstallReview: (MCPInstallChatRequest) -> Void
    let onPublishApp: (_ seedSampleData: Bool) -> Void
    let onDraftChanged: () -> Void
    let onCancelStudio: () -> Void

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
        case .appPreview:
            storedWidth = CGFloat(appPreviewShelfStoredWidth)
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
        case .appPreview:
            appPreviewShelfStoredWidth = Double(clampedWidth)
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
            onOpenWorkspaceApp: onOpenWorkspaceApp,
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
            onOpenGeneratedFile: onOpenGeneratedFile,
            isComposingWorkspaceApp: isComposingWorkspaceApp,
            studioSession: studioSession,
            onStartWorkspaceAppStudio: onStartWorkspaceAppStudio,
            onStartMCPInstallReview: onStartMCPInstallReview,
            onPublishApp: onPublishApp,
            onDraftChanged: onDraftChanged,
            onCancelStudio: onCancelStudio
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
        case .appPreview:
            ShelfWorkspaceAppPreviewView(
                session: studioSession,
                workspace: effectiveWorkspace
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
    var onOpenWorkspaceApp: ((WorkspaceApp) -> Void)?
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
    let isComposingWorkspaceApp: Bool
    @ObservedObject var studioSession: WorkspaceAppStudioSession
    let onStartWorkspaceAppStudio: (String?) -> Void
    let onStartMCPInstallReview: (MCPInstallChatRequest) -> Void
    let onPublishApp: (_ seedSampleData: Bool) -> Void
    let onDraftChanged: () -> Void
    let onCancelStudio: () -> Void

    var body: some View {
        switch ContentDetailPresentation.resolve(
            selectedTask: selectedTask,
            effectiveWorkspace: effectiveWorkspace,
            isComposingTask: isComposingTask,
            isComposingWorkspaceApp: isComposingWorkspaceApp
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
                    onOpenPlan: onOpenPlan,
                    onStartWorkspaceAppStudio: onStartWorkspaceAppStudio,
                    onStartMCPInstallReview: onStartMCPInstallReview
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
                    onOpenGeneratedFile: onOpenGeneratedFile,
                    onStartMCPInstallReview: onStartMCPInstallReview
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
                onOpenPlan: onOpenPlan,
                onStartWorkspaceAppStudio: onStartWorkspaceAppStudio,
                onStartMCPInstallReview: onStartMCPInstallReview
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
                    onManageCapabilities: onManageCapabilities,
                    onOpenWorkspaceApp: onOpenWorkspaceApp
                )
            }
        case .workspaceApp:
            EmptyView()
        case .workspaceAppStudio:
            if let workspace = effectiveWorkspace {
                WorkspaceAppStudioChatView(
                    session: studioSession,
                    workspace: workspace,
                    onPublish: onPublishApp,
                    onDraftChanged: onDraftChanged,
                    onCancel: onCancelStudio
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
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 7) {
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
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 7) {
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
