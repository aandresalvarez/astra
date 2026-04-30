import SwiftUI
import SwiftData

struct ContentView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AgentTask.queuePosition) private var allTasks: [AgentTask]
    @Query(sort: \Skill.name) private var allSkills: [Skill]
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
    @State private var newWorkspaceName = ""
    @State private var runtime = AppRuntimeController()
    @State private var showingNewSchedule = false
    @State private var editingSchedule: TaskSchedule?
    @State private var isSearchActive = false
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""
    @State private var linkedScheduleWarning: LinkedScheduleWarning?
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("copilotPath") private var copilotPath = ""
    @AppStorage("defaultRuntimeID") private var defaultRuntimeID = "claude_code"
    @AppStorage("timeoutSeconds") private var timeoutSeconds = 600
    @AppStorage("appUIScale") private var uiScale: Double = 1.0
    @AppStorage("validationModel") private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @AppStorage("skipPermissions") private var skipPermissions = true
    @AppStorage("lastSelectedWorkspaceID") private var lastSelectedWorkspaceID = ""
    @AppStorage("lastSelectedWorkspacePath") private var lastSelectedWorkspacePath = ""
    @AppStorage("isWorkspaceRightRailVisible") private var isWorkspaceRightRailVisible = true
    @AppStorage(WorkspaceRecoveryService.recoveryNoticeKey) private var recoveryNotice = ""
    /// First-run flag. Flips to true once the user finishes the
    /// onboarding wizard. Exposed via Settings → "Show Onboarding Again"
    /// so users can replay the guide on demand.
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    /// Shared preflight cache — one instance for the whole app run so the
    /// wizard's probe of `claude` warms the cache for the catalog badges
    /// (and vice versa).

    @MainActor
    init(appUpdateController: AppUpdateController) {
        self.appUpdateController = appUpdateController
    }

    private var filteredTasks: [AgentTask] {
        guard let ws = selectedWorkspace else { return [] }
        return allTasks.filter { $0.workspace?.id == ws.id }
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

    private var rightRailInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                selectedWorkspace != nil && isWorkspaceRightRailVisible
            },
            set: { newValue in
                isWorkspaceRightRailVisible = newValue
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            TaskSidebarView(
                tasks: allTasks,
                selectedTask: $selectedTask,
                taskQueue: runtime.taskQueue,
                workspaces: workspaces,
                selectedWorkspace: $selectedWorkspace,
                onNewTask: {
                    selectedTask = nil
                    isComposingTask = true
                },
                onRunQueue: { runQueue() },
                onRunTask: { task in runSingleTask(task) },
                onToggleDone: { task in toggleDone(task) },
                onCancelTask: { task in cancelTask(task) },
                onRetryTask: { task in retryTask(task) },
                onDeleteTask: { task in requestDeleteTask(task) },
                onNewWorkspace: { createWorkspace() },
                onEditWorkspace: { ws in
                    selectedWorkspace = ws
                    showingWorkspaceEditor = true
                },
                onImportWorkspace: { importWorkspace() },
                onShowConfigure: { openCapabilitiesManager() },
                onShowLogs: { showingLogs = true },
                onShowDashboard: { showingDashboard = true },
                onDeleteWorkspace: { ws in deleteWorkspace(ws) },
                onRenameWorkspace: { ws in
                    renameText = ws.name
                    renamingWorkspace = ws
                },
                onNewSchedule: { showingNewSchedule = true },
                onEditSchedule: { schedule in editingSchedule = schedule },
                isSearchActive: $isSearchActive
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detailWithRightRail
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("MainContentView")
        .astraWindowChrome()
        // Right-rail toggle. Attached to the NavigationSplitView root so
        // .primaryAction lands at the WINDOW's trailing edge — past the
        // inspector column — instead of at the inspector boundary
        // (where attaching to .detail or to the inspector content put it).
        .toolbar {
            if appUpdateController.shouldShowUpdateButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appUpdateController.checkForUpdatesFromButton()
                    } label: {
                        Label(appUpdateController.buttonTitle, systemImage: "arrow.down.circle")
                    }
                    .help(appUpdateController.statusMessage ?? "Install the available ASTRA update")
                    .accessibilityIdentifier("AppUpdateButton")
                }
            }

            if selectedWorkspace != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isWorkspaceRightRailVisible.toggle()
                    } label: {
                        Label(
                            isWorkspaceRightRailVisible ? "Hide Control Panel" : "Show Control Panel",
                            systemImage: "sidebar.right"
                        )
                    }
                    .help(isWorkspaceRightRailVisible ? "Hide control panel" : "Show control panel")
                }
            }
        }
        .overlay {
            if isSearchActive {
                SearchPanelOverlay(
                    tasks: allTasks,
                    workspaces: workspaces,
                    selectedTask: $selectedTask,
                    selectedWorkspace: $selectedWorkspace,
                    isActive: $isSearchActive
                )
            }
        }
        .safeAreaInset(edge: .top) {
            topNoticeBanners
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
            if let ws = selectedWorkspace {
                ConfigureView(workspace: ws, initialTab: configureInitialTab, focusItemID: configureFocusItemID)
            }
        }
        .sheet(isPresented: $showingWorkspaceEditor) {
            if let ws = selectedWorkspace {
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
            if let ws = selectedWorkspace {
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
            if let ws = selectedWorkspace {
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
            if let ws = selectedWorkspace {
                ScheduleEditorView(workspace: ws)
            }
        }
        .sheet(item: $editingSchedule) { schedule in
            ScheduleEditorView(workspace: schedule.workspace ?? selectedWorkspace!, schedule: schedule)
        }
        .alert("New Workspace", isPresented: $showingNewWorkspace) {
            TextField("Workspace name", text: $newWorkspaceName)
            Button("Cancel", role: .cancel) { newWorkspaceName = "" }
            Button("Create") { finalizeNewWorkspace() }
        } message: {
            Text("A folder will be created automatically in your workspaces root directory.")
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
        .onChange(of: updateSafetySignature) { refreshUpdateSafetyHooks() }
        .onChange(of: workspaceSelectionSignature) {
            handleWorkspaceSelectionSignatureChanged()
        }
        .onChange(of: selectedWorkspace) {
            handleSelectedWorkspaceChanged()
        }
        .environment(\.preflightCache, runtime.preflightCache)
        // Publish window-scoped actions so File menu commands (New /
        // Import Workspace) can invoke them. See ASTRAApp.swift
        // for the matching FocusedValueKey definitions.
        .focusedValue(\.newWorkspaceAction, { createWorkspace() })
        .focusedValue(\.importWorkspaceAction, { importWorkspace() })
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding && !isUITestingSeededLaunch },
            set: { _ in }
        )) {
            OnboardingWizardView(
                hasCompletedOnboarding: $hasCompletedOnboarding,
                onCreateWorkspace: { createWorkspace() }
            )
            .environment(\.preflightCache, runtime.preflightCache)
            .interactiveDismissDisabled(true)
        }
    }

    // MARK: - Onboarding

    @ViewBuilder
    private var topNoticeBanners: some View {
        if !recoveryNotice.isEmpty || updateBlockNotice != nil {
            VStack(spacing: 0) {
                if !recoveryNotice.isEmpty {
                    recoveryNoticeBanner
                }
                if let updateBlockNotice {
                    updateNoticeBanner(updateBlockNotice)
                }
            }
        }
    }

    private var recoveryNoticeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .foregroundStyle(Stanford.paloAltoGreen)
            Text(recoveryNotice)
                .font(Stanford.body(13))
                .foregroundStyle(Stanford.black)
            Spacer()
            Button("Dismiss") {
                recoveryNotice = ""
            }
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

    private var updateBlockNotice: String? {
        if case .blocked(let message) = appUpdateController.status {
            return message
        }
        return nil
    }

    private func updateNoticeBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Stanford.cardinalRed)
            Text(message)
                .font(Stanford.body(13))
                .foregroundStyle(Stanford.black)
            Spacer()
            Button("Check Again") {
                appUpdateController.checkForUpdatesFromButton()
            }
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

    private var detailWithRightRail: some View {
        detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: rightRailInspectorBinding) {
                if let workspace = selectedWorkspace {
                    WorkspaceRightRailView(
                        workspace: workspace,
                        selectedTask: selectedTask,
                        onConfigure: { openCapabilitiesManager() },
                        onEditWorkspace: { showingWorkspaceEditor = true },
                        onShowDashboard: { showingDashboard = true },
                        onShowLogs: { showingLogs = true },
                        onNewSchedule: { showingNewSchedule = true },
                        onEditSchedule: { schedule in editingSchedule = schedule },
                        onManageCapabilities: { openCapabilitiesManager() },
                        onOpenConfigureTab: { tab, itemID in
                            configureInitialTab = tab
                            configureFocusItemID = itemID
                            showingConfigure = true
                        },
                        onNewSSHConnection: { showingSSHEditor = true },
                        onEditSSHConnection: { conn in editingSSHConnection = conn }
                    )
                    .id(workspace.id)
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 380)
                }
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let task = selectedTask, task.status == .draft {
            // Draft task — show chat with conversation restored
            ChatPanelView(
                taskQueue: runtime.taskQueue,
                workspace: selectedWorkspace,
                sshReloadTrigger: sshReloadTrigger,
                draftToLoad: task,
                onQuickRun: { task in
                    selectedTask = task
                    isComposingTask = false
                    runSingleTask(task)
                },
                onTaskCreated: { task in
                    selectedTask = task
                    isComposingTask = false
                },
                onAddSSHConnection: {
                    showingSSHEditor = true
                },
                onManageSkills: {
                    configureInitialTab = .skills
                    configureFocusItemID = nil
                    showingConfigure = true
                }
            )
        } else if let task = selectedTask {
            TaskMainView(
                task: task,
                taskQueue: runtime.taskQueue,
                onRunTask: { t in runSingleTask(t) },
                onCancelTask: { t in cancelTask(t) },
                onRetryTask: { t in retryTask(t) },
                onResumeTask: { t in resumeTask(t) },
                onApproveTask: { t in approveTask(t) },
                onToggleDone: { t in toggleDone(t) },
                onMoveToDraft: { task in
                    isComposingTask = false
                    selectedTask = nil
                    DispatchQueue.main.async {
                        selectedTask = task
                    }
                },
                onManageSkills: {
                    configureInitialTab = .skills
                    configureFocusItemID = nil
                    showingConfigure = true
                },
                onForkTask: { forkedTask in
                    selectedTask = forkedTask
                }
            )
        } else if isComposingTask, selectedWorkspace != nil {
            ChatPanelView(
                taskQueue: runtime.taskQueue,
                workspace: selectedWorkspace,
                sshReloadTrigger: sshReloadTrigger,
                onQuickRun: { task in
                    selectedTask = task
                    isComposingTask = false
                    runSingleTask(task)
                },
                onTaskCreated: { task in
                    selectedTask = task
                    isComposingTask = false
                },
                onAddSSHConnection: {
                    showingSSHEditor = true
                },
                onManageSkills: {
                    configureInitialTab = .skills
                    configureFocusItemID = nil
                    showingConfigure = true
                }
            )
        } else if let workspace = selectedWorkspace {
            WorkspaceHomeView(
                workspace: workspace,
                tasks: filteredTasks,
                taskQueue: runtime.taskQueue,
                onCreateTask: {
                    selectedTask = nil
                    isComposingTask = true
                },
                onOpenTask: { task in
                    selectedTask = task
                    isComposingTask = false
                },
                onDeleteTask: { task in
                    requestDeleteTask(task)
                },
                onSetDoneState: { task, isDone in
                    setDoneState(task, to: isDone)
                },
                onRunQueue: { runQueue() },
                onConfigure: { openCapabilitiesManager() },
                onShowDashboard: { showingDashboard = true },
                onShowLogs: { showingLogs = true },
                onNewSchedule: { showingNewSchedule = true },
                onEditSchedule: { schedule in editingSchedule = schedule },
                onManageCapabilities: { openCapabilitiesManager() }
            )
        } else {
            // Onboarding — no workspace
            onboardingView
        }
    }

    private func openCapabilitiesManager() {
        configureInitialTab = .capabilities
        configureFocusItemID = nil
        showingConfigure = true
    }

    /// Empty-state shown when the user has completed onboarding but no
    /// workspace is selected (all deleted, or post-upgrade where the
    /// stored selection is stale). Environment checks live in the
    /// onboarding wizard now; this view is purely "pick a workspace".
    private var onboardingView: some View {
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
                    createWorkspace()
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .buttonStyle(StanfordButtonStyle())
                .accessibilityIdentifier("OnboardingNewWorkspaceButton")

                Button {
                    importWorkspace()
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

    // MARK: - Coordinator

    private var coordinator: TaskLifecycleCoordinator {
        TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: runtime.taskQueue)
    }

    private var updateSafetySignature: String {
        let taskSignature = allTasks
            .map { "\($0.id.uuidString):\($0.status.rawValue)" }
            .joined(separator: ",")
        return [
            String(runtime.taskQueue.isProcessing),
            String(runtime.taskQueue.activeCount),
            String(runtime.taskQueue.activeTasks.count),
            taskSignature
        ].joined(separator: "|")
    }

    private var hasUpdateBlockingWork: Bool {
        AppUpdateSafety.isInstallBlocked(
            queueIsProcessing: runtime.taskQueue.isProcessing,
            activeWorkerCount: runtime.taskQueue.activeCount,
            activeTaskCount: runtime.taskQueue.activeTasks.count,
            runningTaskCount: allTasks.filter { $0.status == .running }.count
        )
    }

    private func refreshUpdateSafetyHooks() {
        appUpdateController.configureSafety(
            isWorkActive: { hasUpdateBlockingWork },
            prepareForInstall: { prepareForAppUpdateInstall() }
        )
    }

    private func prepareForAppUpdateInstall() -> Bool {
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
        showingNewWorkspace = true
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
        let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        selectedWorkspace = coordinator.createWorkspace(name: name, rootPath: resolvedRoot)
        newWorkspaceName = ""
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

    private func runQueue() { coordinator.runQueue() }
    private func runSingleTask(_ task: AgentTask) { coordinator.runSingleTask(task) }
    private func cancelTask(_ task: AgentTask) { coordinator.cancelTask(task) }

    private func retryTask(_ task: AgentTask) { coordinator.retryTask(task) }
    private func resumeTask(_ task: AgentTask) { coordinator.resumeTask(task) }
    private func approveTask(_ task: AgentTask) { coordinator.approveTask(task) }

    private func deleteTask(_ task: AgentTask) {
        if selectedTask?.id == task.id {
            selectedTask = nil
        }
        _ = coordinator.deleteTask(task)
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
            return
        }

        let linkedSchedules = coordinator.activeSameThreadSchedules(for: task)
        guard !linkedSchedules.isEmpty else {
            coordinator.setDoneState(task, to: true)
            return
        }

        linkedScheduleWarning = LinkedScheduleWarning(task: task, schedules: linkedSchedules, action: .markDone)
    }

    private func pauseSchedulesAndContinue(_ warning: LinkedScheduleWarning) {
        coordinator.pauseSchedules(warning.schedules)

        switch warning.action {
        case .markDone:
            coordinator.setDoneState(warning.task, to: true)
        case .delete:
            deleteTask(warning.task)
        }
    }

    // MARK: - Migration

    private func migrateConnectorCredentials() {
        coordinator.migrateConnectorCredentials(workspaces: workspaces)
    }

    private func migrateSkillSecrets() {
        coordinator.migrateSkillSecrets(skills: allSkills)
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
        applySettings()
        seedTestDataIfNeeded()
        migrateConnectorCredentials()
        migrateSkillSecrets()
        restoreWorkspaceSelection()
        backfillThreadTitlesIfNeeded()
        enterUITestComposerIfNeeded()
        runtime.startScheduler(modelContext: modelContext)
        runtime.loadPluginCatalog()
        refreshUpdateSafetyHooks()
        appUpdateController.probeForUpdatesOnce()
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
