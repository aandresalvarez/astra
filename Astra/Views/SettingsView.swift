import AppKit
import SwiftUI
import ASTRACore

struct SettingsView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @AppStorage(AppStorageKeys.defaultModel) private var defaultModel = TaskExecutionDefaults.model
    @AppStorage(AppStorageKeys.defaultTokenBudget) private var defaultTokenBudget = TaskExecutionDefaults.tokenBudget
    @AppStorage(AppStorageKeys.defaultAgentPolicyLevel) private var defaultAgentPolicyLevelRaw = AgentPolicyLevel.review.rawValue
    @AppStorage(AppStorageKeys.budgetEnforcementMode) private var budgetEnforcementModeRaw = TaskExecutionDefaults.budgetEnforcementMode.rawValue
    // Defaults derive from ExecutionSandboxSettings so the UI's initial state and
    // the resolved (current()) behavior share one source of truth and can't drift.
    @AppStorage(AppStorageKeys.sandboxEnforcement) private var sandboxEnforcementRaw = ExecutionSandboxSettings.defaultEnforcement.rawValue
    @AppStorage(AppStorageKeys.sandboxReadScope) private var sandboxReadScopeRaw = ExecutionSandboxSettings.defaultReadScope.rawValue
    @AppStorage(AppStorageKeys.sandboxAllowNetwork) private var sandboxAllowNetwork = ExecutionSandboxSettings.defaultAllowNetwork
    @AppStorage(AppStorageKeys.sandboxLayerNativeProviders) private var sandboxLayerNativeProviders = ExecutionSandboxSettings.defaultLayerNativeProviders
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
    @AppStorage(AppStorageKeys.claudeProvider) private var claudeProviderRaw = ClaudeProvider.anthropic.rawValue
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @AppStorage(AppStorageKeys.claudeVertexOpusModel) private var claudeVertexOpusModel = ""
    @AppStorage(AppStorageKeys.claudeVertexSonnetModel) private var claudeVertexSonnetModel = ""
    @AppStorage(AppStorageKeys.claudeVertexHaikuModel) private var claudeVertexHaikuModel = ""
    @AppStorage(AppStorageKeys.claudeAvailableModels) private var claudeAvailableModels = ""
    @AppStorage(AppStorageKeys.copilotAvailableModels) private var copilotAvailableModels = ""
    @AppStorage(AppStorageKeys.runtimeModelCacheRevision) private var runtimeModelCacheRevision = 0

    private let budgetPresets = TaskExecutionDefaults.budgetPresets

    @State private var detectedPath = ""
    @State private var detectedCopilotPath = ""
    @State private var providerPathDrafts: [AgentRuntimeID: String] = [:]
    @State private var detectedProviderPaths: [AgentRuntimeID: String] = [:]
    @State private var expandedProviderRuntime: AgentRuntimeID?
    @State private var roleProfileDrafts: [TaskRoleID: TaskRoleProfile] = [:]
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
            loadProviderPathDrafts()
            loadRoleProfileDrafts()
            detectClaudeCLI()
            detectCopilotCLI()
            if expandedProviderRuntime == nil {
                expandedProviderRuntime = restoredExpandedProviderRuntime()
            }
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
        .onChange(of: runtimeModelCacheRevision) {
            alignDefaultModelsWithRuntime()
        }
        .onChange(of: runtimeProviderSettingsRevision) {
            loadProviderPathDrafts()
            readinessReport = nil
            readinessCheckedAt = nil
        }
        .onChange(of: roleProfileRevision) {
            loadRoleProfileDrafts()
        }
        .onChange(of: logRetentionDays) {
            AppLogger.rotateIfNeeded()
        }
    }

    private var runtimeSettingsTab: some View {
        Form {
            Section("Provider Selection") {
                Picker("Default Provider", selection: $defaultRuntimeID) {
                    ForEach(AgentRuntimeAdapterRegistry.runtimeIDs) { runtime in
                        Text(runtime.displayName).tag(runtime.rawValue)
                    }
                }
                .onChange(of: defaultRuntimeID) {
                    alignDefaultModelsWithRuntime(resetToRuntimeSuggestion: true)
                    expandedProviderRuntime = selectedRuntime
                    ProviderDisclosureStore.expandedRuntimeID = selectedRuntime.rawValue
                    readinessReport = nil
                    readinessCheckedAt = nil
                }
                Text("New tasks use this provider. Existing tasks keep the provider they were created with.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Providers") {
                ForEach(AgentRuntimeAdapterRegistry.runtimeIDs) { runtime in
                    providerDisclosureRow(runtime)
                }
            }

            Section("Default Provider Readiness") {
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
                        Text("Run a readiness check to verify the default provider, authentication, provider route, and required local tools.")
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Runtime Guardrails") {
                runtimeHostPrivacyBoundaryRow

                Text(RuntimeGuardrailsPresentation.hostPrivacyDetail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Picker("Default Budget", selection: $defaultTokenBudget) {
                    ForEach(budgetPresets, id: \.self) { b in
                        Text(b == 0 ? "Unlimited" : "\(b / 1000)k tokens").tag(b)
                    }
                }

                Picker("Budget Enforcement", selection: $budgetEnforcementModeRaw) {
                    ForEach(BudgetEnforcementMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedBudgetEnforcementMode.helpText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Picker("Default Policy", selection: defaultPolicySelectionBinding) {
                    ForEach(AgentPolicyLevel.primaryCases) { level in
                        Label(level.displayName, systemImage: level.symbolName)
                            .tag(level.rawValue)
                    }
                }

                Text(selectedDefaultPolicyLevel.shortDescription)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Picker("Execution Sandbox", selection: sandboxEnforcementSelectionBinding) {
                    ForEach(ExecutionSandboxEnforcement.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedSandboxEnforcement.helpText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Picker("Read Scope", selection: sandboxReadScopeSelectionBinding) {
                    ForEach(ExecutionSandboxReadScope.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(selectedSandboxEnforcement != .bestEffort)

                Text(selectedSandboxReadScope.helpText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Toggle("Allow Network In Sandbox", isOn: $sandboxAllowNetwork)
                    .disabled(selectedSandboxEnforcement == .off)

                Text(sandboxAllowNetwork
                    ? "Sandboxed agents can reach the network — required for the provider's model API and online tools."
                    : "Offline: the sandbox blocks all outbound network. Use only for fully local tasks; most agent runs will fail to reach their model.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)

                Toggle("Also Sandbox Providers With Built-In Sandboxes", isOn: $sandboxLayerNativeProviders)
                    .disabled(selectedSandboxEnforcement == .off)

                Text("Layer ASTRA's sandbox over Codex, Cursor, and Antigravity for defense-in-depth. Off by default — these providers already self-sandbox, and double-confinement can break them.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var runtimeHostPrivacyBoundaryRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Label(
                RuntimeGuardrailsPresentation.hostPrivacyTitle,
                systemImage: RuntimeGuardrailsPresentation.hostPrivacySystemImage
            )
            Spacer()
            Text(RuntimeGuardrailsPresentation.hostPrivacyStatus)
                .foregroundStyle(.secondary)
        }
    }

    private func providerDisclosureRow(_ runtime: AgentRuntimeID) -> some View {
        DisclosureGroup(isExpanded: expandedProviderBinding(for: runtime)) {
            providerConnectionDetails(runtime)
                .padding(.top, 8)
        } label: {
            providerSummaryLabel(runtime)
        }
    }

    private func providerSummaryLabel(_ runtime: AgentRuntimeID) -> some View {
        let status = providerConnectionStatus(for: runtime)

        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)

        return HStack(alignment: .center, spacing: 10) {
            CapabilityLeadingIcon(
                systemImage: providerIcon(for: runtime),
                brand: providerBrand(for: runtime),
                pointSize: 16
            )
            .foregroundStyle(.secondary)
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(Stanford.body(14).weight(.semibold))
                Text(status.detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(status.detail)
            }

            Spacer()

            if runtime == selectedRuntime {
                providerChip("Default", tint: Stanford.statusInfo)
            }

            providerChip(status.label, tint: status.tint)
        }
    }

    @ViewBuilder
    private func providerConnectionDetails(_ runtime: AgentRuntimeID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            providerPathRow(
                title: "CLI path",
                path: providerPathBinding(for: runtime),
                prompt: "Auto-detected",
                detectedPath: detectedProviderPath(for: runtime),
                detectAction: { detectCLI(for: runtime) },
                saveAction: runtime == .claudeCode || runtime == .copilotCLI
                    ? nil
                    : { saveProviderPathDraft(for: runtime) },
                hasUnsavedChanges: hasUnsavedProviderPathDraft(for: runtime)
            )

            if runtime == .claudeCode {
                claudeRouteSettings
            } else {
                let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)
                if !descriptor.authHint.isEmpty {
                    Text(descriptor.authHint)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if runtime != selectedRuntime {
                Button {
                    defaultRuntimeID = runtime.rawValue
                } label: {
                    Label("Make Default", systemImage: "checkmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var claudeRouteSettings: some View {
        Picker("Route through", selection: $claudeProviderRaw) {
            ForEach(ClaudeProvider.allCases) { provider in
                Label(provider.label, systemImage: provider.symbolName)
                    .tag(provider.rawValue)
            }
        }

        if selectedClaudeProvider == .vertex {
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

            Text("Vertex model aliases")
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Use Vertex IDs such as `claude-opus-4-6@default`; plain Anthropic model names do not resolve on Vertex.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)

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

            Text("ASTRA injects the Vertex project, region, and model alias environment variables when it starts Claude Code. Authentication comes from `gcloud auth application-default login`.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        } else {
            Text("Anthropic routing uses the Claude Code CLI session on this Mac. Authenticate or refresh the account with `claude /login`.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
        }
    }

    private func providerChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Stanford.caption(11).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.10)))
    }

    /// The real brand mark for a provider when one ships, so recognizable
    /// services (GitHub Copilot, Claude Code) lead with their glyph and the
    /// generic SF Symbol from `providerIcon` is only a fallback (ICO).
    private func providerBrand(for runtime: AgentRuntimeID) -> BrandMark? {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)
        return BrandMark.resolve(id: runtime.rawValue, name: descriptor.displayName)
    }

    private func providerIcon(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode: "terminal"
        case .copilotCLI: "person.crop.circle"
        case .antigravityCLI: "sparkles"
        case .codexCLI: "curlybraces.square"
        case .cursorCLI: "cursorarrow.rays"
        case .openCodeCLI: "chevron.left.forwardslash.chevron.right"
        default: "terminal"
        }
    }

    private func providerConnectionStatus(
        for runtime: AgentRuntimeID
    ) -> (label: String, detail: String, symbol: String, tint: Color) {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)

        if runtime == selectedRuntime {
            if isCheckingReadiness {
                return (
                    "Checking",
                    "Checking path, account, and model access.",
                    "arrow.triangle.2.circlepath",
                    Stanford.statusInfo
                )
            }

            switch readinessReport?.state {
            case .ready:
                return (
                    "Ready",
                    "\(descriptor.displayName) passed the latest readiness check.",
                    "checkmark.circle.fill",
                    Stanford.statusHealthy
                )
            case .warning:
                return (
                    "Review",
                    readinessReport?.summary ?? "The default provider is usable, with one item to review.",
                    "exclamationmark.triangle.fill",
                    Stanford.statusWarn
                )
            case .blocked:
                return (
                    "Blocked",
                    readinessReport?.summary ?? "Resolve provider setup before starting new tasks.",
                    "xmark.octagon.fill",
                    Stanford.statusError
                )
            case .none:
                return (
                    "Selected",
                    "Default for new tasks. Run Check Now to verify local setup.",
                    "circle.dotted",
                    Stanford.statusInfo
                )
            }
        }

        if !configuredProviderPath(for: runtime).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (
                "Configured",
                "CLI path saved for \(descriptor.displayName).",
                "checkmark.circle.fill",
                Stanford.statusHealthy
            )
        }

        let detected = detectedProviderPath(for: runtime).trimmingCharacters(in: .whitespacesAndNewlines)
        if !detected.isEmpty {
            return (
                "Detected",
                detected,
                "checkmark.circle.fill",
                Stanford.statusHealthy
            )
        }

        return (
            "Needs setup",
            descriptor.installHint.isEmpty ? "Configure the CLI path before using this provider." : descriptor.installHint,
            "circle",
            Stanford.coolGrey
        )
    }

    /// The provider row to open when Settings first appears: the value the user
    /// last left (including an explicit "all collapsed"), falling back to the
    /// default provider only when nothing has been stored yet.
    private func restoredExpandedProviderRuntime() -> AgentRuntimeID? {
        guard let stored = ProviderDisclosureStore.expandedRuntimeID else {
            return selectedRuntime
        }
        // An empty stored value is the sentinel for "user collapsed every row".
        guard !stored.isEmpty else { return nil }
        return AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: stored)
    }

    private func expandedProviderBinding(for runtime: AgentRuntimeID) -> Binding<Bool> {
        Binding(
            get: { expandedProviderRuntime == runtime },
            set: {
                let next: AgentRuntimeID? = $0 ? runtime : nil
                expandedProviderRuntime = next
                ProviderDisclosureStore.expandedRuntimeID = next?.rawValue
            }
        )
    }

    private func providerPathRow(
        title: String,
        path: Binding<String>,
        prompt: String,
        detectedPath: String,
        detectAction: @escaping () -> Void,
        saveAction: (() -> Void)? = nil,
        hasUnsavedChanges: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                Spacer()
                TextField(title, text: path, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 280, maxWidth: 420)
                    .textSelection(.enabled)
                    .onSubmit {
                        saveAction?()
                    }
                if let saveAction {
                    Button("Save") {
                        saveAction()
                    }
                    .disabled(!hasUnsavedChanges)
                }
                Button {
                    detectAction()
                } label: {
                    Label("Detect", systemImage: "magnifyingglass")
                }
            }

            if !detectedPath.isEmpty {
                Label {
                    Text("Detected: \(detectedPath)")
                        .font(Stanford.caption(12))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .foregroundStyle(.secondary)
            }
        }
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

    private var selectedClaudeProvider: ClaudeProvider {
        ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic
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

    private var selectedBudgetEnforcementMode: BudgetEnforcementMode {
        BudgetEnforcementMode(rawValue: budgetEnforcementModeRaw) ?? TaskExecutionDefaults.budgetEnforcementMode
    }

    private var selectedSandboxEnforcement: ExecutionSandboxEnforcement {
        ExecutionSandboxEnforcement.normalized(sandboxEnforcementRaw)
    }

    private var selectedSandboxReadScope: ExecutionSandboxReadScope {
        switch selectedSandboxEnforcement {
        case .off:
            return .open
        case .bestEffort:
            return ExecutionSandboxReadScope.normalized(sandboxReadScopeRaw)
        case .strict:
            return .enforce
        }
    }

    /// Normalizing binding so the segmented Picker always reads/writes a canonical
    /// raw value. A legacy/unknown stored value (which `normalized` tolerates)
    /// therefore still maps to a valid segment instead of leaving the control with
    /// no selection.
    private var sandboxEnforcementSelectionBinding: Binding<String> {
        Binding(
            get: { ExecutionSandboxEnforcement.normalized(sandboxEnforcementRaw).rawValue },
            set: { sandboxEnforcementRaw = ExecutionSandboxEnforcement.normalized($0).rawValue }
        )
    }

    private var sandboxReadScopeSelectionBinding: Binding<String> {
        Binding(
            get: { selectedSandboxReadScope.rawValue },
            set: { sandboxReadScopeRaw = ExecutionSandboxReadScope.normalized($0).rawValue }
        )
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
            runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID),
            providerSettings: providerSettingsForReadiness,
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
            String(runtimeProviderSettingsRevision),
            RuntimeProviderSettingsStore.signature(),
            claudeProviderRaw,
            claudeVertexProjectID,
            claudeVertexRegion,
            claudeVertexOpusModel,
            claudeVertexSonnetModel,
            claudeVertexHaikuModel
        ].joined(separator: "\u{1F}")
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

    private func providerPathBinding(for runtime: AgentRuntimeID) -> Binding<String> {
        switch runtime {
        case .claudeCode:
            return Binding(
                get: { claudePath },
                set: { value in
                    claudePath = value
                    providerPathDrafts[runtime] = value
                }
            )
        case .copilotCLI:
            return Binding(
                get: { copilotPath },
                set: { value in
                    copilotPath = value
                    providerPathDrafts[runtime] = value
                }
            )
        default:
            break
        }

        return Binding(
            get: {
                providerPathDrafts[runtime] ?? RuntimeProviderSettingsStore.executablePath(for: runtime)
            },
            set: { value in
                providerPathDrafts[runtime] = value
            }
        )
    }

    private func loadProviderPathDrafts() {
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            providerPathDrafts[runtime] = RuntimeProviderSettingsStore.executablePath(for: runtime)
        }
    }

    private func detectProviderCLI(_ runtime: AgentRuntimeID) {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)
        let detected = RuntimePathResolver.detectExecutablePath(named: descriptor.executableName)
        guard !detected.isEmpty else { return }
        detectedProviderPaths[runtime] = detected
        if providerPathDrafts[runtime, default: ""].isEmpty {
            providerPathDrafts[runtime] = detected
            RuntimeProviderSettingsStore.setExecutablePath(detected, for: runtime)
        }
    }

    private func saveProviderPathDraft(for runtime: AgentRuntimeID) {
        let value = providerPathDrafts[runtime] ?? ""
        RuntimeProviderSettingsStore.setExecutablePath(value, for: runtime)
    }

    private func hasUnsavedProviderPathDraft(for runtime: AgentRuntimeID) -> Bool {
        ProviderPathPersistenceState.hasUnsavedDraft(
            draft: providerPathDrafts[runtime],
            persisted: RuntimeProviderSettingsStore.executablePath(for: runtime)
        )
    }

    private func detectCLI(for runtime: AgentRuntimeID) {
        switch runtime {
        case .claudeCode:
            detectClaudeCLI()
        case .copilotCLI:
            detectCopilotCLI()
        default:
            detectProviderCLI(runtime)
        }
    }

    private func detectedProviderPath(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode: detectedPath
        case .copilotCLI: detectedCopilotPath
        default: detectedProviderPaths[runtime] ?? ""
        }
    }

    private func configuredProviderPath(for runtime: AgentRuntimeID) -> String {
        ProviderPathPersistenceState.persistedPath(
            for: runtime,
            claudePath: claudePath,
            copilotPath: copilotPath,
            providerPath: RuntimeProviderSettingsStore.executablePath(for: runtime)
        )
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

private extension RuntimeReadinessConfiguration {
    var runtimeReadinessCheckID: String {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).readinessCheckID
    }
}

/// Remembers which provider disclosure row was last expanded so reopening
/// Settings restores the user's layout. Backed by `UserDefaults` directly — not
/// `@AppStorage` — to stay off the architecture-fitness `@AppStorage` ratchet,
/// mirroring `RailDisclosureStore`. Settings is a single global surface, so the
/// key is not workspace-scoped. `nil` means "never touched" (seed the default
/// provider); an empty string is the sentinel for "user collapsed every row".
enum ProviderDisclosureStore {
    private static let key = "settings.providers.expandedRuntimeID"

    static var expandedRuntimeID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.set("", forKey: key)
            }
        }
    }
}
