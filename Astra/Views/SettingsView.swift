import AppKit
import SwiftUI
import ASTRACore

struct SettingsView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @AppStorage(AppStorageKeys.defaultModel) private var defaultModel = TaskExecutionDefaults.model
    @AppStorage(AppStorageKeys.defaultTokenBudget) private var defaultTokenBudget = TaskExecutionDefaults.tokenBudget
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @AppStorage(AppStorageKeys.defaultRuntimeID) private var defaultRuntimeID = TaskExecutionDefaults.runtime.rawValue
    @AppStorage(AppStorageKeys.claudePath) private var claudePath = ""
    @AppStorage(AppStorageKeys.copilotPath) private var copilotPath = ""
    @AppStorage(AppStorageKeys.runtimeProviderSettingsRevision) private var runtimeProviderSettingsRevision = 0
    @AppStorage(AppStorageKeys.roleProfileRevision) private var roleProfileRevision = 0
    @AppStorage(AppStorageKeys.workspacesRoot) private var workspacesRoot = ""
    @AppStorage(AppStorageKeys.timeoutSeconds) private var timeoutSeconds = 600
    @AppStorage(AppStorageKeys.validationModel) private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage("workerPoolSize") private var workerPoolSize = 3
    @AppStorage(AppLogger.sensitiveModeKey) private var sensitiveMode = true
    @AppStorage(AppStorageKeys.runtimeStreamDebugCapture) private var runtimeStreamDebugCapture = LoggingPreferences.defaultRuntimeStreamDebugCapture
    @AppStorage(AppStorageKeys.browserDebugCapture) private var browserDebugCapture = LoggingPreferences.defaultBrowserDebugCapture
    @AppStorage(AppStorageKeys.logRetentionDays) private var logRetentionDays = LoggingPreferences.defaultLogRetentionDays
    @AppStorage(AppStorageKeys.browserAutoPromoteGoogleWorkspace) private var browserAutoPromoteGoogleWorkspace = false
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage(AppStorageKeys.claudeAvailableModels) private var claudeAvailableModels = ""
    @AppStorage(AppStorageKeys.copilotAvailableModels) private var copilotAvailableModels = ""
    @AppStorage(AppStorageKeys.runtimeModelCacheRevision) private var runtimeModelCacheRevision = 0

    private let budgetPresets = TaskExecutionDefaults.budgetPresets

    @State private var roleProfileDrafts: [TaskRoleID: TaskRoleProfile] = [:]
    @StateObject private var macOSPermissions = MacOSPermissionsViewModel()

    @MainActor
    init(appUpdateController: AppUpdateController) {
        self.appUpdateController = appUpdateController
    }

    var body: some View {
        TabView {
            runtimeSettingsTab
                .tabItem {
                    Label("Runtime", systemImage: "cpu")
                }

            roleProfilesSettingsTab
                .tabItem {
                    Label("Roles", systemImage: "person.2")
                }

            permissionsSettingsTab
                .tabItem {
                    Label("Permissions", systemImage: "checkmark.shield")
                }

            defaultsSettingsTab
                .tabItem {
                    Label("Defaults", systemImage: "slider.horizontal.3")
                }

            appearanceSettingsTab
                .tabItem {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }

            updatesSettingsTab
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            dataSettingsTab
                .tabItem {
                    Label("Data", systemImage: "folder")
                }
        }
        .frame(width: 740, height: 640)
        .navigationTitle("Settings")
        .scenePadding()
        .onAppear {
            loadRoleProfileDrafts()
        }
        .onChange(of: claudeAvailableModels) {
            alignDefaultModelsWithRuntime()
        }
        .onChange(of: copilotAvailableModels) {
            alignDefaultModelsWithRuntime()
        }
        .onChange(of: runtimeModelCacheRevision) {
            alignDefaultModelsWithRuntime()
        }
        .onChange(of: runtimeProviderSettingsRevision) {
            loadRoleProfileDrafts()
        }
        .onChange(of: roleProfileRevision) {
            loadRoleProfileDrafts()
        }
        .onChange(of: logRetentionDays) {
            AppLogger.rotateIfNeeded()
        }
    }

    private var runtimeSettingsTab: some View {
        SettingsRuntimeTab(
            defaultModel: $defaultModel,
            defaultTokenBudget: $defaultTokenBudget,
            defaultAgentPolicyLevelRaw: $defaultAgentPolicyLevelRaw,
            defaultRuntimeID: $defaultRuntimeID,
            claudePath: $claudePath,
            copilotPath: $copilotPath,
            runtimeProviderSettingsRevision: $runtimeProviderSettingsRevision,
            claudeAvailableModels: $claudeAvailableModels,
            copilotAvailableModels: $copilotAvailableModels,
            runtimeModelCacheRevision: $runtimeModelCacheRevision,
            validationModel: $validationModel
        )
    }

    private var permissionsSettingsTab: some View {
        Form {
            Section("macOS Permissions") {
                MacOSPermissionsSectionView(
                    context: .settings,
                    workspaceRoot: resolvedWorkspacesRoot,
                    model: macOSPermissions
                )
            }
        }
        .formStyle(.grouped)
    }

    private var roleProfilesSettingsTab: some View {
        Form {
            Section("Mission Roles") {
                ForEach(TaskRoleID.allCases) { role in
                    roleProfileRow(role)
                }
            }

            Section("How ASTRA Uses These") {
                Text("Planner, verifier, browser tester, and summarizer profiles choose internal utility runs. Worker remains task-specific, but its defaults seed new task settings. Verifier defaults prefer a different configured provider when one is available.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func roleProfileRow(_ role: TaskRoleID) -> some View {
        let profile = roleProfileDraft(for: role)
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: profile.runtimeID)
        let source = TaskRoleProfileStore.selection(
            for: role,
            defaultRuntimeID: defaultRuntimeID,
            defaultModel: defaultModel,
            validationModel: validationModel,
            defaultBudget: defaultTokenBudget,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            providerSettings: providerSettingsForReadiness,
            cache: runtimeModelCache
        ).source

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: role.symbolName)
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(role.label)
                        .font(Stanford.body(14).weight(.semibold))
                    Text(role.detail)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(source == "role_profile" ? "Custom" : "Default")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(source == "role_profile" ? Stanford.paloAltoGreen : .secondary)
            }

            Picker("Provider", selection: roleRuntimeBinding(for: role)) {
                ForEach(AgentRuntimeAdapterRegistry.runtimeIDs) { runtime in
                    Text(runtime.displayName).tag(runtime.rawValue)
                }
            }

            roleModelSelectionRow(
                title: "Model",
                role: role,
                runtime: runtime,
                selection: roleModelBinding(for: role)
            )

            HStack {
                Picker("Budget", selection: roleBudgetBinding(for: role)) {
                    ForEach(budgetPresets, id: \.self) { budget in
                        Text(budget == 0 ? "Unlimited" : "\(budget / 1000)k tokens").tag(budget)
                    }
                }
                Picker("Policy", selection: rolePolicyBinding(for: role)) {
                    ForEach(AgentPolicyLevel.primaryCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reset") {
                    TaskRoleProfileStore.clearProfile(role: role)
                    loadRoleProfileDrafts()
                }
                Button("Save") {
                    TaskRoleProfileStore.setProfile(roleProfileDraft(for: role))
                    loadRoleProfileDrafts()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
    }

    private var defaultsSettingsTab: some View {
        Form {
            Section("Defaults") {
                modelSelectionRow(title: "Task Model", selection: $defaultModel)
                Text("Used when ASTRA starts a new task. Suggestions come from \(modelSuggestionSourceText); you can type a custom model ID.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Workspaces Root", text: $workspacesRoot,
                              prompt: Text(AppChannel.current.defaultWorkspacesRoot))
                    Button("Browse") {
                        browseFolder()
                    }
                }
                Text("New workspaces auto-create a subfolder here.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Execution") {
                HStack {
                    Text("Timeout")
                    Spacer()
                    TextField("", value: $timeoutSeconds, format: .number, prompt: Text("600"))
                        .labelsHidden()
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                modelSelectionRow(title: "Utility Model", selection: $validationModel)
                Text("Used for short internal jobs such as title generation and AI validation. Pick a fast, inexpensive model when your provider offers one.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Parallel Workers")
                    Spacer()
                    HStack(spacing: 10) {
                        Text("\(workerPoolSize)")
                            .font(Stanford.body(14).monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(width: 24, alignment: .trailing)
                        Stepper("", value: $workerPoolSize, in: 1...5)
                            .labelsHidden()
                    }
                    .fixedSize()
                }
                Text("Number of tasks that can run simultaneously. Restart app to apply.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceSettingsTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppearancePreference.allCases) { option in
                        Label(option.label, systemImage: option.symbolName)
                            .tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("“System” follows your macOS appearance. Choose Light or Dark to pin ASTRA regardless of the system setting.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy & Logging") {
                Toggle("Sensitive Mode", isOn: $sensitiveMode)
                Text("When enabled, operational logs sanitize secrets, emails, token-like values, and local paths before they are written. Task history remains available as product data for review.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Toggle("Runtime Stream Debug Logging", isOn: $runtimeStreamDebugCapture)
                Text("When enabled, provider runs write bounded stream diagnostics, raw-line samples, unknown JSON shapes, and stderr tails to task logs. ASTRA_STREAM_DEBUG can still override this for one launch.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Toggle("Browser Debug Capture", isOn: $browserDebugCapture)
                Text("When enabled, browser-control tasks receive ASTRA_BROWSER_DEBUG_CAPTURE=1. Failed browser actions persist a per-task browser-flight JSONL entry with a compact tree, console/navigation/network summaries, and a screenshot thumbnail that may contain visible page content. Controlled Chromium uses probed CDP event streams; embedded WebKit uses page instrumentation.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Picker("Keep Logs", selection: $logRetentionDays) {
                    ForEach(LoggingPreferences.logRetentionDayOptions, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                Text("ASTRA removes main, task, breadcrumb, and browser-flight log files older than this retention window during normal logging.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Toggle("Auto-promote Google Workspace helpers", isOn: $browserAutoPromoteGoogleWorkspace)
                Text("When enabled, Google Drive and Docs helpers may switch an Embedded browser task to Controlled mode before acting. Leave off when testing Embedded browser behavior.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Help & Onboarding") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("First-run wizard")
                            .font(Stanford.body(14))
                        Text("Re-run the environment check and catalog overview.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Onboarding Again") {
                        // Flip the gate; ContentView's sheet is bound to
                        // `!hasCompletedOnboarding` and will re-present.
                        hasCompletedOnboarding = false
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var updatesSettingsTab: some View {
        Form {
            Section("App Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Installed Build")
                            .font(Stanford.body(14))
                        Text(AppBuildInfo.current.channelDisplayName)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(AppBuildInfo.current.installedBuildSummary)
                        .font(Stanford.caption(12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automatic update checks")
                            .font(Stanford.body(14))
                        Text(appUpdateController.statusMessage ?? "\(AppChannel.current.displayName) checks the signed Sparkle appcast for GitHub Release updates.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") {
                        appUpdateController.checkForUpdates()
                    }
                    .disabled(!appUpdateController.canCheckForUpdates)
                }
                Text(AppUpdateController.defaultFeedURL)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var dataSettingsTab: some View {
        Form {
            Section("Data Locations") {
                dataLocationRow("App Channel", path: AppChannel.current.displayName, canOpen: false)
                dataLocationRow("App Support", path: WorkspaceRecoveryService.applicationSupportDirectory.path)
                dataLocationRow("SwiftData Store", path: WorkspaceRecoveryService.storeURL.path)
                dataLocationRow("Workspaces", path: resolvedWorkspacesRoot)
                dataLocationRow("Workspace Support", path: "<workspace>/.astra", canOpen: false)
                dataLocationRow("Logs", path: AppLogger.mainLogFile.deletingLastPathComponent().path)
                dataLocationRow("Provider Sessions", path: NSHomeDirectory() + "/.claude/projects")
                dataLocationRow("ASTRA Tools", path: NSHomeDirectory() + "/.astra")
                if FileManager.default.fileExists(atPath: WorkspaceRecoveryService.legacyStoreURL.path) {
                    dataLocationRow("Legacy Store", path: WorkspaceRecoveryService.legacyStoreURL.path)
                }
                Text("App state, workspace artifacts, logs, secrets, and provider session data intentionally live in separate macOS-standard locations.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var resolvedWorkspacesRoot: String {
        workspacesRoot.isEmpty ? AppChannel.current.defaultWorkspacesRoot : workspacesRoot
    }

    private var selectedRuntime: AgentRuntimeID {
        AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
    }

    private var runtimeModels: [String] {
        RuntimeModelAvailability.models(
            for: selectedRuntime,
            cache: runtimeModelCache
        )
    }

    private var modelSuggestionSourceText: String {
        let source = RuntimeModelAvailability.hasCachedModels(
            for: selectedRuntime,
            cache: runtimeModelCache
        ) ? "the latest \(selectedRuntime.displayName) check" : "built-in \(selectedRuntime.displayName) defaults"
        return source
    }

    private var runtimeModelCache: RuntimeModelAvailabilityCache {
        _ = runtimeModelCacheRevision
        return RuntimeModelAvailabilityCache.appStorage(
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels
        )
    }

    private var providerSettingsForReadiness: AgentRuntimeProviderSettings {
        var settings = RuntimeProviderSettingsStore.settings()
        settings.setExecutablePath(claudePath, for: .claudeCode)
        settings.setExecutablePath(copilotPath, for: .copilotCLI)
        return settings
    }

    private func modelSelectionRow(title: String, selection: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
            Spacer()
            TextField("Model ID", text: selection, prompt: Text("Type or choose a model"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 260, maxWidth: 360)
                .textSelection(.enabled)
            Menu {
                ForEach(runtimeModels, id: \.self) { model in
                    Button {
                        selection.wrappedValue = model
                    } label: {
                        ModelMenuItemLabel(
                            model: model,
                            displayName: RuntimeModelAvailability.displayName(
                                for: model,
                                runtime: selectedRuntime,
                                cache: runtimeModelCache
                            ),
                            isSelected: selection.wrappedValue == model
                        )
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(12).weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose \(title)")
            .help("Choose \(title)")
        }
    }

    private func roleModelSelectionRow(
        title: String,
        role: TaskRoleID,
        runtime: AgentRuntimeID,
        selection: Binding<String>
    ) -> some View {
        let models = RuntimeModelAvailability.models(for: runtime, cache: runtimeModelCache)
        return HStack(alignment: .center, spacing: 12) {
            Text(title)
            Spacer()
            TextField("Model ID", text: selection, prompt: Text("Type or choose a model"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 260, maxWidth: 360)
                .textSelection(.enabled)
            Menu {
                ForEach(models, id: \.self) { model in
                    Button {
                        roleModelBinding(for: role).wrappedValue = model
                    } label: {
                        ModelMenuItemLabel(
                            model: model,
                            displayName: RuntimeModelAvailability.displayName(
                                for: model,
                                runtime: runtime,
                                cache: runtimeModelCache
                            ),
                            isSelected: selection.wrappedValue == model
                        )
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(12).weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose \(title)")
            .help("Choose \(title)")
        }
    }

    private func loadRoleProfileDrafts() {
        roleProfileDrafts = Dictionary(
            uniqueKeysWithValues: TaskRoleID.allCases.map { role in
                let selection = TaskRoleProfileStore.selection(
                    for: role,
                    defaultRuntimeID: defaultRuntimeID,
                    defaultModel: defaultModel,
                    validationModel: validationModel,
                    defaultBudget: defaultTokenBudget,
                    defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
                    providerSettings: providerSettingsForReadiness,
                    cache: runtimeModelCache
                )
                return (role, selection.profile)
            }
        )
    }

    private func roleProfileDraft(for role: TaskRoleID) -> TaskRoleProfile {
        if let draft = roleProfileDrafts[role] {
            return draft
        }
        return TaskRoleProfileStore.selection(
            for: role,
            defaultRuntimeID: defaultRuntimeID,
            defaultModel: defaultModel,
            validationModel: validationModel,
            defaultBudget: defaultTokenBudget,
            defaultPolicyLevelRaw: defaultAgentPolicyLevelRaw,
            providerSettings: providerSettingsForReadiness,
            cache: runtimeModelCache
        ).profile
    }

    private func updateRoleProfileDraft(_ role: TaskRoleID, mutate: (inout TaskRoleProfile) -> Void) {
        var draft = roleProfileDraft(for: role)
        mutate(&draft)
        roleProfileDrafts[role] = draft
    }

    private func roleRuntimeBinding(for role: TaskRoleID) -> Binding<String> {
        Binding(
            get: { roleProfileDraft(for: role).runtimeID },
            set: { runtimeID in
                updateRoleProfileDraft(role) { draft in
                    let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: runtimeID)
                    draft.runtimeID = runtime.rawValue
                    draft.model = RuntimeModelAvailability.modelForRuntimeSwitch(
                        currentModel: draft.model,
                        to: runtime,
                        cache: runtimeModelCache
                    )
                }
            }
        )
    }

    private func roleModelBinding(for role: TaskRoleID) -> Binding<String> {
        Binding(
            get: { roleProfileDraft(for: role).model },
            set: { model in
                updateRoleProfileDraft(role) { draft in
                    draft.model = model
                }
            }
        )
    }

    private func roleBudgetBinding(for role: TaskRoleID) -> Binding<Int> {
        Binding(
            get: { roleProfileDraft(for: role).tokenBudget },
            set: { budget in
                updateRoleProfileDraft(role) { draft in
                    draft.tokenBudget = budget
                }
            }
        )
    }

    private func rolePolicyBinding(for role: TaskRoleID) -> Binding<String> {
        Binding(
            get: { roleProfileDraft(for: role).policyLevelRaw },
            set: { policy in
                updateRoleProfileDraft(role) { draft in
                    draft.policyLevelRaw = AgentPolicyLevel.normalized(policy).userFacingLevel.rawValue
                }
            }
        )
    }

    private func dataLocationRow(_ title: String, path: String, canOpen: Bool = true) -> some View {
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.body(15))
                Text(path)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer()
            if canOpen {
                Button("Open") {
                    openLocation(path)
                }
                .disabled(!FileManager.default.fileExists(atPath: path))
            }
        }
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select root folder for workspaces"
        if panel.runModal() == .OK, let url = panel.url {
            workspacesRoot = url.path
        }
    }

    private func openLocation(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    private func alignDefaultModelsWithRuntime(resetToRuntimeSuggestion: Bool = false) {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        let previousDefaultModel = defaultModel
        let previousValidationModel = validationModel
        if resetToRuntimeSuggestion {
            defaultModel = RuntimeModelAvailability.modelForRuntimeSwitch(
                currentModel: defaultModel,
                to: runtime,
                cache: runtimeModelCache
            )
            validationModel = RuntimeModelAvailability.modelForRuntimeSwitch(
                currentModel: validationModel,
                to: runtime,
                cache: runtimeModelCache
            )
        } else {
            defaultModel = RuntimeModelAvailability.normalizedModel(
                defaultModel,
                for: runtime,
                cache: runtimeModelCache
            )
            validationModel = RuntimeModelAvailability.normalizedModel(
                validationModel,
                for: runtime,
                cache: runtimeModelCache
            )
        }
        AppLogger.breadcrumb(action: "settings_runtime_models_aligned", category: "UI", fields: [
            "source": resetToRuntimeSuggestion ? "runtime_switch" : "model_cache_refresh",
            "runtime": runtime.rawValue,
            "previous_default_model": previousDefaultModel,
            "default_model": defaultModel,
            "default_model_changed": String(previousDefaultModel != defaultModel),
            "previous_validation_model": previousValidationModel,
            "validation_model": validationModel,
            "validation_model_changed": String(previousValidationModel != validationModel)
        ], level: previousDefaultModel == defaultModel && previousValidationModel == validationModel ? .debug : .info)
    }
}
