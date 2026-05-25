import AppKit
import SwiftUI
import ASTRACore

struct SettingsView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @AppStorage("defaultModel") private var defaultModel = TaskExecutionDefaults.model
    @AppStorage(AppStorageKeys.defaultTokenBudget) private var defaultTokenBudget = TaskExecutionDefaults.tokenBudget
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @AppStorage(AppStorageKeys.budgetEnforcementMode) private var budgetEnforcementModeRaw = TaskExecutionDefaults.budgetEnforcementMode.rawValue
    @AppStorage("defaultRuntimeID") private var defaultRuntimeID = TaskExecutionDefaults.runtime.rawValue
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("copilotPath") private var copilotPath = ""
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @AppStorage("timeoutSeconds") private var timeoutSeconds = 600
    @AppStorage("validationModel") private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage("workerPoolSize") private var workerPoolSize = 3
    @AppStorage(AppLogger.sensitiveModeKey) private var sensitiveMode = true
    @AppStorage(AppStorageKeys.runtimeStreamDebugCapture) private var runtimeStreamDebugCapture = LoggingPreferences.defaultRuntimeStreamDebugCapture
    @AppStorage(AppStorageKeys.browserDebugCapture) private var browserDebugCapture = LoggingPreferences.defaultBrowserDebugCapture
    @AppStorage(AppStorageKeys.logRetentionDays) private var logRetentionDays = LoggingPreferences.defaultLogRetentionDays
    @AppStorage(AppStorageKeys.browserAutoPromoteGoogleWorkspace) private var browserAutoPromoteGoogleWorkspace = false
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue
    @AppStorage(AppStorageKeys.claudeProvider) private var claudeProviderRaw = ClaudeProvider.anthropic.rawValue
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @AppStorage(AppStorageKeys.claudeVertexOpusModel) private var claudeVertexOpusModel = ""
    @AppStorage(AppStorageKeys.claudeVertexSonnetModel) private var claudeVertexSonnetModel = ""
    @AppStorage(AppStorageKeys.claudeVertexHaikuModel) private var claudeVertexHaikuModel = ""
    @AppStorage(AppStorageKeys.claudeAvailableModels) private var claudeAvailableModels = ""
    @AppStorage(AppStorageKeys.copilotAvailableModels) private var copilotAvailableModels = ""

    private let budgetPresets = TaskExecutionDefaults.budgetPresets

    @State private var detectedPath = ""
    @State private var detectedCopilotPath = ""
    @State private var readinessReport: RuntimeReadinessReport?
    @State private var isCheckingReadiness = false
    @State private var readinessCheckedAt: Date?
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
        .frame(width: 680, height: 560)
        .navigationTitle("Settings")
        .scenePadding()
        .onAppear {
            detectClaudeCLI()
            detectCopilotCLI()
            Task { await refreshRuntimeReadiness() }
        }
        .onChange(of: readinessSignature) {
            readinessReport = nil
            readinessCheckedAt = nil
        }
        .onChange(of: claudeAvailableModels) {
            alignDefaultModelsWithRuntime()
        }
        .onChange(of: copilotAvailableModels) {
            alignDefaultModelsWithRuntime()
        }
        .onChange(of: logRetentionDays) {
            AppLogger.rotateIfNeeded()
        }
    }

    private var runtimeSettingsTab: some View {
        Form {
            Section("Agent Runtime") {
                Picker("Default Provider", selection: $defaultRuntimeID) {
                    ForEach(AgentRuntimeAdapterRegistry.runtimeIDs) { runtime in
                        Text(runtime.displayName).tag(runtime.rawValue)
                    }
                }
                .onChange(of: defaultRuntimeID) {
                    alignDefaultModelsWithRuntime(resetToRuntimeSuggestion: true)
                }
                Text("New tasks use this provider. Existing tasks keep the provider they were created with.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Budget Guardrail") {
                Picker("Default Budget", selection: $defaultTokenBudget) {
                    ForEach(budgetPresets, id: \.self) { b in
                        Text(b == 0 ? "Unlimited" : "\(b / 1000)k tokens").tag(b)
                    }
                }

                Picker("Enforcement", selection: $budgetEnforcementModeRaw) {
                    ForEach(BudgetEnforcementMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedBudgetEnforcementMode.helpText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Agent Policy") {
                Picker("Default Policy", selection: defaultPolicySelectionBinding) {
                    ForEach(AgentPolicyLevel.primaryCases) { level in
                        Label(level.displayName, systemImage: level.symbolName)
                            .tag(level.rawValue)
                    }
                }

                Text(selectedDefaultPolicyLevel.shortDescription)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Technical Readiness") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        readinessSummary
                        Spacer()
                        Button {
                            Task { await refreshRuntimeReadiness() }
                        } label: {
                            if isCheckingReadiness {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Check Now", systemImage: "checkmark.seal")
                            }
                        }
                        .disabled(isCheckingReadiness)
                    }

                    if let readinessReport {
                        LazyVGrid(columns: readinessColumns, alignment: .leading, spacing: 8) {
                            ForEach(readinessReport.checks) { check in
                                readinessTile(check)
                            }
                        }
                    } else {
                        Text("Run a readiness check to verify the selected runtime, authentication, provider route, and required local tools.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Claude CLI") {
                HStack {
                    TextField("Path", text: $claudePath, prompt: Text("Auto-detected"))
                    Button("Detect") { detectClaudeCLI() }
                }
                if !detectedPath.isEmpty {
                    Text("Detected: \(detectedPath)")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Claude Provider") {
                Picker("Route Through", selection: $claudeProviderRaw) {
                    ForEach(ClaudeProvider.allCases) { provider in
                        Label(provider.label, systemImage: provider.symbolName)
                            .tag(provider.rawValue)
                    }
                }

                if claudeProviderRaw == ClaudeProvider.vertex.rawValue {
                    TextField(
                        "GCP Project ID",
                        text: $claudeVertexProjectID,
                        prompt: Text("my-gcp-project")
                    )
                    TextField(
                        "Region",
                        text: $claudeVertexRegion,
                        prompt: Text("us-east5 or global")
                    )

                    Text("Model aliases — Vertex names look like `claude-opus-4-6@default`, not the plain Anthropic IDs. Without these, the CLI tries names that don't exist on Vertex.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    TextField(
                        "Opus alias",
                        text: $claudeVertexOpusModel,
                        prompt: Text("claude-opus-4-6@default")
                    )
                    TextField(
                        "Sonnet alias",
                        text: $claudeVertexSonnetModel,
                        prompt: Text("claude-sonnet-4-6@default")
                    )
                    TextField(
                        "Haiku alias",
                        text: $claudeVertexHaikuModel,
                        prompt: Text("claude-haiku-4-5@20251001")
                    )

                    Text("ASTRA injects CLAUDE_CODE_USE_VERTEX, ANTHROPIC_VERTEX_PROJECT_ID, CLOUD_ML_REGION, the three ANTHROPIC_DEFAULT_*_MODEL aliases, plus ANTHROPIC_MODEL (= Opus) and ANTHROPIC_SMALL_FAST_MODEL (= Haiku) when spawning the Claude CLI. Vertex auth uses your `gcloud auth application-default login` credentials.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Anthropic routing uses `claude /login`. Pick Google Vertex AI to route through your GCP project instead.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("GitHub Copilot CLI") {
                HStack {
                    TextField("Path", text: $copilotPath, prompt: Text("Auto-detected"))
                    Button("Detect") { detectCopilotCLI() }
                }
                if !detectedCopilotPath.isEmpty {
                    Text("Detected: \(detectedCopilotPath)")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                Text("Copilot uses your GitHub Copilot account and may consume Copilot premium requests.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Text("When enabled, browser-control tasks receive ASTRA_BROWSER_DEBUG_CAPTURE=1. Failed browser actions persist a per-task browser-flight JSONL entry with a compact tree, console/navigation/network summaries, and a screenshot thumbnail, which may include visible page content.")
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
        AgentRuntimeID(rawValue: defaultRuntimeID) ?? TaskExecutionDefaults.runtime
    }

    private var runtimeModels: [String] {
        RuntimeModelAvailability.models(
            for: selectedRuntime,
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels
        )
    }

    private var modelSuggestionSourceText: String {
        let source = RuntimeModelAvailability.hasCachedModels(
            for: selectedRuntime,
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels
        ) ? "the latest \(selectedRuntime.displayName) check" : "built-in \(selectedRuntime.displayName) defaults"
        return source
    }

    private var selectedBudgetEnforcementMode: BudgetEnforcementMode {
        BudgetEnforcementMode(rawValue: budgetEnforcementModeRaw) ?? TaskExecutionDefaults.budgetEnforcementMode
    }

    private var selectedDefaultPolicyLevel: AgentPolicyLevel {
        AgentPolicyLevel.normalized(defaultAgentPolicyLevelRaw).userFacingLevel
    }

    private var defaultPolicySelectionBinding: Binding<String> {
        Binding(
            get: { AgentPolicyLevel.normalized(defaultAgentPolicyLevelRaw).userFacingLevel.rawValue },
            set: { defaultAgentPolicyLevelRaw = AgentPolicyLevel.normalized($0).userFacingLevel.rawValue }
        )
    }

    private var readinessConfiguration: RuntimeReadinessConfiguration {
        RuntimeReadinessConfiguration(
            runtime: AgentRuntimeID(rawValue: defaultRuntimeID) ?? TaskExecutionDefaults.runtime,
            claudePath: claudePath,
            copilotPath: copilotPath,
            claudeProvider: ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic,
            vertexProjectID: claudeVertexProjectID,
            vertexRegion: claudeVertexRegion,
            vertexOpusModel: claudeVertexOpusModel,
            vertexSonnetModel: claudeVertexSonnetModel,
            vertexHaikuModel: claudeVertexHaikuModel
        )
    }

    private var readinessSignature: String {
        [
            defaultRuntimeID,
            claudePath,
            copilotPath,
            claudeProviderRaw,
            claudeVertexProjectID,
            claudeVertexRegion,
            claudeVertexOpusModel,
            claudeVertexSonnetModel,
            claudeVertexHaikuModel
        ].joined(separator: "\u{1F}")
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
                        HStack {
                            Text(model)
                            if selection.wrappedValue == model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Stanford.ui(12).weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose \(title)")
        }
    }

    private var readinessSummary: some View {
        HStack(spacing: 8) {
            if isCheckingReadiness {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: readinessSummarySymbol)
                    .foregroundStyle(readinessSummaryColor)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(readinessReport?.summary ?? "Not checked")
                    .font(Stanford.body(14).weight(.medium))
                Text(readinessSubtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readinessSubtitle: String {
        if isCheckingReadiness { return "Checking local tools and provider auth..." }
        guard let readinessCheckedAt else { return "Checks are local and sanitized." }
        return "Last checked \(readinessCheckedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var readinessSummarySymbol: String {
        switch readinessReport?.state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .none: "circle.dotted"
        }
    }

    private var readinessSummaryColor: Color {
        switch readinessReport?.state {
        case .ready: Stanford.statusHealthy
        case .warning: Stanford.statusWarn
        case .blocked: Stanford.statusError
        case .none: Stanford.coolGrey
        }
    }

    private var readinessColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 220), spacing: 8),
            GridItem(.flexible(minimum: 220), spacing: 8)
        ]
    }

    private func readinessTile(_ check: RuntimeReadinessCheck) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: readinessSymbol(for: check.state))
                .foregroundStyle(readinessColor(for: check.state))
                .font(Stanford.ui(13))
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .lineLimit(1)
                Text(check.detail)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let remediation = check.remediation, !remediation.isEmpty {
                    Text(remediation)
                        .font(Stanford.caption(11))
                        .foregroundStyle(readinessColor(for: check.state))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(shape.fill(Color.primary.opacity(0.018)))
        .overlay {
            shape.stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
        .clipShape(shape)
    }

    private func readinessSymbol(for state: RuntimeReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func readinessColor(for state: RuntimeReadinessState) -> Color {
        switch state {
        case .ready: Stanford.statusHealthy
        case .warning: Stanford.statusWarn
        case .blocked: Stanford.statusError
        }
    }

    private func dataLocationRow(_ title: String, path: String, canOpen: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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

    private func detectClaudeCLI() {
        let path = RuntimePathResolver.detectClaudePath()
        if FileManager.default.isExecutableFile(atPath: path) {
            detectedPath = path
            if claudePath.isEmpty { claudePath = path }
        }
    }

    private func detectCopilotCLI() {
        let detected = CopilotCLIRuntime.detectPath()
        if !detected.isEmpty {
            detectedCopilotPath = detected
            if copilotPath.isEmpty { copilotPath = detected }
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

    private func refreshRuntimeReadiness() async {
        isCheckingReadiness = true
        defer { isCheckingReadiness = false }

        let service = RuntimeReadinessService()
        var report = await service.check(configuration: readinessConfiguration)
        if report.checks.contains(where: { $0.id == readinessConfiguration.runtimeReadinessCheckID && $0.state == .ready }) {
            let modelCheck = await refreshModelAvailability(for: readinessConfiguration)
            report = RuntimeReadinessReport(checks: report.checks + [modelCheck])
            alignDefaultModelsWithRuntime()
        }
        readinessReport = report
        readinessCheckedAt = Date()
    }

    private func refreshModelAvailability(for configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        await AgentRuntimeAdapterRegistry
            .adapter(for: configuration.runtime)
            .modelAvailabilityCheck(configuration: configuration)
    }

    private func alignDefaultModelsWithRuntime(resetToRuntimeSuggestion: Bool = false) {
        let runtime = AgentRuntimeID(rawValue: defaultRuntimeID) ?? TaskExecutionDefaults.runtime
        let previousDefaultModel = defaultModel
        let previousValidationModel = validationModel
        if resetToRuntimeSuggestion {
            defaultModel = RuntimeModelAvailability.modelForRuntimeSwitch(
                currentModel: defaultModel,
                to: runtime,
                cachedClaudeModelsJSON: claudeAvailableModels,
                cachedCopilotModelsJSON: copilotAvailableModels
            )
            validationModel = RuntimeModelAvailability.modelForRuntimeSwitch(
                currentModel: validationModel,
                to: runtime,
                cachedClaudeModelsJSON: claudeAvailableModels,
                cachedCopilotModelsJSON: copilotAvailableModels
            )
        } else {
            defaultModel = RuntimeModelAvailability.normalizedModel(
                defaultModel,
                for: runtime,
                cachedClaudeModelsJSON: claudeAvailableModels,
                cachedCopilotModelsJSON: copilotAvailableModels
            )
            validationModel = RuntimeModelAvailability.normalizedModel(
                validationModel,
                for: runtime,
                cachedClaudeModelsJSON: claudeAvailableModels,
                cachedCopilotModelsJSON: copilotAvailableModels
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

private extension RuntimeReadinessConfiguration {
    var runtimeReadinessCheckID: String {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).readinessCheckID
    }
}
