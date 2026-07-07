import AppKit
import SwiftUI
import ASTRACore
import ASTRAPersistence
import ASTRAModels

struct SettingsRuntimeTab: View {
    @Environment(\.preflightCache) private var preflightCache

    @Binding var defaultModel: String
    @Binding var defaultTokenBudget: Int
    @Binding var defaultAgentPolicyLevelRaw: String
    @Binding var defaultRuntimeID: String
    @Binding var claudePath: String
    @Binding var copilotPath: String
    @Binding var runtimeProviderSettingsRevision: Int
    @Binding var claudeAvailableModels: String
    @Binding var copilotAvailableModels: String
    @Binding var runtimeModelCacheRevision: Int
    @Binding var validationModel: String

    @AppStorage(AppStorageKeys.budgetEnforcementMode) private var budgetEnforcementModeRaw =
        TaskExecutionDefaults.budgetEnforcementMode.rawValue
    @AppStorage(AppStorageKeys.sandboxEnforcement) private var sandboxEnforcementRaw =
        ExecutionSandboxSettings.defaultEnforcement.rawValue
    @AppStorage(AppStorageKeys.sandboxReadScope) private var sandboxReadScopeRaw =
        ExecutionSandboxSettings.defaultReadScope.rawValue
    @AppStorage(AppStorageKeys.sandboxAllowNetwork) private var sandboxAllowNetwork =
        ExecutionSandboxSettings.defaultAllowNetwork
    @AppStorage(AppStorageKeys.sandboxLayerNativeProviders) private var sandboxLayerNativeProviders =
        ExecutionSandboxSettings.defaultLayerNativeProviders
    @AppStorage(AppStorageKeys.claudeProvider) private var claudeProviderRaw = ClaudeProvider.anthropic.rawValue
    @AppStorage(AppStorageKeys.claudeVertexProjectID) private var claudeVertexProjectID = ""
    @AppStorage(AppStorageKeys.claudeVertexRegion) private var claudeVertexRegion = ""
    @AppStorage(AppStorageKeys.claudeVertexOpusModel) private var claudeVertexOpusModel = ""
    @AppStorage(AppStorageKeys.claudeVertexSonnetModel) private var claudeVertexSonnetModel = ""
    @AppStorage(AppStorageKeys.claudeVertexHaikuModel) private var claudeVertexHaikuModel = ""
    @StateObject private var settingsRuntimeSetup = RuntimeSetupModel()
    @State private var detectedPath = ""
    @State private var detectedCopilotPath = ""
    @State private var providerPathDrafts: [AgentRuntimeID: String] = [:]
    @State private var detectedProviderPaths: [AgentRuntimeID: String] = [:]

    private let budgetPresets = TaskExecutionDefaults.budgetPresets

    init(
        defaultModel: Binding<String>,
        defaultTokenBudget: Binding<Int>,
        defaultAgentPolicyLevelRaw: Binding<String>,
        defaultRuntimeID: Binding<String>,
        claudePath: Binding<String>,
        copilotPath: Binding<String>,
        runtimeProviderSettingsRevision: Binding<Int>,
        claudeAvailableModels: Binding<String>,
        copilotAvailableModels: Binding<String>,
        runtimeModelCacheRevision: Binding<Int>,
        validationModel: Binding<String>
    ) {
        self._defaultModel = defaultModel
        self._defaultTokenBudget = defaultTokenBudget
        self._defaultAgentPolicyLevelRaw = defaultAgentPolicyLevelRaw
        self._defaultRuntimeID = defaultRuntimeID
        self._claudePath = claudePath
        self._copilotPath = copilotPath
        self._runtimeProviderSettingsRevision = runtimeProviderSettingsRevision
        self._claudeAvailableModels = claudeAvailableModels
        self._copilotAvailableModels = copilotAvailableModels
        self._runtimeModelCacheRevision = runtimeModelCacheRevision
        self._validationModel = validationModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsRuntimeHeader

                RuntimeSetupSection(model: settingsRuntimeSetup)

                advancedProviderSettingsCard

                runtimeGuardrailsCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            await startRuntimeSetup()
        }
        .onChange(of: settingsRuntimeSetup.selectedRuntime) {
            syncSelectedRuntime()
        }
        .onChange(of: settingsRuntimeSetup.readinessReport) {
            Task { await refreshModelAvailabilityIfReady() }
        }
        .onChange(of: runtimeProviderSettingsRevision) {
            loadProviderPathDrafts()
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
    }

