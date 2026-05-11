import SwiftUI
import SwiftData
import ASTRACore
import AppKit

enum ContentSelectionResolver {
    static func effectiveWorkspace(selectedTask: AgentTask?, selectedWorkspace: Workspace?) -> Workspace? {
        selectedTask?.workspace ?? selectedWorkspace
    }
}

enum ContentDetailPresentation: Equatable {
    case draftTask
    case existingTask
    case newTaskComposer
    case workspaceHome
    case noWorkspace

    static func resolve(
        selectedTask: AgentTask?,
        effectiveWorkspace: Workspace?,
        isComposingTask: Bool
    ) -> ContentDetailPresentation {
        if let selectedTask {
            return selectedTask.status == .draft ? .draftTask : .existingTask
        }

        guard let effectiveWorkspace else {
            return .noWorkspace
        }

        if isComposingTask || effectiveWorkspace.tasks.isEmpty {
            return .newTaskComposer
        }

        return .workspaceHome
    }
}

/// Layout-level artifacts shown in the docked Shelf column.
/// Future cases can choose wider sizing for browser or file previews.
private enum WorkspaceCanvasItem: Equatable {
    case plan
    case markdown
    case browser

    var minWidth: CGFloat {
        switch self {
        case .plan: 400
        case .markdown: 360
        case .browser: 360
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .plan: 520
        case .markdown: 520
        case .browser: 440
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .plan: 1040
        case .markdown: 980
        case .browser: 1120
        }
    }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .markdown: "Markdown"
        case .browser: "Browser"
        }
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

@MainActor
private final class ShelfBrowserSessionStore: ObservableObject {
    private let sharedSession = ShelfBrowserSession()
    private var taskSessions: [UUID: ShelfBrowserSession] = [:]

    func session(for taskID: UUID?, pinnedToTask: Bool) -> ShelfBrowserSession {
        guard pinnedToTask, let taskID else {
            sharedSession.bindToTask(taskID)
            return sharedSession
        }

        if let session = taskSessions[taskID] {
            session.bindToTask(taskID)
            return session
        }

        let session = ShelfBrowserSession()
        session.bindToTask(taskID)
        taskSessions[taskID] = session
        return session
    }

    func setPresented(_ isPresented: Bool, taskID: UUID?, pinnedToTask: Bool) {
        sharedSession.setPresented(false)
        for session in taskSessions.values {
            session.setPresented(false)
        }

        guard isPresented else { return }
        session(for: taskID, pinnedToTask: pinnedToTask).setPresented(true)
    }
}

@MainActor
private final class ShelfMarkdownSessionStore: ObservableObject {
    private let sharedSession = ShelfMarkdownSession()
    private var taskSessions: [UUID: ShelfMarkdownSession] = [:]

