import SwiftUI
import SwiftData

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

struct NewWorkspaceDraft: Equatable {
    var name = ""
    var instructions = ""

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreate: Bool {
        !trimmedName.isEmpty
    }

    mutating func clear() {
        name = ""
        instructions = ""
    }
}

struct ContentView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @Environment(\.modelContext) private var modelContext
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
    @State private var shouldApplyOnboardingCapabilitiesToNextWorkspace = false
    @State private var onboardingCapabilityConfiguration = OnboardingCapabilityConfiguration()
    @State private var runtime = AppRuntimeController()
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
    @AppStorage(AppStorageKeys.onboardingEnabledCapabilityIDs) private var onboardingEnabledCapabilityIDsRaw = ""
    @AppStorage("lastSelectedWorkspaceID") private var lastSelectedWorkspaceID = ""
    @AppStorage("lastSelectedWorkspacePath") private var lastSelectedWorkspacePath = ""
    @AppStorage("isWorkspaceRightRailVisible") private var isWorkspaceRightRailVisible = true
    @AppStorage(WorkspaceRecoveryService.recoveryNoticeKey) private var recoveryNotice = ""
    /// First-run flag. Flips to true once the user finishes the
    /// onboarding wizard. Exposed via Settings → "Show Onboarding Again"
    /// so users can replay the guide on demand.
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    /// Tracks whether the wizard has ever been presented. The first
    /// presentation remains modal; later manual replays can be dismissed.
    @AppStorage(AppStorageKeys.hasPresentedOnboarding) private var hasPresentedOnboarding = false
    @State private var isReplayingOnboarding = false
    /// Shared preflight cache — one instance for the whole app run so the
    /// wizard's probe of `claude` warms the cache for the catalog badges
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

    private var selectedTaskUnreadSignature: String {
        guard let selectedTask else { return "" }
        let unread = selectedTask.unreadAt?.timeIntervalSince1970 ?? 0
        return "\(selectedTask.id.uuidString):\(unread)"
    }

    private var rightRailInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                effectiveWorkspace != nil && isWorkspaceRightRailVisible
            },
            set: { newValue in
                isWorkspaceRightRailVisible = newValue
            }
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
                sshReloadTrigger: sshReloadTrigger,
                isRightRailPresented: rightRailInspectorBinding,
                onQuickRun: handleQuickRunTask,
                onTaskCreated: handleTaskCreated,
                onAddSSHConnection: { showingSSHEditor = true },
                onManageSkills: openSkillsManager,
                onRunTask: runSingleTask,
                onCancelTask: cancelTask,
                onRetryTask: retryTask,
                onResumeTask: resumeTask,
                onApproveTask: approveTask,
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
                onImportWorkspace: importWorkspace
            )
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("MainContentView")
        .astraWindowChrome()
        // Right-rail toggle. Attached to the NavigationSplitView root so
        // .primaryAction lands at the WINDOW's trailing edge — past the
        // inspector column — instead of at the inspector boundary
        // (where attaching to .detail or to the inspector content put it).
        .toolbar {
            ContentToolbar(
                appUpdateController: appUpdateController,
                hasWorkspace: effectiveWorkspace != nil,
                isRightRailVisible: isWorkspaceRightRailVisible,
                onCheckForUpdates: appUpdateController.checkForUpdatesFromButton,
                onToggleRightRail: toggleRightRail
            )
        }
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
                    onboardingCapabilityConfiguration.clearSecrets()
                },
                capabilityConfiguration: $onboardingCapabilityConfiguration,
                onCreateWorkspace: {
                    shouldApplyOnboardingCapabilitiesToNextWorkspace = true
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

    private func toggleRightRail() {
        isWorkspaceRightRailVisible.toggle()
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
            thresholdMilliseconds: 0
        ) {
            let descriptor = FetchDescriptor<AgentTask>()
            let tasks = (try? modelContext.fetch(descriptor)) ?? []
            return tasks.reduce(0) { count, task in
                count + (task.status == .running ? 1 : 0)
            }
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
        shouldApplyOnboardingCapabilitiesToNextWorkspace = false
        onboardingCapabilityConfiguration.clearSecrets()
    }

    private func restoreWorkspaceSelection() {
        guard !workspaces.isEmpty else {
            selectedWorkspace = nil
            selectedTask = nil
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
        if shouldApplyOnboardingCapabilitiesToNextWorkspace {
            applyOnboardingCapabilities(to: workspace)
        }
        selectedWorkspace = workspace
        showingNewWorkspace = false
        resetNewWorkspaceDraft()
    }

    private func applyOnboardingCapabilities(to workspace: Workspace) {
        let packages = OnboardingCapabilitySetup.selectedPackages(
            from: PluginCatalog.builtInPackages,
            rawValue: onboardingEnabledCapabilityIDsRaw
        )
        guard !packages.isEmpty else { return }

        let installer = CapabilityInstaller()
        for package in packages {
            let inputs = onboardingCapabilityConfiguration.installationInputs(for: package.id)
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
        if let taskWorkspace = task?.workspace,
           selectedWorkspace?.id != taskWorkspace.id {
            selectedWorkspace = taskWorkspace
        }
        selectedTask = task
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
            validationModel: validationModel,
            isUITestingSeededLaunch: isUITestingSeededLaunch
        )
    }

    private func handleSelectedWorkspaceChanged() {
        let selectedWorkspaceID: UUID? = selectedWorkspace?.id
        let taskWorkspaceID: UUID? = selectedTask?.workspace?.id
        if selectedTask != nil, taskWorkspaceID != selectedWorkspaceID {
            selectedTask = nil
        }
        if isUITestingSeededLaunch {
            selectedTask = nil
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

        selectedTask = nil
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
    let isRightRailVisible: Bool
    let onCheckForUpdates: () -> Void
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
            ToolbarItem(placement: .primaryAction) {
                Button(action: onToggleRightRail) {
                    Label(
                        isRightRailVisible ? "Hide Control Panel" : "Show Control Panel",
                        systemImage: "sidebar.right"
                    )
                }
                .help(isRightRailVisible ? "Hide control panel" : "Show control panel")
            }
        }
    }
}

private struct ContentDetailAreaView: View {
    let selectedTask: AgentTask?
    let effectiveWorkspace: Workspace?
    let isComposingTask: Bool
    let taskQueue: TaskQueue
    let sshReloadTrigger: Int
    @Binding var isRightRailPresented: Bool

    let onQuickRun: (AgentTask) -> Void
    let onTaskCreated: (AgentTask) -> Void
    let onAddSSHConnection: () -> Void
    let onManageSkills: () -> Void
    let onRunTask: (AgentTask) -> Void
    let onCancelTask: (AgentTask) -> Void
    let onRetryTask: (AgentTask) -> Void
    let onResumeTask: (AgentTask) -> Void
    let onApproveTask: (AgentTask) -> Void
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

    var body: some View {
        ContentDetailContentView(
            selectedTask: selectedTask,
            effectiveWorkspace: effectiveWorkspace,
            isComposingTask: isComposingTask,
            taskQueue: taskQueue,
            sshReloadTrigger: sshReloadTrigger,
            onQuickRun: onQuickRun,
            onTaskCreated: onTaskCreated,
            onAddSSHConnection: onAddSSHConnection,
            onManageSkills: onManageSkills,
            onRunTask: onRunTask,
            onCancelTask: onCancelTask,
            onRetryTask: onRetryTask,
            onResumeTask: onResumeTask,
            onApproveTask: onApproveTask,
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
            onImportWorkspace: onImportWorkspace
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: $isRightRailPresented) {
            if let workspace = effectiveWorkspace {
                WorkspaceRightRailView(
                    workspace: workspace,
                    selectedTask: selectedTask,
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
}

private struct ContentDetailContentView: View {
    let selectedTask: AgentTask?
    let effectiveWorkspace: Workspace?
    let isComposingTask: Bool
    let taskQueue: TaskQueue
    let sshReloadTrigger: Int
    let onQuickRun: (AgentTask) -> Void
    let onTaskCreated: (AgentTask) -> Void
    let onAddSSHConnection: () -> Void
    let onManageSkills: () -> Void
    let onRunTask: (AgentTask) -> Void
    let onCancelTask: (AgentTask) -> Void
    let onRetryTask: (AgentTask) -> Void
    let onResumeTask: (AgentTask) -> Void
    let onApproveTask: (AgentTask) -> Void
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
                    onManageSkills: onManageSkills
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
                    onToggleDone: onToggleDone,
                    sshReloadTrigger: sshReloadTrigger,
                    onMoveToDraft: onMoveToDraft,
                    onManageSkills: onManageSkills,
                    onForkTask: onForkTask
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
                onManageSkills: onManageSkills
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
    @Binding var draft: NewWorkspaceDraft
    let rootPath: String
    let onCancel: () -> Void
    let onCreate: () -> Void

    @FocusState private var focusedField: Field?

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
            formFields
            footer
        }
        .padding(24)
        .frame(width: 560)
        .background(Stanford.panelBackground)
        .onAppear {
            focusedField = .name
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
                        if draft.canCreate {
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

    private var footer: some View {
        HStack {
            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(StanfordButtonStyle(isPrimary: false))
                .keyboardShortcut(.cancelAction)

            Button("Create", action: onCreate)
                .buttonStyle(StanfordButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canCreate)
                .opacity(draft.canCreate ? 1 : 0.45)
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
                return "Pause linked schedules before marking done?"
            case .delete:
                return "Pause linked schedules before deleting?"
            }
        }

        var confirmLabel: String {
            switch self {
            case .markDone:
                return "Pause Schedules and Mark Done"
            case .delete:
                return "Pause Schedules and Delete"
            }
        }
    }

    let id = UUID()
    let task: AgentTask
    let schedules: [TaskSchedule]
    let action: Action

    var message: String {
        let names = schedules.map(\.name).joined(separator: ", ")
        return "This task is the same-thread conversation source for active schedules: \(names). Continuing will pause those schedules first so future runs do not lose their thread."
    }
}