    private var settingsRuntimeHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(Stanford.ui(22, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 44, height: 44)
                .background(Stanford.lagunita.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("Choose an AI Runtime")
                    .font(Stanford.heading(22))
                    .foregroundStyle(Stanford.black)
                Text("ASTRA drives a coding-agent CLI on this Mac. Pick the runtime new tasks should use.")
                    .font(Stanford.body(14))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedProviderSettingsCard: some View {
        SettingsRuntimeCard(
            title: "Provider Details",
            subtitle: "Optional overrides for the selected runtime."
        ) {
            let runtime = settingsRuntimeSetup.selectedRuntime

            VStack(alignment: .leading, spacing: 12) {
                providerPathRow(
                    title: "\(runtime.displayName) path",
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
                            .foregroundStyle(Stanford.coolGrey)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var runtimeGuardrailsCard: some View {
        SettingsRuntimeCard(
            title: "Runtime Guardrails",
            subtitle: RuntimeGuardrailsPresentation.hostPrivacyStatus
        ) {
            VStack(alignment: .leading, spacing: 14) {
                runtimeHostPrivacyBoundaryRow

                Text(RuntimeGuardrailsPresentation.hostPrivacyDetail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                settingsDivider

                Picker("Default Budget", selection: $defaultTokenBudget) {
                    ForEach(budgetPresets, id: \.self) { budget in
                        Text(RuntimeBudgetPresentation.settingsLabel(for: budget)).tag(budget)
                    }
                }

                if RuntimeBudgetPresentation.isEnabled(defaultTokenBudget) {
                    Picker("Budget Enforcement", selection: $budgetEnforcementModeRaw) {
                        ForEach(BudgetEnforcementMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(selectedBudgetEnforcementMode.helpText)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Default Policy", selection: defaultPolicySelectionBinding) {
                    ForEach(AgentPolicyLevel.primaryCases) { level in
                        Label(level.displayName, systemImage: level.symbolName)
                            .tag(level.rawValue)
                    }
                }

                Text(selectedDefaultPolicyLevel.shortDescription)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Execution Sandbox", selection: sandboxEnforcementSelectionBinding) {
                    ForEach(ExecutionSandboxEnforcement.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedSandboxEnforcement.helpText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Read Scope", selection: sandboxReadScopeSelectionBinding) {
                    ForEach(ExecutionSandboxReadScope.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(selectedSandboxEnforcement != .bestEffort)

                Text(selectedSandboxReadScope.helpText)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Allow Network In Sandbox", isOn: $sandboxAllowNetwork)
                    .disabled(selectedSandboxEnforcement == .off)

                Text(sandboxAllowNetwork
                    ? "Sandboxed agents can reach the network - required for the provider's model API and online tools."
                    : "Offline: the sandbox blocks all outbound network. Use only for fully local tasks; most agent runs will fail to reach their model.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Also Sandbox Providers With Built-In Sandboxes", isOn: $sandboxLayerNativeProviders)
                    .disabled(selectedSandboxEnforcement == .off)

                Text("Layer ASTRA's sandbox over Codex, Cursor, and Antigravity for defense-in-depth. Off by default - these providers already self-sandbox, and double-confinement can break them.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runtimeHostPrivacyBoundaryRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Label(
                RuntimeGuardrailsPresentation.hostPrivacyTitle,
                systemImage: RuntimeGuardrailsPresentation.hostPrivacySystemImage
            )
            .font(Stanford.body(14).weight(.semibold))
            Spacer()
            Text(RuntimeGuardrailsPresentation.hostPrivacyStatus)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(Stanford.statusHealthy)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Stanford.statusHealthy.opacity(0.10)))
        }
    }

    private var settingsDivider: some View {
        Divider().opacity(0.45)
    }

    @ViewBuilder
    private var claudeRouteSettings: some View {
        Picker("Route through", selection: $claudeProviderRaw) {
            ForEach(ClaudeProvider.allCases) { provider in
                Label(provider.label, systemImage: provider.symbolName)
                    .tag(provider.rawValue)
            }
        }
        .onChange(of: claudeProviderRaw) {
            Task { await refreshSharedRuntimeSetup(force: true) }
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
                .foregroundStyle(Stanford.coolGrey)
                .padding(.top, 2)
            Text("Use Vertex IDs such as `claude-opus-4-6@default`; plain Anthropic model names do not resolve on Vertex.")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)

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
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Anthropic routing uses the Claude Code CLI session on this Mac. Authenticate or refresh the account with `claude /login`.")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(Stanford.body(13).weight(.semibold))
                Spacer()
                TextField(title, text: path, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 280, maxWidth: 420)
                    .textSelection(.enabled)
                    .onSubmit {
                        saveAction?()
                        Task { await refreshSharedRuntimeSetup(force: true) }
                    }
                if let saveAction {
                    Button("Save") {
                        saveAction()
                        Task { await refreshSharedRuntimeSetup(force: true) }
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
                .foregroundStyle(Stanford.coolGrey)
            }
        }
    }

    private func startRuntimeSetup() async {
        loadProviderPathDrafts()
        detectClaudeCLI(refresh: false)
        detectCopilotCLI(refresh: false)
        settingsRuntimeSetup.attach(preflightCache: preflightCache)
        await settingsRuntimeSetup.refreshAndWait(force: false)
    }

    private func refreshSharedRuntimeSetup(force: Bool) async {
        await settingsRuntimeSetup.refreshAndWait(force: force)
    }

    private func syncSelectedRuntime() {
        let runtime = settingsRuntimeSetup.selectedRuntime
        defaultRuntimeID = runtime.rawValue
        alignDefaultModelsWithRuntime(resetToRuntimeSuggestion: true)
    }

    private func refreshModelAvailabilityIfReady() async {
        guard let report = settingsRuntimeSetup.readinessReport, report.state != .blocked else { return }
        let configuration = readinessConfiguration
        guard report.checks.contains(where: {
            $0.id == configuration.runtimeReadinessCheckID && $0.state == .ready
        }) else {
            return
        }
        _ = await AgentRuntimeAdapterRegistry
            .adapter(for: configuration.runtime)
            .modelAvailabilityCheck(configuration: configuration)
        alignDefaultModelsWithRuntime()
    }

    private var readinessConfiguration: RuntimeReadinessConfiguration {
        RuntimeReadinessConfiguration(
            runtime: selectedRuntime,
            providerSettings: providerSettingsForReadiness,
            claudeProvider: selectedClaudeProvider,
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

    private var selectedRuntime: AgentRuntimeID {
        AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
    }

    private var selectedClaudeProvider: ClaudeProvider {
        ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic
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

    private var runtimeModelCache: RuntimeModelAvailabilityCache {
        _ = runtimeModelCacheRevision
        return RuntimeModelAvailabilityCache.appStorage(
            cachedClaudeModelsJSON: claudeAvailableModels,
            cachedCopilotModelsJSON: copilotAvailableModels
        )
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
            detectClaudeCLI(refresh: true)
        case .copilotCLI:
            detectCopilotCLI(refresh: true)
        default:
            detectProviderCLI(runtime)
            Task { await refreshSharedRuntimeSetup(force: true) }
        }
    }

    private func detectClaudeCLI(refresh: Bool) {
        let path = RuntimePathResolver.detectClaudePath()
        if FileManager.default.isExecutableFile(atPath: path) {
            detectedPath = path
            if claudePath.isEmpty { claudePath = path }
            if refresh {
                Task { await refreshSharedRuntimeSetup(force: true) }
            }
        }
    }

    private func detectCopilotCLI(refresh: Bool) {
        let detected = CopilotCLIRuntime.detectPath()
        if !detected.isEmpty {
            detectedCopilotPath = detected
            if copilotPath.isEmpty { copilotPath = detected }
            if refresh {
                Task { await refreshSharedRuntimeSetup(force: true) }
            }
        }
    }

    private func detectedProviderPath(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode: detectedPath
        case .copilotCLI: detectedCopilotPath
        default: detectedProviderPaths[runtime] ?? ""
        }
    }
}

private struct SettingsRuntimeCard<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Stanford.body(15).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                }
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
        )
    }
}

private extension RuntimeReadinessConfiguration {
    var runtimeReadinessCheckID: String {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).readinessCheckID
    }
}
