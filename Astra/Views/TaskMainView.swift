import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ASTRACore

enum TaskComposerPresentation {
    static let usesCompactInputSpacing = true
    static let usesForcedExpandedInputHeight = false
    static let decisionRowUsesNestedChrome = false
    static let decisionRowUsesNestedStroke = false
    static let decisionDockHorizontalPadding: CGFloat = 14
    static let decisionDockTopPadding: CGFloat = 12
    static let decisionDockBottomPadding: CGFloat = 8
    static let decisionRowHorizontalPadding: CGFloat = 12
    static let decisionRowVerticalPadding: CGFloat = 10
    static let decisionRowSpacing: CGFloat = 12
    static let decisionAccentWidth: CGFloat = 3
    static let decisionAccentVerticalInset: CGFloat = 10
    static let decisionIconFrame: CGFloat = 24
    static let decisionIconFontSize: CGFloat = 20
    static let decisionTitleFontSize: CGFloat = 14
    static let decisionDetailFontSize: CGFloat = 12
    static let inputHorizontalPadding: CGFloat = 14
    static let inputTopPadding: CGFloat = 12
    static let inputTopPaddingWithAttachments: CGFloat = 8
    static let inputBottomPadding: CGFloat = 9
}

private struct TaskScopedStatusMessage: Equatable {
    let taskID: UUID
    let text: String
}

private struct TaskVerificationLoadRequest: Hashable {
    let taskID: UUID
    let taskStatus: TaskStatus
    let taskUpdatedAt: Date
    let taskFolder: String
}

enum TaskVerificationPresentationLoader {
    static func presentation(isFinished: Bool, taskFolder: String) async -> TaskVerificationPresentation? {
        guard isFinished, !taskFolder.isEmpty else { return nil }
        let verification = await Task.detached(priority: .utility) {
            TaskContextStateManager.load(taskFolder: taskFolder)?.verification
        }.value
        return verification.map(TaskPresentationState.verificationPresentation(for:))
    }
}

private struct ScheduleSourceContext {
    let taskID: UUID
    let title: String
    let goal: String
    let runtimeID: String
    let model: String
    let tokenBudget: Int
    let conversationContext: String
}

private struct ChatBottomPositionPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatTopPositionPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = -.infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum RunNoticeProminence {
    case actionable
    case detail
}

/// Streaming agent text rendered as plain `Text` while the run is live. Isolated
/// into its own `View` so SwiftUI can diff this subtree independently from the
/// rest of the agent bubble — the bubble re-evaluates often as bucketed snapshot
/// updates flow in, but only this view's body actually depends on `displayText`.
private struct StreamingAgentTextView: View {
    let displayText: String

    var body: some View {
        Text(MarkdownTextView.normalizedStreamingText(displayText))
            .font(Stanford.chatBody())
            .foregroundStyle(Stanford.readingText)
            .textSelection(.enabled)
            .lineSpacing(Stanford.chatBodyLineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Completed agent markdown body. Equatable on its inputs so SwiftUI skips the
/// expensive `MarkdownTextView` parse when neither the text nor the callback
/// identity has changed.
private struct CompletedAgentMarkdownView: View, Equatable {
    let displayText: String
    let onSuggestedNextStep: ((String) -> Void)?

    var body: some View {
        MarkdownTextView(
            text: displayText,
            maxContentWidth: Stanford.chatParagraphMaxWidth,
            onSuggestedNextStep: onSuggestedNextStep
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    static func == (lhs: CompletedAgentMarkdownView, rhs: CompletedAgentMarkdownView) -> Bool {
        lhs.displayText == rhs.displayText
            && ((lhs.onSuggestedNextStep == nil) == (rhs.onSuggestedNextStep == nil))
    }
}

/// Generated-files attachment list rendered for a finished agent turn. Pulled
/// into its own struct so the parent bubble does not re-evaluate this `ForEach`
/// each time unrelated bubble state changes.
private struct AgentGeneratedFilesListView: View {
    let paths: [String]
    let onOpen: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(paths, id: \.self) { path in
                Button {
                    if let onOpen {
                        onOpen(path)
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: Formatters.fileIcon(for: path))
                            .font(Stanford.ui(11))
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(Stanford.caption(12))
                            .underline()
                    }
                    .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)
                .help(TaskGeneratedFiles.shelfDestination(for: path)?.title ?? "Open file")
            }
        }
    }
}

/// Unified main view: compact status bar + chat-style activity thread + composer
struct TaskMainView: View {
    let task: AgentTask
    var taskQueue: TaskQueue?
    var onRunTask: ((AgentTask) -> Void)?
    var onCancelTask: ((AgentTask) -> Void)?
    var onRetryTask: ((AgentTask) -> Void)?
    var onResumeTask: ((AgentTask) -> Void)?
    var onApproveTask: ((AgentTask) -> Void)?
    var onOpenPlan: ((AgentTask) -> Void)?
    var isPlanCanvasVisible = false
    var onToggleDone: ((AgentTask) -> Void)?
    var sshReloadTrigger: Int = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]
    @State private var messageText = ""
    @State private var attachedFiles: [String] = []
    @State private var slashSelectedIndex = 0
    @State private var isDragOver = false
    @State private var showDiffsSheet = false
    @State private var showContextPreview = false
    @State private var showCheckpointBrowser = false
    @State private var expandedRunActivity: Set<UUID> = []
    @State private var expandedRunNetworkDetails: Set<UUID> = []
    @State private var expandedRunPolicyManifests: Set<UUID> = []
    @State private var expandedRunNotices: Set<UUID> = []
    @State private var showScheduleEditor = false
    @State private var scheduleCreationTaskID: UUID?
    @State private var scheduleStatusMessage: TaskScopedStatusMessage?
    @State private var isShowingFilesPopover = false
    @State private var isGeneratingRecap = false
    @State private var recapStatusMessage: String?
    @State private var showCopyConfirmation = false
    @State private var pasteMonitor: Any?
    @State private var threadViewModel = TaskThreadViewModel()
    @State private var sshConnections: [SSHConnection] = []
    @State private var isChatAtBottom = true
    @State private var hasUnseenChatActivity = false
    @State private var shouldScrollAfterUserMessage = false
    @State private var pendingInitialChatScrollTaskID: UUID?
    @State private var isExpandingWindow = false
    @State private var expansionAnchorItemID: String?
    @State private var runtimeHealthNow = Date()
    @State private var lastLoggedRuntimeHealthSignature: String?
    @State private var isPlanMode = false
    @State private var isPlanning = false
    @State private var isAgentPlanExpanded = false
    @State private var isThreadStatusExpanded = false
    @State private var isTaskDecisionDetailsExpanded = false
    @State private var cachedPlanState = TaskPlanState.empty
    @State private var cachedPlanStateSignature = TaskPlanStateCacheSignature.empty
    @State private var pendingPlanStateRefreshTask: Task<Void, Never>?
    @State private var cachedVerificationRequest: TaskVerificationLoadRequest?
    @State private var cachedVerificationPresentation: TaskVerificationPresentation?
    @FocusState private var isComposerFocused: Bool
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("copilotPath") private var copilotPath = ""
    @AppStorage(AppStorageKeys.runtimeProviderSettingsRevision) private var runtimeProviderSettingsRevision = 0
    @AppStorage(AppStorageKeys.roleProfileRevision) private var roleProfileRevision = 0
    @AppStorage(AppStorageKeys.claudeProvider) private var claudeProviderRaw = ClaudeProvider.anthropic.rawValue
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @AppStorage(AppStorageKeys.claudeVertexOpusModel) private var claudeVertexOpusModel = ""
    @AppStorage(AppStorageKeys.claudeVertexSonnetModel) private var claudeVertexSonnetModel = ""
    @AppStorage(AppStorageKeys.claudeVertexHaikuModel) private var claudeVertexHaikuModel = ""
    @AppStorage(AppStorageKeys.claudeAvailableModels) private var claudeAvailableModels = ""
    @AppStorage(AppStorageKeys.copilotAvailableModels) private var copilotAvailableModels = ""
    @AppStorage(AppStorageKeys.runtimeModelCacheRevision) private var runtimeModelCacheRevision = 0
    @AppStorage(AppStorageKeys.skipPermissions) private var skipPermissions = false
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @State private var taskPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @State private var runtimeReadinessStates: [AgentRuntimeID: RuntimeReadinessState] = [:]
    var onMoveToDraft: ((AgentTask) -> Void)?
    var onManageSkills: (() -> Void)?
    var onForkTask: ((AgentTask) -> Void)?
    var onOpenGeneratedFile: ((String) -> Void)?

    private var availableSkills: [Skill] {
        guard let workspace = task.workspace else { return [] }
        return WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools
        ).activeSkills
    }

    private func logTaskCapabilityContext(
        source: String,
        level: LogLevel = .info,
        traceID: String? = nil,
        extraFields: [String: String] = [:]
    ) {
        var fields = CapabilityAudit.taskContextFields(source: source, task: task)
        if let traceID { fields["trace_id"] = traceID }
        for (key, value) in extraFields {
            fields[key] = value
        }
        AppLogger.audit(.capabilityChatContext, category: "UI", taskID: task.id, fields: fields, level: level, fieldMaxLength: 240)
    }

    private var currentThreadSnapshot: TaskThreadSnapshot {
        threadViewModel.snapshot ?? TaskThreadSnapshot.placeholder(
            goal: task.goal,
            createdAt: task.createdAt
        )
    }

    private var threadSnapshotTrigger: TaskThreadSnapshotTrigger {
        TaskThreadSnapshotTrigger(task: task)
    }

    private var generatedFilesTrigger: TaskGeneratedFilesTrigger {
        TaskGeneratedFilesTrigger(task: task, latestRun: currentThreadSnapshot.latestRun)
    }

    private var planStateCacheRefreshTrigger: TaskPlanStateCacheSignature {
        TaskPlanStateCacheSignature(task: task)
    }

    private var runtimeHealth: TaskRuntimeHealth {
        TaskRuntimeHealth.evaluate(
            taskStatus: task.status,
            snapshot: currentThreadSnapshot,
            now: runtimeHealthNow
        )
    }

    private var currentPlanState: TaskPlanState {
        cachedPlanState
    }

    private var executableApprovedPlan: TaskPlanPayload? {
        let state = currentPlanState
        guard let plan = state.plan,
              TaskPlanService.hasRemainingExecutableSteps(in: plan),
              task.status != .queued,
              task.status != .running,
              !isPlanning else {
            return nil
        }

        switch state.lifecycleStatus {
        case .approved, .executing, .failed:
            return plan
        case .none, .draft, .completed, .cancelled:
            return nil
        }
    }

    private func utilityRuntime(for role: TaskRoleID) -> (configuration: AgentUtilityRuntimeConfiguration, selection: TaskRoleProfileSelection) {
        _ = roleProfileRevision
        return TaskRoleProfileStore.utilityRuntime(
            for: role,
            task: task,
            defaultRuntimeID: task.resolvedRuntimeID.rawValue,
            defaultModel: task.model,
            validationModel: task.model,
            defaultBudget: task.tokenBudget,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            providerSettings: providerSettingsForUtilityRuntime,
            cache: runtimeModelCache
        )
    }

    private var providerSettingsForUtilityRuntime: AgentRuntimeProviderSettings {
        var settings = RuntimeProviderSettingsStore.settings()
        settings.setExecutablePath(claudePath, for: .claudeCode)
        settings.setExecutablePath(copilotPath, for: .copilotCLI)
        return settings
    }

    private func alignTaskModelWithRuntime() {
        TaskRuntimeAvailabilityPolicy.alignModelWithCurrentRuntime(
            task: task,
            cache: runtimeModelCache
        )
    }

    private var runtimeModelCache: RuntimeModelAvailabilityCache {
        _ = runtimeModelCacheRevision
        return RuntimeModelAvailabilityCache.appStorage(
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels
        )
    }

    private var runtimeAvailabilityConfiguration: RuntimeProviderAvailabilityConfiguration {
        RuntimeProviderAvailabilityConfiguration(
            providerSettings: providerSettingsForReadiness,
            claudeProvider: ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic,
            vertexProjectID: claudeVertexProjectID,
            vertexRegion: claudeVertexRegion,
            vertexOpusModel: claudeVertexOpusModel,
            vertexSonnetModel: claudeVertexSonnetModel,
            vertexHaikuModel: claudeVertexHaikuModel
        )
    }

    private var providerSettingsForReadiness: AgentRuntimeProviderSettings {
        var settings = RuntimeProviderSettingsStore.settings()
        settings.setExecutablePath(claudePath, for: .claudeCode)
        settings.setExecutablePath(copilotPath, for: .copilotCLI)
        return settings
    }

    private var runtimeAvailabilitySignature: String {
        [
            claudePath,
            copilotPath,
            String(runtimeProviderSettingsRevision),
            RuntimeProviderSettingsStore.signature(),
            claudeProviderRaw,
            claudeVertexProjectID,
            claudeVertexRegion,
            claudeVertexOpusModel,
            claudeVertexSonnetModel,
            claudeVertexHaikuModel
        ].joined(separator: "|")
    }