    func session(for taskID: UUID?, pinnedToTask: Bool) -> ShelfMarkdownSession {
        guard pinnedToTask, let taskID else {
            sharedSession.bindToTask(taskID)
            return sharedSession
        }

        if let session = taskSessions[taskID] {
            session.bindToTask(taskID)
            return session
        }

        let session = ShelfMarkdownSession()
        session.bindToTask(taskID)
        taskSessions[taskID] = session
        return session
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
                        .fill(Stanford.lagunita.opacity(metrics.isResizing ? 0.95 : 0.55))
                        .frame(width: metrics.isResizing ? 3 : 2)
                    Spacer(minLength: 0)
                }
                .frame(width: metrics.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all, edges: .top)
            .allowsHitTesting(false)
        }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @State private var selectedTask: AgentTask?
    @State private var selectedWorkspace: Workspace?
    @State private var showingDashboard = false
    @State private var showingLogs = false
    @State private var showingConfigure = false
    @State private var configureInitialTab: ConfigureTab = .capabilities
    @State private var configureFocusItemID: UUID?
    @State private var showingWorkspaceEditor = false
    @State private var showingNewWorkspace = false
    @State private var showingSSHEditor = false
    @State private var editingSSHConnection: SSHConnection?
    @State private var isComposingTask = false
    @State private var sshReloadTrigger = 0
    @State private var newWorkspaceDraft = NewWorkspaceDraft()
    @State private var runtime = AppRuntimeController()
    @StateObject private var browserSessionStore = ShelfBrowserSessionStore()
    @StateObject private var markdownSessionStore = ShelfMarkdownSessionStore()
    @State private var showingNewSchedule = false
    @State private var editingSchedule: TaskSchedule?
    @State private var isSearchActive = false
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""
    @State private var linkedScheduleWarning: LinkedScheduleWarning?
    @State private var runningTaskCount = 0
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("copilotPath") private var copilotPath = ""
    @AppStorage("defaultRuntimeID") private var defaultRuntimeID = "claude_code"
    @AppStorage("timeoutSeconds") private var timeoutSeconds = 600
    @AppStorage("appUIScale") private var uiScale: Double = 1.0
    @AppStorage("validationModel") private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @AppStorage(AppStorageKeys.skipPermissions) private var skipPermissions = false
    @AppStorage(AppStorageKeys.securityGateDefaultedToReview) private var securityGateDefaultedToReview = false
    @AppStorage(AppStorageKeys.browserPinnedToTask) private var isBrowserPinnedToTask = true
    @AppStorage(AppStorageKeys.markdownPinnedToTask) private var isMarkdownPinnedToTask = true
    @AppStorage("lastSelectedWorkspaceID") private var lastSelectedWorkspaceID = ""
    @AppStorage("lastSelectedWorkspacePath") private var lastSelectedWorkspacePath = ""
    @AppStorage("isWorkspaceRightRailVisible") private var isWorkspaceRightRailVisible = true
    @AppStorage(WorkspaceRecoveryService.recoveryNoticeKey) private var recoveryNotice = ""
    @State private var activeWorkspaceCanvasItem: WorkspaceCanvasItem?
    @State private var panelTransitionGeneration = 0
    @State private var cachedHasCanvasContent = false
    @State private var generatedHTMLPreviewTask: Task<Void, Never>?
    @State private var generatedMarkdownPreviewTask: Task<Void, Never>?
    @State private var markdownAvailabilityTask: Task<Void, Never>?
    @State private var lastGeneratedHTMLPreviewSignature = ""
    @State private var lastGeneratedMarkdownPreviewSignature = ""
    @State private var selectedTaskHasMarkdownShelfContent = false
    @State private var selectedTaskPreferredMarkdownPath = ""
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
    init(appUpdateController: AppUpdateController) {
        self.appUpdateController = appUpdateController
    }

    private var effectiveWorkspace: Workspace? {
        ContentSelectionResolver.effectiveWorkspace(
            selectedTask: selectedTask,
            selectedWorkspace: selectedWorkspace
        )
    }

    private var workspaceSelectionSignature: String {
        workspaces
            .map { "\($0.id.uuidString)|\($0.primaryPath)" }
            .joined(separator: ",")
    }

    private var executionSettingsSignature: String {
        [
            claudePath,
            copilotPath,
            defaultRuntimeID,
            String(timeoutSeconds),
            validationModel,
            String(skipPermissions)
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
            pinnedToTask: isBrowserPinnedToTask
        )
    }

    private var currentMarkdownSession: ShelfMarkdownSession {
        markdownSessionStore.session(
            for: selectedTask?.id,
            pinnedToTask: isMarkdownPinnedToTask
        )
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
        let state = TaskPlanService.reconstruct(for: selectedTask)
        guard let plan = state.plan else {
            return "\(selectedTask.id.uuidString):none:\(htmlPreviewSignature):\(inputSignature)"
        }
        let stepSummary = plan.steps.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: "|")
        return "\(selectedTask.id.uuidString):\(plan.planID.uuidString):\(state.lifecycleStatus.rawValue):\(stepSummary):\(htmlPreviewSignature):\(inputSignature)"
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

    private var isWorkspaceCanvasPresented: Bool {
        activeWorkspaceCanvasItem != nil
    }

    private var panelTransitionAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0.0)
    }

    private var panelHandoffDelay: TimeInterval {
        reduceMotion ? 0 : 0.09
    }

    private var rightRailInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                effectiveWorkspace != nil && isWorkspaceRightRailVisible
            },
            set: setRightRailPresented
        )
    }

    var body: some View {
        NavigationSplitView {
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
                onShowLogs: showLogs,
                onShowDashboard: showDashboard,
                onDeleteWorkspace: deleteWorkspace,
                onRenameWorkspace: beginRenamingWorkspace,
                onNewSchedule: showNewSchedule,
                onEditSchedule: beginEditingSchedule,
                isSearchActive: $isSearchActive
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            ContentDetailAreaView(
                selectedTask: selectedTask,
                effectiveWorkspace: effectiveWorkspace,
                isComposingTask: isComposingTask,
                taskQueue: runtime.taskQueue,
                browserSession: currentBrowserSession,
                isBrowserPinnedToTask: browserPinnedToTaskBinding,
                markdownSession: currentMarkdownSession,
                isMarkdownPinnedToTask: markdownPinnedToTaskBinding,
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
                onShowDashboard: showDashboard,
                onShowLogs: showLogs,
                onNewSchedule: showNewSchedule,
                onEditSchedule: beginEditingSchedule,
                onManageCapabilities: openCapabilitiesManager,
                onEditWorkspace: showWorkspaceEditor,
                onOpenConfigureTab: openConfigureTab,
                onNewSSHConnection: showSSHConnectionEditor,
                onEditSSHConnection: beginEditingSSHConnection,
                onCreateWorkspace: createWorkspace,
                onImportWorkspace: importWorkspace,
                onOpenGeneratedFile: openGeneratedFile
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minHeight: 600)
        .accessibilityIdentifier("MainContentView")
        .astraWindowChrome()
        .astraHiddenToolbarBackground()
        // Right-rail toggle. Attached to the NavigationSplitView root so
        // .primaryAction lands at the WINDOW's trailing edge — past the
        // inspector column — instead of at the inspector boundary
        // (where attaching to .detail or to the inspector content put it).
        .toolbar {
            ContentToolbar(
                appUpdateController: appUpdateController,
                hasWorkspace: effectiveWorkspace != nil,
                hasTaskThread: hasOpenTaskThread,
                hasCanvasContent: hasWorkspaceCanvasContent,
                isCanvasVisible: activeWorkspaceCanvasItem == .plan,
                hasMarkdownContent: selectedTaskHasMarkdownShelfContent,
                isMarkdownVisible: activeWorkspaceCanvasItem == .markdown,
                isBrowserVisible: activeWorkspaceCanvasItem == .browser,
                isRightRailVisible: isWorkspaceRightRailVisible,
                onCheckForUpdates: appUpdateController.checkForUpdatesFromButton,
                onToggleCanvas: toggleWorkspaceCanvas,
                onToggleMarkdown: toggleMarkdownCanvas,
                onToggleBrowser: toggleBrowserCanvas,
                onToggleRightRail: toggleRightRail
            )
        }
        .shelfBoundaryOverlay()
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
                onDismissRecoveryNotice: { recoveryNotice = "" },
                onCheckForUpdates: appUpdateController.checkForUpdatesFromButton
            )
        }
        .onChange(of: selectedTaskCanvasSignature) {
            cachedHasCanvasContent = selectedTask.flatMap { TaskPlanService.reconstruct(for: $0).plan } != nil
            if !cachedHasCanvasContent, activeWorkspaceCanvasItem == .plan {
                activeWorkspaceCanvasItem = nil
            }
            if selectedTask == nil, !isComposingTask, activeWorkspaceCanvasItem == .browser {
                activeWorkspaceCanvasItem = nil
            }
            if selectedTask == nil, !isComposingTask, activeWorkspaceCanvasItem == .markdown {
                activeWorkspaceCanvasItem = nil
            }
            refreshMarkdownShelfAvailabilityForSelectedTask()
            previewGeneratedHTMLForSelectedTaskIfNeeded()
            previewGeneratedMarkdownForSelectedTaskIfNeeded()
        }
        .onChange(of: hasOpenTaskThread) {
            if !hasOpenTaskThread, activeWorkspaceCanvasItem == .browser {
                activeWorkspaceCanvasItem = nil
            }
            if !hasOpenTaskThread, activeWorkspaceCanvasItem == .markdown {
                activeWorkspaceCanvasItem = nil
            }
        }
        .onChange(of: activeWorkspaceCanvasItem) {
            syncBrowserPresentation()
        }
        .sheet(isPresented: $showingLogs) {
            LogViewerView()
                .frame(width: 900, height: 500)
        }
        .sheet(isPresented: $showingDashboard) {
            UsageDashboardView()
                .frame(width: 600, height: 500)
        }
        .sheet(isPresented: $showingConfigure) {
            if let ws = effectiveWorkspace {
                ConfigureView(workspace: ws, initialTab: configureInitialTab, focusItemID: configureFocusItemID)
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
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding && !isUITestingSeededLaunch },
            set: { isPresented in
                if !isPresented, isReplayingOnboarding {
                    hasCompletedOnboarding = true
                }
            }
        )) {
            OnboardingWizardView(
                hasCompletedOnboarding: $hasCompletedOnboarding,
                allowsDismiss: isReplayingOnboarding,
                onDismiss: {
                    hasCompletedOnboarding = true
                },
                onCreateWorkspace: {
                    createWorkspace()
                }
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
        showingConfigure = true
    }

    private func openSkillsManager() {
        configureInitialTab = .skills
        configureFocusItemID = nil
        showingConfigure = true
    }

    private func openConfigureTab(_ tab: ConfigureTab, itemID: UUID?) {
        configureInitialTab = tab
        configureFocusItemID = itemID
        showingConfigure = true
    }

    private func showLogs() {
        showingLogs = true
    }

    private func showDashboard() {
        showingDashboard = true
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

    private func nextPanelTransitionGeneration() -> Int {
        panelTransitionGeneration += 1
        return panelTransitionGeneration
    }

    private func animatePanelChange(_ changes: () -> Void) {
        withAnimation(panelTransitionAnimation) {
            changes()
        }
    }

    private func schedulePanelHandoff(_ generation: Int, _ changes: @escaping () -> Void) {
        guard panelHandoffDelay > 0 else {
            animatePanelChange(changes)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + panelHandoffDelay) {
            guard panelTransitionGeneration == generation else { return }
            animatePanelChange(changes)
        }
    }

    private func setRightRailPresented(_ isPresented: Bool) {
        if isPresented {
            presentRightRail()
        } else {
            let _ = nextPanelTransitionGeneration()
            animatePanelChange {
                isWorkspaceRightRailVisible = false
            }
        }
    }

    private func presentRightRail() {
        let generation = nextPanelTransitionGeneration()
        if activeWorkspaceCanvasItem != nil {
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
            schedulePanelHandoff(generation) {
                isWorkspaceRightRailVisible = true
            }
        } else {
            animatePanelChange {
                isWorkspaceRightRailVisible = true
            }
        }
    }

    private func presentCanvas(_ item: WorkspaceCanvasItem) {
        let generation = nextPanelTransitionGeneration()
        if isWorkspaceRightRailVisible {
            animatePanelChange {
                isWorkspaceRightRailVisible = false
            }
            schedulePanelHandoff(generation) {
                activeWorkspaceCanvasItem = item
            }
        } else {
            animatePanelChange {
                activeWorkspaceCanvasItem = item
            }
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
            let _ = nextPanelTransitionGeneration()
            animatePanelChange {
                if activeWorkspaceCanvasItem == .plan {
                    activeWorkspaceCanvasItem = nil
                }
            }
            return
        }
        if activeWorkspaceCanvasItem == .plan {
            let _ = nextPanelTransitionGeneration()
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.plan)
        }
    }

    private func toggleBrowserCanvas() {
        guard selectedTask != nil || isComposingTask else {
            if activeWorkspaceCanvasItem == .browser {
                let _ = nextPanelTransitionGeneration()
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
            return
        }
        currentBrowserSession.bindToTask(selectedTask?.id)
        if activeWorkspaceCanvasItem == .browser {
            let _ = nextPanelTransitionGeneration()
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.browser)
        }
    }

    private func toggleMarkdownCanvas() {
        guard selectedTaskHasMarkdownShelfContent, selectedTask != nil || isComposingTask else {
            if activeWorkspaceCanvasItem == .markdown {
                let _ = nextPanelTransitionGeneration()
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
            let _ = nextPanelTransitionGeneration()
            animatePanelChange {
                activeWorkspaceCanvasItem = nil
            }
        } else {
            presentCanvas(.markdown)
        }
    }

    private func refreshMarkdownShelfAvailabilityForSelectedTask() {
        markdownAvailabilityTask?.cancel()
        guard let selectedTask else {
            selectedTaskHasMarkdownShelfContent = false
            selectedTaskPreferredMarkdownPath = ""
            if activeWorkspaceCanvasItem == .markdown {
                activeWorkspaceCanvasItem = nil
            }
            return
        }

        let taskID = selectedTask.id
        let attachedMarkdownPath = preferredAttachedMarkdownPath(for: selectedTask)
        selectedTaskPreferredMarkdownPath = attachedMarkdownPath ?? ""
        selectedTaskHasMarkdownShelfContent = attachedMarkdownPath != nil

        let taskFolder = selectedTask.taskFolder
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

    private func closeMarkdownShelfIfUnavailable() {
        guard activeWorkspaceCanvasItem == .markdown else { return }
        let _ = nextPanelTransitionGeneration()
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
        let taskFolder = selectedTask.taskFolder
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

                lastGeneratedHTMLPreviewSignature = signature
                let session = browserSessionStore.session(for: taskID, pinnedToTask: isBrowserPinnedToTask)
                session.load(URL(fileURLWithPath: path))
                if activeWorkspaceCanvasItem != .browser {
                    presentCanvas(.browser)
                }
                syncBrowserPresentation()
            }
        }
    }

    private func previewGeneratedMarkdownForSelectedTaskIfNeeded() {
        guard isMarkdownPinnedToTask else { return }
        guard let selectedTask else {
            generatedMarkdownPreviewTask?.cancel()
            return
        }

        let taskID = selectedTask.id
        let taskFolder = selectedTask.taskFolder
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
        if TaskGeneratedFiles.isHTMLFile(path) {
            let taskID = selectedTask?.id
            let session = browserSessionStore.session(for: taskID, pinnedToTask: isBrowserPinnedToTask)
            session.load(url)
            if let taskID {
                lastGeneratedHTMLPreviewSignature = TaskGeneratedFiles.htmlPreviewSignature(for: path, taskID: taskID)
            }
            presentCanvas(.browser)
            syncBrowserPresentation()
            return
        }

        if TaskGeneratedFiles.isMarkdownFile(path) {
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
        }

        NSWorkspace.shared.open(url)
    }

    private func syncBrowserPresentation() {
        browserSessionStore.setPresented(
            activeWorkspaceCanvasItem == .browser,
            taskID: selectedTask?.id,
            pinnedToTask: isBrowserPinnedToTask
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
    }

    private func handleQuickRunTask(_ task: AgentTask) {
        setSelectedTask(task)
        isComposingTask = false
        runSingleTask(task)
    }

    private func handleTaskCreated(_ task: AgentTask) {
        setSelectedTask(task)
        isComposingTask = false
    }

    private func openPlanCanvas(_ task: AgentTask) {
        guard TaskPlanService.reconstruct(for: task).plan != nil else { return }
        if selectedTask?.id == task.id, activeWorkspaceCanvasItem == .plan {
            let _ = nextPanelTransitionGeneration()
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
        guard !workspaces.isEmpty else {
            selectedWorkspace = nil
            setSelectedTask(nil)
            isComposingTask = false
            return
        }

        if let selectedWorkspace,
           workspaces.contains(where: { $0.id == selectedWorkspace.id }) {
            return
        }

        if let restored = workspaces.first(where: { $0.id.uuidString == lastSelectedWorkspaceID }) ??
            workspaces.first(where: { $0.primaryPath == lastSelectedWorkspacePath }) ??
            workspaces.first {
            selectedWorkspace = restored
        }
    }

    private func persistWorkspaceSelection() {
        guard let selectedWorkspace else {
            lastSelectedWorkspaceID = ""
            lastSelectedWorkspacePath = ""
            return
        }

        lastSelectedWorkspaceID = selectedWorkspace.id.uuidString
        lastSelectedWorkspacePath = selectedWorkspace.primaryPath
    }

    private var resolvedRoot: String {
        if !workspacesRoot.isEmpty { return workspacesRoot }
        return AppChannel.current.defaultWorkspacesRoot
    }

    private func finalizeNewWorkspace() {
        guard newWorkspaceDraft.canCreate else { return }
        let workspace = coordinator.createWorkspace(name: newWorkspaceDraft.trimmedName, rootPath: resolvedRoot)
        workspace.instructions = newWorkspaceDraft.trimmedInstructions
        applyNewWorkspaceCapabilities(to: workspace)
        selectedWorkspace = workspace
        showingNewWorkspace = false
        resetNewWorkspaceDraft()
    }

    private func applyNewWorkspaceCapabilities(to workspace: Workspace) {
        let selectedIDs = newWorkspaceDraft.selectedCapabilityIDs
        guard !selectedIDs.isEmpty else { return }

        var packagesByID: [String: PluginPackage] = [:]
        for package in PluginCatalog.builtInPackages {
            packagesByID[package.id] = package
        }
        let packages = OnboardingCapabilitySetup.configurableOptions.compactMap { option -> PluginPackage? in
            guard let packageID = option.packageID, selectedIDs.contains(packageID) else { return nil }
            return packagesByID[packageID]
        }
        guard !packages.isEmpty else { return }

        let installer = CapabilityInstaller()
        for package in packages {
            let inputs = newWorkspaceDraft.capabilityConfiguration.installationInputs(for: package.id)
            do {
                try installer.install(
                    package,
                    into: workspace,
                    modelContext: modelContext,
                    credentialInputs: inputs.credentialInputs,
                    configInputs: inputs.configInputs,
                    baseURLOverrides: inputs.baseURLOverrides
                )
            } catch {
                AppLogger.warning(
                    "Failed to enable onboarding capability \(package.id): \(error.localizedDescription)",
                    category: "Onboarding"
                )
            }
        }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select workspace folders, config files, or a parent Workspaces folder"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var imported: [Workspace] = []
        var knownWorkspaces = workspaces

        for candidate in WorkspaceImportDiscovery.candidates(for: panel.urls) {
            let workspace: Workspace?
            if let configURL = candidate.configURL {
                workspace = coordinator.importFromConfig(
                    at: configURL,
                    existingWorkspaces: knownWorkspaces,
                    askDuplicateAction: askDuplicateAction
                )
            } else {
                workspace = coordinator.createWorkspaceFromFolder(
                    candidate.folderURL,
                    existingWorkspaces: knownWorkspaces,
                    askDuplicateAction: askDuplicateAction
                )
            }

            if let workspace {
                imported.append(workspace)
                knownWorkspaces.append(workspace)
            }
        }

        for ws in imported {
            coordinator.importSessionsIfNeeded(for: ws)
        }

        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.workspaceExported, category: "UI", fields: [
                "operation": "save_imported_workspaces",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
        for ws in imported {
            WorkspaceConfigManager.autoExport(workspace: ws, modelContext: modelContext)
        }
        if let last = imported.last {
            selectedWorkspace = last
        }
        if !imported.isEmpty {
            AppLogger.audit(.workspaceImported, category: "App", fields: [
                "workspace_count": String(imported.count)
            ])
        }
    }

    private func askDuplicateAction(name: String, existingTaskCount: Int) -> TaskLifecycleCoordinator.DuplicateAction {
        let alert = NSAlert()
        alert.messageText = "Workspace \"\(name)\" already exists"
        alert.informativeText = "The existing workspace has \(existingTaskCount) task(s). What would you like to do?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .duplicate
        default: return .skip
        }
    }

    // MARK: - Task Actions

    private func setSelectedTask(_ task: AgentTask?) {
        let previousTaskID = selectedTask?.id
        let shouldCloseBrowserForTaskChange = isBrowserPinnedToTask
            && activeWorkspaceCanvasItem == .browser
            && previousTaskID != nil
            && previousTaskID != task?.id
        let shouldCloseMarkdownForTaskChange = isMarkdownPinnedToTask
            && activeWorkspaceCanvasItem == .markdown
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
            if shouldCloseBrowserForTaskChange {
                let _ = nextPanelTransitionGeneration()
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
            if shouldCloseMarkdownForTaskChange {
                let _ = nextPanelTransitionGeneration()
                animatePanelChange {
                    activeWorkspaceCanvasItem = nil
                }
            }
            syncBrowserPresentation()
            refreshMarkdownShelfAvailabilityForSelectedTask()
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
        enterUITestComposerIfNeeded()
        runtime.startScheduler(modelContext: modelContext)
        runtime.loadPluginCatalog()
        refreshRunningTaskCount()
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
            let task = AgentTask(
                title: "Seeded Task",
                goal: "UI test task",
                workspace: ws,
                tokenBudget: 50000,
                model: "claude-sonnet-4-6"
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
            defaultRuntimeID: defaultRuntimeID,
            timeoutSeconds: timeoutSeconds,
            validationModel: validationModel,
            skipPermissions: skipPermissions
        )
    }
}

private struct ContentToolbar: ToolbarContent {
    @ObservedObject var appUpdateController: AppUpdateController

    let hasWorkspace: Bool
    let hasTaskThread: Bool
    let hasCanvasContent: Bool
    let isCanvasVisible: Bool
    let hasMarkdownContent: Bool
    let isMarkdownVisible: Bool
    let isBrowserVisible: Bool
    let isRightRailVisible: Bool
    let onCheckForUpdates: () -> Void
    let onToggleCanvas: () -> Void
    let onToggleMarkdown: () -> Void
    let onToggleBrowser: () -> Void
    let onToggleRightRail: () -> Void

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

        if hasWorkspace {
            if hasCanvasContent {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onToggleCanvas) {
                        toolbarToggleLabel(
                            title: isCanvasVisible ? "Hide Plan" : "Show Plan",
                            systemImage: "list.bullet.clipboard",
                            isActive: isCanvasVisible
                        )
                    }
                    .help(isCanvasVisible ? "Hide plan shelf" : "Show plan shelf")
                    .accessibilityIdentifier("WorkspaceCanvasToggleButton")
                }
            }

            if hasTaskThread, hasMarkdownContent {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onToggleMarkdown) {
                        toolbarToggleLabel(
                            title: isMarkdownVisible ? "Hide Markdown" : "Show Markdown",
                            systemImage: "doc.richtext",
                            isActive: isMarkdownVisible
                        )
                    }
                    .help(isMarkdownVisible ? "Hide Markdown shelf" : "Show Markdown shelf")
                    .accessibilityIdentifier("ShelfMarkdownToggleButton")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: onToggleBrowser) {
                        toolbarToggleLabel(
                            title: isBrowserVisible ? "Hide Browser" : "Show Browser",
                            systemImage: isBrowserVisible ? "globe.badge.chevron.backward" : "globe",
                            isActive: isBrowserVisible
                        )
                    }
                    .help(isBrowserVisible ? "Hide browser shelf" : "Show browser shelf")
                    .accessibilityIdentifier("ShelfBrowserToggleButton")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: onToggleRightRail) {
                    toolbarToggleLabel(
                        title: isRightRailVisible ? "Hide Control Panel" : "Show Control Panel",
                        systemImage: "sidebar.right",
                        isActive: isRightRailVisible
                    )
                }
                .help(isRightRailVisible ? "Hide control panel" : "Show control panel")
            }
        }
    }

    // The native macOS toolbar strips most custom styling, but it does respect
    // foregroundStyle, fontWeight, and symbolEffect on the icon. We use all three
    // together so the active panel toggle is unmistakable: cardinal-red tint,
    // semibold weight, and a brief bounce when toggled.
    private func toolbarToggleLabel(title: String, systemImage: String, isActive: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? Stanford.cardinalRed : Color.primary)
                .fontWeight(isActive ? .semibold : .regular)
                .symbolEffect(.bounce, value: isActive)
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
    let sshReloadTrigger: Int
    @Binding var isRightRailPresented: Bool
    @Binding var activeCanvasItem: WorkspaceCanvasItem?
    let isPlanCanvasVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.planShelfWidth) private var planShelfStoredWidth = Double(WorkspaceCanvasItem.plan.idealWidth)
    @AppStorage(AppStorageKeys.browserShelfWidth) private var browserShelfStoredWidth = Double(WorkspaceCanvasItem.browser.idealWidth)
    @AppStorage(AppStorageKeys.markdownShelfWidth) private var markdownShelfStoredWidth = Double(WorkspaceCanvasItem.markdown.idealWidth)
    @State private var shelfDragStartWidth: CGFloat?
    @State private var shelfTransientWidth: CGFloat?
    @State private var resizingShelfItem: WorkspaceCanvasItem?

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
    let onShowDashboard: () -> Void
    let onShowLogs: () -> Void
    let onNewSchedule: () -> Void
    let onEditSchedule: (TaskSchedule) -> Void
    let onManageCapabilities: () -> Void
    let onEditWorkspace: () -> Void
    let onOpenConfigureTab: (ConfigureTab, UUID?) -> Void
    let onNewSSHConnection: () -> Void
    let onEditSSHConnection: (SSHConnection) -> Void
    let onCreateWorkspace: () -> Void
    let onImportWorkspace: () -> Void
    let onOpenGeneratedFile: (String) -> Void

    var body: some View {
        contentWithOptionalCanvas
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(panelAnimation, value: activeCanvasItem)
        .animation(panelAnimation, value: isRightRailPresented)
        .inspector(isPresented: $isRightRailPresented) {
            if let workspace = effectiveWorkspace {
                WorkspaceRightRailView(
                    workspace: workspace,
                    onConfigure: onConfigure,
                    onEditWorkspace: onEditWorkspace,
                    onShowDashboard: onShowDashboard,
                    onShowLogs: onShowLogs,
                    onNewSchedule: onNewSchedule,
                    onEditSchedule: onEditSchedule,
                    onManageCapabilities: onManageCapabilities,
                    onOpenConfigureTab: onOpenConfigureTab,
                    onNewSSHConnection: onNewSSHConnection,
                    onEditSSHConnection: onEditSSHConnection,
                    sshReloadTrigger: sshReloadTrigger
                )
                .id(workspace.id)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 380)
            }
        }
    }

    private var panelAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0.0)
    }

    private var canvasTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var contentWithOptionalCanvas: some View {
        if let activeCanvasItem {
            shelfLayout(for: activeCanvasItem)
        } else {
            detailContent
        }
    }

    private func shelfLayout(for item: WorkspaceCanvasItem) -> some View {
        GeometryReader { proxy in
            let panelWidth = shelfWidth(for: item, availableWidth: proxy.size.width)
            let detailWidth = max(0, proxy.size.width - panelWidth)
            let isResizing = resizingShelfItem == item

            HStack(spacing: 0) {
                detailContent
                    .frame(width: detailWidth, height: proxy.size.height)
                    .clipped()

                canvasContent(for: item)
                .frame(width: panelWidth, height: proxy.size.height)
                // .bar extends behind toolbar; Stanford.panelBackground would stop at the toolbar boundary.
                .background(.bar, ignoresSafeAreaEdges: .top)
                .overlay(alignment: .leading) {
                    shelfResizeHandle(for: item, availableWidth: proxy.size.width)
                }
                .transition(canvasTransition)
                // Lighter shadow while dragging so the GPU isn't re-blurring 18pt of soft shadow each frame.
                .shadow(
                    color: .black.opacity(isResizing ? 0.06 : 0.10),
                    radius: isResizing ? 8 : 18,
                    x: -5,
                    y: 0
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .preference(
                key: ShelfBoundaryMetricsPreferenceKey.self,
                value: ShelfBoundaryMetrics(
                    width: panelWidth,
                    isVisible: true,
                    isResizing: isResizing
                )
            )
        }
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
        }
        return clampedShelfWidth(storedWidth, for: item, availableWidth: availableWidth)
    }

    private func shelfWidth(for item: WorkspaceCanvasItem, availableWidth: CGFloat) -> CGFloat {
        let storedWidth = committedShelfWidth(for: item, availableWidth: availableWidth)
        let candidate = resizingShelfItem == item ? (shelfTransientWidth ?? storedWidth) : storedWidth
        return clampedShelfWidth(candidate, for: item, availableWidth: availableWidth)
    }

    private func clampedShelfWidth(_ width: CGFloat, for item: WorkspaceCanvasItem, availableWidth: CGFloat) -> CGFloat {
        let minimumDetailWidth: CGFloat = item == .browser ? 520 : 420
        let maximumUsableWidth = max(item.minWidth, availableWidth - minimumDetailWidth)
        let maximumWidth = min(item.maxWidth, maximumUsableWidth)
        return min(max(width, item.minWidth), maximumWidth)
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
                }
                guard let shelfDragStartWidth else { return }
                let proposedWidth = shelfDragStartWidth - translation.width
                let next = clampedShelfWidth(proposedWidth, for: item, availableWidth: availableWidth)
                // Bypass any ambient .animation modifier so the panel tracks the cursor 1:1.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    shelfTransientWidth = next
                }
            },
            onEnded: {
                if let shelfTransientWidth {
                    storeShelfWidth(shelfTransientWidth, for: item, availableWidth: availableWidth)
                }
                shelfDragStartWidth = nil
                shelfTransientWidth = nil
                resizingShelfItem = nil
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
            onShowDashboard: onShowDashboard,
            onShowLogs: onShowLogs,
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
                isPinnedToTask: $isMarkdownPinnedToTask
            )
        case .browser:
            ShelfBrowserPanelView(
                session: browserSession,
                isPresented: canvasPresentedBinding(for: .browser),
                isPinnedToTask: $isBrowserPinnedToTask
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
    let onShowDashboard: () -> Void
    let onShowLogs: () -> Void
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
                    onShowDashboard: onShowDashboard,
                    onShowLogs: onShowLogs,
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
    @Environment(\.preflightCache) private var preflightCache
    @Binding var draft: NewWorkspaceDraft
    let rootPath: String
    let onCancel: () -> Void
    let onCreate: () -> Void

    @FocusState private var focusedField: Field?
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @State private var isCapabilitiesExpanded = false
    @State private var githubStatus: HealthStatus?
    @State private var githubAuthStatus: HealthStatus?
    @State private var isProbingGitHub = false

    private enum Field {
        case name
        case instructions
    }

    private var displayedRootPath: String {
        (rootPath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ScrollView {
                formFields
            }
            .scrollIndicators(.visible)
            footer
        }
        .padding(24)
        .frame(width: 620)
        .frame(maxHeight: 760)
        .background(Stanford.panelBackground)
        .onAppear {
            focusedField = .name
            applyCapabilityDefaults()
            Task { await probeGitHub(forceRefresh: false) }
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

    private var formFields: some View {
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
                        if canCreate {
                            onCreate()
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(Stanford.ui(12, weight: .medium))
                        .foregroundStyle(Stanford.lagunita)
                    Text("Workspace instructions")
                        .font(Stanford.caption(13).weight(.semibold))
                        .foregroundStyle(Stanford.black)
                    Text("Optional")
                        .font(Stanford.caption(11).weight(.medium))
                        .foregroundStyle(Stanford.coolGrey)
                }

                Text("Add context that helps the AI agents understand this workspace: the type of work, important people or usernames, project conventions, preferred tools, or anything that helps them ask fewer repeat questions. You can always add or edit this later.")
                    .font(Stanford.body(13))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft.instructions)
                        .font(Stanford.body(14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 118)
                        .background(Stanford.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(focusedField == .instructions ? Stanford.focusRing : Color.secondary.opacity(0.20), lineWidth: 1)
                        )
                        .focused($focusedField, equals: .instructions)

                    if draft.instructions.isEmpty {
                        Text("Example: This workspace is for GitHub PR review. My GitHub username is alvaro, prefer concise summaries, and ask before changing release files.")
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
    }

    private var capabilitiesSection: some View {
        DisclosureGroup(isExpanded: $isCapabilitiesExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if hasReadyCapabilityDefaults {
                    workspaceSetupAssistant
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
                        Text("Capabilities")
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

    private var workspaceSetupAssistant: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready defaults")
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Text(setupAssistantSummary)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Apply") {
                enableReadyDefaults()
            }
            .font(Stanford.caption(11))
            .tint(Stanford.lagunita)
            .disabled(!hasReadyCapabilityDefaults)
        }
        .padding(10)
        .background(Stanford.lagunita.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Stanford.lagunita.opacity(0.18), lineWidth: 1)
        )
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
                    Text(option.subtitle)
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
            HStack(spacing: 8) {
                Image(systemName: isGitHubHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Stanford.ui(12))
                    .foregroundStyle(isGitHubHealthy ? Stanford.paloAltoGreen : Stanford.poppy)
                Text(isGitHubHealthy ? "Uses the authenticated gh CLI from the environment check." : "Run gh auth login, then create this workspace.")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.coolGrey)
            }
        case OnboardingCapabilitySetup.gcloudPackageID:
            VStack(alignment: .leading, spacing: 8) {
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
        return names.isEmpty ? "Add Jira, GitHub, Google Cloud, or REDCap for this workspace." : names.joined(separator: ", ")
    }

    private var canCreate: Bool {
        !draft.trimmedName.isEmpty && capabilityIssues.isEmpty
    }

    private var capabilityIssues: [String] {
        draft.capabilitySetupIssues(githubCLIReady: isGitHubHealthy)
    }

    private var isGitHubHealthy: Bool {
        if case .healthy = githubStatus, case .healthy = githubAuthStatus {
            return true
        }
        return false
    }

    private var hasVertexDefaults: Bool {
        !claudeVertexProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !claudeVertexRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasReadyCapabilityDefaults: Bool {
        isGitHubHealthy || hasVertexDefaults
    }

    private var setupAssistantSummary: String {
        var suggestions: [String] = []
        if isGitHubHealthy {
            suggestions.append("GitHub is ready")
        }
        if hasVertexDefaults {
            suggestions.append("Google Cloud can use Vertex settings")
        }
        return suggestions.joined(separator: ". ") + "."
    }

    private func capabilityStatusText(for packageID: String) -> String {
        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            if isProbingGitHub { return "Checking" }
            return isGitHubHealthy ? "Ready" : "Needs gh"
        case OnboardingCapabilitySetup.gcloudPackageID:
            let project = draft.capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !project.isEmpty { return "Ready" }
            return hasVertexDefaults ? "Can fill" : "Needs project"
        case OnboardingCapabilitySetup.jiraPackageID, OnboardingCapabilitySetup.redcapPackageID:
            return "Needs setup"
        default:
            return "Optional"
        }
    }

    private func capabilityStatusColor(for packageID: String) -> Color {
        switch packageID {
        case OnboardingCapabilitySetup.githubPackageID:
            return isGitHubHealthy ? Stanford.paloAltoGreen : Stanford.coolGrey
        case OnboardingCapabilitySetup.gcloudPackageID:
            let project = draft.capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!project.isEmpty || hasVertexDefaults) ? Stanford.paloAltoGreen : Stanford.coolGrey
        default:
            return Stanford.coolGrey
        }
    }

    private func capabilityBinding(for packageID: String) -> Binding<Bool> {
        Binding(
            get: { draft.selectedCapabilityIDs.contains(packageID) },
            set: { enabled in
                if enabled {
                    draft.selectedCapabilityIDs.insert(packageID)
                    if packageID == OnboardingCapabilitySetup.gcloudPackageID {
                        applyCapabilityDefaults()
                    }
                } else {
                    draft.selectedCapabilityIDs.remove(packageID)
                }
            }
        )
    }

    private func applyCapabilityDefaults() {
        _ = draft.capabilityConfiguration.applyEnvironmentDefaults(
            gcpProject: claudeVertexProjectID,
            gcpRegion: claudeVertexRegion
        )
    }

    private func enableReadyDefaults() {
        applyCapabilityDefaults()
        if isGitHubHealthy {
            draft.selectedCapabilityIDs.insert(OnboardingCapabilitySetup.githubPackageID)
        }
        if !draft.capabilityConfiguration.gcpProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.selectedCapabilityIDs.insert(OnboardingCapabilitySetup.gcloudPackageID)
        }
    }

    private func probeGitHub(forceRefresh: Bool) async {
        isProbingGitHub = true
        defer { isProbingGitHub = false }

        if forceRefresh {
            await preflightCache.invalidate(binary: "gh")
        }

        githubStatus = await preflightCache.status(for: CommonCLIPrerequisites.githubCLI)
        guard case .healthy = githubStatus else {
            githubAuthStatus = nil
            return
        }
        githubAuthStatus = await preflightCache.status(for: CommonCLIPrerequisites.githubAuth)
    }

    private var footer: some View {
        HStack {
            if let firstIssue = capabilityIssues.first {
                Label(firstIssue, systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.poppy)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .keyboardShortcut(.cancelAction)

            Button("Create", action: onCreate)
                .buttonStyle(StanfordButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.45)
        }
    }
}

private struct TopNoticeBannersView: View {
    let recoveryNotice: String
    let updateBlockNotice: String?
    let onDismissRecoveryNotice: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        if !recoveryNotice.isEmpty || updateBlockNotice != nil {
            VStack(spacing: 0) {
                if !recoveryNotice.isEmpty {
                    RecoveryNoticeBanner(
                        message: recoveryNotice,
                        onDismiss: onDismissRecoveryNotice
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
                return "Pause linked routines before marking done?"
            case .delete:
                return "Pause linked routines before deleting?"
            }
        }

        var confirmLabel: String {
            switch self {
            case .markDone:
                return "Pause Routines and Mark Done"
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
