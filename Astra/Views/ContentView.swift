import SwiftUI
import SwiftData
import ASTRACore
import AppKit
import ASTRAModels
import ASTRAPersistence
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
    @Environment(\.modelContext) var modelContext
    @EnvironmentObject var feedbackRouter: FeedbackReportRouter
    @EnvironmentObject var crashOfferService: FeedbackCrashOfferService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @StateObject private var sceneSelection = SceneSelectionModel()
    @State var taskOpenResponsivenessScope = UUID()
    @State var screenTransitionCoordinator = ScreenTransitionCoordinator()
    @State private var showingConfigure = false
    @State private var configureInitialTab: ConfigureTab = .capabilities
    @State private var configureFocusItemID: UUID?
    @State private var configureFocusCapabilityPackageID: String?
    @State private var pendingMCPInstallRequest: MCPInstallChatRequest?
    @State private var showingWorkspaceEditor = false
    @State private var showingNewWorkspace = false
    @State private var showingSSHEditor = false
    @State private var editingSSHConnection: SSHConnection?
    @State private var sshReloadTrigger = 0
    @State private var newWorkspaceDraft = NewWorkspaceDraft()
    @State private var isShowingWorkspaceCapabilityEnableFailure = false
    @StateObject private var browserSessionStore = ShelfBrowserSessionStore()
    @StateObject private var markdownSessionStore = ShelfMarkdownSessionStore()
    @StateObject private var querySession = ShelfQuerySession()
    // App Studio is a conversation (center) + a docked live preview (the .appPreview shelf);
    // both observe this one session, so a chat turn updates the preview.
    @StateObject private var workspaceAppStudioSession = WorkspaceAppStudioSession()
    /// App-scoped Docker recovery owner shared by every main window.
    @ObservedObject var dockerImageRecovery: DockerImageRecoveryCoordinator
    @StateObject private var externalRouteStore = AstraExternalRouteStore.shared
    @State private var browserSessionPolicyTaskProjection = BrowserSessionPolicyTaskProjection()
    @State private var showingNewSchedule = false
    @State private var packageImportPresentation = WorkspacePackageImportSheetPresentation()
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
    @AppStorage(WorkspaceRecoveryService.recoveryNoticeKey) private var recoveryNotice = ""
    @State private var pendingAppPreviewPolicyRestore = false
    @State private var browserToolbarEngine = ShelfBrowserEngine.embedded
    // MARK: Sidebar Presentation
    /// The single owner of sidebar visibility — docked column, floating overlay
    /// drawer, or collapsed. Replaces the former `splitVisibility` @State plus the
    /// responsive/reveal-settling flags; every width probe and the AppKit split
    /// guard now *propose* changes through this model instead of racing on
    /// `splitVisibility` directly.
    @StateObject private var presentation = SidebarPresentationModel()
    // MARK: Right Panel Presentation
    /// The single owner of right-panel presentation — the workspace context
    /// rail's durable visibility intent plus the transient active shelf item.
    /// Replaces the former `isWorkspaceRightRailVisible` persisted flag
    /// (written directly from four independent call sites) and the
    /// `activeWorkspaceCanvasItem` `@State`; every writer now routes through
    /// this model instead of touching either property directly.
    @StateObject private var rightPanel = RightPanelPresentationModel()
    @StateObject private var sidebarTitlebarCommands = SidebarTitlebarCommandBridge()
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
    @State var didCheckCrashFeedback = false
    @State var pendingCrashFeedbackOffer: FeedbackCrashOffer?
    @State var feedbackErrorMessage: String?
    @State var feedbackHostID = UUID()
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
    @State private var cachedShelfAvailabilityPolicy = ShelfAvailabilityPolicy()
    @State private var cachedShelfAvailabilityPolicySignature = ""
    @State private var browserSessionPolicyCache = BrowserSessionPolicyCache()
    @State private var browserSessionPolicyRefreshGate = BrowserSessionPolicyRefreshGate()
    @State private var browserSessionPolicyRefreshTask: Task<Void, Never>?
    /// First-run flag. Flips to true once the user finishes the
    /// onboarding wizard. Exposed via Settings → "Show Onboarding Again"
    /// so users can replay the guide on demand.
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    /// An explicit replay request owns dismissibility. Presentation history
    /// must not silently turn an interrupted first run into a dismissible flow.
    @AppStorage(AppStorageKeys.onboardingReplayRequested) private var onboardingReplayRequested = false
    /// Shared preflight cache — one instance for the whole app run so the
    /// wizard's provider probe warms the cache for the catalog badges
    /// (and vice versa).

    @MainActor
    init(appUpdateController: AppUpdateController, runtime: AppRuntimeController, dockerImageRecovery: DockerImageRecoveryCoordinator) {
        self.appUpdateController = appUpdateController; self.runtime = runtime; self.dockerImageRecovery = dockerImageRecovery
    }

    var selectedTask: AgentTask? {
        sceneSelection.selectedTask
    }

    private var selectedWorkspace: Workspace? {
        sceneSelection.selectedWorkspace
    }

    private var selectedWorkspaceApp: WorkspaceApp? {
        sceneSelection.selectedWorkspaceApp
    }

    private var isComposingTask: Bool {
        sceneSelection.isComposingTask
    }

    /// Read-only forward to `RightPanelPresentationModel`. Every write goes
    /// through the model's methods (`presentCanvas`, `setActiveCanvasItem`,
    /// etc.) — never assign this directly.
    var activeWorkspaceCanvasItem: WorkspaceCanvasItem? {
        rightPanel.activeCanvasItem
    }

    /// Read-only forward to `RightPanelPresentationModel`. Every write goes
    /// through the model's methods (`presentRail`, `dismissRail`,
    /// `setRailPresented`) — never assign this directly.
    private var isWorkspaceRightRailVisible: Bool {
        rightPanel.isRailShown
    }

    private var isComposingWorkspaceApp: Bool {
        sceneSelection.isComposingWorkspaceApp
    }

    var effectiveWorkspace: Workspace? {
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

    private var renameWorkspaceAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingWorkspace != nil },
            set: { isPresented in
                if !isPresented {
                    renamingWorkspace = nil
                }
            }
        )
    }

    private var currentBrowserSession: ShelfBrowserSession {
        let policy = currentBrowserSessionPolicy
        return browserSessionStore.session(
            for: selectedTask?.id,
            pinnedToTask: isBrowserPinnedToTask,
            enabledBrowserAdapters: policy.enabledBrowserAdapters,
            githubReadOnlyMode: policy.githubReadOnlyMode
        )
    }
    private var currentMarkdownSession: ShelfMarkdownSession {
        markdownSessionStore.session(
            for: selectedTask?.id,
            workspaceID: effectiveWorkspaceID,
            pinnedToTask: isMarkdownPinnedToTask
        )
    }
    private var currentBrowserSessionPolicy: BrowserSessionPolicy {
        browserSessionPolicyRefreshGate.policy
    }
    private var browserSessionPolicyRefreshTriggerSignature: String {
        let workspace = selectedTask?.workspace ?? effectiveWorkspace
        let environmentJSON = selectedTask?.executionEnvironmentSnapshotJSON
            ?? workspace?.activeExecutionEnvironmentJSON
            ?? "host"
        return BrowserSessionPolicyRefreshTrigger(
            taskID: selectedTask?.id, workspaceID: workspace?.id,
            enabledCapabilityIDs: normalizedEnabledCapabilityIDs(for: selectedTask),
            taskCanvasRevision: selectedTaskCanvasSignature,
            taskRevision: String(selectedTask?.updatedAt.timeIntervalSince1970 ?? 0),
            workspaceRevision: [workspaceSelectionSignature, String(workspace?.updatedAt.timeIntervalSince1970 ?? 0)]
                .joined(separator: ":"),
            environmentRevision: environmentJSON
        ).rawValue
    }
    private func normalizedEnabledCapabilityIDs(for task: AgentTask?) -> [String] {
        (task?.workspace?.enabledCapabilityIDs ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
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
        TaskCanvasRefreshSignature(task: selectedTask).rawValue
    }

    private var hasWorkspaceCanvasContent: Bool { cachedHasCanvasContent }

    private var hasOpenTaskThread: Bool {
        selectedTask != nil || isComposingTask
    }

    private var shelfAvailabilityPolicy: ShelfAvailabilityPolicy {
        guard cachedShelfAvailabilityPolicySignature == shelfAvailabilityPolicyRefreshSignature else {
            return loadingShelfAvailabilityPolicy
        }
        return cachedShelfAvailabilityPolicy
    }

    private var loadingShelfAvailabilityPolicy: ShelfAvailabilityPolicy {
        shelfAvailabilityPolicyWorkspaceHasEnabledPacks
            ? .loadingForPackEnabledWorkspace()
            : ShelfAvailabilityPolicy()
    }

    private var shelfAvailabilityPolicyRefreshSignature: String {
        guard let workspace = effectiveWorkspace else { return "no-workspace" }
        let enabledPacks = workspace.enabledPackIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
        let overrides = workspace.shelfVisibilityOverrides
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return [
            workspace.id.uuidString,
            enabledPacks,
            overrides
        ].joined(separator: "|")
    }

    private var shelfAvailabilityPolicyWorkspaceHasEnabledPacks: Bool {
        effectiveWorkspace?.enabledPackIDs.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
    }

    private var shelfAvailabilityContext: ShelfAvailabilityPolicy.Context {
        ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: hasOpenTaskThread,
            hasWorkspaceContext: effectiveWorkspace != nil,
            hasPlanContent: hasWorkspaceCanvasContent,
            hasFilesShelfContent: selectedTaskHasMarkdownShelfContent,
            hasQueryShelfContent: selectedTaskHasQueryShelfContent,
            isComposingWorkspaceApp: isComposingWorkspaceApp,
            activeShelfID: activeWorkspaceCanvasItem?.shelfID
        )
    }

    private var topRightActions: WorkspaceTopRightActions {
        let policy = shelfAvailabilityPolicy
        let context = shelfAvailabilityContext
        return WorkspaceTopRightActions(
            hasWorkspace: effectiveWorkspace != nil,
            canShowPlanShelf: policy.isToolbarAvailable(.plan, in: context),
            canShowTextShelf: policy.isToolbarAvailable(.files, in: context),
            canShowBrowserShelf: policy.isToolbarAvailable(.browser, in: context),
            canShowQueryShelf: policy.isToolbarAvailable(.query, in: context),
            canShowAppPreviewShelf: policy.isToolbarAvailable(.appPreview, in: context),
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
        rightPanel.hasAnyPanelPresented(hasWorkspace: effectiveWorkspace != nil)
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
        OnboardingPresentationBindings.sheet(
            hasCompletedOnboarding: $hasCompletedOnboarding,
            replayRequested: $onboardingReplayRequested,
            isUITestingSeededLaunch: isUITestingSeededLaunch
        )
    }

    private var onboardingCompletionBinding: Binding<Bool> {
        OnboardingPresentationBindings.completion(
            hasCompletedOnboarding: $hasCompletedOnboarding,
            replayRequested: $onboardingReplayRequested
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
            appUpdateController: appUpdateController,
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
            isDockerRecoveryBusy: dockerImageRecovery.isBusy, dockerRecoveryTaskID: dockerImageRecovery.activeTaskID,
            onDeleteTask: requestDeleteTask,
            onEditWorkspace: beginEditingWorkspace,
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
            dockerImageRecovery: dockerImageRecovery,
            taskOpenResponsivenessScope: taskOpenResponsivenessScope,
            filesShelfResponsivenessScope: taskOpenResponsivenessScope,
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
            onForkTask: { setSelectedTask($0) },
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
            canOpenGeneratedFileInShelf: canOpenGeneratedFileInShelf,
            onOpenWorkspaceFile: openWorkspaceFileInShelf,
            isComposingWorkspaceApp: isComposingWorkspaceApp,
            studioSession: workspaceAppStudioSession,
            onStartWorkspaceAppStudio: { prompt in startWorkspaceAppStudio(initialPrompt: prompt) },
            onStartMCPInstallReview: { request in pendingMCPInstallRequest = request },
            onReportProblem: presentTaskFeedback,
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
                try await runWorkspaceAppAction(app: app, action: action, manifest: manifest, input: input)
            }, onDeleted: { setSelectedWorkspaceApp(nil) }
        )
        .id(app.id)
    }

    private func startWorkspaceAppStudio(
        existingManifest: WorkspaceAppManifest? = nil,
        initialPrompt: String? = nil,
        workspace targetWorkspace: Workspace? = nil
    ) {
        let studioWorkspace = targetWorkspace ?? effectiveWorkspace
        applySceneSelectionIntent {
            sceneSelection.composeApp(workspace: studioWorkspace)
        }
        rightPanel.hideRailWithoutClearingCanvasItem()
        if let workspace = studioWorkspace {
            workspaceAppStudioSession.reset(for: workspace, existingManifest: existingManifest, initialPrompt: initialPrompt)
        }
        let appPreviewItem = WorkspaceCanvasPolicyTransition.itemAfterAppStudioStart(
            policy: shelfAvailabilityPolicy,
            context: shelfAvailabilityContext
        )
        pendingAppPreviewPolicyRestore = appPreviewItem == nil
        setActiveWorkspaceCanvasItem(appPreviewItem, intent: .transient)
    }

    /// Leave the Studio without publishing: drop the composer, collapse the preview, cancel gen.
    private func cancelWorkspaceAppStudio() {
        workspaceAppStudioSession.cancelGeneration()
        sceneSelection.clearWorkspaceAppSurface()
        pendingAppPreviewPolicyRestore = false
        if activeWorkspaceCanvasItem == .appPreview {
            setActiveWorkspaceCanvasItem(nil, intent: .transient)
        }
    }

    private func toggleAppPreviewCanvas() {
        if activeWorkspaceCanvasItem == .appPreview {
            pendingAppPreviewPolicyRestore = false
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, intent: .transient)
            }
        } else {
            guard canPresentWorkspaceCanvasItem(.appPreview) else { return }
            pendingAppPreviewPolicyRestore = false
            animatePanelChange {
                rightPanel.hideRailWithoutClearingCanvasItem()
                setActiveWorkspaceCanvasItem(.appPreview, intent: .transient)
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
            applySceneSelectionIntent {
                sceneSelection.clear()
            }
            if let workspace = failure.workspace ?? effectiveWorkspace {
                startWorkspaceAppStudio(workspace: workspace)
                workspaceAppStudioSession.noteDraftOpenFailure(appName: app?.name ?? "this draft app", detail: failure.detail)
            } else if activeWorkspaceCanvasItem == .appPreview {
                setActiveWorkspaceCanvasItem(nil, intent: .transient)
            }
            return
        }
        if activeWorkspaceCanvasItem == .appPreview {
            setActiveWorkspaceCanvasItem(nil, intent: .transient)
        }
        applySceneSelectionIntent {
            sceneSelection.openApp(app, workspace: sceneCoordinator.workspace(for: app))
        }
    }

    private func runWorkspaceAppAction(
        app: WorkspaceApp,
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput
    ) async throws -> WorkspaceAppActionExecutionResult {
        guard let workspace = sceneCoordinator.workspace(for: app) else {
            throw WorkspaceAppUIError.noWorkspace
        }
        let appID = app.id
        let bindings = (try? modelContext.fetch(
            FetchDescriptor<WorkspaceAppDependencyBinding>()
        ))?.filter { $0.appID == appID } ?? []
        // Route through the ASYNC executor so a workflow action that contains a
        // connector `capability.read` step resolves on the live async client
        // instead of hitting the unavailable synchronous one.
        return try await WorkspaceAppActionExecutor().executeAsync(
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
            result = try service.updateApp(existing, manifest: draft.manifest, in: appWorkspace, modelContext: modelContext, status: .published, persistence: .saveOnly)
            isNewApp = isDraftFirstPublish
        } else {
            // New app: create in the selected workspace, deduping the logical id within it.
            target = workspace
            let manifest = WorkspaceAppStudioBuilder.manifestForPublishing(draft.manifest, existingLogicalIDs: Set(allApps.filter { $0.workspaceID == workspace.id }.map(\.logicalID)))
            result = try service.createApp(manifest: manifest, in: workspace, modelContext: modelContext, status: .published, persistence: .saveOnly)
            isNewApp = true
        }
        // Flush the build journal + snapshot the version (best-effort) into the app's OWN workspace.
        WorkspaceAppStudioJournalService().save(workspaceAppStudioSession.journal, appID: result.app.logicalID, workspacePath: target.primaryPath)
        workspaceAppStudioSession.cancelGeneration()
        do {
            let publishedData = try WorkspaceAppService.encodeManifest(result.manifest)
            try WorkspaceAppVersionService().recordPublish(app: result.app, manifestData: publishedData, validated: true, in: target, modelContext: modelContext)
        } catch {
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: target, modelContext: modelContext)
            AppLogger.error("Workspace app published but version snapshot failed: \(error)", category: "WorkspaceApps")
        }
        if seedSampleData, isNewApp { WorkspaceAppSampleSeeder.seed(manifest: result.manifest, workspacePath: target.primaryPath, appID: result.app.logicalID) }
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
        // Installs the titlebar accessory: leading navigation commands plus the
        // workspace action aligned to the live sidebar edge when it is visible.
        .astraWindowChrome(
            isSearchActive: $isSearchActive,
            sidebarCommands: sidebarTitlebarCommands,
            isSidebarToggleHovered: $isSidebarToggleHovered,
            isSidebarHidden: presentation.isSidebarHidden,
            sidebarWidth: presentation.sidebarWidth,
            showsNewWorkspaceCommand: WorkspaceAvailabilityPresentation(workspaceCount: workspaces.count).showsTitlebarCreationCommand
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
            //
            // `.collapsed` hides the sidebar footer (this control's normal home)
            // with no trace at all — restore a fallback for just that state.
            // `.docked`/`.overlay` both already keep the footer on screen.
            if presentation.mode == .collapsed {
                CollapsedSidebarUpdateToolbar(
                    appUpdateController: appUpdateController,
                    onCheckForUpdates: appUpdateController.checkForUpdatesFromButton
                )
            }
            if topRightActions.showsToolbar {
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
                    selectedWorkspace: selectedWorkspaceBinding,
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

    private var rootLayoutWithFeedbackChrome: some View {
        rootLayoutWithChrome
            .focusedSceneValue(\.reportProblemAction, { presentGeneralFeedback(from: .help) })
            .feedbackReportSheetHost(feedbackHostID)
            .modifier(ContentFeedbackAlertsModifier(
                hasCompletedOnboarding: hasCompletedOnboarding,
                offer: $pendingCrashFeedbackOffer,
                errorMessage: $feedbackErrorMessage,
                checkForOffer: checkForCrashFeedbackOffer,
                presentOffer: presentCrashFeedback,
                declineOffer: declineCrashFeedback
            ))
    }

    var body: some View {
        rootLayoutWithFeedbackChrome
        .modifier(ScreenTransitionReadinessObserver(coordinator: screenTransitionCoordinator))
        .onChange(of: selectedTaskCanvasSignature) {
            handleSelectedTaskCanvasSignatureChanged()
        }
        .onChange(of: hasOpenTaskThread) {
            if let activeWorkspaceCanvasItem,
               !canPresentWorkspaceCanvasItem(activeWorkspaceCanvasItem) {
                animatePanelChange {
                    setActiveWorkspaceCanvasItem(nil, intent: .transient)
                }
            }
            // Opening a task while the sidebar is a too-narrow overlay drawer
            // dismisses the drawer so the detail area is visible (no-op when the
            // sidebar is docked or already collapsed).
            if hasOpenTaskThread {
                presentation.handleSelectionCommitted()
            }
        }
        .onChange(of: shelfAvailabilityPolicy) {
            invalidateActiveWorkspaceCanvasItemIfUnavailable(remember: false)
            restorePendingAppPreviewAfterShelfPolicyLoadIfAvailable()
        }
        .task(id: shelfAvailabilityPolicyRefreshSignature) {
            await refreshShelfAvailabilityPolicy()
        }
        .modifier(BrowserSessionPolicyObserver(
            signature: browserSessionPolicyRefreshTriggerSignature,
            onRefresh: refreshBrowserSessionPolicy(source:),
            onTaskEventInserted: handleBrowserPolicyTaskEventInsertion
        ))
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
        .alert("Rename Workspace", isPresented: renameWorkspaceAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingWorkspace = nil }
            Button("Rename") {
                if let ws = renamingWorkspace, !renameText.isEmpty {
                    ws.name = renameText
                    do {
                        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                            workspace: ws,
                            modelContext: modelContext
                        )
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
        .sheet(item: $packageImportPresentation.presented, onDismiss: { packageImportPresentation.sheetDismissed() }) { request in
            WorkspacePackageImportReviewView(packageURL: request.url) { imported in
                packageImportPresentation.presented = nil
                if let imported {
                    applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.importWorkspace(imported))
                }
            }
            .id(request.id)
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
        .workspaceCapabilityEnableFailureAlert(isPresented: $isShowingWorkspaceCapabilityEnableFailure)
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
            sidebarTitlebarCommands.installSidebarToggleHandler(handleSidebarToggle)
            sidebarTitlebarCommands.installNewWorkspaceHandler(createWorkspace)
            handleAppear()
        }
        .onDisappear {
            sidebarTitlebarCommands.clearSidebarToggleHandler()
            sidebarTitlebarCommands.clearNewWorkspaceHandler()
            TaskOpenResponsivenessTelemetry.cancel(scope: taskOpenResponsivenessScope, reason: "content_view_disappeared")
            screenTransitionCoordinator.cancelForViewDisappearance()
            browserSessionPolicyRefreshTask?.cancel()
        }
        .onChange(of: executionSettingsSignature) { applySettings() }
        .background {
            UpdateSafetyObserver(
                taskQueue: runtime.taskQueue,
                runningTaskCount: runningTaskCount,
                onChange: handleUpdateSafetyChange
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
                hasCompletedOnboarding: onboardingCompletionBinding,
                allowsDismiss: onboardingReplayRequested,
                onDismiss: { onboardingCompletionBinding.wrappedValue = true },
                onCreateWorkspace: finalizeOnboardingWorkspace
            )
            .environment(\.preflightCache, runtime.preflightCache)
            .interactiveDismissDisabled(!onboardingReplayRequested)
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

    private func handleUpdateSafetyChange() {
        refreshRunningTaskCount()
        refreshUpdateSafetyHooks()
    }

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
        applySceneSelectionIntent {
            sceneSelection.openWorkspace(workspace)
        }
        showingWorkspaceEditor = true
    }

    private func beginRenamingWorkspace(_ workspace: Workspace) {
        renameText = workspace.name
        renamingWorkspace = workspace
    }

    private func showNewSchedule() {
        showingNewSchedule = ScheduleCreationGate.canPresent(effectiveWorkspace: effectiveWorkspace)
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
            setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
            rightPanel.dismissRail()
            presentation.revealAfterClearingRightSidePanel()
        }
    }

    private func handleSelectedTaskCanvasSignatureChanged() {
        cachedHasCanvasContent = selectedTask.flatMap { TaskPlanService.reconstruct(for: $0).plan } != nil
        if let activeWorkspaceCanvasItem,
           !canPresentWorkspaceCanvasItem(activeWorkspaceCanvasItem) {
            setActiveWorkspaceCanvasItem(nil, intent: .transient)
        }
        refreshMarkdownShelfAvailabilityForSelectedTask()
        refreshQueryShelfAvailabilityForSelectedTask()
        refreshGeneratedHTMLAvailabilityForSelectedTask()
        restoreRememberedWorkspaceCanvasItemIfAvailable()
    }

    private var workspaceCanvasPreferenceService: WorkspaceCanvasItemPreferenceService { WorkspaceCanvasItemPreferenceService(modelContext: modelContext) }

    private func setRightRailPresented(_ isPresented: Bool) {
        animatePanelChange { rightPanel.setRailPresented(isPresented) }
        if isPresented {
            workspaceCanvasPreferenceService.apply(.explicitUserChoice, item: nil, for: selectedTask)
        }
    }

    private func presentRightRail(rememberShelfState: Bool = true) {
        animatePanelChange {
            rightPanel.presentRail()
        }
        if rememberShelfState {
            workspaceCanvasPreferenceService.apply(.explicitUserChoice, item: nil, for: selectedTask)
        }
    }

    private func presentCanvas(_ item: WorkspaceCanvasItem) {
        guard canPresentWorkspaceCanvasItem(item) else { return }
        beginScreenTransitionIfNeeded(to: item, source: "shelf_action")
        commitWorkspaceCanvasItemChange {
            rightPanel.presentCanvas(item)
        }
        workspaceCanvasPreferenceService.apply(.explicitUserChoice, item: item, for: selectedTask)
        screenTransitionCoordinator.stateCommitted()
    }

    private var workspaceCanvasItemBinding: Binding<WorkspaceCanvasItem?> {
        Binding(
            get: { activeWorkspaceCanvasItem },
            set: { item in
                guard item.map(canPresentWorkspaceCanvasItem) ?? true else { return }
                setActiveWorkspaceCanvasItem(item, intent: .explicitUserChoice)
            }
        )
    }

    private func setActiveWorkspaceCanvasItem(_ item: WorkspaceCanvasItem?, intent: WorkspaceCanvasPreferenceIntent) {
        beginScreenTransitionIfNeeded(to: item, source: "shelf_state")
        commitWorkspaceCanvasItemChange {
            rightPanel.setActiveCanvasItem(item)
        }
        workspaceCanvasPreferenceService.apply(intent, item: item, for: selectedTask)
        screenTransitionCoordinator.stateCommitted()
    }

    /// Canvas shelves are docked beside the transcript. Committing the final
    /// geometry in one transaction prevents an enclosing `withAnimation` from
    /// interpolating transcript width and re-laying out long Markdown chats on
    /// every frame.
    private func commitWorkspaceCanvasItemChange(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private func restoreRememberedWorkspaceCanvasItemIfAvailable() {
        guard let item = rightPanel.restoreRememberedItemIfAvailable(
            rememberedItem: workspaceCanvasPreferenceService.rememberedItem(for: selectedTask),
            canPresent: canPresentWorkspaceCanvasItem
        ) else {
            return
        }

        beginScreenTransition(destination: screenTransitionDestination(item), source: "remembered_shelf_restore")
        prepareWorkspaceCanvasItemForPresentation(item, source: "remembered_shelf_restore")
    }

    private func invalidateActiveWorkspaceCanvasItemIfUnavailable(remember: Bool) {
        let nextItem = WorkspaceCanvasPolicyTransition.itemAfterPolicyChange(
            currentItem: activeWorkspaceCanvasItem,
            policy: shelfAvailabilityPolicy,
            context: shelfAvailabilityContext
        )
        guard nextItem != activeWorkspaceCanvasItem else { return }
        setActiveWorkspaceCanvasItem(nextItem, intent: remember ? .explicitUserChoice : .transient)
    }

    private func restorePendingAppPreviewAfterShelfPolicyLoadIfAvailable() {
        guard pendingAppPreviewPolicyRestore else { return }
        let nextItem = WorkspaceCanvasPolicyTransition.itemAfterPendingAppPreviewPolicyRestore(
            currentItem: activeWorkspaceCanvasItem,
            pendingRestore: true,
            policy: shelfAvailabilityPolicy,
            context: shelfAvailabilityContext
        )
        if nextItem != activeWorkspaceCanvasItem {
            pendingAppPreviewPolicyRestore = false
            setActiveWorkspaceCanvasItem(nextItem, intent: .transient)
            return
        }
        if !isComposingWorkspaceApp { pendingAppPreviewPolicyRestore = false }
    }

    private func canPresentWorkspaceCanvasItem(_ item: WorkspaceCanvasItem) -> Bool {
        shelfAvailabilityPolicy.canPresent(item.shelfID, in: shelfAvailabilityContext)
    }

    private func prepareWorkspaceCanvasItemForPresentation(_ item: WorkspaceCanvasItem, source: String) {
        switch item {
        case .plan:
            return
        case .markdown:
            let session = currentMarkdownSession
            session.bindToTask(selectedTask?.id)
            guard !selectedTaskPreferredMarkdownPath.isEmpty else { return }
            let url = URL(fileURLWithPath: selectedTaskPreferredMarkdownPath)
            Task { await session.loadAutomaticallyIfAllowedAsync(url) }
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
        guard canPresentWorkspaceCanvasItem(.plan) else {
            animatePanelChange {
                if activeWorkspaceCanvasItem == .plan {
                    setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
                }
            }
            return
        }
        if activeWorkspaceCanvasItem == .plan {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
            }
        } else {
            presentCanvas(.plan)
        }
    }

    private func toggleBrowserCanvas() {
        if activeWorkspaceCanvasItem == .browser {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
            }
        } else {
            guard canPresentWorkspaceCanvasItem(.browser) else { return }
            currentBrowserSession.bindToTask(selectedTask?.id)
            loadPreferredGeneratedHTMLForBrowserShelfIfNeeded(source: "browser_shelf_open")
            presentCanvas(.browser)
        }
    }

    private func openBrowserCanvas(engine: ShelfBrowserEngine) {
        guard canPresentWorkspaceCanvasItem(.browser) else { return }
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
        guard canPresentWorkspaceCanvasItem(.markdown) else {
            if activeWorkspaceCanvasItem == .markdown {
                animatePanelChange {
                    setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
                }
            }
            return
        }
        let session = currentMarkdownSession
        session.bindToTask(selectedTask?.id)
        if !selectedTaskPreferredMarkdownPath.isEmpty {
            let url = URL(fileURLWithPath: selectedTaskPreferredMarkdownPath)
            Task { await session.loadAutomaticallyIfAllowedAsync(url) }
        }
        if activeWorkspaceCanvasItem == .markdown {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
            }
        } else {
            presentCanvas(.markdown)
        }
    }

    private func toggleQueryCanvas() {
        guard canPresentWorkspaceCanvasItem(.query) else {
            if activeWorkspaceCanvasItem == .query {
                animatePanelChange {
                    setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
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
                setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
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
            setActiveWorkspaceCanvasItem(nil, intent: .transient)
        }
    }

    private func closeQueryShelfIfUnavailable() {
        guard activeWorkspaceCanvasItem == .query, !selectedTaskHasQueryShelfContent else { return }
        animatePanelChange {
            setActiveWorkspaceCanvasItem(nil, intent: .transient)
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
        let policy = currentBrowserSessionPolicy
        let session = browserSessionStore.session(
            for: taskID,
            pinnedToTask: isBrowserPinnedToTask,
            enabledBrowserAdapters: policy.enabledBrowserAdapters,
            githubReadOnlyMode: policy.githubReadOnlyMode
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
    @MainActor
    private func refreshShelfAvailabilityPolicy() async {
        let signature = shelfAvailabilityPolicyRefreshSignature
        let workspace = effectiveWorkspace
        let hasEnabledPacks = shelfAvailabilityPolicyWorkspaceHasEnabledPacks
        let catalogSnapshot = hasEnabledPacks
            ? await Task.detached { AstraPackCatalog().load() }.value
            : nil
        guard !Task.isCancelled, signature == shelfAvailabilityPolicyRefreshSignature else { return }
        cachedShelfAvailabilityPolicy = AstraPackWorkspaceProfileProvider.shelfAvailabilityPolicy(
            for: workspace,
            catalogSnapshot: catalogSnapshot
        )
        cachedShelfAvailabilityPolicySignature = signature
    }
    private func refreshBrowserSessionPolicy(source: String) {
        browserSessionPolicyRefreshTask?.cancel()
        let token = browserSessionPolicyRefreshGate.begin(), task = selectedTask; syncBrowserPresentation()
        let taskID = task?.id, workspace = task?.workspace ?? effectiveWorkspace
        let workspaceID = workspace?.id, enabledCapabilityIDs = normalizedEnabledCapabilityIDs(for: task)
        let taskEventRevision = browserSessionPolicyTaskProjection.revision(for: task)
        let latestUserMessage = browserSessionPolicyTaskProjection.latestUserMessage(for: taskID, modelContext: modelContext)
        let contextSnapshot = task.map { BrowserSessionPolicyContext.Snapshot(
            goal: $0.goal, latestUserMessage: latestUserMessage) }
        let contextText = contextSnapshot.map(BrowserSessionPolicyContext.latestContextText(in:)) ?? ""
        let hostControlInput = task.map { BrowserSessionPolicyContext.HostControlInput(task: $0,
            enabledPackageIDs: enabledCapabilityIDs, contextText: contextText) }
        let isDraft = task?.status == .draft
        let hasRuns = isDraft && task.map { BrowserSessionPolicyContext.hasRuns(taskID: $0.id, modelContext: modelContext) } == true
        let environmentSnapshot = DockerExecutionPlanner.EnvironmentSnapshot(taskSnapshotJSON: task?.executionEnvironmentSnapshotJSON,
            workspaceEnvironmentJSON: isDraft && !hasRuns ? workspace?.activeExecutionEnvironmentJSON : nil, isDraft: isDraft, hasRuns: hasRuns)
        let catalogPolicyInput = workspace.map(BrowserSessionPolicyContext.CatalogPolicyInput.init(workspace:))
        browserSessionPolicyRefreshTask = Task { @MainActor in
            let diskSnapshot = await Task.detached(priority: .userInitiated) {
                let packages = CapabilityRuntimeResourceMatcher.packageDefinitions()
                return (
                    approvalRevision: CapabilityApprovalStore().revisionFingerprint(),
                    packageFingerprint: CapabilityRuntimeResourceMatcher.packageDefinitionsFingerprint(),
                    packages: packages,
                    approvals: CapabilityApprovalStore().records(),
                    contextText: contextText, environment: DockerExecutionPlanner.resolveEnvironment(from: environmentSnapshot),
                    policyContext: catalogPolicyInput?.resolve(),
                    hostControlCapabilitySnapshot: hostControlInput?.resolve(packageDefinitions: packages))
            }.value
            guard !Task.isCancelled else { return }
            let environmentRevision = diskSnapshot.environment.signatureFingerprint
            let signature = BrowserSessionPolicySignature(
                taskID: taskID, workspaceID: workspaceID, environmentRevision: environmentRevision,
                enabledCapabilityIDs: enabledCapabilityIDs, approvalRevision: diskSnapshot.approvalRevision,
                packageDefinitionFingerprint: diskSnapshot.packageFingerprint, taskEventRevision: taskEventRevision,
                catalogPolicyRevision: catalogPolicyInput?.signature ?? "no-policy")
            let policy = browserSessionPolicyCache.policy(
                for: signature,
                source: BrowserSessionPolicySource(
                    packageDefinitions: { diskSnapshot.packages },
                    approvalRecords: { diskSnapshot.approvals },
                    latestContextText: { diskSnapshot.contextText },
                    environment: { diskSnapshot.environment },
                    enabledBrowserAdapters: { signature, packages, approvalRecords in
                        guard var policyContext = diskSnapshot.policyContext else { return [] }
                        policyContext.approvalRecords = approvalRecords
                        return packages.filter {
                            signature.enabledCapabilityIDs.contains($0.id)
                                && CapabilityCatalogPolicy.decision(for: $0, context: policyContext).canRun
                        }
                            .flatMap(\.browserAdapters)
                            .compactMap(BrowserSiteAdapterID.normalized)
                    },
                    githubReadOnlyMode: { environment, _ in BrowserSessionPolicyContext.githubReadOnlyMode(
                        environment: environment, capabilitySnapshot: diskSnapshot.hostControlCapabilitySnapshot) }
                )
            )
            guard browserSessionPolicyRefreshGate.accept(policy, for: token) else { return }
            syncBrowserPresentation()
            AppLogger.audit(.shelfBrowserPreview, category: "Browser", taskID: taskID, fields: [
                "event": "browser_session_policy_refreshed",
                "source": source,
                "enabled_browser_adapters": policy.enabledBrowserAdapters.joined(separator: ","),
                "github_read_only_mode": String(policy.githubReadOnlyMode)
            ])
        }
    }
    private func handleBrowserPolicyTaskEventInsertion(_ insertion: DurableTaskEventInsertion) {
        guard browserSessionPolicyTaskProjection.record(insertion, selectedTaskID: selectedTask?.id) else { return }
        refreshBrowserSessionPolicy(source: "task_event_inserted")
    }
    private func openGeneratedFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        switch TaskGeneratedFiles.shelfDestination(for: path) {
        case .browser?:
            guard canOpenGeneratedFileInShelf(.browser) else {
                NSWorkspace.shared.open(url)
                return
            }
            let taskID = selectedTask?.id
            let policy = currentBrowserSessionPolicy
            let session = browserSessionStore.session(
                for: taskID,
                pinnedToTask: isBrowserPinnedToTask,
                enabledBrowserAdapters: policy.enabledBrowserAdapters,
                githubReadOnlyMode: policy.githubReadOnlyMode
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
            guard canOpenGeneratedFileInShelf(.files) else {
                NSWorkspace.shared.open(url)
                return
            }
            selectedTaskPreferredMarkdownPath = path
            selectedTaskHasMarkdownShelfContent = true
            let session = currentMarkdownSession
            presentCanvas(.markdown)
            Task { await session.loadAsync(url) }
            return

        case .query?:
            guard canOpenGeneratedFileInShelf(.query) else {
                NSWorkspace.shared.open(url)
                return
            }
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

    private func canOpenGeneratedFileInShelf(_ destination: TaskGeneratedFileShelfDestination?) -> Bool {
        TaskGeneratedFileOpenRouter.canOpenInShelf(
            destination: destination,
            policy: shelfAvailabilityPolicy,
            context: shelfAvailabilityContext
        )
    }

    private func openWorkspaceFileInShelf(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let taskID = selectedTask?.id
        guard canOpenGeneratedFileInShelf(.files) else {
            NSWorkspace.shared.open(url)
            AppLogger.audit(.gitChangedFileOpenedInShelf, category: "Git", taskID: taskID, fields: [
                "path": url.path,
                "result": FileManager.default.fileExists(atPath: url.path) ? "opened_system" : "missing_system"
            ], level: FileManager.default.fileExists(atPath: url.path) ? .info : .warning)
            return
        }
        selectedTaskPreferredMarkdownPath = url.path
        selectedTaskHasMarkdownShelfContent = true
        let session = currentMarkdownSession
        AppLogger.audit(.gitChangedFileOpenedInShelf, category: "Git", taskID: taskID, fields: [
            "path": url.path,
            "result": FileManager.default.fileExists(atPath: url.path) ? "opened" : "missing"
        ], level: FileManager.default.fileExists(atPath: url.path) ? .info : .warning)
        presentCanvas(.markdown)
        Task { await session.loadAsync(url) }
    }

    private func syncBrowserPresentation() {
        let policy = currentBrowserSessionPolicy
        browserSessionStore.setPresented(
            activeWorkspaceCanvasItem == .browser,
            taskID: selectedTask?.id,
            pinnedToTask: isBrowserPinnedToTask,
            enabledBrowserAdapters: policy.enabledBrowserAdapters,
            githubReadOnlyMode: policy.githubReadOnlyMode
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
        let wasComposingWorkspaceApp = isComposingWorkspaceApp
        applySceneSelectionIntent {
            sceneSelection.openWorkspace(workspace)
        }
        clearWorkspaceAppSurfaceSideEffects(wasComposing: wasComposingWorkspaceApp)
    }

    private func clearWorkspaceAppSurfaceSelection() {
        let wasComposing = isComposingWorkspaceApp
        sceneSelection.clearWorkspaceAppSurface()
        clearWorkspaceAppSurfaceSideEffects(wasComposing: wasComposing)
    }

    private func clearWorkspaceAppSurfaceSideEffects(wasComposing: Bool) {
        if wasComposing {
            workspaceAppStudioSession.cancelGeneration()
            pendingAppPreviewPolicyRestore = false
        }
        if activeWorkspaceCanvasItem == .appPreview {
            setActiveWorkspaceCanvasItem(nil, intent: .transient)
        }
    }

    private func startComposingTask() {
        let wasComposingWorkspaceApp = isComposingWorkspaceApp
        setSelectedTask(nil, recordsFinalHomeTransition: false)
        sceneSelection.composeTask()
        clearWorkspaceAppSurfaceSideEffects(wasComposing: wasComposingWorkspaceApp)
        presentRightRail(rememberShelfState: false)
    }

    private func handleQuickRunTask(_ task: AgentTask) {
        promoteDraftBrowserSessionIfNeeded(to: task)
        setSelectedTask(task)
        runSingleTask(task)
    }

    private func handleTaskCreated(_ task: AgentTask) {
        promoteDraftBrowserSessionIfNeeded(to: task)
        setSelectedTask(task)
        presentRightRail(rememberShelfState: false)
    }

    private func promoteDraftBrowserSessionIfNeeded(to task: AgentTask) {
        guard selectedTask == nil || isComposingTask else { return }
        let wasPresented = activeWorkspaceCanvasItem == .browser
        let policy = currentBrowserSessionPolicy
        let promoted = browserSessionStore.promoteSharedSession(
            to: task.id,
            pinnedToTask: isBrowserPinnedToTask,
            isPresented: wasPresented,
            enabledBrowserAdapters: policy.enabledBrowserAdapters,
            githubReadOnlyMode: policy.githubReadOnlyMode
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
        let previousTaskID = selectedTask?.id
        let currentCachedHasPlanContent = cachedHasCanvasContent
        let targetHasPlanContent: Bool
        if previousTaskID == task.id {
            targetHasPlanContent = currentCachedHasPlanContent
        } else {
            targetHasPlanContent = TaskPlanService.reconstruct(for: task).plan != nil
        }
        guard targetHasPlanContent else { return }

        if previousTaskID == task.id, activeWorkspaceCanvasItem == .plan {
            animatePanelChange {
                setActiveWorkspaceCanvasItem(nil, intent: .explicitUserChoice)
            }
            return
        }
        if previousTaskID != task.id {
            setSelectedTask(task)
            cachedHasCanvasContent = WorkspacePlanCanvasPresentationTransition.cachedHasPlanContentAfterTargetValidation(
                previousTaskID: previousTaskID,
                targetTaskID: task.id,
                currentCachedHasPlanContent: currentCachedHasPlanContent,
                targetHasPlanContent: targetHasPlanContent
            )
        }
        presentCanvas(.plan)
    }

    private func openExistingTask(_ task: AgentTask) {
        setSelectedTask(task)
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
        setSelectedTask(nil, recordsFinalHomeTransition: false)
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
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: nil,
                modelContext: modelContext
            )
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
        let outcome = createWorkspace(from: newWorkspaceDraft, source: "workspace_creation")
        guard outcome != .notCreated else { return }
        if outcome == .createdWithCapabilityIssues {
            isShowingWorkspaceCapabilityEnableFailure = true
        }
        showingNewWorkspace = false
        resetNewWorkspaceDraft()
    }

    @discardableResult
    private func finalizeOnboardingWorkspace(_ draft: NewWorkspaceDraft) -> WorkspaceCreationOutcome {
        createWorkspace(from: draft, source: "onboarding")
    }

    @discardableResult
    private func createWorkspace(from draft: NewWorkspaceDraft, source: String) -> WorkspaceCreationOutcome {
        guard let result = workspaceActionCoordinator.createWorkspace(from: draft, source: source) else { return .notCreated }
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.create(workspace: result.workspace))
        return result.hasCapabilityEnableFailures ? .createdWithCapabilityIssues : .created
    }

    private func deleteWorkspace(_ ws: Workspace) {
        markdownSessionStore.releaseSession(forWorkspaceID: ws.id)
        let next = coordinator.deleteWorkspace(ws, existingWorkspaces: workspaces)
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.delete(workspace: ws, nextWorkspace: next))
    }

    private func importWorkspace() {
        let urls = WorkspaceImportPanel.selectedURLs()
        guard !urls.isEmpty else { return }

        // .astra-share packages get the review-before-import flow (each selected
        // one reviewed in turn); everything else stays on the legacy path.
        let partition = WorkspacePackageImportRouting.partition(urls)
        if !partition.packageURLs.isEmpty {
            packageImportPresentation.request(partition.packageURLs.map(WorkspacePackageImportRequest.init(url:)))
        }
        guard !partition.legacyURLs.isEmpty else { return }

        let result = workspaceActionCoordinator.importWorkspaces(
            from: partition.legacyURLs,
            existingWorkspaces: workspaces,
            askDuplicateAction: WorkspaceDuplicateActionPrompt.ask
        )
        applyWorkspaceSelectionUpdate(workspaceSelectionCoordinator.importWorkspace(result.selectedWorkspace))
    }

    private func applyWorkspaceSelectionUpdate(_ update: ContentWorkspaceSelectionUpdate) {
        let previousTaskID = selectedTask?.id
        if previousTaskID != update.selectedTask?.id {
            TaskOpenResponsivenessTelemetry.beginForSelection(task: update.selectedTask, source: "workspace_selection", scope: taskOpenResponsivenessScope)
        }
        let transitionTask = TaskOpenResponsivenessTelemetry.shouldMeasureSelectionTransition(previousTaskID: previousTaskID, nextTaskID: update.selectedTask?.id) ? update.selectedTask : nil
        let sceneUpdate = measurePreShellNavigation(for: transitionTask) {
            updateCanvasForTaskSelectionChange(previousTaskID: previousTaskID, nextTaskID: update.selectedTask?.id)
            let sceneUpdate = sceneSelection.apply(update)
            if previousTaskID != update.selectedTask?.id {
                handleSelectedTaskIdentityChanged(to: update.selectedTask)
            }
            markTaskRead(update.selectedTask)
            return sceneUpdate
        }
        if sceneUpdate.clearedWorkspaceAppSurface {
            clearWorkspaceAppSurfaceSideEffects(wasComposing: sceneUpdate.cancelledWorkspaceAppComposer)
        }
        if update.shouldPresentRightRail {
            presentRightRail(
                rememberShelfState: update.shouldRememberShelfStateWhenPresentingRightRail
            )
        }
    }

    private func applySceneSelectionIntent(_ intent: () -> Void) {
        let selectionStart = TaskOpenResponsivenessTelemetry.captureSelectionStart()
        let previousTaskID = selectedTask?.id
        let isComposingTaskForTransition = isComposingTask
        intent()
        guard previousTaskID != selectedTask?.id else { return }
        TaskOpenResponsivenessTelemetry.beginForSelection(task: selectedTask, source: "scene_selection",
                                                          scope: taskOpenResponsivenessScope, selectionStart: selectionStart)
        updateCanvasForTaskSelectionChange(
            previousTaskID: previousTaskID,
            nextTaskID: selectedTask?.id,
            isComposingTaskForTransition: isComposingTaskForTransition
        )
        handleSelectedTaskIdentityChanged(to: selectedTask)
        markTaskRead(selectedTask)
        if let selectedTask {
            TaskOpenResponsivenessTelemetry.recordPhase("pre_shell_navigation", task: selectedTask,
                                                        scope: taskOpenResponsivenessScope,
                                                        startedAtUptimeNanoseconds: selectionStart.uptimeNanoseconds)
        }
    }
    // MARK: - Task Actions
    private func setSelectedTask(_ task: AgentTask?, recordsFinalHomeTransition: Bool = true) {
        let previousTaskID = selectedTask?.id
        if previousTaskID != task?.id {
            TaskOpenResponsivenessTelemetry.beginForSelection(task: task, source: "task_selection", scope: taskOpenResponsivenessScope)
            if task == nil, recordsFinalHomeTransition {
                beginScreenTransition(destination: "workspace_home", source: "task_selection_cleared",
                                      taskID: nil, usesSelectedTask: false)
            }
        }
        let transitionTask = TaskOpenResponsivenessTelemetry.shouldMeasureSelectionTransition(
            previousTaskID: previousTaskID, nextTaskID: task?.id) ? task : nil
        measurePreShellNavigation(for: transitionTask) {
            updateCanvasForTaskSelectionChange(
                previousTaskID: previousTaskID,
                nextTaskID: task?.id,
                recordsTransition: recordsFinalHomeTransition
            )
            let wasComposingWorkspaceApp = isComposingWorkspaceApp
            sceneSelection.openTask(task)
            clearWorkspaceAppSurfaceSideEffects(wasComposing: wasComposingWorkspaceApp)
            if previousTaskID != task?.id {
                handleSelectedTaskIdentityChanged(to: task)
            }
            markTaskRead(task)
        }
    }
    private func measurePreShellNavigation<T>(for task: AgentTask?, _ work: () -> T) -> T {
        TaskOpenResponsivenessTelemetry.measurePhase("pre_shell_navigation", task: task, scope: taskOpenResponsivenessScope, work)
    }

    private func updateCanvasForTaskSelectionChange(
        previousTaskID: UUID?,
        nextTaskID: UUID?,
        isComposingTaskForTransition: Bool? = nil,
        recordsTransition: Bool = true
    ) {
        guard previousTaskID != nextTaskID else { return }
        let nextCanvasItem = WorkspaceCanvasItemSelectionTransition.itemAfterTaskSelectionChange(
            currentItem: activeWorkspaceCanvasItem,
            previousTaskID: previousTaskID,
            nextTaskID: nextTaskID,
            isComposingTask: isComposingTaskForTransition ?? isComposingTask
        )
        if nextCanvasItem != activeWorkspaceCanvasItem {
            if recordsTransition {
                beginScreenTransitionIfNeeded(
                    to: nextCanvasItem,
                    source: "task_selection_shelf_clear",
                    baseDestination: nextTaskID == nil ? "workspace_home" : "task_chat",
                    taskID: nextTaskID,
                    usesSelectedTask: false
                )
            }
            rightPanel.setActiveCanvasItem(nextCanvasItem)
            workspaceCanvasPreferenceService.apply(.transient, item: nextCanvasItem, for: selectedTask)
        }
    }

    private func handleSelectedTaskIdentityChanged(to task: AgentTask?) {
        clearGeneratedHTMLDiscoveryState()
        browserSessionPolicyRefreshTask?.cancel(); _ = browserSessionPolicyRefreshGate.begin()
        bindTaskScopedSessions(to: task?.id)
        syncBrowserPresentation()
        refreshMarkdownShelfAvailabilityForSelectedTask()
        refreshQueryShelfAvailabilityForSelectedTask()
        refreshGeneratedHTMLAvailabilityForSelectedTask()
        restoreRememberedWorkspaceCanvasItemIfAvailable()
    }
    private func bindTaskScopedSessions(to taskID: UUID?) {
        currentBrowserSession.bindToTask(taskID)
        currentMarkdownSession.bindToTask(taskID)
        querySession.bindToTask(taskID)
    }

    private func markSelectedTaskReadIfNeeded() {
        markTaskRead(selectedTask)
    }

    private func markTaskRead(_ task: AgentTask?) {
        guard let task, task.unreadAt != nil else { return }
        TaskOpenResponsivenessTelemetry.measurePhase(
            "mark_task_read_persistence",
            task: task,
            scope: taskOpenResponsivenessScope
        ) {
            task.markRead()
            do {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext
                )
            } catch {
                AppLogger.audit(.taskFailed, category: "UI", taskID: task.id, fields: [
                    "operation": "mark_task_read",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
        }
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
        guard dockerImageRecovery.canStartTaskRetry(for: task.id) else {
            AppLogger.audit(.taskRetried, category: "UI", taskID: task.id, fields: [
                "retry_mode": "rejected_docker_recovery_busy"
            ], level: .warning)
            return
        }
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
        let deletedTaskID = task.id; dockerImageRecovery.invalidateIfTaskDeleted(deletedTaskID)
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
            dockerImageRecovery.invalidateIfTaskClosed(task.id); coordinator.setDoneState(task, to: true)
            refreshRunningTaskCount()
            return
        }

        linkedScheduleWarning = LinkedScheduleWarning(task: task, schedules: linkedSchedules, action: .markDone)
    }

    private func pauseSchedulesAndContinue(_ warning: LinkedScheduleWarning) {
        coordinator.pauseSchedules(warning.schedules)

        switch warning.action {
        case .markDone:
            dockerImageRecovery.invalidateIfTaskClosed(warning.task.id); coordinator.setDoneState(warning.task, to: true)
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
        // Switching away from an app surface exits App Studio/detail. Workspace
        // changes caused by app/app-studio intents are already bound to the new
        // workspace and must not clear themselves via this observer.
        if sceneSelection.shouldClearWorkspaceAppSurfaceAfterWorkspaceChange {
            clearWorkspaceAppSurfaceSelection()
        }
        if isUITestingSeededLaunch {
            setSelectedTask(nil)
            if selectedWorkspace != nil {
                sceneSelection.composeTask()
            } else {
                sceneSelection.openWorkspace(nil)
            }
        } else if isComposingTask {
            sceneSelection.openWorkspace(selectedWorkspace)
        }
        invalidateActiveWorkspaceCanvasItemIfUnavailable(remember: false)
        persistWorkspaceSelection()
    }

    private func handleWorkspaceSelectionSignatureChanged() {
        restoreWorkspaceSelection()
        enterUITestComposerIfNeeded()
        handlePendingExternalRoute()
    }

    private func handleAppear() {
        cachedHasCanvasContent = selectedTask.flatMap { TaskPlanService.reconstruct(for: $0).plan } != nil
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
            runtime.taskQueue.replayRecoveredTurns(modelContext: modelContext)
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
        sceneSelection.composeTask()
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
                sceneSelection.openWorkspace(existing)
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
        sceneSelection.openWorkspace(ws)
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
            TaskStateMachine.enqueueFromUITestSeed(task, modelContext: modelContext)
            modelContext.insert(task)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: ws, modelContext: modelContext)
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

/// Fallback for when the sidebar footer is off screen — see the `.collapsed` gate above.
private struct CollapsedSidebarUpdateToolbar: ToolbarContent {
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
    @ObservedObject var dockerImageRecovery: DockerImageRecoveryCoordinator
    let taskOpenResponsivenessScope: UUID
    let filesShelfResponsivenessScope: UUID
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
    @StateObject private var markdownFileIndex = ShelfFileIndexController()

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
    let canOpenGeneratedFileInShelf: (TaskGeneratedFileShelfDestination?) -> Bool
    let onOpenWorkspaceFile: (String) -> Void
    let isComposingWorkspaceApp: Bool
    @ObservedObject var studioSession: WorkspaceAppStudioSession
    let onStartWorkspaceAppStudio: (String?) -> Void
    let onStartMCPInstallReview: (MCPInstallChatRequest) -> Void
    let onReportProblem: (
        AgentTask, FeedbackReportPrefill, UUID?, RuntimeFeedbackPersistedEvidence?, Date?
    ) -> Void
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
            let layoutMode = WorkspaceRightPanelLayoutMode.resolve(
                panel: activePanel, usesInspectorOverlay: usesInspectorOverlay
            )
            let detailProposalWidth = layoutMode.detailProposalWidth(
                availableWidth: availableWidth, panelWidth: dockedPanelWidth
            )
            let detailUnobscuredWidth = layoutMode.detailUnobscuredWidth(availableWidth: availableWidth, panelWidth: dockedPanelWidth)
            let transitionMode = WorkspaceRightPanelTransitionMode.resolve(usesInspectorOverlay: usesInspectorOverlay)
            ZStack(alignment: .trailing) {
                detailContent
                    .environment(\.taskChatUnobscuredWidth, detailUnobscuredWidth)
                    .frame(width: detailProposalWidth, height: proxy.size.height)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                    .clipped()
                if let activePanel, !usesInspectorOverlay {
                    rightPanel(
                        activePanel,
                        width: dockedPanelWidth,
                        availableWidth: availableWidth,
                        isOverlay: false
                    )
                    .zIndex(1)
                }

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
            .animation(
                transitionMode.animatesPanel ? panelAnimation : nil,
                value: activeRightPanel
            )
        }
        .background(Stanford.panelBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: activeCanvasItem) { oldValue, newValue in
            guard oldValue == .markdown, newValue != .markdown else { return }
            markdownFileIndex.cancel(
                responsivenessScope: filesShelfResponsivenessScope,
                reason: "shelf_closed"
            )
            markdownSession.cancelPendingDocumentLoad()
        }
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
            dockerImageRecovery: dockerImageRecovery,
            taskOpenResponsivenessScope: taskOpenResponsivenessScope,
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
            canOpenGeneratedFileInShelf: canOpenGeneratedFileInShelf,
            isComposingWorkspaceApp: isComposingWorkspaceApp,
            studioSession: studioSession,
            onStartWorkspaceAppStudio: onStartWorkspaceAppStudio,
            onStartMCPInstallReview: onStartMCPInstallReview,
            onReportProblem: onReportProblem,
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
                fileIndex: markdownFileIndex,
                isPinnedToTask: $isMarkdownPinnedToTask,
                workspace: effectiveWorkspace,
                task: selectedTask,
                onOpenGeneratedFile: onOpenGeneratedFile,
                responsivenessScope: filesShelfResponsivenessScope
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
    @ObservedObject var dockerImageRecovery: DockerImageRecoveryCoordinator
    let taskOpenResponsivenessScope: UUID
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
    let canOpenGeneratedFileInShelf: (TaskGeneratedFileShelfDestination?) -> Bool
    let isComposingWorkspaceApp: Bool
    @ObservedObject var studioSession: WorkspaceAppStudioSession
    let onStartWorkspaceAppStudio: (String?) -> Void
    let onStartMCPInstallReview: (MCPInstallChatRequest) -> Void
    let onReportProblem: (
        AgentTask, FeedbackReportPrefill, UUID?, RuntimeFeedbackPersistedEvidence?, Date?
    ) -> Void
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
                    dockerImageRecovery: dockerImageRecovery,
                    taskOpenResponsivenessScope: taskOpenResponsivenessScope,
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
                    canOpenGeneratedFileInShelf: canOpenGeneratedFileInShelf,
                    onStartMCPInstallReview: onStartMCPInstallReview,
                    onReportProblem: { prefill, runID, evidence, failureOccurredAt in
                        onReportProblem(task, prefill, runID, evidence, failureOccurredAt)
                    }
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
                    onOpenWorkspaceApp: onOpenWorkspaceApp,
                    onAddSSHConnection: onAddSSHConnection,
                    sshReloadTrigger: sshReloadTrigger
                )
            }
        case .workspaceApp:
            EmptyView()
        case .workspaceAppStudio:
            if let workspace = effectiveWorkspace {
                WorkspaceAppStudioChatView(
                    session: studioSession,
                    workspace: workspace,
                    enabledPackIDs: WorkspaceAppStudioTemplatePackLoadingSource(workspace: workspace).enabledPackIDs,
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

                Text(WorkspaceSetupFormMode.standard.presentation.headerSubtitle)
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
        self._isCapabilitiesExpanded = State(initialValue: mode.presentation.expandsCapabilitiesInitially)
    }

    private var displayedRootPath: String {
        (rootPath as NSString).abbreviatingWithTildeInPath
    }

    private var presentation: WorkspaceCreationPresentation {
        mode.presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if presentation.showsWorkspacePrimer {
                WorkspaceConceptPrimer()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Workspace name")
                    .font(Stanford.caption(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)

                TextField(presentation.namePlaceholder, text: $draft.name)
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
                    .accessibilityLabel("Workspace name")
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

                Text(presentation.guidanceDescription)
                    .font(Stanford.body(13))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft.instructions)
                        .font(Stanford.body(14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 86)
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(focusedField == .guidance ? Stanford.focusRing : Color.secondary.opacity(0.20), lineWidth: 1)
                        )
                        .focused($focusedField, equals: .guidance)
                        .accessibilityLabel("Workspace guidance")
                        .accessibilityHint(presentation.guidanceDescription)

                    if draft.instructions.isEmpty {
                        Text(presentation.guidancePlaceholder)
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
                Text(presentation.capabilitiesExpandedDescription)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

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
                        Text(presentation.capabilitiesTitle)
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
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Stanford.sandstone.opacity(0.22), lineWidth: 1)
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
        OnboardingCapabilitySetup.outcomeSubtitle(for: option)
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
            return presentation.capabilitiesSummary
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
            source: mode.validationSource,
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