    private var chatStatusDisclosureAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.12) : .easeInOut(duration: 0.26)
    }

    private var chatStatusDetailsTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 0, y: -6)),
            removal: .opacity
        )
    }

    private var chatStatusBlockTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 0, y: 8)),
            removal: .opacity
        )
    }

    private var threadScrollSignature: String {
        let itemCount = currentThreadSnapshot.conversationItems.count
        let lastItemID = currentThreadSnapshot.conversationItems.last?.id ?? "none"
        let latestOutputCount = currentThreadSnapshot.latestRun?.output.count ?? 0
        let latestStatus = currentThreadSnapshot.latestRun?.status.rawValue ?? "none"
        return "count=\(itemCount)#last=\(lastItemID)#latest=\(latestOutputCount)#status=\(latestStatus)"
    }

    private static func chatHorizontalPadding(for width: CGFloat) -> CGFloat {
        if width < 520 { return 12 }
        if width < 760 { return 16 }
        return 32
    }

    private static func chatColumnMaxWidth(for width: CGFloat) -> CGFloat {
        let horizontalPadding = chatHorizontalPadding(for: width) * 2
        let usableWidth = max(240, width - horizontalPadding)
        guard usableWidth >= 860 else { return usableWidth }

        let proportionalWidth = max(900, usableWidth * 0.78)
        return min(usableWidth, proportionalWidth, 1280)
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
                .frame(maxHeight: .infinity, alignment: .top)

            composerView
        }
        .navigationTitle("")
        .navigationSubtitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                taskTitleToolbar
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL,
                  TaskGeneratedFiles.shelfDestination(for: url.path) != nil,
                  let onOpenGeneratedFile else {
                return .systemAction
            }
            onOpenGeneratedFile(url.path)
            return .handled
        })
        .sheet(isPresented: $showDiffsSheet) {
            DiffsTabView(task: task)
                .frame(minWidth: 700, minHeight: 500)
        }
        .sheet(isPresented: $showContextPreview) {
            let request = contextPreviewRequest
            if let manifest = contextPreviewManifest(for: request) {
                PromptContextPreviewSheet(manifest: manifest)
                    .frame(minWidth: 700, minHeight: 600)
            } else {
                PromptContextPreviewUnavailableSheet(
                    reason: request.unavailableReason ?? "No provider prompt is pending."
                )
            }
        }
        .sheet(isPresented: $showScheduleEditor) {
            if let ws = task.workspace {
                ScheduleEditorView(
                    workspace: ws,
                    prefillName: task.title,
                    prefillGoal: task.goal,
                    prefillRuntimeID: task.resolvedRuntimeID.rawValue,
                    prefillModel: task.model,
                    prefillBudget: task.tokenBudget,
                    prefillSkillIDs: Set(task.skills.map { $0.id.uuidString }),
                    prefillConversationContext: scheduleConversationContext,
                    prefillSourceTaskID: task.id
                )
            }
        }
        .sheet(isPresented: $showCheckpointBrowser) {
            TaskCheckpointBrowserSheet(
                task: task,
                snapshot: currentThreadSnapshot,
                onRestore: forkTask(from:)
            )
            .frame(minWidth: 780, minHeight: 540)
        }
        .task(id: runtimeAvailabilitySignature) {
            await refreshRuntimeAvailability()
        }
        .task(id: planStateCacheRefreshTrigger) {
            refreshPlanStateCache()
        }
        .task(id: verificationLoadRequest) {
            await refreshVerificationPresentation(for: verificationLoadRequest)
        }
        .onChange(of: task.id) {
            isChatAtBottom = true
            hasUnseenChatActivity = false
            shouldScrollAfterUserMessage = true
            pendingInitialChatScrollTaskID = task.id
            isExpandingWindow = false
            expansionAnchorItemID = nil
            runtimeHealthNow = Date()
            lastLoggedRuntimeHealthSignature = nil
            threadViewModel.reset(for: task)
            loadSSHConnections()
            alignTaskAfterRuntimeAvailabilityRefresh()
            initializeTaskPolicySelection()
            refreshTaskContextState()
            refreshPlanStateCache()
            cachedVerificationRequest = nil
            cachedVerificationPresentation = nil
        }
        .onAppear {
            alignTaskModelWithRuntime()
            initializeTaskPolicySelection()
            runtimeHealthNow = Date()
            pendingInitialChatScrollTaskID = task.id
            threadViewModel.reset(for: task)
            loadSSHConnections()
            refreshTaskContextState()
            refreshPlanStateCache()
            cachedVerificationRequest = nil
            cachedVerificationPresentation = nil
            logRuntimeHealthIfNeeded(reason: "appear")
            installPasteMonitor()
        }
        .onDisappear {
            pendingPlanStateRefreshTask?.cancel()
            threadViewModel.cancelGeneratedFilesRefresh()
            removePasteMonitor()
        }
        .onChange(of: sshReloadTrigger) { loadSSHConnections() }
        .onChange(of: claudeAvailableModels) { alignTaskModelWithRuntime() }
        .onChange(of: copilotAvailableModels) { alignTaskModelWithRuntime() }
        .onChange(of: runtimeModelCacheRevision) { alignTaskModelWithRuntime() }
        .onChange(of: threadSnapshotTrigger) { _, _ in
            threadViewModel.refreshSnapshot(for: task)
            schedulePlanStateCacheRefresh()
            runtimeHealthNow = Date()
            logRuntimeHealthIfNeeded(reason: "snapshot")
        }
        .onChange(of: generatedFilesTrigger) { _, _ in
            threadViewModel.refreshGeneratedFiles(folder: TaskWorkspaceAccess(task: task).taskFolder)
        }
        .onChange(of: runtimeHealth.telemetrySignature) { _, _ in
            logRuntimeHealthIfNeeded(reason: "health")
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            guard task.status == .running else {
                lastLoggedRuntimeHealthSignature = nil
                return
            }
            runtimeHealthNow = now
            logRuntimeHealthIfNeeded(reason: "timer")
        }
    }

    private func logRuntimeHealthIfNeeded(reason: String) {
        guard task.status == .running else {
            lastLoggedRuntimeHealthSignature = nil
            return
        }

        let health = runtimeHealth
        guard health.state != .notRunning else { return }
        let signature = health.telemetrySignature
        guard lastLoggedRuntimeHealthSignature != signature else { return }
        lastLoggedRuntimeHealthSignature = signature

        AppLogger.audit(
            .runtimeProgressState,
            category: "Worker",
            taskID: task.id,
            fields: health.telemetryFields(reason: reason),
            level: health.isAttentionState ? .warning : .debug
        )
    }

    private func refreshRuntimeAvailability() async {
        let states = await RuntimeProviderAvailabilityService().states(
            configuration: runtimeAvailabilityConfiguration
        )
        // Skip partial results from a mid-flight task cancellation: SwiftUI's .task(id:) cancels
        // the running task when the signature changes, causing withTaskGroup's for-await loop to
        // exit early with fewer entries than registered runtimes. Writing partial states would
        // drop providers from the menu until the replacement task completes.
        guard states.count == AgentRuntimeAdapterRegistry.runtimeIDs.count else { return }
        runtimeReadinessStates = states
        alignTaskAfterRuntimeAvailabilityRefresh()
    }

    private func refreshPlanStateCache() {
        let signature = TaskPlanStateCacheSignature(task: task)
        guard cachedPlanStateSignature != signature else { return }
        cachedPlanState = TaskPlanService.reconstruct(for: task)
        cachedPlanStateSignature = signature
    }

    private func refreshTaskContextState() {
        TaskContextStateManager.refresh(task: task)
    }

    private func schedulePlanStateCacheRefresh() {
        pendingPlanStateRefreshTask?.cancel()
        pendingPlanStateRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            refreshPlanStateCache()
        }
    }

    private func alignTaskAfterRuntimeAvailabilityRefresh() {
        TaskRuntimeAvailabilityPolicy.alignAfterReadinessRefresh(
            task: task,
            runtimeReadinessStates: runtimeReadinessStates,
            cache: runtimeModelCache
        )
    }

    // MARK: - Header Actions

    private var taskTitleToolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            taskTitleGroup
            taskControlBar
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var taskTitleGroup: some View {
        Text(task.title)
            .font(Stanford.ui(14, weight: .semibold))
            .foregroundStyle(Stanford.black)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
            .frame(maxWidth: 420, alignment: .leading)
    }

    private var taskControlBar: some View {
        HStack(spacing: 6) {
            filesButton
            if task.status != .draft {
                moreMenu
            }
        }
        .controlSize(.small)
        .frame(height: 30, alignment: .center)
    }

    private var filesButton: some View {
        Button {
            isShowingFilesPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isShowingFilesPopover ? "doc.text.fill" : "doc.text")
                    .font(Stanford.ui(12, weight: .medium))
                if headerFileCount > 0 {
                    Text("Files \(headerFileCount)")
                        .font(Stanford.caption(11).weight(.medium))
                }
            }
            .foregroundStyle(isShowingFilesPopover ? Stanford.lagunita : .secondary)
            .padding(.horizontal, headerFileCount > 0 ? 8 : 6)
            .frame(height: 26)
            .background {
                if isShowingFilesPopover {
                    Capsule()
                        .fill(Stanford.lagunita.opacity(0.10))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingFilesPopover, arrowEdge: .top) {
            taskFilesPopover
                .frame(width: 340)
        }
        .help(headerFileCount == 0 ? "Task files" : "\(headerFileCount) task file\(headerFileCount == 1 ? "" : "s")")
        .accessibilityLabel(headerFileCount == 0 ? "Task files" : "\(headerFileCount) task files")
    }

    private var headerFileCount: Int {
        headerFileItems.count
    }

    private var headerFileItems: [TaskFileItem] {
        TaskFileIndex.headerItems(
            runs: currentThreadSnapshot.sortedRuns,
            generatedFilePaths: threadViewModel.generatedFilePaths,
            inputs: task.inputs
        )
    }

    private var headerTextShelfFileItems: [TaskFileItem] {
        headerFileItems.filter { $0.destination == .files }
    }

    private func openHeaderFileItem(_ item: TaskFileItem) {
        isShowingFilesPopover = false
        if item.destination != nil, let onOpenGeneratedFile {
            onOpenGeneratedFile(item.path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
    }

    private func openHeaderTextFilesInShelf() {
        guard let onOpenGeneratedFile else { return }
        let items = headerTextShelfFileItems
        guard !items.isEmpty else { return }
        isShowingFilesPopover = false
        for item in items {
            onOpenGeneratedFile(item.path)
        }
    }

    private func formatHeaderFileSize(_ size: Int64) -> String {
        guard size > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private var taskFilesPopover: some View {
        let items = headerFileItems

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("Task Files")
                    .font(Stanford.body(13).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No files yet")
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(Stanford.black)
                    Text("Generated and attached files will appear here.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                openHeaderFileItem(item)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: item.destination?.systemImage ?? Formatters.fileIcon(for: item.path))
                                        .font(Stanford.ui(13))
                                        .foregroundStyle(item.destination == nil ? Stanford.coolGrey : Stanford.lagunita)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(Stanford.body(13).weight(.medium))
                                            .foregroundStyle(Stanford.black)
                                            .lineLimit(1)
                                        Text(item.path)
                                            .font(Stanford.caption(11))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer(minLength: 8)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(item.source)
                                            .font(Stanford.caption(10).weight(.medium))
                                            .foregroundStyle(Stanford.lagunita)
                                        let size = formatHeaderFileSize(item.size)
                                        if !size.isEmpty {
                                            Text(size)
                                                .font(Stanford.caption(10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.destination?.title ?? "Open in default app")

                            if item.id != items.last?.id {
                                Divider().padding(.leading, 39)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openHeaderTextFilesInShelf()
                } label: {
                    Label("Open in Files", systemImage: "square.split.2x1")
                        .font(Stanford.caption(12).weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(headerTextShelfFileItems.isEmpty || onOpenGeneratedFile == nil ? .secondary : Stanford.lagunita)
                .disabled(headerTextShelfFileItems.isEmpty || onOpenGeneratedFile == nil)
                .help("Open all text files in the Files shelf")

                Spacer()

                if !TaskWorkspaceAccess(task: task).taskFolder.isEmpty {
                    Button {
                        isShowingFilesPopover = false
                        NSWorkspace.shared.open(URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder))
                    } label: {
                        Image(systemName: "folder")
                            .font(Stanford.ui(12, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Stanford.lagunita)
                    .help("Open task folder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Stanford.panelBackground)
    }

    @ViewBuilder
    private var mainContent: some View {
        summaryContent
    }

    private var contextPreviewRequest: PromptContextPreviewRequest {
        PromptContextPreviewPresentation.request(
            taskStatus: task.status,
            hasProviderSession: task.hasProviderSession,
            messageText: messageText,
            attachedFiles: attachedFiles
        )
    }

    private func contextPreviewManifest(for request: PromptContextPreviewRequest) -> PromptAssemblyManifest? {
        switch request.kind {
        case .initialRun:
            return AgentPromptBuilder.buildPromptAssembly(for: task)
        case .followUp:
            guard let followUpMessage = request.followUpMessage else { return nil }
            return AgentPromptBuilder.buildFreshFollowUpPromptAssembly(
                message: followUpMessage,
                task: task
            )
        case .unavailable:
            return nil
        }
    }

    /// Snapshot the conversation at routine creation time.
    /// Captures user messages and agent responses chronologically.
    private var scheduleConversationContext: String {
        if let exactContext = exactRecentTaskConversationContext() {
            return exactContext
        }

        return snapshotConversationContext(includePlanningAndSystem: true)
    }

    private func exactRecentTaskConversationContext(
        includePlanningAndSystem: Bool = true
    ) -> String? {
        guard let transcript = AgentPromptBuilder.buildRecentConversationTranscript(for: task) else {
            return nil
        }

        var sections = [
            "Current task goal:\n\(task.goal)",
            "Recent task conversation transcript:\n\(transcript)"
        ]

        if includePlanningAndSystem {
            let supplemental = supplementalPlanningAndSystemContext()
            if !supplemental.isEmpty {
                sections.append("Recent planning and system context:\n\(supplemental)")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private func supplementalPlanningAndSystemContext() -> String {
        currentThreadSnapshot.conversationItems.compactMap { item in
            switch item {
            case .planUserMessage(let text, _):
                return "User planning: \(text)"
            case .planAssistantMessage(let text, _):
                return "Planning assistant: \(text)"
            case .scheduleResult(let text, _):
                return "Routine result: \(text)"
            case .systemInfo(let text, _):
                return "System: \(text)"
            case .recapResult(let text, _):
                return "Recap: \(text)"
            case .userMessage, .agentResponse:
                return nil
            }
        }.joined(separator: "\n\n")
    }

    private func snapshotConversationContext(includePlanningAndSystem: Bool) -> String {
        var lines: [String] = ["Current task goal:\n\(task.goal)"]

        for item in currentThreadSnapshot.conversationItems.dropFirst().suffix(24) {
            switch item {
            case .userMessage(let text, _):
                lines.append("User: \(text)")
            case .planUserMessage(let text, _):
                if includePlanningAndSystem {
                    lines.append("User planning: \(text)")
                }
            case .planAssistantMessage(let text, _):
                if includePlanningAndSystem {
                    lines.append("Planning assistant: \(text)")
                }
            case .agentResponse(let run):
                let protocolState = currentThreadSnapshot.protocolState(for: run)
                let response = run.output.isEmpty ? (protocolState.completionSummary ?? "") : run.output
                let output = String(response.prefix(3000))
                lines.append("Agent: \(output)")
            case .scheduleResult(let text, _):
                if includePlanningAndSystem {
                    lines.append("Routine result: \(text)")
                }
            case .systemInfo(let text, _):
                if includePlanningAndSystem {
                    lines.append("System: \(text)")
                }
            case .recapResult(let text, _):
                if includePlanningAndSystem {
                    lines.append("Recap: \(text)")
                }
            }
        }

        return lines.joined(separator: "\n\n")
    }

    private var isCreatingScheduleForCurrentTask: Bool {
        scheduleCreationTaskID == task.id
    }

    private var currentScheduleStatusMessage: String? {
        guard scheduleStatusMessage?.taskID == task.id else { return nil }
        return scheduleStatusMessage?.text
    }

    private var currentVerificationPresentation: TaskVerificationPresentation? {
        guard cachedVerificationRequest == verificationLoadRequest else { return nil }
        return cachedVerificationPresentation
    }

    private var missionControlPresentation: MissionControlPresentation? {
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = folder.isEmpty ? nil : TaskContextStateManager.load(taskFolder: folder)
        return MissionControlPresentation.build(
            task: task,
            planState: cachedPlanState,
            state: state
        )
    }

    private var verificationLoadRequest: TaskVerificationLoadRequest? {
        guard isFinished else { return nil }
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        guard !folder.isEmpty else { return nil }
        return TaskVerificationLoadRequest(
            taskID: task.id,
            taskStatus: task.status,
            taskUpdatedAt: task.updatedAt,
            taskFolder: folder
        )
    }

    @MainActor
    private func refreshVerificationPresentation(for request: TaskVerificationLoadRequest?) async {
        guard let request else {
            cachedVerificationRequest = nil
            cachedVerificationPresentation = nil
            return
        }
        let presentation = await TaskVerificationPresentationLoader.presentation(
            isFinished: true,
            taskFolder: request.taskFolder
        )
        guard verificationLoadRequest == request else { return }
        cachedVerificationRequest = request
        cachedVerificationPresentation = presentation
    }

    private func setScheduleStatusMessage(_ message: String, for taskID: UUID? = nil) {
        scheduleStatusMessage = TaskScopedStatusMessage(taskID: taskID ?? task.id, text: message)
    }

    private func clearScheduleStatusMessage(for taskID: UUID? = nil) {
        let scopedTaskID = taskID ?? task.id
        if scheduleStatusMessage?.taskID == scopedTaskID {
            scheduleStatusMessage = nil
        }
    }

    private func approveMissionCorrection(_ correctiveStepID: String) {
        TaskCorrectiveWorkService.approveStep(
            task: task,
            correctiveStepID: correctiveStepID,
            modelContext: modelContext
        )
        MissionControlPresentation.recordAction(
            TaskMissionActionEventTypes.approved,
            task: task,
            correctiveStepID: correctiveStepID,
            modelContext: modelContext
        )
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private func dismissMissionCorrection(_ correctiveStepID: String) {
        let reason = "Dismissed from Mission Control."
        TaskCorrectiveWorkService.dismissStep(
            task: task,
            correctiveStepID: correctiveStepID,
            reason: reason,
            modelContext: modelContext
        )
        MissionControlPresentation.recordAction(
            TaskMissionActionEventTypes.dismissed,
            task: task,
            correctiveStepID: correctiveStepID,
            reason: reason,
            modelContext: modelContext
        )
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private func createMissionCorrectionTask(_ correctiveStepID: String) {
        let child = TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: correctiveStepID,
            modelContext: modelContext
        )
        MissionControlPresentation.recordAction(
            TaskMissionActionEventTypes.correctionCreated,
            task: task,
            correctiveStepID: correctiveStepID,
            correctiveTaskID: child?.id,
            modelContext: modelContext
        )
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.id.uuidString, forType: .string)
                    showCopyConfirmation = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { showCopyConfirmation = false }
                    }
                } label: {
                    Label(showCopyConfirmation ? "Copied Task ID" : "Copy Task ID", systemImage: "number")
                }

                if task.tokensUsed > 0 {
                    Label(Formatters.formatTokens(task.tokensUsed), systemImage: "number")
                }
                if task.tokenBudget > 0 {
                    Label("Budget \(Formatters.formatTokens(task.tokenBudget))", systemImage: "speedometer")
                } else {
                    Label("Budget unlimited", systemImage: "speedometer")
                }
                if task.costUSD > 0 {
                    Label(String(format: "$%.2f", task.costUSD), systemImage: "dollarsign.circle")
                }
                if let run = latestRun, let completed = run.completedAt {
                    let durationSec = Int(completed.timeIntervalSince(run.startedAt))
                    Label(formatDuration(durationSec), systemImage: "clock")
                }
                if let run = latestRun, run.inputTokens > 0 {
                    Label("Context \(Formatters.formatTokens(run.inputTokens))/200.0k", systemImage: "circle.dashed")
                }
            }

            Section {
                Button {
                    showContextPreview = true
                } label: {
                    Label("Context Preview", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    showCheckpointBrowser = true
                } label: {
                    Label("Checkpoints", systemImage: "clock.arrow.circlepath")
                }
                .disabled(currentThreadSnapshot.sortedRuns.isEmpty)

                Button {
                    showScheduleEditor = true
                } label: {
                    Label("Convert to Routine", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: 26)
        .help("More actions")
    }

    private var summaryContent: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Color.clear
                            .frame(height: 1)
                            .id("chatTop")
                            .background(chatTopPositionReader())
                        chatThreadContent
                        Color.clear
                            .frame(height: 1)
                            .id("chatBottom")
                            .background(chatBottomPositionReader())
                    }
                    .frame(maxWidth: Self.chatColumnMaxWidth(for: viewport.size.width), alignment: .leading)
                    .padding(.horizontal, Self.chatHorizontalPadding(for: viewport.size.width))
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "task-chat-scroll")
                .overlay(alignment: .bottom) {
                    newActivityPill(proxy: proxy)
                }
                .onPreferenceChange(ChatBottomPositionPreferenceKey.self) { bottomMinY in
                    updateChatBottomState(bottomMinY: bottomMinY, viewportHeight: viewport.size.height)
                }
                .onPreferenceChange(ChatTopPositionPreferenceKey.self) { topMinY in
                    handleChatTopPositionChange(topMinY: topMinY)
                }
                .onAppear {
                    scrollChatToBottom(proxy, animated: false)
                }
                .onChange(of: threadScrollSignature) { oldValue, newValue in
                    handleThreadScrollChange(
                        oldSignature: oldValue,
                        newSignature: newValue,
                        proxy: proxy
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var chatThreadContent: some View {
        PerformanceSignposts.renderTaskThread {
            chatThreadContentBody
        }
    }

    @ViewBuilder
    private var chatThreadContentBody: some View {
        if task.isForked {
            HStack(spacing: 6) {
                Image(systemName: "arrow.branch")
                    .font(Stanford.ui(11))
                Text("Forked from another task at step \(task.forkedAtRunIndex + 1)")
                    .font(Stanford.caption(12))
            }
            .foregroundStyle(Stanford.plum)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Stanford.plum.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 14)
        }

        if !currentThreadSnapshot.latestAgentPlanItems.isEmpty {
            agentPlanPanel(items: currentThreadSnapshot.latestAgentPlanItems)
                .padding(.horizontal, 14)
        }

        if currentThreadSnapshot.omittedRunCount > 0 {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Stanford.sandstone.opacity(0.36))
                    .frame(height: 1)
                    .frame(maxWidth: 40)
                Text("Earlier activity")
                    .font(Stanford.chatMeta(11))
                    .foregroundStyle(Stanford.coolGrey.opacity(0.6))
                Rectangle()
                    .fill(Stanford.sandstone.opacity(0.36))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
        }

        ForEach(currentThreadSnapshot.conversationItems) { item in
            conversationItemView(item)
                .id(item.id)
        }

    }

    @ViewBuilder
    private var threadStatusDisclosure: some View {
        let count = threadStatusCount
        if shouldShowThreadStatusDisclosure {
            let accent = threadStatusAccentColor
            let summary = threadStatusSummaryText

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(chatStatusDisclosureAnimation) {
                        isThreadStatusExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isThreadStatusExpanded ? "chevron.down" : "chevron.right")
                            .font(Stanford.ui(10))
                            .frame(width: 12)

                        Image(systemName: threadStatusIcon)
                            .font(Stanford.ui(12))
                            .frame(width: 14)

                        Text("Task state")
                            .font(Stanford.chatSection())
                        Text(summary)
                            .font(Stanford.chatMeta())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if count > 1 {
                            Text("\(count)")
                                .font(Stanford.chatMeta(10))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.10))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isThreadStatusExpanded {
                    threadStatusDetails
                        .transition(chatStatusDetailsTransition)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Task state. \(summary)")
            .transition(chatStatusBlockTransition)
        }
    }

    @ViewBuilder
    private var threadStatusDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if task.status == .running {
                threadStatusDetailRow(
                    title: runtimeHealth.message,
                    detail: runtimeHealth.detail,
                    icon: runtimeHealth.isAttentionState ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath",
                    color: runtimeHealth.isAttentionState ? Stanford.poppy : Stanford.lagunita
                )
            }

            if shouldShowPendingApprovalStatus {
                threadStatusDetailRow(
                    title: "Waiting for your approval",
                    detail: pendingApprovalStatusDetail,
                    icon: "person.crop.circle.badge.questionmark",
                    color: Stanford.poppy
                )
            }

            if isCreatingScheduleForCurrentTask {
                threadStatusDetailRow(
                    title: "Creating routine...",
                    detail: nil,
                    icon: "arrow.triangle.2.circlepath",
                    color: Stanford.lagunita,
                    isLoading: true
                )
            }

            if isGeneratingRecap {
                threadStatusDetailRow(
                    title: "Generating recap...",
                    detail: nil,
                    icon: "doc.text.magnifyingglass",
                    color: Stanford.lagunita,
                    isLoading: true
                )
            }

            if let msg = recapStatusMessage {
                threadStatusDetailRow(
                    title: msg,
                    detail: nil,
                    icon: "exclamationmark.triangle",
                    color: Stanford.poppy,
                    dismissAction: { recapStatusMessage = nil }
                )
            }

            if let statusMsg = currentScheduleStatusMessage {
                threadStatusAttributedRow(
                    text: MarkdownTextView.markdownAttributed(statusMsg),
                    icon: isScheduleStatusError ? "exclamationmark.triangle" : "checkmark.circle",
                    color: isScheduleStatusError ? Stanford.poppy : Stanford.paloAltoGreen,
                    dismissAction: { clearScheduleStatusMessage() }
                )
            }

            if let verification = currentVerificationPresentation {
                threadStatusDetailRow(
                    title: verification.title,
                    detail: verification.detail,
                    icon: verification.systemImage,
                    color: verificationColor(for: verification.tone)
                )
            }
        }
        .padding(.top, 2)
    }

    private var shouldShowThreadStatusDisclosure: Bool {
        let count = threadStatusCount
        guard count > 0 else { return false }
        if count == 1,
           task.status == .running,
           !runtimeHealth.isAttentionState,
           latestRunningRunHasActivityDisclosure {
            return false
        }
        return true
    }

    private var latestRunningRunHasActivityDisclosure: Bool {
        guard task.status == .running,
              let run = latestRun,
              run.status == .running else {
            return false
        }
        let presentation = currentThreadSnapshot.activityPresentation(for: run)
        return shouldShowRunActivityDisclosure(presentation)
    }

    private var threadStatusCount: Int {
        var count = 0
        if task.status == .running { count += 1 }
        if shouldShowPendingApprovalStatus { count += 1 }
        if isCreatingScheduleForCurrentTask { count += 1 }
        if isGeneratingRecap { count += 1 }
        if recapStatusMessage != nil { count += 1 }
        if currentScheduleStatusMessage != nil { count += 1 }
        if currentVerificationPresentation != nil { count += 1 }
        return count
    }

    private var shouldShowPendingApprovalStatus: Bool {
        task.status == .pendingUser && (latestRun?.output.isEmpty ?? true)
    }

    private var pendingApprovalStatusDetail: String {
        hasOpenRuntimePermissionApprovalRequest
            ? (pendingRuntimePermissionDecision?.compactAuditSummary ?? pendingApprovalSurfaceSummary)
            : "Use the review controls above the composer to continue."
    }

    private var threadStatusSummaryText: String {
        let parts = threadStatusSummaryParts
        guard !parts.isEmpty else { return "" }
        let visible = Array(parts.prefix(3))
        let hiddenCount = parts.count - visible.count
        if hiddenCount > 0 {
            return visible.joined(separator: " · ") + " · +\(hiddenCount)"
        }
        return visible.joined(separator: " · ")
    }

    private var threadStatusSummaryParts: [String] {
        var parts: [String] = []
        if task.status == .running {
            parts.append(runtimeHealth.message)
        }
        if shouldShowPendingApprovalStatus {
            parts.append(hasOpenRuntimePermissionApprovalRequest ? (pendingRuntimePermissionDecision?.compactAuditSummary ?? pendingApprovalSurfaceSummary) : "Waiting for approval")
        }
        if isCreatingScheduleForCurrentTask {
            parts.append("Creating routine")
        }
        if isGeneratingRecap {
            parts.append("Generating recap")
        }
        if recapStatusMessage != nil {
            parts.append("Recap needs attention")
        }
        if currentScheduleStatusMessage != nil {
            parts.append(isScheduleStatusError ? "Routine needs attention" : "Routine created")
        }
        if let verification = currentVerificationPresentation {
            parts.append(verification.summary)
        }
        return parts
    }

    private var threadStatusAccentColor: Color {
        if runtimeHealth.isAttentionState ||
            shouldShowPendingApprovalStatus ||
            recapStatusMessage != nil ||
            isScheduleStatusError ||
            currentVerificationPresentation?.tone == .failed ||
            currentVerificationPresentation?.tone == .attention {
            return Stanford.poppy
        }
        if currentVerificationPresentation?.tone == .verified {
            return Stanford.paloAltoGreen
        }
        return Stanford.lagunita
    }

    private var threadStatusIcon: String {
        if runtimeHealth.isAttentionState ||
            recapStatusMessage != nil ||
            isScheduleStatusError ||
            currentVerificationPresentation?.tone == .failed {
            return "exclamationmark.triangle"
        }
        if shouldShowPendingApprovalStatus {
            return "person.crop.circle.badge.questionmark"
        }
        if let verification = currentVerificationPresentation {
            return verification.systemImage
        }
        if task.status == .running {
            return "dot.radiowaves.left.and.right"
        }
        return "list.bullet.rectangle"
    }

    private func verificationColor(for tone: TaskVerificationTone) -> Color {
        switch tone {
        case .verified:
            return Stanford.paloAltoGreen
        case .attention:
            return Stanford.poppy
        case .failed:
            return Stanford.failed
        case .neutral:
            return Stanford.coolGrey
        }
    }

    private func threadStatusDetailRow(
        title: String,
        detail: String? = nil,
        icon: String,
        color: Color,
        isLoading: Bool = false,
        dismissAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 17)
            } else {
                Image(systemName: icon)
                    .font(Stanford.ui(12))
                    .foregroundStyle(color)
                    .frame(width: 16, height: 17)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.chatSection())
                    .foregroundStyle(Stanford.black)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(Stanford.ui(10))
                        .foregroundStyle(Stanford.coolGrey)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Stanford.cardBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func threadStatusAttributedRow(
        text: AttributedString,
        icon: String,
        color: Color,
        dismissAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(Stanford.ui(12))
                .foregroundStyle(color)
                .frame(width: 16, height: 17)

            Text(text)
                .font(Stanford.chatSection())
                .foregroundStyle(Stanford.black)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(Stanford.ui(10))
                        .foregroundStyle(Stanford.coolGrey)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Stanford.cardBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func conversationItemView(_ item: TaskConversationItem) -> some View {
        switch item {
        case .userMessage(let text, let timestamp):
            chatUserBubble(text: text, timestamp: timestamp)
        case .planUserMessage(let text, let timestamp):
            chatUserBubble(text: text, timestamp: timestamp)
        case .planAssistantMessage(let text, let timestamp):
            planAssistantBubble(text: text, timestamp: timestamp)
        case .agentResponse(let run):
            chatAgentBubble(run: run)
        case .scheduleResult(let text, let timestamp):
            scheduleResultBubble(text: text, timestamp: timestamp)
        case .systemInfo(let text, let timestamp):
            systemInfoBubble(text: text, timestamp: timestamp)
        case .recapResult(let text, let timestamp):
            recapBubble(text: text, timestamp: timestamp)
        }
    }

    private func chatBottomPositionReader() -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChatBottomPositionPreferenceKey.self,
                value: proxy.frame(in: .named("task-chat-scroll")).minY
            )
        }
    }

    private func chatTopPositionReader() -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChatTopPositionPreferenceKey.self,
                value: proxy.frame(in: .named("task-chat-scroll")).minY
            )
        }
    }

    private func handleChatTopPositionChange(topMinY: CGFloat) {
        guard topMinY > -300 else { return }
        guard currentThreadSnapshot.omittedRunCount > 0 else { return }
        guard !isExpandingWindow else { return }
        isExpandingWindow = true
        expansionAnchorItemID = currentThreadSnapshot.conversationItems.first?.id
        threadViewModel.expandWindow(for: task)
    }

    @ViewBuilder
    private func newActivityPill(proxy: ScrollViewProxy) -> some View {
        if hasUnseenChatActivity && !isChatAtBottom {
            Button {
                scrollChatToBottom(proxy)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                        .font(Stanford.ui(11))
                    Text("Jump to latest")
                        .font(Stanford.chatSection())
                }
                .foregroundStyle(Stanford.lagunita)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThickMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Stanford.lagunita.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Jump to latest activity")
            .padding(.bottom, 10)
        }
    }

    private func updateChatBottomState(bottomMinY: CGFloat, viewportHeight: CGFloat) {
        let wasAtBottom = isChatAtBottom
        isChatAtBottom = bottomMinY <= viewportHeight + 80
        if isChatAtBottom && !wasAtBottom {
            hasUnseenChatActivity = false
        }
    }

    private func handleThreadScrollChange(
        oldSignature: String,
        newSignature: String,
        proxy: ScrollViewProxy
    ) {
        guard oldSignature != newSignature else { return }

        if let anchorID = expansionAnchorItemID {
            expansionAnchorItemID = nil
            isExpandingWindow = false
            DispatchQueue.main.async {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            return
        }

        if pendingInitialChatScrollTaskID == task.id {
            scrollChatToBottomAfterLayout(proxy, animated: false)
            shouldScrollAfterUserMessage = false
            if currentSnapshotMatchesTaskHistory {
                pendingInitialChatScrollTaskID = nil
            }
            return
        }

        if shouldScrollAfterUserMessage || isChatAtBottom {
            scrollChatToBottom(proxy)
            shouldScrollAfterUserMessage = false
            return
        }

        hasUnseenChatActivity = true
    }

    private var currentSnapshotMatchesTaskHistory: Bool {
        currentThreadSnapshot.totalEventCount >= task.events.count
            && currentThreadSnapshot.totalRunCount >= task.runs.count
    }

    private func scrollChatToBottomAfterLayout(_ proxy: ScrollViewProxy, animated: Bool) {
        scrollChatToBottom(proxy, animated: animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scrollChatToBottom(proxy, animated: animated)
        }
    }

    private func scrollChatToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        hasUnseenChatActivity = false
        shouldScrollAfterUserMessage = false
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        }
    }

    private var isScheduleStatusError: Bool {
        guard let msg = currentScheduleStatusMessage else { return false }
        return msg.hasPrefix("Failed") || msg.hasPrefix("Could not") || msg.hasPrefix("Invalid")
    }

    // MARK: - Chat Bubbles

    private func chatUserBubble(text: String, timestamp _: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 4) {
                Text(MarkdownTextView.markdownAttributed(text))
                    .font(Stanford.chatBody())
                    .lineSpacing(Stanford.chatBodyLineSpacing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.primary.opacity(0.028))
                    .foregroundStyle(Stanford.readingText)
                    .tint(Stanford.link)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 16,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: 16
                    ))
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: 16,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 16
                        )
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your message: \(text)")
    }

    private func scheduleResultBubble(text: String, timestamp _: Date) -> some View {
        timelineEventRow(
            text: text,
            icon: "arrow.triangle.2.circlepath",
            tint: Stanford.poppy
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Routine result: \(text)")
    }

    private func systemInfoBubble(text: String, timestamp _: Date) -> some View {
        timelineEventRow(
            text: text,
            icon: "info.circle",
            tint: Stanford.coolGrey
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("System notice: \(text)")
    }

    private func timelineEventRow(
        text: String,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Rectangle()
                .fill(Stanford.sandstone.opacity(0.36))
                .frame(height: 1)
                .frame(maxWidth: 60)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .font(Stanford.ui(11, weight: .medium))
                    .foregroundStyle(tint)
                Text(MarkdownTextView.markdownAttributed(text))
                    .font(Stanford.chatMeta(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .tint(Stanford.link)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)

            Rectangle()
                .fill(Stanford.sandstone.opacity(0.36))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
    }

    private func recapBubble(text: String, timestamp _: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.paloAltoGreen)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                MarkdownTextView(
                    text: text,
                    maxContentWidth: Stanford.chatParagraphMaxWidth,
                    onSuggestedNextStep: pursueSuggestedNextStep
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.024))
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Stanford.paloAltoGreen.opacity(0.72))
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }

            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task recap")
    }

    private func planAssistantBubble(text: String, timestamp _: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "list.bullet.clipboard")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                MarkdownTextView(
                    text: text,
                    maxContentWidth: Stanford.chatParagraphMaxWidth,
                    onSuggestedNextStep: pursueSuggestedNextStep
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.024))
            .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Stanford.lagunita.opacity(0.72))
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }

            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Planning response")
    }

    private func chatAgentBubble(run: TaskRunSnapshot) -> some View {
        let activity = currentThreadSnapshot.activity(for: run)
        let protocolState = currentThreadSnapshot.protocolState(for: run)
        let outputPresentation = currentThreadSnapshot.outputPresentation(for: run)
        let displayNotices = runNoticesToDisplay(activity.notices, for: run)
        let actionableNotices = displayNotices.filter { isActionableRunNotice($0, for: run) }
        let runActivityPresentation = currentThreadSnapshot.activityPresentation(for: run)
        let hasUserFacingOutput = outputPresentation.hasDisplayText && !run.hasVPNWarning
        let showsGeneratedFiles = run.id == latestRun?.id && run.status != .running && !threadViewModel.generatedFilePaths.isEmpty
        let copyText = outputPresentation.hasDisplayText ? outputPresentation.displayText : (protocolState.completionSummary ?? "")
        let showResponseActions = run.status != .running

        return VStack(alignment: .leading, spacing: 8) {
            if hasUserFacingOutput {
                if run.status == .running {
                    StreamingAgentTextView(displayText: outputPresentation.displayText)
                } else {
                    CompletedAgentMarkdownView(
                        displayText: outputPresentation.displayText,
                        onSuggestedNextStep: pursueSuggestedNextStep
                    )
                    .equatable()
                }
            }

            if run.completedWithoutUserFacingResult && !showsGeneratedFiles && !protocolState.hasCompletion {
                completedEmptyRunNotice()
            }

            // Generated files belong with the finished turn, not the live progress row.
            if showsGeneratedFiles {
                AgentGeneratedFilesListView(
                    paths: threadViewModel.generatedFilePaths,
                    onOpen: onOpenGeneratedFile
                )
            }

            if protocolState.hasCompletion {
                agentCompletionPanel(protocolState)
            }

            if run.hasVPNWarning {
                networkAccessNotice()
                if !run.output.isEmpty {
                    networkAccessTechnicalDetails(run)
                }
            }

            if run.status == .cancelled {
                runCancellationNotice(run)
            }

            ForEach(actionableNotices) { notice in
                runNoticeView(notice, prominence: .actionable)
            }

            if showResponseActions || shouldShowRunFooterSummary(run) {
                HStack(spacing: 12) {
                    if showResponseActions {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copyText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(Stanford.ui(12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                        .help("Copy")

                        if !activity.fileChanges.isEmpty {
                            Button {
                                isShowingFilesPopover = true
                            } label: {
                                Image(systemName: "doc.text")
                                    .font(Stanford.ui(12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                            .help("\(activity.fileChanges.count) changed files")
                        }

                        Button {
                            forkTask(from: run)
                        } label: {
                            Image(systemName: "arrow.branch")
                            .font(Stanford.ui(12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.coolGrey.opacity(0.7))
                        .help("Fork from here")
                    }

                    runFooterSummaryLabel(
                        run: run,
                        presentation: runActivityPresentation,
                        notices: displayNotices
                    )
                }
                .padding(.top, 2)
            }

            if shouldShowRunActivityDisclosure(runActivityPresentation) {
                runActivityDisclosure(
                    run: run,
                    presentation: runActivityPresentation,
                    notices: displayNotices
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent response")
    }

    private func completedEmptyRunNotice() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.poppy)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("Provider returned no result")
                    .font(Stanford.chatSection())
                    .foregroundStyle(Stanford.poppy)
                Text("The run finished without text output or a visible generated file. Retry this task or switch providers.")
                    .font(Stanford.chatSection())
                    .foregroundStyle(Stanford.readingText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func runFooterSummaryLabel(
        run: TaskRunSnapshot,
        presentation: RunActivityPresentation,
        notices: [TaskRunNotice]
    ) -> some View {
        if run.status == .running && run.completedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(runFooterSummaryParts(
                    run: run,
                    presentation: presentation,
                    notices: notices,
                    now: context.date
                ).joined(separator: " · "))
                    .font(Stanford.chatMeta())
                    .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                    .monospacedDigit()
            }
        } else {
            Text(runFooterSummaryParts(
                run: run,
                presentation: presentation,
                notices: notices,
                now: Date()
            ).joined(separator: " · "))
                .font(Stanford.chatMeta())
                .foregroundStyle(Stanford.coolGrey.opacity(0.5))
                .monospacedDigit()
        }
    }

    private func shouldShowRunFooterSummary(_ run: TaskRunSnapshot) -> Bool {
        run.status != .running && (run.completedAt != nil || run.tokensUsed > 0 || run.exitCode != nil || !run.stopReason.isEmpty)
    }

    private func runFooterSummaryParts(
        run: TaskRunSnapshot,
        presentation: RunActivityPresentation,
        notices: [TaskRunNotice],
        now: Date
    ) -> [String] {
        var parts = [runFooterStatusLabel(run: run, notices: notices)]
        let toolCallCount = presentation.tools.reduce(0) { $0 + $1.count }
        if toolCallCount > 0 {
            parts.append("\(toolCallCount) tool \(toolCallCount == 1 ? "call" : "calls")")
        }
        if presentation.files.count > 0 {
            parts.append("\(presentation.files.count) \(presentation.files.count == 1 ? "file" : "files")")
        }
        if shouldShowBudgetTokenCount(run) {
            let used = max(task.tokensUsed, run.tokensUsed)
            parts.append("Budget \(Formatters.formatTokens(used))/\(Formatters.formatTokens(task.tokenBudget))")
        }
        if let duration = runFooterDurationLabel(run, now: now) {
            parts.append(duration)
        }
        return parts
    }

    private func runFooterStatusLabel(run: TaskRunSnapshot, notices: [TaskRunNotice]) -> String {
        if run.status == .running {
            return "Running"
        }
        if runStoppedByPolicy(run, notices: notices) {
            return "Blocked"
        }
        if runStoppedBySystem(run, notices: notices) {
            return "Stopped"
        }
        switch run.status {
        case .completed: return TaskPresentationState.reviewPresentation(status: .completed, isClosed: false).runOutcomeLabel
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .budgetExceeded: return "Over budget"
        case .timeout: return "Timed out"
        case .running: return "Running"
        }
    }

    private func runFooterDurationLabel(_ run: TaskRunSnapshot, now: Date) -> String? {
        if run.status == .running && run.completedAt == nil {
            return "Working for \(formatChatDuration(Int(now.timeIntervalSince(run.startedAt))))"
        }
        guard let completed = run.completedAt else { return nil }
        return "Worked for \(formatChatDuration(Int(completed.timeIntervalSince(run.startedAt))))"
    }

    private func shouldShowBudgetTokenCount(_ run: TaskRunSnapshot) -> Bool {
        guard task.tokenBudget > 0 else { return false }
        let used = max(task.tokensUsed, run.tokensUsed)
        return task.status == .budgetExceeded || Double(used) >= Double(task.tokenBudget) * 0.8
    }

    private func shouldShowRunActivityDisclosure(_ presentation: RunActivityPresentation) -> Bool {
        presentation.hasVisibleDetails
    }

    @ViewBuilder
    private func runActivityDisclosure(
        run: TaskRunSnapshot,
        presentation: RunActivityPresentation,
        notices: [TaskRunNotice]
    ) -> some View {
        if run.status == .running && run.completedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                runActivityDisclosureContent(
                    run: run,
                    presentation: presentation,
                    notices: notices,
                    now: context.date
                )
            }
        } else {
            runActivityDisclosureContent(
                run: run,
                presentation: presentation,
                notices: notices,
                now: Date()
            )
        }
    }

    private func runActivityDisclosureContent(
        run: TaskRunSnapshot,
        presentation: RunActivityPresentation,
        notices: [TaskRunNotice],
        now: Date
    ) -> some View {
        let isExpanded = expandedRunActivity.contains(run.id)
        let accent = runActivitySummaryColor(run: run, notices: notices)
        let title = runActivityDisclosureTitle(run: run, notices: notices)
        let parts = runActivitySummaryParts(run: run, presentation: presentation, notices: notices, now: now)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(chatStatusDisclosureAnimation) {
                    if isExpanded {
                        expandedRunActivity.remove(run.id)
                    } else {
                        expandedRunActivity.insert(run.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10))
                        .frame(width: 12)
                    if run.status != .running {
                        Image(systemName: runActivitySummaryIcon(run: run, notices: notices))
                            .font(Stanford.ui(12))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(Stanford.chatSection())
                                .lineLimit(1)
                                .layoutPriority(1)
                            if run.status == .running {
                                runActivityLiveBadge(run: run, now: now)
                                    .fixedSize()
                            }
                        }
                        if !parts.isEmpty {
                            Text(parts.joined(separator: " · "))
                                .font(Stanford.chatMeta())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 8)
                }
                .foregroundStyle(accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                runActivityDetails(run: run, presentation: presentation)
                    .transition(chatStatusDetailsTransition)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(TaskThreadStatusChrome.runActivityBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(parts.joined(separator: ", "))")
        .transition(chatStatusBlockTransition)
    }

    private func runActivityDisclosureTitle(run: TaskRunSnapshot, notices: [TaskRunNotice]) -> String {
        if run.status == .running {
            let message = runtimeHealth.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Agent is working..." : message
        }
        return "Details"
    }

    private func runActivityDetails(
        run: TaskRunSnapshot,
        presentation: RunActivityPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !presentation.approvals.isEmpty {
                runActivityDetailSection(
                    title: presentation.approvals.count == 1 ? "Permission" : "Permissions",
                    systemImage: "hand.raised"
                ) {
                    permissionApprovalList(presentation.approvals)
                }
            }

            if !presentation.issues.isEmpty {
                runActivityDetailSection(
                    title: presentation.issues.count == 1 ? "Issue" : "Issues",
                    systemImage: "exclamationmark.circle"
                ) {
                    ForEach(presentation.issues) { issue in
                        runIssueView(issue)
                    }
                }
            }

            if !presentation.progressMessages.isEmpty {
                runActivityDetailSection(
                    title: presentation.progressMessages.count == 1 ? "Progress" : "Progress updates",
                    systemImage: "text.bubble"
                ) {
                    progressMessageList(presentation.progressMessages)
                }
            }

            if !presentation.tools.isEmpty {
                runActivityDetailSection(title: "Tool activity", systemImage: "wrench.and.screwdriver") {
                    toolActivityList(presentation.tools)
                }
            }

            if !presentation.files.isEmpty {
                runActivityDetailSection(title: "Files", systemImage: "doc.text") {
                    Button {
                        isShowingFilesPopover = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(Stanford.ui(11))
                            Text("\(presentation.files.count) changed \(presentation.files.count == 1 ? "file" : "files")")
                                .font(Stanford.chatSection())
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right")
                                .font(Stanford.ui(10))
                        }
                        .foregroundStyle(Stanford.lagunita)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let policy = presentation.policy {
                runActivityDetailSection(title: "Policy", systemImage: "checklist.shield") {
                    runPolicySummaryView(policy, for: run)
                }
            }

            if !presentation.technicalOutputs.isEmpty {
                runActivityDetailSection(title: "Technical output", systemImage: "terminal") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presentation.technicalOutputs) { output in
                            technicalOutputView(output)
                        }
                    }
                }
            }

            if !presentation.stats.isEmpty {
                runActivityDetailSection(title: "Stats", systemImage: "chart.bar") {
                    factList(presentation.stats)
                }
            }
        }
        .padding(.top, 2)
    }

    private func runActivityDetailSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(Stanford.chatMeta())
                .foregroundStyle(Stanford.coolGrey.opacity(0.86))
            content()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(TaskThreadStatusChrome.runActivityDetailBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(0.052), lineWidth: 1)
        )
    }

    private func runActivitySummaryParts(
        run: TaskRunSnapshot,
        presentation: RunActivityPresentation,
        notices: [TaskRunNotice],
        now: Date
    ) -> [String] {
        var parts: [String] = []
        let toolCallCount = presentation.tools.reduce(0) { $0 + $1.count }
        let progressCount = presentation.progressMessages.count
        let approvalCount = presentation.approvals.count
        let warningCount = presentation.issues.filter { $0.severity == .warning }.count
        let issueCount = presentation.issues.filter { $0.severity == .error }.count

        if toolCallCount > 0 {
            parts.append("\(toolCallCount) tool \(toolCallCount == 1 ? "call" : "calls")")
        }
        if progressCount > 0 {
            parts.append("\(progressCount) progress \(progressCount == 1 ? "update" : "updates")")
        }
        if warningCount > 0 {
            parts.append("\(warningCount) \(warningCount == 1 ? "warning" : "warnings")")
        }
        if approvalCount > 0 {
            if approvalCount == 1, let approval = presentation.approvals.first {
                parts.append(approval.decision.compactAuditSummary)
            } else {
                parts.append("\(approvalCount) permissions requested")
            }
        } else if runStoppedByPolicy(run, notices: notices) {
            parts.append("stopped by policy")
        } else if runStoppedBySystem(run, notices: notices) {
            parts.append("stopped by system")
        } else if issueCount > 0 {
            parts.append("\(issueCount) \(issueCount == 1 ? "issue" : "issues")")
        }
        if presentation.files.count > 0 {
            parts.append("\(presentation.files.count) \(presentation.files.count == 1 ? "file" : "files") changed")
        }
        if presentation.policy != nil && !parts.contains(where: { $0.contains("policy") }) {
            parts.append("policy")
        }
        if presentation.technicalOutputs.count > 0 && toolCallCount == 0 {
            parts.append("\(presentation.technicalOutputs.count) technical \(presentation.technicalOutputs.count == 1 ? "output" : "outputs")")
        }
        guard !parts.isEmpty else { return [runStatusLabel(run).lowercased()] }
        return Array(parts.prefix(4))
    }

    private func runActivityLiveBadge(run: TaskRunSnapshot, now: Date) -> some View {
        let elapsed = compactLiveDuration(Int(now.timeIntervalSince(run.startedAt)))
        let pulse = (sin(now.timeIntervalSinceReferenceDate * (2 * Double.pi / 2.8)) + 1) / 2
        let dotOpacity = 0.48 + (pulse * 0.22)
        let dotScale = 0.92 + (pulse * 0.08)

        return HStack(spacing: 4) {
            Circle()
                .fill(Stanford.lagunita.opacity(dotOpacity))
                .frame(width: 4.5, height: 4.5)
                .scaleEffect(dotScale)
                .animation(.easeInOut(duration: 1.2), value: dotOpacity)
            Text("Live · \(elapsed)")
                .font(Stanford.chatMeta(10))
                .foregroundStyle(Stanford.lagunita.opacity(0.9))
                .monospacedDigit()
        }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Stanford.lagunita.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
            )
    }

    private func compactLiveDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainingSeconds = clamped % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

    private func runActivitySummaryIcon(run: TaskRunSnapshot, notices: [TaskRunNotice]) -> String {
        if run.status == .running {
            return "arrow.triangle.2.circlepath"
        }
        if notices.contains(where: { $0.type == "permission.approval.requested" }) {
            return "hand.raised"
        }
        if runStoppedByPolicy(run, notices: notices) {
            return "shield.slash"
        }
        if runStoppedBySystem(run, notices: notices) {
            return "octagon"
        }
        if notices.contains(where: { $0.type == "error" || $0.type == "budget.exceeded" }) {
            return "exclamationmark.circle"
        }
        if notices.contains(where: { $0.type == "budget.warning" }) {
            return "exclamationmark.triangle"
        }
        return "list.bullet.rectangle"
    }

    private func runActivitySummaryColor(run: TaskRunSnapshot, notices: [TaskRunNotice]) -> Color {
        if run.status == .running {
            return Stanford.lagunita
        }
        if runStoppedByPolicy(run, notices: notices) || runStoppedBySystem(run, notices: notices) {
            return Stanford.poppy
        }
        if notices.contains(where: { $0.type == "error" || $0.type == "budget.exceeded" }) {
            return Stanford.failed
        }
        if notices.contains(where: { $0.type == "budget.warning" }) {
            return Stanford.poppy
        }
        return Stanford.coolGrey
    }

    private func isActionableRunNotice(_ notice: TaskRunNotice, for run: TaskRunSnapshot) -> Bool {
        TaskRunNoticePresentationRules.shouldShowInline(notice, for: run)
    }

    private func runStoppedByPolicy(_ run: TaskRunSnapshot, notices: [TaskRunNotice]) -> Bool {
        let stopReason = run.stopReason.lowercased()
        return stopReason.contains("policy") ||
            notices.contains(where: runNoticeLooksPolicyBlocked)
    }

    private func runStoppedBySystem(_ run: TaskRunSnapshot, notices: [TaskRunNotice]) -> Bool {
        guard run.status == .failed else { return false }
        let stopReason = run.stopReason.lowercased()
        if stopReason.contains("stopped") ||
            stopReason.contains("blocked") ||
            stopReason.contains("controlled") ||
            stopReason.contains("browser") {
            return true
        }

        return notices.contains { notice in
            let payload = notice.payload.lowercased()
            return payload.contains("astra stopped") ||
                payload.contains("controlled mode") ||
                payload.contains("controlled browser") ||
                payload.contains("safe edit path") ||
                payload.contains("did not fall back")
        }
    }

    private func runNoticeLooksPolicyBlocked(_ notice: TaskRunNotice) -> Bool {
        guard notice.type == "error" else { return false }
        let payload = notice.payload.lowercased()
        return payload.contains("violated the run policy") ||
            payload.contains("provider allow-list") ||
            payload.contains("policy violation") ||
            payload.contains("not in the provider allow-list")
    }

    private func runPolicySummaryView(_ policy: PolicySummaryPresentation, for run: TaskRunSnapshot) -> some View {
        let isExpanded = expandedRunPolicyManifests.contains(run.id)
        let color = policy.badge == nil ? Stanford.coolGrey : Stanford.poppy
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(chatStatusDisclosureAnimation) {
                    if isExpanded {
                        expandedRunPolicyManifests.remove(run.id)
                    } else {
                        expandedRunPolicyManifests.insert(run.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checklist.shield")
                        .font(Stanford.ui(11))
                        .frame(width: 14)
                    Text(policy.title)
                        .font(Stanford.chatSection())
                        .foregroundStyle(Stanford.black)
                    Text(policy.subtitle)
                        .font(Stanford.chatMeta())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let badge = policy.badge {
                        Text(badge)
                            .font(Stanford.chatMeta(10))
                            .foregroundStyle(Stanford.poppy)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10))
                }
                .foregroundStyle(color)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    factList(policy.facts)
                    if let rawPayload = policy.rawPayload, !rawPayload.isEmpty {
                        rawOutputDisclosure(rawPayload)
                    }
                }
                .transition(chatStatusDetailsTransition)
            }
        }
        .padding(.vertical, 1)
    }

    private func runIssueView(_ issue: RunIssuePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: issueIcon(issue.severity))
                    .font(Stanford.ui(12))
                    .foregroundStyle(issueColor(issue.severity))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(Stanford.chatSection())
                        .foregroundStyle(issueColor(issue.severity))
                    Text(issue.summary)
                        .font(Stanford.chatSection())
                        .foregroundStyle(Stanford.readingText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if let rawPayload = issue.rawPayload, !rawPayload.isEmpty {
                rawOutputDisclosure(rawPayload)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 1)
    }

    private func technicalOutputView(_ output: TechnicalOutputPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: output.severity == .error ? "xmark.octagon" : "doc.text.magnifyingglass")
                    .font(Stanford.ui(12))
                    .foregroundStyle(issueColor(output.severity))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.title)
                        .font(Stanford.chatSection())
                        .foregroundStyle(Stanford.black)
                    if !output.summary.isEmpty {
                        Text(output.summary)
                            .font(Stanford.chatSection())
                            .foregroundStyle(Stanford.coolGrey)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            if !output.facts.isEmpty {
                factList(output.facts)
                    .padding(.leading, 22)
            }
            if !output.rawPayload.isEmpty {
                rawOutputDisclosure(output.rawPayload)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 1)
    }

    private func progressMessageList(_ messages: [TaskRunProgressMessage]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(messages) { message in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(Stanford.ui(11))
                        .foregroundStyle(Stanford.coolGrey)
                        .frame(width: 14)
                    Text(message.text)
                        .font(Stanford.chatSection())
                        .foregroundStyle(Stanford.coolGrey)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func factList(_ facts: [RunFactPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(facts) { fact in
                HStack(alignment: .top, spacing: 8) {
                    Text(fact.title)
                        .font(Stanford.chatMeta())
                        .foregroundStyle(.secondary)
                        .frame(width: 112, alignment: .leading)
                    Text(fact.value)
                        .font(fact.isMonospaced ? Stanford.chatRaw(11) : Stanford.chatMeta())
                        .foregroundStyle(Stanford.readingText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func rawOutputDisclosure(_ rawPayload: String, label: String = "Show raw output") -> some View {
        DisclosureGroup {
            rawOutputBlock(rawPayload)
                .padding(.top, 4)
        } label: {
            Text(label)
                .font(Stanford.chatMeta())
                .foregroundStyle(Stanford.coolGrey)
        }
        .accentColor(Stanford.coolGrey)
    }

    private func rawOutputBlock(_ rawPayload: String) -> some View {
        let displayContent = rawPayload.count > 5000 ? String(rawPayload.prefix(5000)) + "\n... (truncated)" : rawPayload
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(displayContent)
                .font(Stanford.chatRaw())
                .foregroundStyle(Stanford.coolGrey)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: 180, alignment: .leading)
        .background(Stanford.fog.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func issueColor(_ severity: RunActivitySeverity) -> Color {
        switch severity {
        case .info: Stanford.coolGrey
        case .warning: Stanford.poppy
        case .error: Stanford.failed
        }
    }

    private func issueIcon(_ severity: RunActivitySeverity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func policyColor(_ level: AgentPolicyLevel) -> Color {
        switch level {
        case .locked: Stanford.failed
        case .review: Stanford.paloAltoGreen
        case .build: Stanford.lagunita
        case .network: Stanford.sky
        case .autonomous: Stanford.lagunita
        case .custom: Stanford.plum
        }
    }

    private func runNoticeView(
        _ notice: TaskRunNotice,
        prominence: RunNoticeProminence
    ) -> some View {
        let presentation = runNoticePresentation(for: notice)
        let body = runNoticeBody(for: notice)
        let isCollapsible = prominence == .actionable
        let isExpanded = !isCollapsible || expandedRunNotices.contains(notice.id)
        let rawDetail = isExpanded ? runNoticeRawDetail(for: notice, body: body) : nil
        let strokeOpacity = prominence == .actionable ? 0.12 : 0.08

        return VStack(alignment: .leading, spacing: isExpanded ? 6 : 0) {
            if isCollapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isExpanded {
                            expandedRunNotices.remove(notice.id)
                        } else {
                            expandedRunNotices.insert(notice.id)
                        }
                    }
                } label: {
                    runNoticeTitleRow(
                        presentation: presentation,
                        showsChevron: true,
                        isExpanded: isExpanded
                    )
                }
                .buttonStyle(.plain)
            } else {
                runNoticeTitleRow(
                    presentation: presentation,
                    showsChevron: false,
                    isExpanded: true
                )
            }

            if isExpanded {
                runNoticeDetailBody(body: body, rawDetail: rawDetail)
                    .padding(.leading, isCollapsible ? 32 : 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isExpanded ? 8 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(TaskThreadStatusChrome.runNoticeBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(presentation.color.opacity(strokeOpacity), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(presentation.color.opacity(prominence == .actionable ? 0.72 : 0.46))
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(runNoticeAccessibilityLabel(
            title: presentation.title,
            body: body,
            isCollapsible: isCollapsible,
            isExpanded: isExpanded
        ))
    }

    private func permissionApprovalList(_ approvals: [RuntimePermissionApprovalNoticePresentation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approvals) { approval in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "hand.raised")
                            .font(Stanford.ui(11))
                            .foregroundStyle(Stanford.coolGrey.opacity(0.82))
                            .frame(width: 16)
                        Text(approval.decision.compactAuditSummary)
                            .font(Stanford.chatSection())
                            .foregroundStyle(Stanford.readingText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }

                    Text(approval.decision.scope)
                        .font(Stanford.chatMeta())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 23)

                    if let rawPayload = approval.rawPayload {
                        rawOutputDisclosure(rawPayload, label: "Show permission details")
                            .padding(.leading, 23)
                    }
                }
            }
        }
    }

    private func runNoticeTitleRow(
        presentation: (title: String, icon: String, color: Color),
        showsChevron: Bool,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 7) {
            if showsChevron {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Stanford.ui(10))
                    .foregroundStyle(presentation.color.opacity(0.82))
                    .frame(width: 12)
            }

            Image(systemName: presentation.icon)
                .font(Stanford.ui(12))
                .foregroundStyle(presentation.color)
                .frame(width: 16)

            Text(presentation.title)
                .font(Stanford.chatSection())
                .foregroundStyle(presentation.color)

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    private func runNoticeDetailBody(body: String, rawDetail: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(body)
                .font(Stanford.chatSection())
                .foregroundStyle(Stanford.readingText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let rawDetail {
                rawOutputDisclosure(rawDetail)
                    .padding(.top, 2)
            }
        }
    }

    private func runNoticeAccessibilityLabel(
        title: String,
        body: String,
        isCollapsible: Bool,
        isExpanded: Bool
    ) -> String {
        guard isCollapsible else { return "\(title). \(body)" }
        return isExpanded ? "\(title). \(body)" : "\(title). Collapsed. Expand for details."
    }

    private func runNoticesToDisplay(_ notices: [TaskRunNotice], for run: TaskRunSnapshot) -> [TaskRunNotice] {
        guard run.hasVPNWarning else { return notices }
        return notices.filter { $0.type != "error" }
    }

    private func networkAccessNotice() -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(Stanford.ui(17))
                .foregroundStyle(Stanford.statusInfo)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Network access needed")
                        .font(Stanford.chatSection())
                        .foregroundStyle(Stanford.readingText)
                    Text("This task needs your organization's network. Connect to VPN, then retry.")
                        .font(Stanford.chatMeta(13))
                        .foregroundStyle(Stanford.readingText)
                        .lineSpacing(Stanford.chatCompactLineSpacing)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        networkAccessStep("Connect VPN", systemImage: "checkmark.shield")
                        networkAccessStep("Press Retry", systemImage: "arrow.clockwise")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        networkAccessStep("Connect VPN", systemImage: "checkmark.shield")
                        networkAccessStep("Press Retry", systemImage: "arrow.clockwise")
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .background(Stanford.statusInfo.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Stanford.statusInfo.opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network access needed. Connect to VPN, then retry.")
        .transition(chatStatusBlockTransition)
    }

    private func networkAccessStep(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(Stanford.chatMeta())
            .foregroundStyle(Stanford.statusInfo)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Stanford.statusInfo.opacity(0.10))
            .clipShape(Capsule())
    }

    private func networkAccessTechnicalDetails(_ run: TaskRunSnapshot) -> some View {
        let isExpanded = expandedRunNetworkDetails.contains(run.id)
        let presentation = NetworkAccessTechnicalDetailsPresentation(output: run.output)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(chatStatusDisclosureAnimation) {
                    if isExpanded {
                        expandedRunNetworkDetails.remove(run.id)
                    } else {
                        expandedRunNetworkDetails.insert(run.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10))
                    Text("Technical details")
                        .font(Stanford.chatSection())
                    Spacer(minLength: 8)
                    Text(presentation.subtitle)
                        .font(Stanford.chatMeta())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(Stanford.coolGrey)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(presentation.summary)
                        .font(Stanford.chatMeta(12))
                        .foregroundStyle(Stanford.readingText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if !presentation.facts.isEmpty {
                        factList(presentation.facts)
                    }

                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(presentation.copyText, forType: .string)
                        } label: {
                            Label("Copy diagnostics", systemImage: "doc.on.doc")
                                .font(Stanford.chatMeta())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.statusInfo)
                        .help("Copy parsed diagnostics and the raw provider response")

                        Spacer(minLength: 0)
                    }

                    rawOutputDisclosure(presentation.rawPayload, label: "Show raw provider response")
                }
                .padding(10)
                .background(Stanford.fog.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(chatStatusDetailsTransition)
            }
        }
        .transition(chatStatusBlockTransition)
    }

    private func runNoticePresentation(for notice: TaskRunNotice) -> (title: String, icon: String, color: Color) {
        switch notice.type {
        case "budget.warning":
            ("Budget warning", "exclamationmark.triangle", Stanford.poppy)
        case "budget.exceeded":
            ("Budget exceeded", "xmark.octagon", Stanford.failed)
        case "permission.approval.requested":
            ("Permission requested", "hand.raised", Stanford.coolGrey)
        case "astra.permission_summary":
            ("Permission summary", "checklist.shield", Stanford.coolGrey)
        case "error":
            runNoticeLooksPolicyBlocked(notice)
                ? ("Policy blocked this run", "shield.slash", Stanford.failed)
                : ("Run stopped", "xmark.octagon", Stanford.failed)
        default:
            ("Notice", "info.circle", Stanford.coolGrey)
        }
    }

    private func runNoticeBody(for notice: TaskRunNotice) -> String {
        switch notice.type {
        case "budget.warning":
            return budgetWarningBody(for: notice.payload)
        case "budget.exceeded":
            return "This task exceeded its budget. Resume with a higher budget or retry with a narrower request."
        case "permission.approval.requested":
            return permissionApprovalBody(for: notice.payload)
        case "error" where runNoticeLooksPolicyBlocked(notice):
            return "ASTRA stopped this run because the requested action is outside the current policy. Review the policy or retry with broader permissions."
        case "error":
            return providerErrorBody(for: notice.payload)
        default:
            break
        }

        guard notice.type == "astra.permission_summary",
              let data = notice.payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return notice.payload
        }

        let status = json["status"] as? String ?? "unknown"
        let stopReason = json["stopReason"] as? String ?? "unknown"
        let tools = json["toolUseCount"] as? Int ?? 0
        let denied = json["deniedCount"] as? Int ?? 0
        let files = json["fileChangeCount"] as? Int ?? 0
        let toolsUsed = (json["toolsUsed"] as? [String] ?? []).prefix(6).joined(separator: ", ")
        let commands = (json["commandsRun"] as? [String] ?? []).prefix(3).joined(separator: " | ")
        let domains = (json["externalDomains"] as? [String] ?? []).prefix(4).joined(separator: ", ")
        let envKeys = (json["environmentKeyNames"] as? [String] ?? []).prefix(6).joined(separator: ", ")
        let approvals = (json["approvalsGranted"] as? [String] ?? []).prefix(3).joined(separator: ", ")
        let broad = (json["usedBroadProviderPermissions"] as? Bool ?? false) ? "yes" : "no"
        let escalated = (json["exceededInitialPermissionLevel"] as? Bool ?? false) ? "yes" : "no"

        var parts = [
            "Status: \(status)",
            "Stop reason: \(stopReason)",
            "Tools used: \(tools)",
            "Permission denials/requests: \(denied)",
            "Files changed: \(files)",
            "Broad provider permissions: \(broad)",
            "Exceeded initial permission level: \(escalated)"
        ]
        if !toolsUsed.isEmpty { parts.append("Observed tools: \(toolsUsed)") }
        if !commands.isEmpty { parts.append("Commands: \(commands)") }
        if !domains.isEmpty { parts.append("External domains: \(domains)") }
        if !envKeys.isEmpty { parts.append("Env keys: \(envKeys)") }
        if !approvals.isEmpty { parts.append("Approvals: \(approvals)") }
        return parts.joined(separator: ". ") + "."
    }

    private func permissionApprovalBody(for payload: String) -> String {
        RuntimePermissionApprovalText(payload: payload).noticeBody
    }

    private var pendingApprovalSurfaceSummary: String {
        if let payload = latestRuntimePermissionRequestPayload {
            return RuntimePermissionApprovalText(payload: payload).compactSummary
        }
        return "\(task.resolvedRuntimeID.displayName) needs one-time permission before it can continue."
    }

    private func budgetWarningBody(for payload: String) -> String {
        let lower = payload.lowercased()
        if lower.contains("launch estimate") {
            return "This task may use more budget than expected. ASTRA continued because budget enforcement is set to warning mode."
        }
        if lower.contains("warning mode") || lower.contains("warning only") {
            return "This task has used more budget than expected. ASTRA kept it running because budget enforcement is set to warning mode."
        }
        return "This task may use more budget than expected. ASTRA continued because budget enforcement is set to warning mode."
    }

    private func providerErrorBody(for payload: String) -> String {
        let lower = payload.lowercased()
        if lower.contains("exited with code") || lower.contains("failed before astra received") {
            return "The provider stopped before returning a visible response. Retry the task or open run details for the technical output."
        }
        if payload.isEmpty {
            return "The provider stopped unexpectedly. Retry the task or open run details for diagnostics."
        }
        return String(payload.prefix(220))
    }

    private func runNoticeRawDetail(for notice: TaskRunNotice, body: String) -> String? {
        guard !notice.payload.isEmpty,
              notice.payload != body else {
            return nil
        }

        switch notice.type {
        case "budget.warning", "budget.exceeded", "error", "permission.approval.requested":
            return notice.payload
        default:
            return nil
        }
    }

    private func forkTask(from run: TaskRunSnapshot) {
        guard let sourceRun = task.runs.first(where: { $0.id == run.id }) else { return }
        let forked = AgentTask.fork(from: task, upToRun: sourceRun, in: modelContext)
        try? modelContext.save()
        onForkTask?(forked)
    }

    private func agentPlanPanel(items: [TaskProtocolTodoItem]) -> some View {
        let completedCount = items.filter(\.isDone).count
        let totalCount = items.count
        let progress = totalCount == 0 ? "No steps" : "\(completedCount)/\(totalCount) complete"

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(chatStatusDisclosureAnimation) {
                    isAgentPlanExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isAgentPlanExpanded ? "chevron.down" : "chevron.right")
                        .font(Stanford.ui(10))
                        .frame(width: 12)
                    Image(systemName: "checklist")
                        .font(Stanford.ui(12))
                    Text("Plan")
                        .font(Stanford.chatSection())
                    Text(progress)
                        .font(Stanford.chatMeta())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if completedCount == totalCount, totalCount > 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(Stanford.ui(11))
                            .foregroundStyle(Stanford.paloAltoGreen)
                    }
                }
                .foregroundStyle(Stanford.coolGrey)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isAgentPlanExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        agentPlanItemRow(item)
                    }
                }
                .padding(.top, 2)
                .transition(chatStatusDetailsTransition)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Stanford.fog.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Stanford.coolGrey.opacity(0.18), lineWidth: 1)
        )
        .transition(chatStatusBlockTransition)
    }

    private func agentPlanItemRow(_ item: TaskProtocolTodoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .font(Stanford.ui(12))
                .foregroundStyle(item.isDone ? Stanford.paloAltoGreen : Stanford.coolGrey)
                .frame(width: 14, height: 16)
            Text(item.text)
                .font(Stanford.chatMeta(13))
                .foregroundStyle(item.isDone ? Stanford.coolGrey : Stanford.black)
                .strikethrough(item.isDone, color: Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func agentCompletionPanel(_ state: TaskRunProtocolState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(Stanford.ui(15))
                .foregroundStyle(Stanford.paloAltoGreen)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                if let summary = state.completionSummary {
                    Text(summary)
                        .font(Stanford.chatBody(15))
                        .foregroundStyle(Stanford.readingText)
                        .lineSpacing(Stanford.chatCompactLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let verifiedBy = state.verifiedBy, !verifiedBy.isEmpty {
                    Text("Verified by \(verifiedBy)")
                        .font(Stanford.chatSection())
                        .foregroundStyle(Stanford.coolGrey)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Stanford.paloAltoGreen.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Stanford.paloAltoGreen.opacity(0.24), lineWidth: 1)
        )
    }

    private func runCancellationNotice(_ run: TaskRunSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(Stanford.ui(13))
                .foregroundStyle(Stanford.coolGrey)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.stopReason == "app_restarted" ? "Run interrupted" : "Run cancelled")
                    .font(Stanford.chatSection())
                    .foregroundStyle(Stanford.black)
                Text(run.stopReason == "app_restarted"
                     ? "ASTRA restarted before this run could finish. The preserved tool output below is from before the interruption."
                    : "This run stopped before completion. Any preserved tool output below is partial.")
                    .font(Stanford.chatMeta())
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Stanford.fog.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func toolActivityList(_ tools: [ToolActivityPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(tools) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: toolIcon(item.toolName))
                            .font(Stanford.ui(11))
                            .foregroundStyle(Stanford.coolGrey)
                            .frame(width: 14)
                        Text(item.toolName)
                            .font(Stanford.chatSection())
                            .foregroundStyle(Stanford.black)
                        Text(item.countLabel)
                            .font(Stanford.chatMeta())
                            .foregroundStyle(Stanford.coolGrey)
                        Spacer(minLength: 0)
                    }
                    if let detail = item.detail, !detail.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            if let detailLabel = item.detailLabel {
                                Text(detailLabel)
                                    .font(Stanford.chatMeta())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                            }
                            Text(detail)
                                .font(item.detailKind == .command ? Stanford.chatRaw(11) : Stanford.chatMeta())
                                .foregroundStyle(Stanford.coolGrey)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 20)
                    }
                    if item.rawPayloads.count > 1 {
                        rawOutputDisclosure(item.rawPayloads.joined(separator: "\n"))
                            .padding(.leading, 20)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    @ViewBuilder
    private func toolResultView(_ content: String) -> some View {
        rawOutputBlock(content)
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit", "MultiEdit": return "pencil"
        case "Bash", "Shell": return "terminal"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        case "Validation tests": return "checkmark.seal"
        case "AI self-check": return "sparkles"
        case "Workspace isolation": return "square.dashed.inset.filled"
        default: return "wrench"
        }
    }

    private func runStatusIcon(_ run: TaskRunSnapshot) -> String {
        switch run.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .budgetExceeded: return "exclamationmark.triangle.fill"
        case .running: return "circle.dotted"
        case .timeout: return "clock.badge.exclamationmark"
        }
    }

    private func runStatusColor(_ run: TaskRunSnapshot) -> Color {
        switch run.status {
        case .completed: return Stanford.paloAltoGreen
        case .failed, .budgetExceeded, .timeout: return Stanford.failed
        case .cancelled: return Stanford.coolGrey
        case .running: return Stanford.lagunita
        }
    }

    private func runStatusLabel(_ run: TaskRunSnapshot) -> String {
        switch run.status {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .budgetExceeded: return "Budget exceeded"
        case .running: return "Running"
        case .timeout: return "Timed out"
        }
    }

    // MARK: - Chat Thread

    private var sortedEvents: [TaskEventSnapshot] {
        currentThreadSnapshot.sortedEvents
    }

    private var latestRun: TaskRunSnapshot? {
        currentThreadSnapshot.latestRun
    }

    private var taskReviewPresentation: TaskReviewPresentation {
        TaskPresentationState.reviewPresentation(status: task.status, isClosed: task.isDone)
    }

    private var taskDecisionDockPresentation: TaskDecisionDockPresentation? {
        let plan = executableApprovedPlan
        let nextStep = plan.flatMap { TaskPlanService.nextExecutableStep(in: $0) }
        let planActionTitle = plan == nil ? nil : (skipPermissions ? "Run remaining plan" : "Approve next step")
        let planActionDetail = plan.map { nextStep.map { "Next: \($0.title)" } ?? $0.title }
        let planModeLabel = plan == nil
            ? nil
            : (skipPermissions
                ? "Auto mode runs every remaining step."
                : "Ask mode runs one approved step, then pauses again.")

        return TaskDecisionDockPresentation.build(TaskDecisionDockPresentation.Context(
            status: task.status,
            isClosed: task.isDone,
            review: taskReviewPresentation,
            mission: missionControlPresentation,
            verification: currentVerificationPresentation,
            pendingReviewState: pendingTaskReviewState,
            hasRuntimePermissionRequest: hasOpenRuntimePermissionApprovalRequest,
            runtimePermissionTitle: pendingRuntimePermissionDecision?.title,
            runtimePermissionSummary: pendingRuntimePermissionDecision?.summary,
            runtimePermissionScope: pendingRuntimePermissionDecision?.scope,
            runtimePermissionCommandPreview: pendingRuntimePermissionDecision?.commandPreview,
            runtimePermissionAllowSimilarLabel: pendingRuntimePermissionDecision?.allowSimilarLabel,
            canApproveSimilarRuntimePermission: canApproveSimilarRuntimePermissionForTask,
            hasExecutableApprovedPlan: plan != nil,
            planActionTitle: planActionTitle,
            planActionDetail: planActionDetail,
            planModeLabel: planModeLabel,
            canOpenPlan: onOpenPlan != nil,
            isPlanCanvasVisible: isPlanCanvasVisible,
            canRunApprovedPlan: taskQueue != nil,
            latestRunHasNoUsableResult: latestRunHasNoUsableResult,
            completedTaskNeedsArtifactAttention: completedTaskNeedsArtifactAttention,
            canCancel: onCancelTask != nil,
            canRun: onRunTask != nil,
            canApprove: onApproveTask != nil,
            canRetry: onRetryTask != nil,
            canResume: task.hasProviderSession && onResumeTask != nil,
            canToggleDone: canToggleTaskDoneFromDecisionDock,
            hasProviderSession: task.hasProviderSession,
            failureReason: failureReason,
            artifactPaths: taskDecisionArtifactPaths,
            extraDetails: taskDecisionExtraDetails
        ))
    }

    private var taskDecisionArtifactPaths: [String] {
        dedupePaths(threadViewModel.generatedFilePaths + task.artifacts.filter { !$0.isStale }.map(\.path))
    }

    private var taskDecisionExtraDetails: [TaskDecisionDockDetail] {
        var details: [TaskDecisionDockDetail] = []
        if task.status == .running {
            details.append(TaskDecisionDockDetail(
                id: "runtime-health",
                title: runtimeHealth.message,
                summary: runtimeHealth.detail ?? runtimeHealth.message,
                systemImage: runtimeHealth.isAttentionState ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath",
                tone: runtimeHealth.isAttentionState ? .attention : .running
            ))
        }

        if shouldShowPendingApprovalStatus && !hasOpenRuntimePermissionApprovalRequest {
            details.append(TaskDecisionDockDetail(
                id: "pending-approval",
                title: "Waiting for your approval",
                summary: pendingApprovalStatusDetail,
                systemImage: "person.crop.circle.badge.questionmark",
                tone: .attention
            ))
        }

        if isCreatingScheduleForCurrentTask {
            details.append(TaskDecisionDockDetail(
                id: "routine-creating",
                title: "Creating routine",
                summary: "ASTRA is creating the routine for this task.",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .running
            ))
        }

        if isGeneratingRecap {
            details.append(TaskDecisionDockDetail(
                id: "recap-generating",
                title: "Generating recap",
                summary: "ASTRA is summarizing the task conversation.",
                systemImage: "doc.text.magnifyingglass",
                tone: .running
            ))
        }

        if let msg = recapStatusMessage {
            details.append(TaskDecisionDockDetail(
                id: "recap-message",
                title: "Recap needs attention",
                summary: msg,
                systemImage: "exclamationmark.triangle",
                tone: .attention
            ))
        }

        if let statusMsg = currentScheduleStatusMessage {
            details.append(TaskDecisionDockDetail(
                id: "routine-status",
                title: isScheduleStatusError ? "Routine needs attention" : "Routine created",
                summary: statusMsg,
                systemImage: isScheduleStatusError ? "exclamationmark.triangle" : "checkmark.circle",
                tone: isScheduleStatusError ? .attention : .verified
            ))
        }

        return details
    }

    private func dedupePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }

    private var composerTaskStatusOverride: ComposerTaskStatusPresentation? {
        if task.status == .failed, let run = latestRun {
            let activity = currentThreadSnapshot.activity(for: run)
            let notices = runNoticesToDisplay(activity.notices, for: run)

            if runStoppedByPolicy(run, notices: notices) {
                return ComposerTaskStatusPresentation(
                    label: "Blocked",
                    icon: "shield.slash",
                    color: Stanford.poppy,
                    help: "ASTRA stopped this run because the requested action is outside the current policy."
                )
            }

            if runStoppedBySystem(run, notices: notices) {
                return ComposerTaskStatusPresentation(
                    label: "Stopped",
                    icon: "octagon",
                    color: Stanford.poppy,
                    help: "ASTRA stopped this run before the agent could safely continue. Fix the setup or retry with a narrower request."
                )
            }
        }

        return composerTaskStatusPresentation(from: taskReviewPresentation)
    }

    private func composerTaskStatusPresentation(from review: TaskReviewPresentation) -> ComposerTaskStatusPresentation? {
        guard let label = review.composerLabel,
              let icon = review.composerIcon,
              let help = review.composerHelp else { return nil }
        return ComposerTaskStatusPresentation(
            label: label,
            icon: icon,
            color: reviewColor(for: review.tone),
            help: help
        )
    }

    private func reviewColor(for tone: TaskReviewTone) -> Color {
        switch tone {
        case .quiet:
            return Stanford.coolGrey
        case .attention:
            return Stanford.poppy
        case .failed:
            return Stanford.failed
        case .closed:
            return Stanford.paloAltoGreen
        }
    }

    private var isFinished: Bool {
        [.completed, .pendingUser, .failed, .budgetExceeded, .cancelled].contains(task.status)
    }

    // (Activity tab removed — run activity is summarized inline in agent response bubbles)

    // MARK: - Result Helpers

    @ViewBuilder
    private var resultSummaryView: some View {
        if let run = latestRun {
            let fileChanges = currentThreadSnapshot.activity(for: run).fileChanges
            let fileCount = fileChanges.count
            let writeCount = fileChanges.filter { $0.changeType == "Write" }.count
            let editCount = fileChanges.filter { $0.changeType == "Edit" }.count

            VStack(alignment: .leading, spacing: 6) {
                if task.status == .pendingUser {
                    Label("Use the review controls above the composer to continue.", systemImage: "info.circle")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.poppy)
                } else if task.status == .completed {
                    Label("Run finished.", systemImage: "checkmark.seal")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.paloAltoGreen)
                } else if task.status == .failed {
                    Label(failureReason, systemImage: "exclamationmark.triangle")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.failed)
                    if task.hasProviderSession {
                        Text("**Resume** to continue or **Retry** to start over.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                } else if task.status == .budgetExceeded {
                    Label("Budget exhausted (\(Formatters.formatTokens(task.tokensUsed))/\(Formatters.formatTokens(task.tokenBudget))).", systemImage: "exclamationmark.triangle")
                        .font(Stanford.body(14))
                        .foregroundStyle(Stanford.failed)
                    if task.hasProviderSession {
                        Text("**Resume** with a higher budget or **Retry** fresh.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(Stanford.coolGrey)
                    }
                }

                if fileCount > 0 {
                    HStack(spacing: 10) {
                        if writeCount > 0 {
                            Label("\(writeCount) created", systemImage: "doc.badge.plus")
                                .font(Stanford.caption(12))
                                .foregroundStyle(Stanford.paloAltoGreen)
                        }
                        if editCount > 0 {
                            Label("\(editCount) edited", systemImage: "pencil")
                                .font(Stanford.caption(12))
                                .foregroundStyle(Stanford.lagunita)
                        }
                    }
                }
            }
        }
    }

    private var resultIcon: String {
        switch task.status {
        case .completed: return "checkmark.circle.fill"
        case .pendingUser: return "person.crop.circle.badge.questionmark"
        case .failed, .budgetExceeded: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "circle.fill"
        }
    }

    private var resultColor: Color {
        switch task.status {
        case .completed: return Stanford.paloAltoGreen
        case .pendingUser: return Stanford.poppy
        case .failed, .budgetExceeded: return Stanford.failed
        case .cancelled: return Stanford.coolGrey
        default: return Stanford.lagunita
        }
    }

    private var resultTitle: String {
        switch task.status {
        case .completed: return TaskPresentationState.reviewPresentation(status: task.status, isClosed: task.isDone).runOutcomeLabel
        case .pendingUser: return TaskPresentationState.reviewPresentation(status: task.status, isClosed: task.isDone).runOutcomeLabel
        case .failed: return TaskPresentationState.reviewPresentation(status: task.status, isClosed: task.isDone).runOutcomeLabel
        case .budgetExceeded: return TaskPresentationState.reviewPresentation(status: task.status, isClosed: task.isDone).runOutcomeLabel
        case .cancelled: return TaskPresentationState.reviewPresentation(status: task.status, isClosed: task.isDone).runOutcomeLabel
        default: return "Result"
        }
    }

    private var failureReason: String {
        let errorEvents = task.events.filter { $0.type == "error" }
        if let lastError = errorEvents.last {
            let payload = lastError.payload
            if payload.contains("idle timeout") || payload.contains("timed out") {
                return "Agent went idle — no output for the timeout period."
            }
            if payload.contains("CLI not found") {
                return "Provider CLI not found. Check Settings."
            }
            if payload.contains("not found") || payload.contains("Workspace") {
                return "Workspace directory not found."
            }
            if payload.contains("isolation") || payload.contains("Isolation") {
                return "Workspace isolation setup failed."
            }
            if payload.contains("exit") || payload.contains("exited") {
                if let run = latestRun {
                    if run.exitCode == 143 { return "Process killed (SIGTERM) — likely timeout." }
                    if run.exitCode == 137 { return "Process killed (SIGKILL) — may be out of memory." }
                    if run.exitCode != 0 { return "Agent exited with code \(run.exitCode ?? -1)." }
                }
            }
            return String(payload.prefix(200))
        }
        if let run = latestRun, run.exitCode == 143 {
            return "Process killed (SIGTERM) — likely timeout."
        }
        return "The agent encountered an error. Check the activity log."
    }

    // MARK: - Composer

    private var hasInput: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    private var showSlashMenu: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && !trimmed.contains(" ") && trimmed.count < 14
    }

    private var slashMenuMatchesRemember: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        return "/remember".hasPrefix(trimmed)
    }

    private var slashMenuMatchesRoutine: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        return "/routine".hasPrefix(trimmed) || "/schedule".hasPrefix(trimmed)
    }

    private var slashMenuMatchesRecap: Bool {
        let trimmed = messageText.trimmingCharacters(in: .whitespaces).lowercased()
        return "/recap".hasPrefix(trimmed)
    }

    private var visibleSlashOptions: [(id: String, command: String)] {
        var opts: [(id: String, command: String)] = []
        if slashMenuMatchesRemember { opts.append(("remember", "/remember ")) }
        if slashMenuMatchesRoutine { opts.append(("routine", "/routine ")) }
        if slashMenuMatchesRecap { opts.append(("recap", "/recap")) }
        return opts
    }

    /// Icon / color / title / subtitle metadata for a slash option id.
    private static func slashOptionMeta(_ id: String) -> (icon: String, color: Color, title: String, subtitle: String) {
        switch id {
        case "remember":
            return ("text.badge.checkmark", Stanford.lagunita, "Add Memory", "Save a fact to this workspace's memory")
        case "routine":
            return ("arrow.triangle.2.circlepath", Stanford.poppy, "Create Routine", "Automate this task on a recurring cadence")
        case "recap":
            return ("doc.text", Stanford.paloAltoGreen, "Recap Task", "Summarize progress so you can pause and resume later")
        default:
            return ("questionmark", Stanford.coolGrey, id.capitalized, "")
        }
    }

    private func selectSlashOption() {
        let opts = visibleSlashOptions
        guard !opts.isEmpty else { return }
        let idx = min(slashSelectedIndex, opts.count - 1)
        selectSlashOption(opts[idx])
    }

    /// Commands that take no argument execute immediately on selection.
    /// Commands that take args just fill the composer so the user can type.
    private func selectSlashOption(_ opt: (id: String, command: String)) {
        messageText = opt.command
        if Self.isNoArgSlashCommand(opt.id) {
            sendMessage()
        }
    }

    private func loadSSHConnections() {
        guard let workspace = task.workspace, !workspace.primaryPath.isEmpty else {
            sshConnections = []
            return
        }
        sshConnections = SSHConnectionManager.load(workspacePath: workspace.primaryPath)
    }

    private static func isNoArgSlashCommand(_ id: String) -> Bool {
        id == "recap"
    }

    private var hasOpenRuntimePermissionApprovalRequest: Bool {
        let latestRequest = sortedEvents
            .filter { $0.type == "permission.approval.requested" }
            .max { $0.timestamp < $1.timestamp }
        guard let latestRequest else { return false }

        let latestApproval = sortedEvents
            .filter { $0.type == "task.approved" }
            .max { $0.timestamp < $1.timestamp }
        return latestApproval.map { latestRequest.timestamp > $0.timestamp } ?? true
    }

    private var latestRuntimePermissionRequestPayload: String? {
        sortedEvents
            .filter { $0.type == "permission.approval.requested" }
            .max { $0.timestamp < $1.timestamp }?
            .payload
    }

    private var pendingRuntimePermissionDecision: RuntimePermissionDecisionPresentation? {
        latestRuntimePermissionRequestPayload.map(RuntimePermissionDecisionPresentation.init(payload:))
    }

    private var latestRuntimePermissionTaskScopedGrants: [PermissionGrant] {
        guard let payload = latestRuntimePermissionRequestPayload else { return [] }
        let structured = PermissionBroker.structuredApprovalGrants(from: payload)
        let grants = structured.isEmpty ? PermissionBroker.legacyApprovalGrants(from: payload) : structured
        return PermissionBroker.taskScopedApprovalGrants(for: grants)
    }

    private var canApproveSimilarRuntimePermissionForTask: Bool {
        hasOpenRuntimePermissionApprovalRequest && !latestRuntimePermissionTaskScopedGrants.isEmpty
    }

    private var shouldShowTaskDecisionDock: Bool {
        taskDecisionDockPresentation != nil
    }

    private var latestRunHasNoUsableResult: Bool {
        pendingTaskDismissalReason == .noUsableResult ||
            pendingTaskDismissalReason == .missingRequiredArtifact
    }

    private var pendingTaskDismissalReason: PendingTaskDismissalReason? {
        pendingTaskReviewState.dismissalReason
    }

    private var pendingTaskReviewState: PendingTaskReviewState {
        guard !hasOpenRuntimePermissionApprovalRequest else { return .none }
        return PendingTaskReviewPolicy.reviewState(
            for: task,
            latestRun: latestRunModel
        )
    }

    private var completedTaskNeedsArtifactAttention: Bool {
        PendingTaskReviewPolicy.completedTaskNeedsArtifactAttention(
            task: task,
            latestRun: latestRunModel
        )
    }

    private var latestRunModel: TaskRun? {
        task.runs.max(by: { $0.startedAt < $1.startedAt })
    }

    private var pendingDecisionTitle: String {
        if hasOpenRuntimePermissionApprovalRequest {
            return pendingRuntimePermissionDecision?.title ?? "Permission needed"
        }
        if latestRunHasNoUsableResult {
            return "No usable result"
        }
        return pendingTaskDismissalReason == .policyBlocked ? "Policy blocked" : "Needs your review"
    }

    private var pendingDecisionDetail: String {
        if hasOpenRuntimePermissionApprovalRequest {
            let fallback = "\(task.resolvedRuntimeID.displayName) needs one-time permission before it can continue."
            return pendingRuntimePermissionDecision?.summary ?? fallback
        }
        if pendingTaskDismissalReason == .policyBlocked {
            return "The run stopped before completion. Retry with broader policy permissions; dismissing will not mark it completed."
        }
        if latestRunHasNoUsableResult {
            return "The task did not create the expected artifact. Retry or dismiss without marking it completed."
        }
        return "Review the latest output, then approve it or retry the task."
    }

    private var pendingDecisionPrimaryLabel: String {
        if hasOpenRuntimePermissionApprovalRequest {
            return "Allow once & continue"
        }
        return pendingTaskDismissalReason != nil ? "Dismiss" : "Approve result"
    }

    private var pendingDecisionPrimaryIcon: String {
        hasOpenRuntimePermissionApprovalRequest ? "lock.open.fill" : "checkmark"
    }

    private var pendingDecisionIcon: String {
        if hasOpenRuntimePermissionApprovalRequest {
            return "hand.raised.fill"
        }
        if pendingTaskDismissalReason == .policyBlocked {
            return "shield.slash.fill"
        }
        return latestRunHasNoUsableResult ? "doc.badge.exclamationmark" : "person.crop.circle.badge.questionmark"
    }

    private var composerPlaceholder: String {
        switch task.status {
        case .queued: return "Type to refine this task (moves back to draft)..."
        case .completed: return "Ask a follow-up question..."
        case .pendingUser: return "Send a message to continue..."
        default: return "Send a message..."
        }
    }

    @ViewBuilder
    private var taskDecisionDock: some View {
        if let presentation = taskDecisionDockPresentation {
            TaskDecisionDockView(
                presentation: presentation,
                isExpanded: $isTaskDecisionDetailsExpanded,
                onAction: handleTaskDecisionDockAction
            )
            .onAppear {
                isTaskDecisionDetailsExpanded = presentation.prefersExpandedDetails
            }
            .onChange(of: presentation.id) { _, _ in
                isTaskDecisionDetailsExpanded = presentation.prefersExpandedDetails
            }
        }
    }

    private func handleTaskDecisionDockAction(_ action: TaskDecisionDockAction) {
        switch action.kind {
        case .stop:
            onCancelTask?(task)
        case .allowOnce, .approveResult, .dismissReview:
            onApproveTask?(task)
        case .allowSimilar:
            approveSimilarRuntimePermissionForTask()
        case .approveCorrection:
            if let id = action.payload { approveMissionCorrection(id) }
        case .createCorrectionTask:
            if let id = action.payload { createMissionCorrectionTask(id) }
        case .dismissCorrection:
            if let id = action.payload { dismissMissionCorrection(id) }
        case .openPlan:
            onOpenPlan?(task)
        case .runApprovedPlan:
            guard let plan = executableApprovedPlan else { return }
            runApprovedPlan(plan, mode: skipPermissions ? .fullPlan : .nextStep)
        case .runTask:
            onRunTask?(task)
        case .retry:
            onRetryTask?(task)
        case .resume:
            onResumeTask?(task)
        case .openArtifact:
            guard let path = action.payload else { return }
            if let onOpenGeneratedFile {
                onOpenGeneratedFile(path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case .closeTask, .closeAnyway, .closeWithoutRunningPlan, .reopenTask:
            toggleTaskDoneFromDecisionDock()
        }
    }

    private var pendingReviewDecisionDock: some View {
        let primaryColor = hasOpenRuntimePermissionApprovalRequest ? Stanford.poppy : Stanford.paloAltoGreen

        return taskDecisionSurface(
            icon: pendingDecisionIcon,
            color: primaryColor,
            title: pendingDecisionTitle,
            detail: pendingDecisionDetail,
            detailLineLimit: hasOpenRuntimePermissionApprovalRequest ? 2 : 3,
            scope: hasOpenRuntimePermissionApprovalRequest ? pendingRuntimePermissionDecision?.scope : nil,
            commandPreview: hasOpenRuntimePermissionApprovalRequest ? pendingRuntimePermissionDecision?.commandPreview : nil
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                if let onRetry = onRetryTask {
                    Button("Retry") {
                        onRetry(task)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
                    .controlSize(.small)
                    .accessibilityLabel("Retry task")
                }

                if hasOpenRuntimePermissionApprovalRequest,
                   canApproveSimilarRuntimePermissionForTask {
                    Button {
                        approveSimilarRuntimePermissionForTask()
                    } label: {
                        Label("Allow similar", systemImage: "checkmark.shield")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
                    .controlSize(.small)
                    .help((pendingRuntimePermissionDecision?.allowSimilarLabel ?? "Allow similar requests") + " for this task.")
                    .accessibilityIdentifier("ApproveSimilarTaskButton")
                    .accessibilityLabel("Allow similar for this task")
                }

                if let onApprove = onApproveTask {
                    Button {
                        onApprove(task)
                    } label: {
                        Label(pendingDecisionPrimaryLabel, systemImage: pendingDecisionPrimaryIcon)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: true, color: primaryColor))
                    .controlSize(.small)
                    .accessibilityIdentifier("ApproveTaskButton")
                    .accessibilityLabel(pendingDecisionPrimaryLabel)
                }

                taskDecisionOverflowMenu(doneLabelOverride: latestRunHasNoUsableResult ? TaskPresentationState.closeAnywayActionTitle : nil)
            }
        }
    }

    private func approveSimilarRuntimePermissionForTask() {
        guard let taskQueue else {
            onApproveTask?(task)
            return
        }
        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: taskQueue)
        coordinator.approveSimilarRuntimePermissionForTask(task)
    }

    private func planDecisionDock(_ plan: TaskPlanPayload) -> some View {
        let nextStep = TaskPlanService.nextExecutableStep(in: plan)
        let mode: TaskPlanExecutionMode = skipPermissions ? .fullPlan : .nextStep
        let title = skipPermissions ? "Run remaining plan" : "Approve next step"
        let detail = nextStep.map { "Next: \($0.title)" } ?? plan.title
        let modeLabel = skipPermissions
            ? "Auto mode runs every remaining step."
            : "Ask mode runs one approved step, then pauses again."
        let tint = skipPermissions ? Stanford.poppy : Stanford.paloAltoGreen

        return taskDecisionSurface(
            icon: skipPermissions ? "play.circle.fill" : "checkmark.circle.fill",
            color: tint,
            title: title,
            detail: detail,
            modeLabel: modeLabel
        ) {
            HStack(spacing: 8) {
                if let onOpenPlan {
                    Button {
                        onOpenPlan(task)
                    } label: {
                        Label(
                            isPlanCanvasVisible ? "Hide Plan" : "Open Plan",
                            systemImage: "list.bullet.clipboard"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: false))
                    .controlSize(.small)
                    .help(isPlanCanvasVisible ? "Hide plan shelf" : "Open plan shelf")
                    .accessibilityIdentifier("OpenPlanButton")
                }

                Button {
                    runApprovedPlan(plan, mode: mode)
                } label: {
                    Label(title, systemImage: skipPermissions ? "play.fill" : "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: true, color: tint))
                .controlSize(.small)
                .disabled(taskQueue == nil)
                .accessibilityIdentifier(skipPermissions ? "RunRemainingPlanButton" : "ApproveNextPlanStepButton")

                taskDecisionOverflowMenu(doneLabelOverride: TaskPresentationState.closeWithoutRunningPlanActionTitle)
            }
        }
    }

    private var queuedDecisionDock: some View {
        taskDecisionSurface(
            icon: "play.circle.fill",
            color: Stanford.lagunita,
            title: "Ready to run",
            detail: "Start this task now, or send a message below to refine it first."
        ) {
            HStack(spacing: 8) {
                if let onRun = onRunTask {
                    Button {
                        onRun(task)
                    } label: {
                        Label("Run task", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: true, color: Stanford.lagunita))
                    .controlSize(.small)
                    .accessibilityIdentifier("RunTaskButton")
                    .accessibilityLabel("Run task")
                }

                taskDecisionOverflowMenu()
            }
        }
    }

    private var failedDecisionDock: some View {
        let canResume = task.hasProviderSession && onResumeTask != nil
        let isBudgetExceeded = task.status == .budgetExceeded
        let title = isBudgetExceeded ? "Budget exceeded" : "Run stopped"
        let detail = isBudgetExceeded
            ? "Raise the budget and resume, or retry this task from scratch."
            : failureReason

        return taskDecisionSurface(
            icon: isBudgetExceeded ? "speedometer" : "exclamationmark.triangle.fill",
            color: Stanford.failed,
            title: title,
            detail: detail,
            detailLineLimit: 2
        ) {
            HStack(spacing: 8) {
                if let onRetry = onRetryTask {
                    Button {
                        onRetry(task)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: !canResume, color: Stanford.lagunita))
                    .controlSize(.small)
                    .help("Start over from scratch")
                    .accessibilityLabel("Retry task")
                }

                if task.hasProviderSession, let onResume = onResumeTask {
                    Button {
                        onResume(task)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: true, color: Stanford.lagunita))
                    .controlSize(.small)
                    .help("Continue where the agent left off")
                    .accessibilityLabel("Resume task")
                }

                taskDecisionOverflowMenu()
            }
        }
    }

    private var doneStateDecisionDock: some View {
        let review = taskReviewPresentation

        return taskDecisionSurface(
            icon: task.isDone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill",
            color: task.isDone ? Stanford.lagunita : Stanford.paloAltoGreen,
            title: review.decisionTitle,
            detail: review.decisionDetail
        ) {
            taskDoneToggleButton(isPrimary: true)
        }
    }

    private var completedNoUsableResultDecisionDock: some View {
        taskDecisionSurface(
            icon: "doc.badge.exclamationmark",
            color: Stanford.poppy,
            title: "No usable result",
            detail: "This finished run did not create the expected artifact. Retry or close it anyway.",
            detailLineLimit: 2
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                if let onRetry = onRetryTask {
                    Button("Retry") {
                        onRetry(task)
                    }
                    .buttonStyle(StanfordButtonStyle(isPrimary: true, color: Stanford.poppy))
                    .controlSize(.small)
                    .accessibilityLabel("Retry task")
                }

                Button {
                    toggleTaskDoneFromDecisionDock()
                } label: {
                    Label(TaskPresentationState.closeAnywayActionTitle, systemImage: taskDoneToggleIcon)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(StanfordButtonStyle(isPrimary: onRetryTask == nil, color: taskDoneToggleColor))
                .controlSize(.small)
                .accessibilityLabel(TaskPresentationState.closeAnywayActionTitle)
            }
        }
    }

    private func taskDecisionSurface<Actions: View>(
        icon: String,
        color: Color,
        title: String,
        detail: String,
        detailLineLimit: Int = 1,
        modeLabel: String? = nil,
        scope: String? = nil,
        commandPreview: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let hasSupportingRows = modeLabel != nil || scope != nil || commandPreview != nil || detailLineLimit > 1

        return ViewThatFits(in: .horizontal) {
            taskDecisionHorizontalLayout(
                icon: icon,
                color: color,
                title: title,
                detail: detail,
                detailLineLimit: detailLineLimit,
                modeLabel: modeLabel,
                scope: scope,
                commandPreview: commandPreview,
                hasSupportingRows: hasSupportingRows,
                actions: actions
            )

            taskDecisionStackedLayout(
                icon: icon,
                color: color,
                title: title,
                detail: detail,
                detailLineLimit: detailLineLimit,
                modeLabel: modeLabel,
                scope: scope,
                commandPreview: commandPreview,
                actions: actions
            )
        }
        .padding(.horizontal, TaskComposerPresentation.decisionRowHorizontalPadding)
        .padding(.vertical, TaskComposerPresentation.decisionRowVerticalPadding)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            Capsule()
                .fill(color.opacity(0.76))
                .frame(width: TaskComposerPresentation.decisionAccentWidth)
                .padding(.vertical, TaskComposerPresentation.decisionAccentVerticalInset)
                .padding(.leading, 1)
        }
    }

    private func taskDecisionHorizontalLayout<Actions: View>(
        icon: String,
        color: Color,
        title: String,
        detail: String,
        detailLineLimit: Int,
        modeLabel: String?,
        scope: String?,
        commandPreview: String?,
        hasSupportingRows: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: hasSupportingRows ? .top : .center, spacing: TaskComposerPresentation.decisionRowSpacing) {
            Image(systemName: icon)
                .font(Stanford.ui(TaskComposerPresentation.decisionIconFontSize, weight: .semibold))
                .foregroundStyle(color)
                .frame(
                    width: TaskComposerPresentation.decisionIconFrame,
                    height: TaskComposerPresentation.decisionIconFrame
                )
                .padding(.top, hasSupportingRows ? 1 : 0)

            taskDecisionTextStack(
                title: title,
                detail: detail,
                detailLineLimit: detailLineLimit,
                modeLabel: modeLabel,
                scope: scope,
                commandPreview: commandPreview
            )
            .layoutPriority(1)

            Spacer(minLength: 8)

            actions()
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func taskDecisionStackedLayout<Actions: View>(
        icon: String,
        color: Color,
        title: String,
        detail: String,
        detailLineLimit: Int,
        modeLabel: String?,
        scope: String?,
        commandPreview: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: TaskComposerPresentation.decisionRowSpacing) {
                Image(systemName: icon)
                    .font(Stanford.ui(TaskComposerPresentation.decisionIconFontSize, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(
                        width: TaskComposerPresentation.decisionIconFrame,
                        height: TaskComposerPresentation.decisionIconFrame
                    )

                taskDecisionTextStack(
                    title: title,
                    detail: detail,
                    detailLineLimit: detailLineLimit,
                    modeLabel: modeLabel,
                    scope: scope,
                    commandPreview: commandPreview
                )

                Spacer(minLength: 0)
            }

            HStack {
                Spacer(minLength: 0)
                actions()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func taskDecisionTextStack(
        title: String,
        detail: String,
        detailLineLimit: Int,
        modeLabel: String?,
        scope: String?,
        commandPreview: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Stanford.body(TaskComposerPresentation.decisionTitleFontSize).weight(.semibold))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
            Text(detail)
                .font(Stanford.caption(TaskComposerPresentation.decisionDetailFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(detailLineLimit)
                .fixedSize(horizontal: false, vertical: true)

            if let modeLabel {
                Text(modeLabel)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let scope {
                Text(scope)
                    .font(Stanford.chatMeta())
                    .foregroundStyle(Stanford.coolGrey.opacity(0.85))
                    .lineLimit(1)
            }

            if let commandPreview {
                Label(commandPreview, systemImage: "terminal")
                    .font(Stanford.caption(11).monospaced())
                    .foregroundStyle(Stanford.readingText.opacity(0.82))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var canToggleTaskDoneFromDecisionDock: Bool {
        task.status != .running && task.status != .draft
    }

    private var taskDoneToggleTitle: String {
        task.isDone ? TaskPresentationState.reopenTaskActionTitle : TaskPresentationState.closeTaskActionTitle
    }

    private var taskDoneToggleIcon: String {
        task.isDone ? "arrow.uturn.backward" : "checkmark.circle"
    }

    private var taskDoneToggleColor: Color {
        task.isDone ? Stanford.lagunita : Stanford.paloAltoGreen
    }

    private func taskDoneToggleButton(isPrimary: Bool = false) -> some View {
        Button {
            toggleTaskDoneFromDecisionDock()
        } label: {
            Label(taskDoneToggleTitle, systemImage: taskDoneToggleIcon)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(StanfordButtonStyle(isPrimary: isPrimary, color: taskDoneToggleColor))
        .controlSize(.small)
        .accessibilityLabel(taskDoneToggleTitle)
    }

    @ViewBuilder
    private func taskDecisionOverflowMenu(doneLabelOverride: String? = nil) -> some View {
        if canToggleTaskDoneFromDecisionDock {
            Menu {
                Button {
                    toggleTaskDoneFromDecisionDock()
                } label: {
                    Label(task.isDone ? TaskPresentationState.reopenTaskActionTitle : (doneLabelOverride ?? TaskPresentationState.closeTaskActionTitle),
                          systemImage: taskDoneToggleIcon)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(Stanford.coolGrey)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.035)))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .help("More task decisions")
            .accessibilityLabel("More task decisions")
        }
    }

    private func toggleTaskDoneFromDecisionDock() {
        if let onToggleDone {
            onToggleDone(task)
        } else {
            withAnimation(reduceMotion ? nil : .default) {
                task.isDone.toggle()
                task.updatedAt = Date()
                try? modelContext.save()
            }
        }
    }

    private var composerFill: Color {
        isComposerFocused ? Stanford.cardBackground.opacity(0.98) : Stanford.cardBackground.opacity(0.90)
    }

    private var composerStrokeColor: Color {
        if isDragOver {
            return Stanford.cardinalRed.opacity(0.68)
        }
        if isComposerFocused {
            return Stanford.lagunita.opacity(0.30)
        }
        return Color.primary.opacity(0.10)
    }

    private var composerStrokeWidth: CGFloat {
        isDragOver || isComposerFocused ? 1.5 : 1
    }

    private var composerView: some View {
        let composerShape = RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous)

        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                if shouldShowTaskDecisionDock {
                    taskDecisionDock
                        .padding(.horizontal, TaskComposerPresentation.decisionDockHorizontalPadding)
                        .padding(.top, TaskComposerPresentation.decisionDockTopPadding)
                        .padding(.bottom, TaskComposerPresentation.decisionDockBottomPadding)

                    Divider()
                        .overlay(Color.primary.opacity(0.06))
                }

                if !attachedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachedFiles, id: \.self) { file in
                                fileChip(file)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    }
                }

                TextField(composerPlaceholder, text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Stanford.chatBody())
                    .lineLimit(2...10)
                    .padding(.horizontal, TaskComposerPresentation.inputHorizontalPadding)
                    .padding(.top, attachedFiles.isEmpty ? TaskComposerPresentation.inputTopPadding : TaskComposerPresentation.inputTopPaddingWithAttachments)
                    .padding(.bottom, TaskComposerPresentation.inputBottomPadding)
                    .focused($isComposerFocused)
                    .onSubmit {
                        if showSlashMenu && !visibleSlashOptions.isEmpty {
                            selectSlashOption()
                        } else {
                            sendMessage()
                        }
                    }
                    .onKeyPress(.tab) {
                        if showSlashMenu && !visibleSlashOptions.isEmpty { selectSlashOption(); return .handled }
                        return .ignored
                    }
                    .onKeyPress(.upArrow) {
                        if showSlashMenu {
                            slashSelectedIndex = max(0, slashSelectedIndex - 1)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        if showSlashMenu {
                            slashSelectedIndex = min(visibleSlashOptions.count - 1, slashSelectedIndex + 1)
                            return .handled
                        }
                        return .ignored
                    }
                    .onChange(of: messageText) { slashSelectedIndex = 0 }
                    .disabled(task.status == .running)

                Color.clear
                    .frame(height: 2)

                ComposerToolbar(
                    model: task.model,
                    runtimeID: task.runtimeID ?? AgentRuntimeID.claudeCode.rawValue,
                    budget: task.tokenBudget,
                    skills: task.skills,
                    availableSkills: availableSkills,
                    workspace: task.workspace,
                    runtimeReadinessStates: runtimeReadinessStates,
                    taskStatus: task.status,
                    taskStatusOverride: composerTaskStatusOverride,
                    isRunning: task.status == .running || isPlanning,
                    hasInput: hasInput,
                    onAttachFile: { attachFile() },
                    onPasteClipboard: { smartPaste() },
                    onSend: { sendMessage() },
                    onStop: (shouldShowTaskDecisionDock || onCancelTask == nil) ? nil : { onCancelTask?(task) },
                    onModelChange: { task.model = $0 },
                    onRuntimeChange: { runtime in
                        let previousRuntime = task.runtimeID
                        let previousModel = task.model
                        task.runtimeID = runtime
                        let resolved = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtime)
                        let resolvedModel = RuntimeModelAvailability.modelForRuntimeSwitch(
                            currentModel: task.model,
                            to: resolved,
                            cache: runtimeModelCache
                        )
                        task.model = resolvedModel
                        task.updatedAt = Date()
                        AppLogger.breadcrumb(action: "task_runtime_changed", category: "UI", taskID: task.id, fields: [
                            "source": "task_composer",
                            "previous_runtime": previousRuntime ?? "none",
                            "runtime": runtime,
                            "previous_model": previousModel,
                            "model": resolvedModel,
                            "model_changed": String(previousModel != resolvedModel),
                            "workspace_id": task.workspace?.id.uuidString ?? "none"
                        ])
                    },
                    onBudgetChange: { task.tokenBudget = $0 },
                    onRemoveSkill: { skill in
                        task.skills.removeAll { $0.id == skill.id }
                        TaskCapabilitySnapshotter.capture(for: task)
                        task.updatedAt = Date()
                        AppLogger.breadcrumb(action: "task_skill_removed", category: "UI", taskID: task.id, fields: [
                            "source": "task_composer",
                            "skill_id": skill.id.uuidString,
                            "skill_name": skill.name,
                            "runtime": task.runtimeID ?? "none",
                            "workspace_id": task.workspace?.id.uuidString ?? "none"
                        ])
                    },
                    onToggleSkill: { skill, enabled in
                        if enabled {
                            if !task.skills.contains(where: { $0.id == skill.id }) {
                                task.skills.append(skill)
                            }
                        } else {
                            task.skills.removeAll { $0.id == skill.id }
                        }
                        TaskCapabilitySnapshotter.capture(for: task)
                        task.updatedAt = Date()
                        let traceID = AuditTrace.make("task-skill-toggle")
                        AppLogger.breadcrumb(action: enabled ? "task_skill_enabled" : "task_skill_disabled", category: "UI", taskID: task.id, traceID: traceID, fields: [
                            "source": "task_composer",
                            "skill_id": skill.id.uuidString,
                            "skill_name": skill.name,
                            "runtime": task.runtimeID ?? "none",
                            "workspace_id": task.workspace?.id.uuidString ?? "none"
                        ])
                        logTaskCapabilityContext(source: "task_skill_toggle", traceID: traceID, extraFields: [
                            "skill_id": skill.id.uuidString,
                            "skill_name": skill.name,
                            "skill_enabled": String(enabled)
                        ])
                    },
                    onManageSkills: onManageSkills,
                    skipPermissions: $skipPermissions,
                    policyLevelRaw: $taskPolicyLevelRaw,
                    useAgentTeam: .constant(false),
                    teamSize: .constant(3),
                    isPlanMode: $isPlanMode,
                    planModeHelp: "Turn on Goal Mode to refine the task goal before resuming",
                    onPolicyLevelChange: { level in
                        TaskPolicyStore.recordSelection(
                            level: level,
                            task: task,
                            modelContext: modelContext,
                            source: "task_composer"
                        )
                        task.updatedAt = Date()
                        try? modelContext.save()
                    },
                    showSecurityGate: true,
                    sshConnections: sshConnections
                )
            }
            .background(composerFill)
            .clipShape(composerShape)
            .overlay(
                composerShape
                    .stroke(composerStrokeColor, lineWidth: composerStrokeWidth)
            )
            .shadow(color: Color.black.opacity(isComposerFocused ? 0.08 : 0.045), radius: isComposerFocused ? 12 : 8, y: 3)
            .overlay(alignment: .topLeading) {
                if showSlashMenu && !visibleSlashOptions.isEmpty {
                    let opts = visibleSlashOptions
                    VStack(spacing: 0) {
                        ForEach(Array(opts.enumerated()), id: \.element.id) { index, opt in
                            let isSelected = index == min(slashSelectedIndex, opts.count - 1)
                            let meta = Self.slashOptionMeta(opt.id)
                            Button {
                                selectSlashOption(opt)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: meta.icon)
                                        .font(Stanford.body(16))
                                        .foregroundStyle(meta.color)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(opt.command.trimmingCharacters(in: .whitespaces))
                                                .font(Stanford.body(14)).fontWeight(.semibold)
                                            Text(meta.title)
                                                .font(Stanford.caption(13)).foregroundStyle(Stanford.coolGrey)
                                        }
                                        Text(meta.subtitle)
                                            .font(Stanford.caption(12))
                                            .foregroundStyle(Stanford.coolGrey)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.primary.opacity(0.075) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: 420)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Stanford.radiusLarge, style: .continuous)
                            .stroke(Color.primary.opacity(0.11), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.14), radius: 14, y: -3)
                    .offset(y: -CGFloat(visibleSlashOptions.count) * 48 - 16)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDragOver) { providers in
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            var fileURL: URL?
                            if let data = item as? Data {
                                fileURL = URL(dataRepresentation: data, relativeTo: nil)
                            } else if let url = item as? URL {
                                fileURL = url
                            }
                            guard let url = fileURL else { return }
                            DispatchQueue.main.async {
                                if !attachedFiles.contains(url.path) {
                                    attachedFiles.append(url.path)
                                }
                            }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                            guard let data else { return }
                            let tempPath = NSTemporaryDirectory() + "astra_drop_\(UUID().uuidString.prefix(8)).png"
                            try? data.write(to: URL(fileURLWithPath: tempPath))
                            DispatchQueue.main.async {
                                attachedFiles.append(tempPath)
                            }
                        }
                    }
                }
                return true
            }
        }
    }

    /// Smart paste: inspect clipboard and route to the right action.
    /// Returns true if it handled the paste (non-text content), false to
    /// let the TextField handle it natively (short text).
    @discardableResult
    private func smartPaste() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []

        // 1. File URLs — attach directly
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls where !attachedFiles.contains(url.path) {
                attachedFiles.append(url.path)
            }
            return true
        }

        // 2. Image data (screenshot, copied image) — save as temp PNG
        if types.contains(.png) || types.contains(.tiff) {
            if let image = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let first = image.first {
                if let tiff = first.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let tempPath = NSTemporaryDirectory() + "astra_paste_\(UUID().uuidString.prefix(8)).png"
                    try? png.write(to: URL(fileURLWithPath: tempPath))
                    attachedFiles.append(tempPath)
                    return true
                }
            }
        }

        // 3. Text — short text pastes inline, long text attaches as file
        if let text = pb.string(forType: .string), !text.isEmpty {
            let lineCount = text.components(separatedBy: .newlines).count
            if lineCount > 10 || text.count > 500 {
                let ext = text.hasPrefix("{") || text.hasPrefix("[") ? "json" : "txt"
                let tempPath = NSTemporaryDirectory() + "astra_paste_\(UUID().uuidString.prefix(8)).\(ext)"
                try? text.write(toFile: tempPath, atomically: true, encoding: .utf8)
                attachedFiles.append(tempPath)
                return true
            }
            return false
        }

        return false
    }

    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if isComposerFocused,
               event.modifierFlags.contains(.shift),
               Self.isReturnKey(event),
               task.status != .running {
                messageText.append("\n")
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v" {
                if smartPaste() { return nil }
            }
            return event
        }
    }

    private static func isReturnKey(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }

    private func removePasteMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
            pasteMonitor = nil
        }
    }

    /// Autocomplete /routine in the composer with a trailing space for inline instructions.
    private func selectSlashSchedule() {
        messageText = "/routine "
    }

    private func pursueSuggestedNextStep(_ suggestion: String) {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messageText = trimmed
        isComposerFocused = true
    }

    // MARK: - Agentic Routine Creation

    private static let jsonBlockRegex = try? NSRegularExpression(
        pattern: "```json\\s*\\n([\\s\\S]*?)\\n\\s*```",
        options: []
    )

    /// Use the selected utility runtime to analyze the conversation context + user instruction and create a routine.
    /// Ask the selected utility runtime to summarize the task conversation so the user can resume later.
    /// Response is plain markdown (no JSON), inserted as a recap.result event.
    private func generateRecapAgentically() {
        let conversationSnapshot = scheduleConversationContext
        guard !conversationSnapshot.isEmpty else {
            recapStatusMessage = "Nothing to recap yet — this task has no conversation."
            return
        }

        isGeneratingRecap = true
        recapStatusMessage = nil

        let workspacePath = task.workspace?.primaryPath ?? ""

        let systemPrompt = """
        The user typed /recap. They are the sole reader and will use this to resume their own work on this task after a context switch.

        Read the conversation above and produce a recap in this exact format. OMIT any section that would be empty — don't write "(none)" or placeholders.

        ## Intent
        One sentence describing the current exploration, candidate goal, or what "done" looks like if a goal exists.

        ## Progress
        - Bullets: what was done, plus the non-obvious *why* behind any decision (decisions rot fastest from memory).
        - Max 5 bullets.

        ## Next steps
        - Ordered bullets of concrete actions. The first one must be immediately executable without further thinking.
        - Max 5 bullets.

        ## Watch out
        - Gotchas, blockers, dead-ends already ruled out, things waiting on someone else.
        - Skip this section entirely if there's nothing meaningful to flag.

        Rules:
        - Target ≤150 words total, hard cap 250.
        - Markdown only. No preamble, no sign-off, no meta commentary like "Here is your recap".
        - If the conversation has fewer than ~3 substantive exchanges, reply with a single sentence saying there isn't enough yet to recap.

        Current task title: \(task.title)
        Current task goal: \(task.goal)
        """

        let messages: [(role: String, content: String)] = [
            (role: "user", content: """
            Here is the conversation so far on this task:

            \(String(conversationSnapshot.prefix(12000)))
            """)
        ]
        let roleRuntime = utilityRuntime(for: .summarizer)
        TaskRoleProfileStore.recordSelected(roleRuntime.selection, task: task, modelContext: modelContext)

        Task {
            let result = await SpecEngine.chat(
                messages: messages,
                workspacePath: workspacePath,
                skillContext: systemPrompt,
                utilityRuntime: roleRuntime.configuration
            )

            await MainActor.run {
                switch result {
                case .success(let response):
                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        isGeneratingRecap = false
                        recapStatusMessage = "Recap came back empty. Try again."
                        return
                    }
                    let event = TaskEvent(task: task, type: "recap.result", payload: trimmed)
                    modelContext.insert(event)
                    // Force a save so the inverse relationship (task.events) fires
                    // observation immediately — otherwise the bubble can lag behind
                    // the spinner by several seconds.
                    try? modelContext.save()
                    task.updatedAt = Date()
                    isGeneratingRecap = false
                case .failure(let error):
                    isGeneratingRecap = false
                    recapStatusMessage = "Failed to generate recap: \(error.localizedDescription)"
                }
            }
        }
    }

    private func createScheduleAgentically(instruction: String) {
        guard let ws = task.workspace else {
            setScheduleStatusMessage("No workspace found for this task.")
            return
        }

        let conversationSnapshot = scheduleConversationContext
        let source = ScheduleSourceContext(
            taskID: task.id,
            title: task.title,
            goal: task.goal,
            runtimeID: task.resolvedRuntimeID.rawValue,
            model: task.model,
            tokenBudget: task.tokenBudget,
            conversationContext: conversationSnapshot
        )

        scheduleCreationTaskID = source.taskID
        clearScheduleStatusMessage(for: source.taskID)

        let existingSchedules = ws.schedules.map { "\($0.name) (\($0.frequencySummary))" }.joined(separator: ", ")
        let skillList = availableSkills.map { $0.name }.joined(separator: ", ")
        let workspacePath = ws.primaryPath

        let systemPrompt = """
        You are a routines assistant. The user is working on an existing task and wants to create a routine from it.

        Analyze the user's instruction and the conversation context to create a routine. You must output a single JSON block with the routine configuration.

        ## Rules
        - Infer the schedule type (once, interval, daily, weekly) from the instruction
        - Write detailed, self-contained instructions that capture the full intent from both the instruction AND the conversation context
        - The instructions should be specific enough that an agent running this routine later (with no other context) can execute it correctly
        - Pick a short, descriptive name for the routine
        - Add a short description if it helps distinguish the routine in a list
        - Include routinePaths only if the instruction explicitly names local folders
        - If the instruction mentions a time, use it. Otherwise pick a sensible default (9:00 for daily, Monday 9:00 for weekly)
        - For interval: common values are 900 (15m), 1800 (30m), 3600 (1h), 14400 (4h), 43200 (12h)
        - For daily/weekly: hour is 0-23, minute is 0/15/30/45
        - For weekly: dayOfWeek 1=Sunday, 2=Monday, 3=Tuesday, 4=Wednesday, 5=Thursday, 6=Friday, 7=Saturday

        Existing routines: \(existingSchedules.isEmpty ? "none" : existingSchedules)
        Available capabilities to attach: \(skillList.isEmpty ? "none" : skillList)

        Current task title: \(source.title)
        Current task goal: \(source.goal)

        Output ONLY a JSON block — no other text:
        ```json
        {"name": "...", "description": "...", "instructions": "detailed instructions", "scheduleType": "daily|weekly|interval|once", "intervalSeconds": 3600, "dailyHour": 9, "dailyMinute": 0, "weeklyDayOfWeek": 2, "routinePaths": ["/absolute/folder"], "skills": ["skill name", ...], "model": "\(source.model)"}
        ```
        Only include fields relevant to the chosen scheduleType. skills and routinePaths are optional.
        """

        let messages: [(role: String, content: String)] = [
            (role: "user", content: """
            Here is the conversation context from the current task:

            \(conversationSnapshot.isEmpty ? "(no conversation yet)" : String(conversationSnapshot.prefix(8000)))

            ---

            Create a routine: \(instruction)
            """)
        ]
        let roleRuntime = utilityRuntime(for: .summarizer)
        TaskRoleProfileStore.recordSelected(roleRuntime.selection, task: task, modelContext: modelContext)

        Task {
            let result = await SpecEngine.chat(
                messages: messages,
                workspacePath: workspacePath,
                skillContext: systemPrompt,
                utilityRuntime: roleRuntime.configuration
            )

            await MainActor.run {
                if scheduleCreationTaskID == source.taskID {
                    scheduleCreationTaskID = nil
                }

                switch result {
                case .success(let response):
                    parseAndCreateSchedule(from: response, workspace: ws, source: source)
                case .failure(let error):
                    setScheduleStatusMessage("Failed to create routine: \(error.localizedDescription)", for: source.taskID)
                }
            }
        }
    }

    /// Parse the provider's JSON response and create the routine schedule.
    private func parseAndCreateSchedule(from response: String, workspace: Workspace, source: ScheduleSourceContext) {
        guard let regex = Self.jsonBlockRegex,
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let jsonRange = Range(match.range(at: 1), in: response) else {
            // Try parsing the whole response as JSON (providers sometimes skip the fences)
            if let data = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                createScheduleFromJSON(json, workspace: workspace, source: source)
                return
            }
            setScheduleStatusMessage(
                "Could not parse routine configuration. Try again with clearer instructions.",
                for: source.taskID
            )
            return
        }

        let jsonStr = String(response[jsonRange])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            setScheduleStatusMessage("Invalid routine configuration. Try again.", for: source.taskID)
            return
        }

        createScheduleFromJSON(json, workspace: workspace, source: source)
    }

    /// Create a routine from parsed JSON fields.
    private func createScheduleFromJSON(_ json: [String: Any], workspace: Workspace, source: ScheduleSourceContext) {
        let name = json["name"] as? String ?? source.title
        let goal = (json["instructions"] as? String) ?? (json["goal"] as? String) ?? source.goal
        let description = json["description"] as? String ?? ""
        let scheduleTypeRaw = json["scheduleType"] as? String ?? "daily"
        let scheduleType = ScheduleType(rawValue: scheduleTypeRaw) ?? .daily

        let schedule = TaskSchedule(name: name, goal: goal, workspace: workspace, scheduleType: scheduleType)
        schedule.routineDescription = description

        if let interval = json["intervalSeconds"] as? Int { schedule.intervalSeconds = interval }
        if let hour = json["dailyHour"] as? Int { schedule.dailyHour = hour }
        if let minute = json["dailyMinute"] as? Int { schedule.dailyMinute = minute }
        if let dow = json["weeklyDayOfWeek"] as? Int { schedule.weeklyDayOfWeek = dow }
        if let paths = json["routinePaths"] as? [String] { schedule.routinePaths = paths }
        schedule.runtimeID = source.runtimeID
        if let m = json["model"] as? String { schedule.model = m } else { schedule.model = source.model }

        schedule.tokenBudget = source.tokenBudget
        schedule.conversationContext = source.conversationContext
        schedule.sourceTaskID = source.taskID

        // Compute initial nextFireDate
        let now = Date()
        switch scheduleType {
        case .once:
            schedule.nextFireDate = now.addingTimeInterval(60)
        case .interval:
            schedule.nextFireDate = now.addingTimeInterval(TimeInterval(schedule.intervalSeconds))
        case .daily:
            schedule.nextFireDate = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: schedule.dailyHour, minute: schedule.dailyMinute),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86400)
        case .weekly:
            schedule.nextFireDate = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: schedule.dailyHour, minute: schedule.dailyMinute, weekday: schedule.weeklyDayOfWeek),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(604800)
        }

        // Attach skills by name
        if let skillNames = json["skills"] as? [String] {
            let matchedIDs = workspace.skills.filter { skillNames.contains($0.name) }.map { $0.id.uuidString }
            schedule.skillIDs = matchedIDs
        }

        modelContext.insert(schedule)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        setScheduleStatusMessage("Routine **\(name)** created — \(schedule.frequencySummary)", for: source.taskID)

        AppLogger.audit(.taskStats, category: "UI", fields: [
            "event": "schedule_created",
            "source": "agentic_slash_command",
            "source_task_id": source.taskID.uuidString,
            "workspace_id": workspace.id.uuidString,
            "schedule_type": scheduleTypeRaw
        ])
    }

    // MARK: - Helpers

    private func runApprovedPlan(_ plan: TaskPlanPayload, mode: TaskPlanExecutionMode) {
        guard let taskQueue,
              task.status != .queued,
              task.status != .running else { return }

        recordCurrentTaskPolicyIfNeeded(source: "approved_plan_run")
        TaskPlanService.recordApproved(plan, task: task, modelContext: modelContext)
        showPlanCanvasIfNeeded()
        task.status = .queued
        task.completedAt = nil
        task.updatedAt = Date()
        try? modelContext.save()
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
        threadViewModel.refreshSnapshot(for: task)

        Task {
            await taskQueue.executeApprovedPlan(task: task, plan: plan, mode: mode, modelContext: modelContext) { _ in }
            await MainActor.run {
                _ = WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                threadViewModel.refreshSnapshot(for: task)
            }
        }
    }

    private func showPlanCanvasIfNeeded() {
        guard !isPlanCanvasVisible else { return }
        onOpenPlan?(task)
    }

    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty else { return }

        shouldScrollAfterUserMessage = true

        // Intercept /remember command — direct action, no provider call needed
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("/remember ") {
            let memoryText = String(trimmed.dropFirst("/remember ".count)).trimmingCharacters(in: .whitespaces)
            if !memoryText.isEmpty {
                task.workspace?.memories.append(memoryText)
                let confirmEvent = TaskEvent(task: task, type: "system.info", payload: "💾 Memory saved: \"\(memoryText)\"")
                modelContext.insert(confirmEvent)
            }
            messageText = ""
            return
        }

        // Intercept /recap command — agentic summary, no provider session needed
        if lower == "/recap" || lower.hasPrefix("/recap ") {
            messageText = ""
            generateRecapAgentically()
            return
        }

        // Intercept /routine and legacy /schedule commands — use agentic handler
        if lower == "/routine" || lower.hasPrefix("/routine ") || lower == "/schedule" || lower.hasPrefix("/schedule ") {
            let commandLength = lower.hasPrefix("/routine") ? "/routine ".count : "/schedule ".count
            let instructions = (lower == "/routine" || lower == "/schedule")
                ? ""
                : String(trimmed.dropFirst(commandLength)).trimmingCharacters(in: .whitespaces)
            messageText = ""
            if instructions.isEmpty {
                showScheduleEditor = true
            } else {
                createScheduleAgentically(instruction: instructions)
            }
            return
        }

        var msg = messageText
        if !attachedFiles.isEmpty {
            let fileList = attachedFiles.map { "- \($0)" }.joined(separator: "\n")
            msg += "\n\nAttached files:\n\(fileList)"
            attachedFiles = []
        }
        messageText = ""
        let traceID = AuditTrace.make(isPlanMode ? "task-plan-chat" : "task-chat")
        AppLogger.breadcrumb(action: isPlanMode ? "task_plan_chat_sent" : "task_chat_sent", category: "UI", taskID: task.id, traceID: traceID, fields: [
            "source": isPlanMode ? "task_plan_chat" : "task_continue_chat",
            "runtime": task.runtimeID ?? "none",
            "model": task.model,
            "workspace_id": task.workspace?.id.uuidString ?? "none",
            "task_status": task.status.rawValue,
            "message_length": String(msg.count)
        ])

        if isPlanMode {
            sendPlanningMessage(msg, traceID: traceID)
            return
        }

        if task.status == .queued {
            task.status = .draft
            task.updatedAt = Date()
            let systemEvent = TaskEvent(task: task, type: "task.started", payload: "Moved back to draft for editing.")
            modelContext.insert(systemEvent)
            let userEvent = TaskEvent(task: task, type: "user.message", payload: msg)
            modelContext.insert(userEvent)
            AppLogger.audit(.taskRetried, category: "UI", taskID: task.id, fields: [
                "status": "draft",
                "source": "chat_message"
            ])
            onMoveToDraft?(task)
        } else if [.pendingUser, .completed, .failed, .budgetExceeded, .cancelled].contains(task.status), let taskQueue {
            // Note: don't insert user.message here — continueSession() does it with the TaskRun link
            let interruptionSummary = TaskRunLifecycleService.cancelTask(
                task,
                modelContext: modelContext,
                source: .supersededByNewRun
            )
            if interruptionSummary.runsUpdated > 0 {
                AppLogger.audit(.taskInterrupted, category: "UI", taskID: task.id, fields: [
                    "source": TaskRunInterruptionSource.supersededByNewRun.auditSource,
                    "running_runs_cancelled": String(interruptionSummary.runsUpdated),
                    "next_action": "continue_session"
                ], level: .warning)
            }
            task.status = .running
            task.updatedAt = Date()
            task.completedAt = nil
            logTaskCapabilityContext(source: "task_continue_chat", traceID: traceID)
            recordCurrentTaskPolicyIfNeeded(source: "task_continue_chat")
            Task {
                await taskQueue.continueSession(task: task, message: msg, modelContext: modelContext) { _ in }
            }
        } else {
            let event = TaskEvent(task: task, type: "user.message", payload: msg)
            modelContext.insert(event)
        }
    }

    private func sendPlanningMessage(_ msg: String, traceID: String = AuditTrace.make("task-plan-chat")) {
        guard !isPlanning else { return }

        shouldScrollAfterUserMessage = true
        let userEvent = TaskEvent(task: task, type: TaskPlanConversationEventTypes.userMessage, payload: msg)
        modelContext.insert(userEvent)
        task.updatedAt = Date()
        try? modelContext.save()
        threadViewModel.refreshSnapshot(for: task)

        let history = planningConversationHistory(appendingUserMessage: msg)
        let workspacePath = planningWorkspacePath
        let skillContext = planModeSkillContext()
        isPlanning = true
        logTaskCapabilityContext(source: "task_plan_chat", traceID: traceID)
        let roleRuntime = utilityRuntime(for: .planner)
        TaskRoleProfileStore.recordSelected(roleRuntime.selection, task: task, modelContext: modelContext)

        Task {
            let result = await SpecEngine.chat(
                messages: history,
                workspacePath: workspacePath,
                skillContext: skillContext,
                utilityRuntime: roleRuntime.configuration
            )

            await MainActor.run {
                isPlanning = false
                switch result {
                case .success(let response):
                    let assistantEvent = TaskEvent(
                        task: task,
                        type: TaskPlanConversationEventTypes.assistantMessage,
                        payload: TaskPlanService.userVisiblePlanningText(from: response)
                    )
                    modelContext.insert(assistantEvent)

                    let existingPlan = TaskPlanService.reconstruct(for: task).plan
                    var plan = TaskPlanService.parsePlanPayload(from: response)
                        ?? TaskPlanFallbackBuilder.plan(from: response, fallbackGoal: msg)
                    if let existingPlan {
                        plan.planID = existingPlan.planID
                        TaskPlanService.recordUpdated(plan, task: task, modelContext: modelContext)
                    } else {
                        TaskPlanService.recordCreated(plan, task: task, modelContext: modelContext)
                    }

                case .failure(let error):
                    let errorEvent = TaskEvent(
                        task: task,
                        type: TaskPlanConversationEventTypes.assistantMessage,
                        payload: "Goal mode failed: \(error.localizedDescription)"
                    )
                    modelContext.insert(errorEvent)
                }

                task.updatedAt = Date()
                WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
                threadViewModel.refreshSnapshot(for: task)
            }
        }
    }

    private var planningWorkspacePath: String {
        if !TaskWorkspaceAccess(task: task).codeWorkingDirectory.isEmpty {
            return TaskWorkspaceAccess(task: task).codeWorkingDirectory
        }
        return task.workspace?.primaryPath ?? FileManager.default.currentDirectoryPath
    }

    private func initializeTaskPolicySelection() {
        let level = TaskPolicyStore.latestSelectedLevel(for: task)
            ?? AgentPolicyDefaults.effectiveLevel(
                workspace: task.workspace,
                globalDefaultRaw: defaultAgentPolicyLevelRaw,
                skipPermissions: skipPermissions
            )
        taskPolicyLevelRaw = level.rawValue
        skipPermissions = level == .autonomous
    }

    private func recordCurrentTaskPolicyIfNeeded(source: String) {
        let level = skipPermissions ? AgentPolicyLevel.autonomous : AgentPolicyLevel.normalized(taskPolicyLevelRaw)
        guard TaskPolicyStore.latestSelectedLevel(for: task) != level else { return }
        TaskPolicyStore.recordSelection(
            level: level,
            task: task,
            modelContext: modelContext,
            source: source
        )
    }

    private func planningConversationHistory(appendingUserMessage _: String) -> [(role: String, content: String)] {
        if let exactContext = exactRecentTaskConversationContext(includePlanningAndSystem: false) {
            var messages: [(role: String, content: String)] = [
                (role: "user", content: exactContext)
            ]
            messages.append(contentsOf: currentThreadSnapshot.conversationItems.compactMap { item in
                switch item {
                case .planUserMessage(let text, _):
                    return (role: "user", content: text)
                case .planAssistantMessage(let text, _):
                    return (role: "assistant", content: text)
                case .userMessage, .agentResponse, .scheduleResult, .systemInfo, .recapResult:
                    return nil
                }
            })
            return messages
        }

        let recentSnapshotItems = currentThreadSnapshot.conversationItems.dropFirst().suffix(24)
        var messages: [(role: String, content: String)] = [
            (role: "user", content: "Current task goal:\n\(task.goal)")
        ]
        messages.append(contentsOf: recentSnapshotItems.compactMap { item in
            switch item {
            case .userMessage(let text, _), .planUserMessage(let text, _):
                return (role: "user", content: text)
            case .planAssistantMessage(let text, _):
                return (role: "assistant", content: text)
            case .agentResponse(let run):
                let response = run.output.isEmpty
                    ? currentThreadSnapshot.protocolState(for: run).completionSummary
                    : run.output
                return response.map { (role: "assistant", content: String($0.prefix(2000))) }
            case .scheduleResult, .systemInfo, .recapResult:
                return nil
            }
        })
        return messages
    }

    private func planModeSkillContext() -> String {
        var context = """
        GOAL MODE:
        You are helping the user refine or revise the approved goal and plan for an existing ASTRA task. Do not execute tools, shell commands, writes, or external mutations. Use the visible conversation context to propose a safe execution plan.
        The user confirms the plan through ASTRA's Plan controls. The confirmation button is named "Approve Plan"; do not tell them to click "Create Task" in Goal Mode.

        Return concise planning prose, then include exactly one structured plan line using this prefix:
        ASTRA_PLAN {"version":1,"planID":"UUID","title":"Short title","goal":"Brief goal summary","steps":[{"id":"stable-step-id","title":"Step title","detail":"What to do","status":"pending","risk":"low","likelyTools":["Read"],"doneSignal":"How ASTRA knows this step is done","outputs":[{"kind":"file","scope":"task_output","path":"relative/path.ext","required":true,"prepareParentDirectories":true}]}],"validationContract":{"version":1,"assertions":[{"id":"artifact-exists","scope":"plan","description":"Generated artifact exists","method":"artifact","required":true,"path":"relative/path.ext"},{"id":"artifact-text","scope":"plan","description":"Generated artifact contains expected text","method":"text_contains","required":true,"path":"relative/path.ext","evidenceQuery":"Expected visible text"}]}}

        Step risk must be low, medium, or high. Step status must be pending. Include every likely permission needed for each step: Read for inspection, Grep for search, Write for creating files, Edit for changing existing files, and Bash for tests/builds/scripts. If a step creates an HTML/CSS/JS/file artifact, include Write in likelyTools and add an outputs entry with kind file, scope task_output, and the relative path. Use task_output for generated task artifacts; use workspace only when the user explicitly asks to modify the project/repository. Include a done signal for each step. Include validationContract assertions when the task has verifiable proof, such as commands that must exit 0, artifacts that must exist, file text that must be present, manual approvals, structured text evidence, browser-visible behavior in a generated artifact, or independent verifier review. Use method values command, artifact, text_contains, manual, text_evidence, browser_behavior, or verifier. For generated files, prefer artifact plus text_contains assertions instead of shell commands; set path to the generated artifact path and evidenceQuery to the expected text. For browser_behavior, set path to the generated HTML/artifact path and evidenceQuery to the expected visible text. Command assertions must be a single allowlisted command and must not use shell composition such as &&, ||, semicolons, pipes, or redirects. Use scope plan for final proof and scope step with stepID for step-specific proof. The user must confirm from the Plan panel before execution starts.
        """

        let capabilityContext = taskCapabilitySkillContext()
        if !capabilityContext.isEmpty {
            context += "\n\n" + capabilityContext
        }
        return context
    }

    private func taskCapabilitySkillContext() -> String {
        let resolver = TaskCapabilityResolver(task: task)
        let scope = resolver.promptScope()
        let skills = scope.behaviorSkills
        let connectors = scope.connectors
        let localTools = scope.localTools

        var sections: [String] = []
        if !skills.isEmpty {
            sections.append(skills.map { skill in
                var desc = "## Skill: \(skill.name)\nInstructions:\n\(skill.behaviorInstructions)"
                if !skill.connectors.isEmpty {
                    desc += "\nConnectors: \(skill.connectorSummary)"
                }
                if !skill.localTools.isEmpty {
                    desc += "\nLocal Tools: \(skill.localToolSummary)"
                }
                if !skill.environmentKeys.isEmpty {
                    desc += "\nEnvironment Variables: \(skill.environmentKeys.joined(separator: ", "))"
                }
                if !skill.customTools.isEmpty {
                    desc += "\nCustom Tools: \(skill.customTools.joined(separator: ", "))"
                }
                return desc
            }.joined(separator: "\n\n"))
        }
        if !connectors.isEmpty {
            let connectorList = connectors.map { "- \($0.name) (\($0.serviceType))" }.joined(separator: "\n")
            sections.append("Enabled connectors for this task:\n\(connectorList)")
        }
        if !localTools.isEmpty {
            let toolList = localTools.map { "- \($0.name) (\($0.toolType))" }.joined(separator: "\n")
            sections.append("Enabled local tools for this task:\n\(toolList)")
        }
        if scope.prunedForBrowserTask, !scope.excludedSkillNames.isEmpty {
            sections.append("Configured capabilities excluded from this provider task scope:\n\(scope.excludedSkillNames.map { "- \($0)" }.joined(separator: "\n"))")
        }
        return sections.joined(separator: "\n\n")
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic"]

    private func fileChip(_ file: String) -> some View {
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        let isImage = Self.imageExtensions.contains(ext)

        return HStack(spacing: 6) {
            if isImage, let nsImage = NSImage(contentsOfFile: file) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: Formatters.fileIcon(for: file))
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 16)
            }
            Text(URL(fileURLWithPath: file).lastPathComponent)
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button {
                attachedFiles.removeAll { $0 == file }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(Stanford.ui(11))
                    .foregroundStyle(Stanford.coolGrey.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files or images to attach"
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !attachedFiles.contains(url.path) {
                    attachedFiles.append(url.path)
                }
            }
        }
    }


    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func formatChatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 {
            return "\(clamped) sec"
        }

        let totalMinutes = clamped / 60
        let remainingSeconds = clamped % 60
        if totalMinutes < 60 {
            if remainingSeconds == 0 {
                return "\(totalMinutes) min"
            }
            return "\(totalMinutes) min, \(remainingSeconds) sec"
        }

        let hours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr, \(remainingMinutes) min"
    }

}

// MARK: - Markdown Text View

/// Renders text as formatted markdown with support for headers, bold, italic,
/// code blocks, lists, tables, dividers, blockquotes, and system notices.
struct MarkdownTextView: View {
    let text: String
    let maxContentWidth: CGFloat?
    let onSuggestedNextStep: ((String) -> Void)?
    @State private var blocks: [MarkdownBlock] = []
    @State private var skippedSuggestionIDs: Set<UUID> = []

    init(
        text: String,
        maxContentWidth: CGFloat? = Stanford.chatParagraphMaxWidth,
        onSuggestedNextStep: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.maxContentWidth = maxContentWidth
        self.onSuggestedNextStep = onSuggestedNextStep
        _blocks = State(initialValue: Self.cachedParse(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                markdownBlockView(
                    block,
                    suggestedNextActions: suggestedNextActions(for: block, at: index)
                )
                    .frame(maxWidth: maxWidth(for: block), alignment: .leading)
                    .padding(.top, topSpacing(for: block, previous: index > 0 ? blocks[index - 1] : nil))
            }
        }
        .textSelection(.enabled)
        .tint(Stanford.link)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text) { _, newText in
            blocks = Self.cachedParse(newText)
            skippedSuggestionIDs.removeAll(keepingCapacity: true)
        }
    }

    @ViewBuilder
    private func markdownBlockView(_ block: MarkdownBlock, suggestedNextActions: [SuggestedNextAction] = []) -> some View {
        switch block.kind {
        case .codeBlock(let lang):
            codeBlockView(lang: lang, code: block.content)

        case .table:
            tableView(block.content)

        case .divider:
            Divider()
                .padding(.vertical, 6)

        case .heading(let level):
            Text(Self.markdownAttributed(block.content))
                .font(level == 1 ? Stanford.heading(20) : level == 2 ? Stanford.heading(18) : Stanford.heading(16))
                .foregroundStyle(Stanford.readingText)
                .padding(.bottom, 2)

        case .listItem(let depth, let marker):
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker)
                        .font(Stanford.chatBody(depth == 0 ? 15 : 13))
                        .foregroundStyle(Stanford.coolGrey.opacity(0.72))
                        .frame(width: 24, alignment: .trailing)
                        .padding(.leading, CGFloat(depth) * 18)
                    Text(Self.markdownAttributed(block.content))
                        .font(Stanford.chatBody())
                        .foregroundStyle(Stanford.readingText)
                        .textSelection(.enabled)
                        .lineSpacing(Stanford.chatCompactLineSpacing)
                }

                if let suggestedNextStep = suggestedNextActions.first,
                   let onSuggestedNextStep,
                   !skippedSuggestionIDs.contains(block.id) {
                    SuggestedNextStepControls(
                        onPursue: { onSuggestedNextStep(suggestedNextStep.composerText) },
                        onSkip: { skippedSuggestionIDs.insert(block.id) }
                    )
                    .padding(.leading, 32 + CGFloat(depth) * 18)
                }
            }
            .padding(.vertical, 1)

        case .blockquote:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Stanford.sandstone.opacity(0.5))
                    .frame(width: 3)
                Text(Self.markdownAttributed(block.content, whitespaceMode: .preserving))
                    .font(Stanford.documentExcerpt())
                    .italic()
                    .foregroundStyle(Stanford.readingText.opacity(0.78))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .lineSpacing(Stanford.chatBodyLineSpacing)
            }
            .background(Stanford.fog.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .notice:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(Stanford.ui(14))
                    .foregroundStyle(Stanford.lagunita)
                    .padding(.top, 1)
                Text(Self.markdownAttributed(block.content))
                    .font(Stanford.chatBody(15))
                    .foregroundStyle(Stanford.readingText)
                    .lineSpacing(Stanford.chatCompactLineSpacing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Stanford.lagunita.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .label:
            Text(Self.markdownAttributed(block.content))
                .font(Stanford.chatSection())
                .foregroundStyle(Stanford.readingText)

        case .blank:
            Color.clear.frame(height: 2)

        case .text:
            VStack(alignment: .leading, spacing: 7) {
                Text(Self.markdownAttributed(block.content))
                    .font(Stanford.chatBody())
                    .foregroundStyle(Stanford.readingText)
                    .textSelection(.enabled)
                    .lineSpacing(Stanford.chatBodyLineSpacing)

                if !suggestedNextActions.isEmpty,
                   let onSuggestedNextStep,
                   !skippedSuggestionIDs.contains(block.id) {
                    SuggestedNextActionChips(
                        actions: suggestedNextActions,
                        onPursue: { action in onSuggestedNextStep(action.composerText) },
                        onSkip: { skippedSuggestionIDs.insert(block.id) }
                    )
                }
            }
        }
    }

    private func topSpacing(for block: MarkdownBlock, previous: MarkdownBlock?) -> CGFloat {
        guard let previous else { return 0 }
        if previous.kind == .blank { return 0 }

        switch block.kind {
        case .blank:
            return 6
        case .heading:
            return previous.kind == .divider ? 8 : 14
        case .listItem:
            if case .listItem = previous.kind { return 6 }
            return 8
        case .codeBlock, .table, .blockquote, .notice:
            return 10
        case .divider:
            return 12
        case .label:
            return 10
        case .text:
            switch previous.kind {
            case .heading, .label:
                return 6
            case .text:
                return 9
            default:
                return 8
            }
        }
    }

    private func maxWidth(for block: MarkdownBlock) -> CGFloat? {
        guard let maxContentWidth else { return nil }
        switch block.kind {
        case .table:
            return maxContentWidth
        default:
            return maxContentWidth
        }
    }

    private func suggestedNextActions(for block: MarkdownBlock, at index: Int) -> [SuggestedNextAction] {
        guard onSuggestedNextStep != nil else { return [] }
        return Self.suggestedNextActions(for: block, at: index, in: blocks)
    }

    static func suggestedNextActions(in blocks: [MarkdownBlock]) -> [SuggestedNextAction] {
        blocks.enumerated().flatMap { index, block in
            suggestedNextActions(for: block, at: index, in: blocks)
        }
    }

    static func suggestedNextActions(for block: MarkdownBlock, at index: Int, in blocks: [MarkdownBlock]) -> [SuggestedNextAction] {
        switch block.kind {
        case .listItem(let depth, _):
            guard depth == 0,
                  isInsideSuggestedNextStepsSection(index: index, blocks: blocks),
                  let title = normalizedSuggestedAction(block.content) else {
                return []
            }
            return [SuggestedNextAction(title: title)]

        case .text:
            return inlineSuggestedNextActions(from: block.content)

        default:
            return []
        }
    }

    private static func isInsideSuggestedNextStepsSection(index: Int, blocks: [MarkdownBlock]) -> Bool {
        guard index > 0 else { return false }
        for priorIndex in stride(from: index - 1, through: 0, by: -1) {
            let prior = blocks[priorIndex]
            if case .heading = prior.kind {
                let heading = prior.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return heading == "next steps" || heading == "suggested next steps"
            }
            if case .divider = prior.kind { return false }
        }
        return false
    }

    private static func inlineSuggestedNextActions(from content: String) -> [SuggestedNextAction] {
        let plain = plainMarkdownText(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remainder = inlineSuggestionRemainder(from: plain) else { return [] }

        var seen = Set<String>()
        var actions: [SuggestedNextAction] = []
        for candidate in splitInlineSuggestionRemainder(remainder) {
            guard let title = normalizedSuggestedAction(candidate) else { continue }
            let key = title.lowercased()
            guard seen.insert(key).inserted else { continue }
            actions.append(SuggestedNextAction(title: title))
            if actions.count == 4 { break }
        }
        return actions
    }

    private static func inlineSuggestionRemainder(from text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = normalized.lowercased()
        for prefix in ["next suggestion:", "next suggestions:"] where lowercase.hasPrefix(prefix) {
            let start = normalized.index(normalized.startIndex, offsetBy: prefix.count)
            let remainder = normalized[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    private static func splitInlineSuggestionRemainder(_ text: String) -> [String] {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ";", with: ",")

        while let last = normalized.last, [".", "!", "?"].contains(last) {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let commaParts = normalized
            .split(separator: ",")
            .map { String($0) }

        if commaParts.count > 1 {
            return commaParts
        }

        return [normalized]
    }

    private static func normalizedSuggestedAction(_ text: String) -> String? {
        var value = plainMarkdownText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        for conjunction in ["and ", "or "] {
            if value.lowercased().hasPrefix(conjunction) {
                value = String(value.dropFirst(conjunction.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        value = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".;:,")))

        guard value.count >= 3,
              value.count <= 140,
              value.rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        return value
    }

    private final class MarkdownBlockCacheEntry {
        let blocks: [MarkdownBlock]

        init(blocks: [MarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private static let parseCache: NSCache<NSString, MarkdownBlockCacheEntry> = {
        let cache = NSCache<NSString, MarkdownBlockCacheEntry>()
        cache.countLimit = 500
        return cache
    }()

    private static func cachedParse(_ text: String) -> [MarkdownBlock] {
        let key = NSString(string: text)
        if let cached = parseCache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = parse(text)
        parseCache.setObject(MarkdownBlockCacheEntry(blocks: blocks), forKey: key)
        return blocks
    }

    // MARK: - Code Block

    private func codeBlockView(lang: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !lang.isEmpty {
                    Text(lang)
                        .font(Stanford.chatRaw(11).weight(.semibold))
                        .foregroundStyle(Stanford.coolGrey)
                        .textCase(.uppercase)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(Stanford.ui(11))
                        Text("Copy")
                            .font(Stanford.ui(11))
                    }
                    .foregroundStyle(Stanford.coolGrey)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Stanford.chatRaw())
                    .foregroundStyle(Stanford.readingText)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.fog.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Table Rendering

    private func tableView(_ raw: String) -> some View {
        let table = Self.parseTable(raw)
        let columnWidths = Self.tableColumnWidths(table.rows, columnCount: table.columnCount)
        let numericColumns = Self.numericTableColumns(table.rows, columnCount: table.columnCount)
        let tableWidth = Self.tableRenderedWidth(columnWidths, columnCount: table.columnCount)
        let showsOverflowCue = tableWidth > min(maxContentWidth ?? Stanford.chatParagraphMaxWidth, Stanford.chatParagraphMaxWidth)

        return ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIdx, cells in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<table.columnCount, id: \.self) { colIdx in
                                let cell = colIdx < cells.count ? cells[colIdx] : ""
                                let alignment = numericColumns.contains(colIdx) ? MarkdownTableAlignment.trailing : table.alignment(for: colIdx)

                                tableCellView(cell, rowIndex: rowIdx, alignment: alignment)
                                    .frame(width: columnWidths[colIdx], alignment: alignment.frameAlignment)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)

                                if colIdx < table.columnCount - 1 {
                                    Divider()
                                        .opacity(0.25)
                                }
                            }
                        }
                        .background(rowIdx == 0 ? Stanford.fog.opacity(0.5) : (rowIdx % 2 == 0 ? Stanford.fog.opacity(0.2) : Color.clear))

                        if rowIdx == 0 {
                            Divider()
                                .opacity(0.35)
                        } else if table.rows.count >= 5 && rowIdx < table.rows.count - 1 {
                            Divider()
                                .opacity(0.16)
                        }
                    }
                }
                .frame(width: tableWidth, alignment: .leading)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.visible)

            if showsOverflowCue {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor).opacity(0),
                        Color(nsColor: .windowBackgroundColor).opacity(0.84)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 26)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Stanford.sandstone.opacity(0.3), lineWidth: 0.5))
    }

    @ViewBuilder
    private func tableCellView(
        _ cell: String,
        rowIndex: Int,
        alignment: MarkdownTableAlignment
    ) -> some View {
        if rowIndex > 0, let statusColor = Self.tableStatusStyle(for: cell) {
            Text(cell)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.10))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else if rowIndex > 0, Self.isNumericTableCell(cell) {
            Text(cell)
                .font(Stanford.chatRaw(13))
                .foregroundStyle(Stanford.readingText)
                .textSelection(.enabled)
                .multilineTextAlignment(alignment.textAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        } else {
            Text(Self.markdownAttributed(cell))
                .font(rowIndex == 0 ? Stanford.chatSection(13) : Stanford.chatBody(14))
                .foregroundStyle(Stanford.readingText)
                .textSelection(.enabled)
                .multilineTextAlignment(alignment.textAlignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        }
    }

    private enum MarkdownTableAlignment {
        case leading
        case center
        case trailing

        var textAlignment: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var frameAlignment: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    private struct MarkdownTable {
        let rows: [[String]]
        let alignments: [MarkdownTableAlignment]
        let columnCount: Int

        func alignment(for index: Int) -> MarkdownTableAlignment {
            index < alignments.count ? alignments[index] : .leading
        }
    }

    private static func parseTable(_ raw: String) -> MarkdownTable {
        let lines = raw.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else {
            return MarkdownTable(rows: [], alignments: [], columnCount: 0)
        }

        var rows: [[String]] = []
        var alignments: [MarkdownTableAlignment] = []

        for line in lines {
            let cells = splitTableCells(line)
            if let separatorAlignments = tableSeparatorAlignments(cells) {
                alignments = separatorAlignments
            } else {
                rows.append(cells)
            }
        }

        let columnCount = max(
            rows.map(\.count).max() ?? 0,
            alignments.count
        )

        return MarkdownTable(
            rows: rows,
            alignments: alignments,
            columnCount: columnCount
        )
    }

    private static func tableColumnWidths(_ rows: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }

        return (0..<columnCount).map { column in
            let maxLength = rows.map { row in
                column < row.count ? row[column].count : 0
            }.max() ?? 0

            return max(88, min(320, CGFloat(maxLength) * 7.5 + 32))
        }
    }

    private static func tableRenderedWidth(_ widths: [CGFloat], columnCount: Int) -> CGFloat {
        let dividerWidth = max(0, columnCount - 1)
        let horizontalPadding = CGFloat(columnCount) * 24
        return widths.reduce(0, +) + horizontalPadding + CGFloat(dividerWidth)
    }

    private static func numericTableColumns(_ rows: [[String]], columnCount: Int) -> Set<Int> {
        guard rows.count > 1 else { return [] }
        var result = Set<Int>()
        for column in 0..<columnCount {
            let bodyCells = rows.dropFirst().compactMap { row -> String? in
                guard column < row.count else { return nil }
                let value = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            guard !bodyCells.isEmpty,
                  bodyCells.allSatisfy(isNumericTableCell) else { continue }
            result.insert(column)
        }
        return result
    }

    private static func isNumericTableCell(_ cell: String) -> Bool {
        let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.,:%$€£¥+-() hHkKmMbBtT")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func tableStatusStyle(for cell: String) -> Color? {
        let normalized = cell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("in progress") || normalized.contains("open") {
            return Stanford.poppy
        }
        if normalized.contains("waiting") || normalized.contains("blocked") {
            return Stanford.sky
        }
        if normalized.contains("done") || normalized.contains("complete") || normalized.contains("resolved") {
            return Stanford.completed
        }
        if normalized.contains("failed") || normalized.contains("error") || normalized.contains("budget") {
            return Stanford.failed
        }
        if normalized.contains("cancelled") || normalized.contains("canceled") {
            return Stanford.cancelled
        }
        if ["critical", "highest", "urgent"].contains(normalized) {
            return Stanford.failed
        }
        if normalized == "high" {
            return Stanford.poppy
        }
        if normalized == "medium" || normalized == "normal" {
            return Stanford.lagunita
        }
        if normalized == "low" || normalized == "unassigned" {
            return Stanford.coolGrey
        }
        return nil
    }

    // MARK: - Parsing

    enum BlockKind: Equatable {
        case text
        case codeBlock(language: String)
        case table
        case divider
        case heading(level: Int)
        case listItem(depth: Int, marker: String)
        case blockquote
        case notice
        case label
        case blank
    }

    struct MarkdownBlock: Identifiable {
        let id = UUID()
        let kind: BlockKind
        let content: String
    }

    struct SuggestedNextAction: Identifiable, Equatable {
        let id: String
        let title: String
        let composerText: String

        init(title: String) {
            self.title = title
            self.composerText = title
            self.id = title.lowercased()
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        if let astBlocks = MarkdownASTBlockParser.parse(text), !astBlocks.isEmpty {
            return astBlocks
        }

        return parseLegacy(text)
    }

    private static func parseLegacy(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        func flushText() {
            let joined = normalizedParagraph(textBuffer)
            if !joined.isEmpty {
                blocks.append(MarkdownBlock(kind: .text, content: joined))
            }
            textBuffer = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code block (```)
            if trimmed.hasPrefix("```") {
                flushText()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(MarkdownBlock(kind: .codeBlock(language: lang), content: codeLines.joined(separator: "\n")))
                continue
            }

            // Horizontal rule / divider (---, ***, ___)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushText()
                blocks.append(MarkdownBlock(kind: .divider, content: ""))
                i += 1
                continue
            }

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushText()
                // Only add blank if the previous block wasn't already a blank/divider
                if let last = blocks.last, last.kind != .blank && last.kind != .divider {
                    blocks.append(MarkdownBlock(kind: .blank, content: ""))
                }
                i += 1
                continue
            }

            // Headings (# through ######), including permissive "#Title" output.
            if let heading = Self.headingMatch(trimmed) {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: heading.level), content: heading.content))
                i += 1
                continue
            }

            // Setext headings:
            // Title
            // =====
            if textBuffer.isEmpty,
               i + 1 < lines.count,
               let level = Self.setextHeadingLevel(lines[i + 1]),
               !trimmed.isEmpty,
               !trimmed.contains("|") {
                flushText()
                blocks.append(MarkdownBlock(kind: .heading(level: level), content: trimmed))
                i += 2
                continue
            }

            // List items (- item, * item, + item, or numbered 1. item)
            if let listMatch = Self.listItemMatch(trimmed) {
                flushText()
                let depth = (line.count - line.drop(while: { $0 == " " }).count) / 2
                let marker = listMatch.marker == "\u{2022}" && depth > 0 ? "\u{25E6}" : listMatch.marker
                blocks.append(MarkdownBlock(
                    kind: .listItem(depth: min(depth, 3), marker: marker),
                    content: listMatch.content
                ))
                i += 1
                continue
            }

            // Blockquotes (> text), including quoted blank lines as paragraph breaks.
            if let firstQuoteLine = Self.blockquoteLineContent(trimmed) {
                flushText()
                var quoteLines: [String] = [firstQuoteLine]
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if let quoteLine = Self.blockquoteLineContent(nextTrimmed) {
                        quoteLines.append(quoteLine)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(MarkdownBlock(kind: .blockquote, content: normalizedBlockquote(quoteLines)))
                continue
            }

            // System notices: [Reminder: ...], [Note: ...], [Warning: ...]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") &&
               (trimmed.contains("Reminder:") || trimmed.contains("Note:") || trimmed.contains("Warning:")) {
                flushText()
                let inner = String(trimmed.dropFirst().dropLast())
                blocks.append(MarkdownBlock(kind: .notice, content: inner))
                i += 1
                continue
            }

            // GitHub-style table detection. Supports optional leading/trailing pipes:
            // A | B
            // --- | ---
            if let table = Self.tableBlock(startingAt: i, in: lines) {
                flushText()
                blocks.append(MarkdownBlock(kind: .table, content: table.lines.joined(separator: "\n")))
                i = table.nextIndex
                continue
            }

            // Label lines: "Something:" at end of a short line (< 60 chars, ends with colon)
            if trimmed.hasSuffix(":") && trimmed.count < 60 && !trimmed.contains("//") {
                flushText()
                blocks.append(MarkdownBlock(kind: .label, content: trimmed))
                i += 1
                continue
            }

            textBuffer.append(line)
            i += 1
        }

        flushText()
        return blocks
    }

    static func normalizedStreamingText(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var normalizedLines: [String] = []
        var paragraph: [String] = []
        var isInsideCodeBlock = false

        func flushParagraph() {
            let normalized = normalizedParagraph(paragraph)
            if !normalized.isEmpty {
                normalizedLines.append(normalized)
            }
            paragraph = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                isInsideCodeBlock.toggle()
                normalizedLines.append(line)
                continue
            }
            if isInsideCodeBlock {
                normalizedLines.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                if normalizedLines.last?.isEmpty != true {
                    normalizedLines.append("")
                }
                continue
            }
            if headingMatch(trimmed) != nil ||
                listItemMatch(trimmed) != nil ||
                blockquoteLineContent(trimmed) != nil ||
                tableHeaderCells(line) != nil {
                flushParagraph()
                normalizedLines.append(line)
                continue
            }
            paragraph.append(line)
        }

        flushParagraph()
        return normalizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedParagraph(_ lines: [String]) -> String {
        var segments: [String] = []
        var current = ""

        for rawLine in lines {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            let hasMarkdownHardBreak = rawLine.hasSuffix("  ") || trimmedLine.hasSuffix("\\")
            let segment = trimmedLine.hasSuffix("\\")
                ? String(trimmedLine.dropLast()).trimmingCharacters(in: .whitespaces)
                : trimmedLine
            guard !segment.isEmpty else { continue }

            if current.isEmpty {
                current = segment
            } else {
                current += " " + segment
            }

            if hasMarkdownHardBreak {
                segments.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            segments.append(current)
        }

        return repairMissingSentenceSpaces(segments.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedBlockquote(_ lines: [String]) -> String {
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let shouldPreserveLineBreaks = lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ||
            nonEmptyLines.filter { $0.count <= 72 }.count > nonEmptyLines.count / 2

        if shouldPreserveLineBreaks {
            return lines
                .map { repairMissingSentenceSpaces($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalizedParagraph(lines)
    }

    private static func repairMissingSentenceSpaces(_ text: String) -> String {
        let pattern = #"([a-z0-9][.!?])([A-Z][a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1 $2"
        )
    }

    private static func headingMatch(_ line: String) -> (level: Int, content: String)? {
        guard line.first == "#" else { return nil }

        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }

        let contentStart = line.index(line.startIndex, offsetBy: hashes)
        var content = String(line[contentStart...])
        if content.first?.isWhitespace == true {
            content = content.trimmingCharacters(in: .whitespaces)
        }

        content = stripClosingHeadingHashes(content)
        guard !content.isEmpty else { return nil }

        return (hashes, content)
    }

    private static func stripClosingHeadingHashes(_ content: String) -> String {
        var trimmed = content.trimmingCharacters(in: .whitespaces)

        guard let lastNonHash = trimmed.lastIndex(where: { $0 != "#" }) else {
            return trimmed
        }

        let hashStart = trimmed.index(after: lastNonHash)
        guard hashStart < trimmed.endIndex,
              trimmed[lastNonHash].isWhitespace else {
            return trimmed
        }

        trimmed.removeSubrange(hashStart..<trimmed.endIndex)
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    private static func setextHeadingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func tableBlock(startingAt index: Int, in lines: [String]) -> (lines: [String], nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        guard tableHeaderCells(lines[index]) != nil else { return nil }

        let separatorCells = splitTableCells(lines[index + 1])
        guard tableSeparatorAlignments(separatorCells) != nil else { return nil }

        var tableLines = [lines[index], lines[index + 1]]
        var nextIndex = index + 2

        while nextIndex < lines.count {
            let candidate = lines[nextIndex]
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  tableHeaderCells(candidate) != nil,
                  tableSeparatorAlignments(splitTableCells(candidate)) == nil else {
                break
            }

            tableLines.append(candidate)
            nextIndex += 1
        }

        return (tableLines, nextIndex)
    }

    private static func tableHeaderCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        let cells = splitTableCells(line)
        guard cells.count >= 2 else { return nil }
        return cells
    }

    private static func splitTableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") {
            row.removeFirst()
        }
        if row.hasSuffix("|") {
            row.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        var isInsideCodeSpan = false

        for character in row {
            if character == "`", !isEscaped {
                isInsideCodeSpan.toggle()
                current.append(character)
            } else if character == "|", !isEscaped, !isInsideCodeSpan {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }

            if character == "\\" && !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func tableSeparatorAlignments(_ cells: [String]) -> [MarkdownTableAlignment]? {
        guard cells.count >= 2 else { return nil }

        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            guard let alignment = tableSeparatorAlignment(cell) else { return nil }
            alignments.append(alignment)
        }
        return alignments
    }

    private static func tableSeparatorAlignment(_ cell: String) -> MarkdownTableAlignment? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }

        let startsWithColon = trimmed.hasPrefix(":")
        let endsWithColon = trimmed.hasSuffix(":")
        var dashes = trimmed
        if startsWithColon {
            dashes.removeFirst()
        }
        if endsWithColon {
            dashes.removeLast()
        }

        guard dashes.count >= 3,
              dashes.allSatisfy({ $0 == "-" }) else {
            return nil
        }

        if startsWithColon && endsWithColon { return .center }
        if endsWithColon { return .trailing }
        return .leading
    }

    /// Match list item prefixes: "- ", "* ", "+ ", "1. ", "2. " etc.
    private static func listItemMatch(_ line: String) -> (marker: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return ("\u{2022}", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("* ") && !trimmed.hasPrefix("**") { return ("\u{2022}", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("+ ") { return ("\u{2022}", String(trimmed.dropFirst(2))) }
        // Numbered: "1. ", "2. ", etc.
        if let dotIdx = trimmed.firstIndex(of: "."),
           dotIdx != trimmed.startIndex,
           trimmed[trimmed.startIndex..<dotIdx].allSatisfy(\.isNumber),
           trimmed.index(after: dotIdx) < trimmed.endIndex,
           trimmed[trimmed.index(after: dotIdx)] == " " {
            let marker = String(trimmed[trimmed.startIndex...dotIdx])
            return (marker, String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...]))
        }
        return nil
    }

    private static func blockquoteLineContent(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        var content = String(line.dropFirst())
        if content.first?.isWhitespace == true {
            content.removeFirst()
        }
        return content
    }

    static func markdownAttributed(
        _ text: String,
        whitespaceMode: MarkdownLinkifier.WhitespaceMode = .normalized
    ) -> AttributedString {
        MarkdownLinkifier.markdownAttributed(text, whitespaceMode: whitespaceMode)
    }

    static func plainMarkdownText(_ text: String) -> String {
        String(markdownAttributed(text).characters)
    }

    static func monospacedTableText(_ raw: String) -> String {
        let table = parseTable(raw)
        guard table.columnCount > 0, !table.rows.isEmpty else { return raw }

        let widths = (0..<table.columnCount).map { column in
            max(
                3,
                table.rows.map { row in
                    column < row.count ? row[column].count : 0
                }.max() ?? 0
            )
        }

        func padded(_ value: String, column: Int) -> String {
            let width = widths[column]
            let padding = max(0, width - value.count)

            switch table.alignment(for: column) {
            case .leading:
                return value + String(repeating: " ", count: padding)
            case .center:
                let leading = padding / 2
                let trailing = padding - leading
                return String(repeating: " ", count: leading) + value + String(repeating: " ", count: trailing)
            case .trailing:
                return String(repeating: " ", count: padding) + value
            }
        }

        func rowText(_ cells: [String]) -> String {
            (0..<table.columnCount)
                .map { column in
                    padded(column < cells.count ? cells[column] : "", column: column)
                }
                .joined(separator: "  ")
        }

        let separator = widths.enumerated()
            .map { column, width in
                padded(String(repeating: "-", count: width), column: column)
            }
            .joined(separator: "  ")

        var renderedRows: [String] = []
        for (index, row) in table.rows.enumerated() {
            renderedRows.append(rowText(row))
            if index == 0 {
                renderedRows.append(separator)
            }
        }

        return renderedRows.joined(separator: "\n")
    }
}

private struct SuggestedNextStepControls: View {
    let onPursue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPursue) {
                Label("Pursue", systemImage: "arrow.right.circle")
                    .font(Stanford.caption(11).weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Stanford.lagunita.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
            )
            .help("Move this suggestion into the composer")

            Button(action: onSkip) {
                Text("Skip")
                    .font(Stanford.caption(11).weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Hide this suggestion")
        }
        .textSelection(.disabled)
    }
}

private struct SuggestedNextActionChips: View {
    let actions: [MarkdownTextView.SuggestedNextAction]
    let onPursue: (MarkdownTextView.SuggestedNextAction) -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        actionButton(action)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(actions) { action in
                        actionButton(action)
                            .frame(maxWidth: 340, alignment: .leading)
                    }
                }
            }

            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(Stanford.caption(10).weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Stanford.coolGrey.opacity(0.78))
            .help("Hide these suggestions")
            .accessibilityLabel("Hide suggested actions")
        }
        .textSelection(.disabled)
    }

    private func actionButton(_ action: MarkdownTextView.SuggestedNextAction) -> some View {
        Button {
            onPursue(action)
        } label: {
            Label {
                Text(action.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "arrow.right.circle")
            }
            .font(Stanford.caption(11).weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Stanford.lagunita)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Stanford.lagunita.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Stanford.lagunita.opacity(0.16), lineWidth: 1)
        )
        .help("Move \"\(action.title)\" into the composer")
        .accessibilityLabel("Pursue suggestion: \(action.title)")
    }
}

// MARK: - Clickable Path Text

struct ClickablePathText: View {
    let text: String
    let workspacePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let lineSegments = Self.parseSegments(from: line, workspacePath: workspacePath)
                if lineSegments.contains(where: { $0.isPath }) {
                    HStack(spacing: 0) {
                        ForEach(lineSegments) { seg in
                            if seg.isPath {
                                Button {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: seg.resolvedPath!))
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: seg.isDirectory ? "folder.fill" : "doc.fill")
                                            .font(Stanford.ui(11))
                                        Text(seg.text)
                                            .underline()
                                    }
                                    .font(Stanford.chatRaw())
                                    .foregroundStyle(Stanford.lagunita)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(seg.resolvedPath!)")
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            } else {
                                Text(markdownInline(seg.text))
                                    .font(Stanford.chatBody())
                                    .foregroundStyle(Stanford.readingText)
                            }
                        }
                    }
                } else {
                    Text(markdownInline(line))
                        .font(Stanford.chatBody())
                        .foregroundStyle(Stanford.readingText)
                        .textSelection(.enabled)
                }
            }
        }
        .lineSpacing(Stanford.chatBodyLineSpacing)
    }

    private func markdownInline(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }

    // MARK: - Path Detection

    struct TextSegment: Identifiable {
        let id = UUID()
        let text: String
        let resolvedPath: String?
        let isDirectory: Bool

        var isPath: Bool { resolvedPath != nil }
    }

    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?:(?:/[\w.@\-]+)+(?:\.\w+)?|(?:\.{0,2}/)?(?:[\w.@\-]+/)+[\w.@\-]+(?:\.\w+)?)"#
    )

    static func parseSegments(from text: String, workspacePath: String) -> [TextSegment] {
        guard let regex = pathRegex else {
            return [TextSegment(text: text, resolvedPath: nil, isDirectory: false)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        if matches.isEmpty {
            return [TextSegment(text: text, resolvedPath: nil, isDirectory: false)]
        }

        var segments: [TextSegment] = []
        var lastEnd = 0

        for match in matches {
            let range = match.range
            if range.location > lastEnd {
                let before = nsText.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
                segments.append(TextSegment(text: before, resolvedPath: nil, isDirectory: false))
            }

            let pathStr = nsText.substring(with: range)
            let resolved: String
            if pathStr.hasPrefix("/") {
                resolved = pathStr
            } else if !workspacePath.isEmpty {
                resolved = (workspacePath as NSString).appendingPathComponent(pathStr)
            } else {
                resolved = pathStr
            }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) {
                segments.append(TextSegment(text: pathStr, resolvedPath: resolved, isDirectory: isDir.boolValue))
            } else {
                segments.append(TextSegment(text: pathStr, resolvedPath: nil, isDirectory: false))
            }

            lastEnd = range.location + range.length
        }

        if lastEnd < nsText.length {
            let remaining = nsText.substring(from: lastEnd)
            segments.append(TextSegment(text: remaining, resolvedPath: nil, isDirectory: false))
        }

        return segments
    }
}

// MARK: - Resizable Divider

struct ResizeDivider: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Stanford.lagunita.opacity(0.4) : Stanford.fog)
            .frame(height: 6)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isDragging ? Stanford.lagunita : Stanford.coolGrey.opacity(0.4))
                    .frame(width: 36, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let newHeight = height + value.translation.height
                        height = min(maxHeight, max(minHeight, newHeight))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
