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
    @AppStorage(LocalModelSettingsStore.providerEnabledKey) private var localModelProviderEnabled = LocalModelSettingsStore.defaultProviderEnabled
    @AppStorage(LocalModelSettingsStore.preferredModelKey) private var localModelPreferredModel = LocalMLXRuntime.defaultModel
    @AppStorage(LocalModelSettingsStore.maxContextTokensKey) private var localModelMaxContextTokens = LocalModelSettingsStore.defaultMaxContextTokens
    @AppStorage(LocalModelSettingsStore.maxOutputTokensKey) private var localModelMaxOutputTokens = LocalModelSettingsStore.defaultMaxOutputTokens
    @AppStorage(LocalModelSettingsStore.keepWarmTTLSecondsKey) private var localModelKeepWarmTTLSeconds = LocalModelSettingsStore.defaultKeepWarmTTLSeconds
    @AppStorage(LocalModelSettingsStore.memoryBudgetGBKey) private var localModelMemoryBudgetGB = LocalModelSettingsStore.defaultMemoryBudgetGB
    @AppStorage(LocalModelSettingsStore.experimentalToolsKey) private var localModelExperimentalTools = false
    @AppStorage(LocalModelSettingsStore.localAgentMaxTurnsKey) private var localAgentMaxTurns = LocalModelSettingsStore.defaultLocalAgentMaxTurns
    @AppStorage(LocalModelSettingsStore.localAgentMaxToolCallsKey) private var localAgentMaxToolCalls = LocalModelSettingsStore.defaultLocalAgentMaxToolCalls
    @AppStorage(LocalModelSettingsStore.localAgentToolTimeoutSecondsKey) private var localAgentToolTimeoutSeconds = LocalModelSettingsStore.defaultLocalAgentToolTimeoutSeconds
    @AppStorage(LocalAgentToolCapability.taskOutputWrite.settingsKey) private var localAgentTaskOutputWriteEnabled = false
    @AppStorage(LocalAgentToolCapability.workspaceWrite.settingsKey) private var localAgentWorkspaceWriteEnabled = false
    @AppStorage(LocalAgentToolCapability.shellExecution.settingsKey) private var localAgentShellExecutionEnabled = false
    @AppStorage(LocalAgentToolCapability.networkFetch.settingsKey) private var localAgentNetworkFetchEnabled = false
    @AppStorage(LocalAgentToolCapability.browserClick.settingsKey) private var localAgentBrowserClickEnabled = false
    @AppStorage(LocalAgentToolCapability.browserType.settingsKey) private var localAgentBrowserTypeEnabled = false
    @AppStorage(LocalModelPerformanceStore.profileKey) private var localModelPerformanceProfileJSON = ""

    private let budgetPresets = TaskExecutionDefaults.budgetPresets

    @State private var detectedPath = ""
    @State private var detectedCopilotPath = ""
    @State private var providerPathDrafts: [AgentRuntimeID: String] = [:]
    @State private var providerHomeDirectoryDrafts: [AgentRuntimeID: String] = [:]
    @State private var detectedProviderPaths: [AgentRuntimeID: String] = [:]
    @State private var expandedProviderRuntime: AgentRuntimeID?
    @State private var roleProfileDrafts: [TaskRoleID: TaskRoleProfile] = [:]
    @State private var readinessReport: RuntimeReadinessReport?
    @State private var isCheckingReadiness = false
    @State private var readinessCheckedAt: Date?
    @State private var pendingLocalModelInstall: LocalModelInstallCandidate?
    @State private var lastLocalModelInstallCandidate: LocalModelInstallCandidate?
    @State private var isInstallingLocalModel = false
    @State private var localModelInstallTask: Task<Void, Never>?
    @State private var localModelInstallStatus: String?
    @State private var localModelInstallProgressState: LocalModelInstallProgress?
    @State private var isRunningLocalModelValidation = false
    @State private var localModelValidationCheck: RuntimeReadinessCheck?
    @State private var localModelHardwareValidationRevision = 0
    @State private var localModelValidationExchangeStatus: String?
    @State private var localAgentBetaSoakExchangeStatus: String?
    @State private var localAgentBetaSoakRevision = 0
    @State private var localModelReleaseValidationExchangeStatus: String?
    @State private var localModelReleaseValidationRevision = 0
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
        .confirmationDialog(
            "Install Local MLX Model",
            isPresented: localModelInstallConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingLocalModelInstall
        ) { candidate in
            Button("Download and Install") {
                startLocalModelInstall(candidate)
            }
            Button("Cancel", role: .cancel) {
                pendingLocalModelInstall = nil
            }
        } message: { candidate in
            Text(candidate.consentMessage)
        }
        .onAppear {
            loadProviderPathDrafts()
            loadRoleProfileDrafts()
            detectClaudeCLI()
            detectCopilotCLI()
            if expandedProviderRuntime == nil {
                expandedProviderRuntime = selectedRuntime
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

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: providerIcon(for: runtime))
                .font(Stanford.ui(16, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(AgentRuntimeAdapterRegistry.descriptor(for: runtime).displayName)
                    .font(Stanford.body(14).weight(.semibold))
                Text(status.detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if runtime == selectedRuntime {
                providerChip("Default", tint: Stanford.statusInfo)
            }

            if runtime == .localMLX, localModelExperimentalTools {
                providerChip("Experimental", tint: .orange)
            }

            Image(systemName: status.symbol)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(status.tint)
                .frame(width: 14)
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
            } else if runtime == .localMLX {
                localModelSettings
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

    @ViewBuilder
    private var localModelSettings: some View {
        Toggle("Enable Private Local Chat", isOn: $localModelProviderEnabled)

        VStack(alignment: .leading, spacing: 4) {
            localModelStatusLine("Mode", localModelModeSummary)
            HStack(alignment: .center, spacing: 8) {
                Toggle("Enable Local Agent", isOn: $localModelExperimentalTools)
                Text("Experimental")
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 4))
            }
            Text("Private Local Chat stays on this Mac and cannot use tools. Local Agent is experimental: it can use read-only ASTRA-brokered tools by default. Each write, shell, network, and browser capability must be enabled below and still pauses for approval when policy requires it.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if localModelExperimentalTools {
                localAgentCapabilityToggles
                    .padding(.top, 4)
                localAgentAdvancedLimits
                    .padding(.top, 4)
            }
        }
        .disabled(!localModelProviderEnabled)

        localModelHardwareStatus
            .disabled(!localModelProviderEnabled)

        localModelReleaseReadiness
            .disabled(!localModelProviderEnabled)

        Group {
            localModelSetupGuidance

            localNumericRow(
                title: "Max context",
                value: $localModelMaxContextTokens,
                range: 1_024...65_536,
                step: 1_024,
                prompt: "8192"
            )

            localNumericRow(
                title: "Max output",
                value: $localModelMaxOutputTokens,
                range: 128...8_192,
                step: 128,
                prompt: "1024"
            )

            localNumericRow(
                title: "Keep-warm TTL",
                value: $localModelKeepWarmTTLSeconds,
                range: 0...3_600,
                step: 30,
                prompt: "0"
            )

            Picker("Memory budget", selection: $localModelMemoryBudgetGB) {
                Text("Auto").tag(0)
                ForEach(localModelMemoryBudgetChoices, id: \.self) { budget in
                    Text("\(budget) GB").tag(budget)
                }
            }

            Text(localModelMemoryBudgetDetail)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .disabled(!localModelProviderEnabled)

        Text("Local MLX runs a model installed on this Mac. Readiness checks whether this Mac, the selected model, Private Local Chat, and any enabled Local Agent tools are ready before running.")
            .font(Stanford.caption(12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private var localAgentCapabilityToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approved tool capabilities")
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Turn on only the local actions this Mac should allow. ASTRA still checks policy, asks for approval when required, and blocks disabled tools before execution.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            localAgentWarnings
            Toggle("Task output writes", isOn: $localAgentTaskOutputWriteEnabled)
            Toggle("Workspace file edits", isOn: $localAgentWorkspaceWriteEnabled)
            Toggle("Shell commands", isOn: $localAgentShellExecutionEnabled)
            Toggle("Network fetches", isOn: $localAgentNetworkFetchEnabled)
            Toggle("Browser clicks", isOn: $localAgentBrowserClickEnabled)
            Toggle("Browser typing", isOn: $localAgentBrowserTypeEnabled)
        }
    }

    private var localAgentAdvancedLimits: some View {
        DisclosureGroup("Local Agent advanced limits") {
            VStack(alignment: .leading, spacing: 8) {
                Text("These limits cap ASTRA-brokered Local Agent work before a local model can loop too long or wait on a slow tool.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                localNumericRow(
                    title: "Agent turns",
                    value: $localAgentMaxTurns,
                    range: 1...32,
                    step: 1,
                    prompt: String(LocalModelSettingsStore.defaultLocalAgentMaxTurns)
                )
                localNumericRow(
                    title: "Tool calls",
                    value: $localAgentMaxToolCalls,
                    range: 1...50,
                    step: 1,
                    prompt: String(LocalModelSettingsStore.defaultLocalAgentMaxToolCalls)
                )
                localNumericRow(
                    title: "Tool timeout",
                    value: $localAgentToolTimeoutSeconds,
                    range: 5...120,
                    step: 5,
                    prompt: String(LocalModelSettingsStore.defaultLocalAgentToolTimeoutSeconds)
                )
                localModelStatusLine("Beta soak", localAgentBetaSoakDetail)
                HStack(spacing: 8) {
                    Button {
                        copyLocalAgentBetaSoakEvidence()
                    } label: {
                        Label("Copy Beta Evidence", systemImage: "doc.on.doc")
                    }
                    .disabled(LocalAgentBetaSoakStore.report().sampleCount == 0)

                    Button {
                        importLocalAgentBetaSoakEvidence()
                    } label: {
                        Label("Import Beta Evidence", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                if let localAgentBetaSoakExchangeStatus {
                    Text(localAgentBetaSoakExchangeStatus)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var localAgentWarnings: some View {
        let warnings = localAgentWarningMessages
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Stanford.statusWarn)
                            .frame(width: 16, height: 16)
                        Text(warning)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var localModelSetupGuidance: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                localModelStatusLine("Selected", selectedLocalModelSummary)

                Text("Install one model. ASTRA saves it in its own app data folder and selects it automatically.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                localModelInstallOption(localModelRecommendedInstallCandidate, isPrimary: true)

                Text("More models")
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(localModelInstallCandidates.dropFirst())) { candidate in
                    localModelInstallOption(candidate)
                }

                localModelInstallProgress
                localModelAdvancedSetup
            }
            .padding(.top, 6)
        } label: {
            Label("Install local model", systemImage: "square.and.arrow.down")
                .font(Stanford.body(13).weight(.medium))
        }
    }

    @ViewBuilder
    private var localModelInstallProgress: some View {
        if isInstallingLocalModel || localModelInstallStatus != nil {
            HStack(alignment: .center, spacing: 8) {
                if isInstallingLocalModel {
                    if let fraction = localModelInstallProgressState?.fractionCompleted {
                        ProgressView(value: fraction, total: 1)
                            .frame(width: 120)
                            .help(localModelInstallProgressSummary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(localModelInstallStatus ?? "Ready to install.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(localModelInstallStatusColor)
                        .textSelection(.enabled)
                    if isInstallingLocalModel, localModelInstallProgressState != nil {
                        Text(localModelInstallProgressSummary)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if isInstallingLocalModel {
                    Button("Cancel Download") {
                        cancelLocalModelInstall()
                    }
                    .buttonStyle(.bordered)
                } else if let lastLocalModelInstallCandidate {
                    Button("Retry Download") {
                        startLocalModelInstall(lastLocalModelInstallCandidate)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var localModelAdvancedSetup: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                providerFolderRow(
                    title: "Model folder",
                    path: providerHomeDirectoryBinding(for: .localMLX),
                    prompt: "Select model folder",
                    browseAction: { browseProviderHomeDirectory(for: .localMLX) },
                    saveAction: { saveProviderHomeDirectoryDraft(for: .localMLX) },
                    hasUnsavedChanges: hasUnsavedProviderHomeDirectoryDraft(for: .localMLX)
                )

                Picker("Model ID", selection: $localModelPreferredModel) {
                    ForEach(localModelChoices, id: \.self) { model in
                        Text(localModelDisplayName(for: model)).tag(model)
                    }
                }
                .onChange(of: localModelPreferredModel) {
                    if selectedRuntime == .localMLX {
                        defaultModel = localModelPreferredModel
                        validationModel = localModelPreferredModel
                    }
                }

                Text("Only installed model IDs appear here. Install another model above, or use Browse when selecting a model you installed outside ASTRA.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } label: {
            Label("Advanced manual setup", systemImage: "slider.horizontal.3")
                .font(Stanford.caption(12).weight(.medium))
        }
    }

    private func localModelInstallOption(
        _ candidate: LocalModelInstallCandidate,
        isPrimary: Bool = false
    ) -> some View {
        let state = localModelCandidateState(for: candidate)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(state.tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(candidate.title)
                        .font(Stanford.body(13).weight(.semibold))
                    if isPrimary {
                        providerChip("Recommended", tint: Stanford.statusHealthy)
                    }
                    Text(state.label)
                        .font(Stanford.caption(11).weight(.semibold))
                        .foregroundStyle(state.tint)
                }
                Text(candidate.subtitle)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !candidate.reason.isEmpty {
                    Text(candidate.reason)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(candidate.estimatedSize) download")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                if localModelCandidateIsInstalled(candidate), !localModelCandidateIsSelected(candidate) {
                    selectInstalledLocalModel(candidate)
                } else {
                    pendingLocalModelInstall = candidate
                }
            } label: {
                Label(
                    localModelCandidateButtonTitle(for: candidate),
                    systemImage: localModelCandidateButtonIcon(for: candidate)
                )
            }
            .buttonStyle(.bordered)
            .disabled(isInstallingLocalModel)
        }
    }

    private var localModelHardwareStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Hardware")
                Spacer()
                Button {
                    Task { await runLocalModelValidation() }
                } label: {
                    if isRunningLocalModelValidation {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Validate This Mac", systemImage: "speedometer")
                    }
                }
                .disabled(!localModelProviderEnabled || isRunningLocalModelValidation)
                Text(localHardwareProfile.capacityLabel)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(localHardwareProfile.tier == .recommended32GBPlus ? Stanford.statusHealthy : Stanford.statusWarn)
            }
            localModelStatusLine("Capacity", "\(localHardwareProfile.unifiedMemoryDescription) unified memory")
            localModelStatusLine("Speed", localHardwareProfile.speedLabel)
            localModelStatusLine("Smoke", localModelSmokeProfileDetail)
            localModelStatusLine("Coverage", localModelHardwareValidationDetail)
            HStack(spacing: 8) {
                Button {
                    copyLocalModelValidationEvidence()
                } label: {
                    Label("Copy Evidence", systemImage: "doc.on.doc")
                }
                .disabled(localModelHardwareValidationReport.samples.isEmpty)

                Button {
                    importLocalModelValidationEvidence()
                } label: {
                    Label("Import Evidence", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.bordered)
            if let localModelValidationExchangeStatus {
                Text(localModelValidationExchangeStatus)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let localModelValidationCheck {
                Text(localModelValidationCheck.remediation.map { "\(localModelValidationCheck.detail) \($0)" } ?? localModelValidationCheck.detail)
                    .font(Stanford.caption(12))
                    .foregroundStyle(readinessColor(for: localModelValidationCheck.state))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var localModelReleaseReadiness: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        copyLocalModelReleaseValidationEvidence()
                    } label: {
                        Label("Copy Release Evidence", systemImage: "doc.on.doc")
                    }
                    .disabled(localModelReleaseValidationReport.samples.isEmpty)

                    Button {
                        importLocalModelReleaseValidationEvidence()
                    } label: {
                        Label("Import Release Evidence", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        copyLocalModelReleaseReadinessSummary()
                    } label: {
                        Label("Copy Readiness Summary", systemImage: "checklist")
                    }

                    Button {
                        copyLocalModelCombinedReleaseEvidence()
                    } label: {
                        Label("Copy Validation Bundle", systemImage: "shippingbox")
                    }

                    Button {
                        importLocalModelCombinedReleaseEvidence()
                    } label: {
                        Label("Import Validation Bundle", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                .buttonStyle(.bordered)
                if let localModelReleaseValidationExchangeStatus {
                    Text(localModelReleaseValidationExchangeStatus)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                localModelReleaseReadinessSummaryView

                ForEach(localModelReleaseGateChecks) { check in
                    localModelReleaseGateRow(check)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Release readiness", systemImage: "checklist")
                .font(Stanford.body(13).weight(.medium))
        }
    }

    private var localModelReleaseReadinessSummaryView: some View {
        let summary = localModelReleaseReadinessSummary
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: summary.isReadyForGA ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.isReadyForGA ? Stanford.statusHealthy : Stanford.statusWarn)
                Text(summary.title)
                    .font(Stanford.body(13).weight(.semibold))
                providerChip(summary.isReadyForGA ? "GA ready" : "Needs evidence", tint: summary.isReadyForGA ? Stanford.statusHealthy : Stanford.statusWarn)
            }
            Text(summary.detail)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let nextAction = summary.nextAction {
                Text(nextAction)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func localModelReleaseGateRow(_ check: LocalModelReleaseGateCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: releaseGateSymbol(for: check.status))
                    .foregroundStyle(releaseGateColor(for: check.status))
                Text(check.title)
                    .font(Stanford.body(13).weight(.semibold))
                providerChip(check.status == .passed ? "Passed" : "In progress", tint: releaseGateColor(for: check.status))
            }

            ForEach(check.evidence, id: \.self) { evidence in
                Text(evidence)
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            ForEach(check.blockers, id: \.self) { blocker in
                Text(blocker)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func localNumericRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        prompt: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func localModelStatusLine(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(detail)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var localModelModeSummary: String {
        localModelExperimentalTools
            ? "Private Local Chat plus \(configuredLocalAgentCapabilities.enabledSummary)"
            : "Private Local Chat only"
    }

    private var configuredLocalAgentCapabilities: LocalAgentToolCapabilities {
        var enabled = Set<LocalAgentToolCapability>()
        if localAgentTaskOutputWriteEnabled { enabled.insert(.taskOutputWrite) }
        if localAgentWorkspaceWriteEnabled { enabled.insert(.workspaceWrite) }
        if localAgentShellExecutionEnabled { enabled.insert(.shellExecution) }
        if localAgentNetworkFetchEnabled { enabled.insert(.networkFetch) }
        if localAgentBrowserClickEnabled { enabled.insert(.browserClick) }
        if localAgentBrowserTypeEnabled { enabled.insert(.browserType) }
        return LocalAgentToolCapabilities(enabled: enabled)
    }

    private var localAgentWarningMessages: [String] {
        var warnings: [String] = []
        if !localHardwareProfile.isAppleSilicon {
            warnings.append("Local Agent requires Apple Silicon. Use a cloud or CLI provider for tool work on this Mac.")
        } else {
            switch localHardwareProfile.tier {
            case .unsupported8GB:
                warnings.append("This Mac is below the supported Local Agent tier. Keep Local Agent tools off or use another provider for tool work.")
            case .minimum16GB:
                warnings.append("16 GB Macs can try small Local Agent tasks only. Keep context and tool limits low; 32 GB+ is the beta target.")
            case .recommended32GBPlus:
                break
            }
        }

        let highRisk = LocalAgentToolCapability.allCases
            .filter { configuredLocalAgentCapabilities.contains($0) }
            .map(\.displayName)
        if !highRisk.isEmpty {
            warnings.append("High-risk Local Agent tools enabled: \(highRisk.joined(separator: ", ")). ASTRA still asks for scoped approval before writes, shell, network, or browser changes.")
        }
        return warnings
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func providerChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Stanford.caption(11).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.10)))
    }

    private func providerIcon(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode: "terminal"
        case .copilotCLI: "person.crop.circle"
        case .antigravityCLI: "sparkles"
        case .localMLX: "cpu"
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
                    runtime == .localMLX
                        ? "\(localModelModeSummary) passed the latest readiness check."
                        : "\(descriptor.displayName) passed the latest readiness check.",
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

        if runtime == .localMLX,
           !configuredProviderHomeDirectory(for: runtime).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (
                "Configured",
                "Model folder saved for Private Local Chat. Local Agent tools stay experimental.",
                "checkmark.circle.fill",
                Stanford.statusHealthy
            )
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

    private func expandedProviderBinding(for runtime: AgentRuntimeID) -> Binding<Bool> {
        Binding(
            get: { expandedProviderRuntime == runtime },
            set: { expandedProviderRuntime = $0 ? runtime : nil }
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

    private func providerFolderRow(
        title: String,
        path: Binding<String>,
        prompt: String,
        browseAction: @escaping () -> Void,
        saveAction: @escaping () -> Void,
        hasUnsavedChanges: Bool
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
                        saveAction()
                    }
                Button("Save") {
                    saveAction()
                }
                .disabled(!hasUnsavedChanges)
                Button {
                    browseAction()
                } label: {
                    Label("Browse", systemImage: "folder")
                }
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
                    .foregroundStyle(Stanford.lagunita)
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

    private var localModelChoices: [String] {
        LocalModelInstallChoices.selectableRuntimeModels(preferredModel: localModelPreferredModel)
    }

    private var localModelInstallCandidates: [LocalModelInstallCandidate] {
        LocalModelInstallCandidate.installCandidates(for: localHardwareProfile)
    }

    private var localModelRecommendedInstallCandidate: LocalModelInstallCandidate {
        LocalModelInstallCandidate.recommendedCandidate(for: localHardwareProfile)
    }

    private var selectedLocalModelDirectory: String {
        let draft = providerHomeDirectoryDrafts[.localMLX]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !draft.isEmpty { return draft }
        return RuntimeProviderSettingsStore.homeDirectory(for: .localMLX)
    }

    private var selectedLocalModelSummary: String {
        LocalModelSelectionSummary.summary(directory: selectedLocalModelDirectory)
    }

    private func localModelDisplayName(for model: String) -> String {
        LocalModelInstallCandidate.installCandidates.first { $0.runtimeModel == model }?.title ?? model
    }

    private func localModelCandidateState(
        for candidate: LocalModelInstallCandidate
    ) -> (label: String, symbol: String, tint: Color) {
        if localModelCandidateIsSelected(candidate) {
            return ("Selected", "checkmark.circle.fill", Stanford.statusHealthy)
        }
        if localModelCandidateIsInstalled(candidate) {
            return ("Installed", "checkmark.circle", Stanford.statusHealthy)
        }
        return ("Not installed", "arrow.down.circle", .secondary)
    }

    private func localModelCandidateIsSelected(_ candidate: LocalModelInstallCandidate) -> Bool {
        let selected = selectedLocalModelDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return false }
        return standardizedLocalModelDirectory(selected) == standardizedLocalModelDirectory(candidate.localDirectory)
    }

    private func localModelCandidateIsInstalled(_ candidate: LocalModelInstallCandidate) -> Bool {
        LocalModelCatalog.validate(directory: candidate.localDirectory).state != .blocked
    }

    private func localModelCandidateButtonTitle(for candidate: LocalModelInstallCandidate) -> String {
        if localModelCandidateIsSelected(candidate) { return "Reinstall" }
        if localModelCandidateIsInstalled(candidate) { return "Use" }
        return "Install"
    }

    private func localModelCandidateButtonIcon(for candidate: LocalModelInstallCandidate) -> String {
        if localModelCandidateIsInstalled(candidate), !localModelCandidateIsSelected(candidate) {
            return "checkmark.circle"
        }
        return "arrow.down.circle"
    }

    private func standardizedLocalModelDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private var localHardwareProfile: LocalHardwareProfile {
        LocalHardwareProfile.current()
    }

    private var localModelMemoryBudgetChoices: [Int] {
        [4, 6, 8, 10, 12, 16, 24, 32, 48, 64]
    }

    private var localModelMemoryBudgetDetail: String {
        let automatic = LocalModelMemoryBudget.budgetBytes(for: localHardwareProfile)
        let effective = LocalModelMemoryBudget.effectiveBudgetBytes(
            for: localHardwareProfile,
            configuredBudgetBytes: LocalModelSettingsStore.memoryBudgetOverrideBytes()
        )
        if localModelMemoryBudgetGB == 0 {
            return "Auto budget is \(LocalModelCatalog.formatBytes(effective)) for this Mac."
        }
        return "Configured budget is capped at \(LocalModelCatalog.formatBytes(effective)) by ASTRA's conservative \(LocalModelCatalog.formatBytes(automatic)) automatic ceiling."
    }

    private var localModelSmokeProfile: LocalModelPerformanceProfile? {
        LocalModelPerformanceStore.profile(raw: localModelPerformanceProfileJSON)
    }

    private var localModelSmokeProfileDetail: String {
        guard let profile = localModelSmokeProfile else {
            return "No measured local smoke throughput yet."
        }
        let firstToken = profile.firstTokenLatencyMs.map { "\($0)ms first token" } ?? "unknown first token"
        let throughput = profile.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "unknown throughput"
        let checkedAt = profile.checkedAt.formatted(date: .omitted, time: .shortened)
        return "\(throughput), \(firstToken), \(profile.backend), \(checkedAt)"
    }

    private var localModelHardwareValidationReport: LocalModelHardwareValidationReport {
        _ = localModelHardwareValidationRevision
        return LocalModelHardwareValidationStore.report()
    }

    private var localModelHardwareValidationDetail: String {
        let report = localModelHardwareValidationReport
        guard let latest = report.samples.last else {
            return "No local validation run recorded yet."
        }
        let tier = LocalModelHardwareValidationMatrix.tier(for: latest.profile)?.displayName ?? "this Mac"
        let checkedAt = latest.profile.checkedAt.formatted(date: .omitted, time: .shortened)
        let outcome: String
        switch latest.outcome {
        case .passed:
            outcome = "\(latest.iterations) checks passed"
        case .failed:
            outcome = "last run failed"
        case .blockedAsExpected:
            outcome = "expected hardware block recorded"
        }
        if report.isCompleteForGA {
            return "\(tier): \(outcome), \(checkedAt). All required Mac tiers covered."
        }
        if !report.nonCoveringSamples.isEmpty {
            return "\(tier): \(outcome), \(checkedAt). \(report.summary) \(report.nonCoveringSummary)"
        }
        return "\(tier): \(outcome), \(checkedAt). \(report.summary)"
    }

    private var localAgentBetaSoakDetail: String {
        _ = localAgentBetaSoakRevision
        let report = LocalAgentBetaSoakStore.report()
        guard report.sampleCount > 0 else {
            return "No Local Agent beta soak runs recorded yet."
        }
        return "\(report.completedCount) completed, \(report.approvalRequiredCount) awaiting approval, \(report.blockedCount) blocked, \(report.cancelledCount) cancelled. \(report.summary)"
    }

    private var localModelReleaseGateChecks: [LocalModelReleaseGateCheck] {
        _ = localModelHardwareValidationRevision
        _ = localAgentBetaSoakRevision
        _ = localModelReleaseValidationRevision
        return LocalModelReleaseGateAudit.checks()
    }

    private var localModelReleaseReadinessSummary: LocalModelReleaseReadinessSummary {
        LocalModelReleaseReadinessSummaryBuilder.summary(for: localModelReleaseGateChecks)
    }

    private var localModelReleaseValidationReport: LocalModelReleaseCandidateValidationReport {
        _ = localModelReleaseValidationRevision
        return LocalModelReleaseCandidateValidationStore.report()
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

    private var selectedDefaultPolicyLevel: AgentPolicyLevel {
        AgentPolicyLevel.normalized(defaultAgentPolicyLevelRaw).userFacingLevel
    }

    private var localModelInstallStatusColor: Color {
        if isInstallingLocalModel { return .secondary }
        guard let localModelInstallStatus else { return .secondary }
        if localModelInstallStatus.hasPrefix("Installed")
            || localModelInstallStatus.hasPrefix("Selected") {
            return Stanford.statusHealthy
        }
        return Stanford.statusError
    }

    private var localModelInstallProgressSummary: String {
        guard let progress = localModelInstallProgressState else {
            return "Preparing download..."
        }
        let downloaded = ByteCountFormatter.string(
            fromByteCount: Int64(min(progress.downloadedBytes, UInt64(Int64.max))),
            countStyle: .file
        )
        let estimated = ByteCountFormatter.string(
            fromByteCount: Int64(min(progress.estimatedBytes, UInt64(Int64.max))),
            countStyle: .file
        )
        if let fraction = progress.fractionCompleted {
            return "\(downloaded) of \(estimated) (\(Int((fraction * 100).rounded()))%)"
        }
        return "\(downloaded) downloaded"
    }

    private var localModelInstallConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingLocalModelInstall != nil },
            set: { isPresented in
                if !isPresented {
                    pendingLocalModelInstall = nil
                }
            }
        )
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
            claudeVertexHaikuModel,
            String(localModelProviderEnabled),
            localModelPreferredModel,
            String(localModelMaxContextTokens),
            String(localModelMaxOutputTokens),
            String(localModelKeepWarmTTLSeconds),
            String(localModelMemoryBudgetGB),
            String(localModelExperimentalTools),
            configuredLocalAgentCapabilities.enabledSummary
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

    private func releaseGateSymbol(for status: LocalModelReleaseGateStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .inProgress: "clock.badge.exclamationmark"
        }
    }

    private func releaseGateColor(for status: LocalModelReleaseGateStatus) -> Color {
        switch status {
        case .passed: Stanford.statusHealthy
        case .inProgress: Stanford.statusWarn
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
            providerHomeDirectoryDrafts[runtime] = RuntimeProviderSettingsStore.homeDirectory(for: runtime)
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

    private func providerHomeDirectoryBinding(for runtime: AgentRuntimeID) -> Binding<String> {
        Binding(
            get: {
                providerHomeDirectoryDrafts[runtime] ?? RuntimeProviderSettingsStore.homeDirectory(for: runtime)
            },
            set: { value in
                providerHomeDirectoryDrafts[runtime] = value
            }
        )
    }

    private func saveProviderHomeDirectoryDraft(for runtime: AgentRuntimeID) {
        let value = providerHomeDirectoryDrafts[runtime] ?? ""
        if runtime == .localMLX {
            saveLocalModelDirectory(value)
            return
        }
        RuntimeProviderSettingsStore.setHomeDirectory(value, for: runtime)
    }

    private func hasUnsavedProviderHomeDirectoryDraft(for runtime: AgentRuntimeID) -> Bool {
        ProviderPathPersistenceState.hasUnsavedDraft(
            draft: providerHomeDirectoryDrafts[runtime],
            persisted: RuntimeProviderSettingsStore.homeDirectory(for: runtime)
        )
    }

    private func browseProviderHomeDirectory(for runtime: AgentRuntimeID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select the local model folder"
        if panel.runModal() == .OK, let url = panel.url {
            providerHomeDirectoryDrafts[runtime] = url.path
            if runtime == .localMLX {
                saveLocalModelDirectory(url.path)
                return
            }
            RuntimeProviderSettingsStore.setHomeDirectory(url.path, for: runtime)
        }
    }

    private func saveLocalModelDirectory(_ path: String) {
        providerHomeDirectoryDrafts[.localMLX] = path
        let report = LocalModelCatalog.importModel(directory: path)
        guard report.state != .blocked else {
            localModelInstallStatus = report.remediation.map { "\(report.detail) \($0)" } ?? report.detail
            readinessReport = nil
            readinessCheckedAt = nil
            return
        }

        RuntimeProviderSettingsStore.setHomeDirectory(path, for: .localMLX)
        localModelInstallStatus = "Selected existing local model folder."
        lastLocalModelInstallCandidate = nil
        readinessReport = nil
        readinessCheckedAt = nil
        Task { await refreshRuntimeReadiness() }
    }

    private func selectInstalledLocalModel(_ candidate: LocalModelInstallCandidate) {
        let validation = LocalModelCatalog.validate(directory: candidate.localDirectory)
        guard validation.state != .blocked else {
            localModelInstallStatus = validation.remediation.map { "\(validation.detail) \($0)" } ?? validation.detail
            return
        }

        LocalModelSettingsStore.setModelDirectory(
            candidate.localDirectory,
            metadata: validation.metadata
        )
        UserDefaults.standard.set(candidate.runtimeModel, forKey: LocalModelSettingsStore.preferredModelKey)
        RuntimeProviderSettingsStore.setHomeDirectory(candidate.localDirectory, for: .localMLX)
        providerHomeDirectoryDrafts[.localMLX] = candidate.localDirectory
        localModelPreferredModel = candidate.runtimeModel
        if selectedRuntime == .localMLX {
            defaultModel = candidate.runtimeModel
            validationModel = candidate.runtimeModel
        }
        localModelInstallStatus = "Selected \(candidate.title)."
        lastLocalModelInstallCandidate = nil
        readinessReport = nil
        readinessCheckedAt = nil
        Task { await refreshRuntimeReadiness() }
    }

    @MainActor
    private func startLocalModelInstall(_ candidate: LocalModelInstallCandidate) {
        localModelInstallTask?.cancel()
        lastLocalModelInstallCandidate = candidate
        localModelInstallProgressState = nil
        localModelInstallTask = Task { await installLocalModel(candidate) }
    }

    @MainActor
    private func cancelLocalModelInstall() {
        localModelInstallTask?.cancel()
        localModelInstallStatus = "Cancelling local model download and cleaning up partial files..."
    }

    @MainActor
    private func installLocalModel(_ candidate: LocalModelInstallCandidate) async {
        pendingLocalModelInstall = nil
        isInstallingLocalModel = true
        localModelInstallStatus = "Downloading \(candidate.title) to ASTRA's LocalModels folder..."
        localModelInstallProgressState = LocalModelInstallProgress(downloadedBytes: 0, estimatedBytes: candidate.estimatedBytes)
        defer {
            isInstallingLocalModel = false
            localModelInstallTask = nil
        }

        do {
            let result = try await LocalModelInstaller().install(candidate: candidate) { progress in
                await MainActor.run {
                    localModelInstallProgressState = progress
                }
            }
            providerHomeDirectoryDrafts[.localMLX] = result.candidate.localDirectory
            localModelPreferredModel = result.candidate.runtimeModel
            defaultModel = result.candidate.runtimeModel
            validationModel = result.candidate.runtimeModel
            localModelInstallStatus = "Installed and selected \(result.candidate.title)."
            localModelInstallProgressState = nil
            lastLocalModelInstallCandidate = nil
            readinessReport = nil
            readinessCheckedAt = nil
            await refreshRuntimeReadiness()
        } catch LocalModelInstallerError.cancelled {
            localModelInstallStatus = LocalModelInstallerError.cancelled.localizedDescription
            localModelInstallProgressState = nil
            readinessReport = nil
            readinessCheckedAt = nil
        } catch {
            localModelInstallStatus = error.localizedDescription
            localModelInstallProgressState = nil
            readinessReport = nil
            readinessCheckedAt = nil
        }
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

    private func configuredProviderHomeDirectory(for runtime: AgentRuntimeID) -> String {
        ProviderPathPersistenceState.persistedPath(
            for: runtime,
            claudePath: "",
            copilotPath: "",
            providerPath: RuntimeProviderSettingsStore.homeDirectory(for: runtime)
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

    private func runLocalModelValidation() async {
        isRunningLocalModelValidation = true
        localModelValidationCheck = nil
        localModelValidationExchangeStatus = nil
        defer { isRunningLocalModelValidation = false }

        let mode: LocalModelValidationMode = localModelExperimentalTools ? .localAgentReadOnly : .localChat
        let result = await LocalModelSustainedValidationService().run(
            configuration: readinessConfiguration,
            mode: mode
        )
        localModelValidationCheck = result.check
        localModelHardwareValidationRevision += 1
        if result.check.state != .blocked {
            readinessReport = nil
            readinessCheckedAt = nil
        }
    }

    private func copyLocalModelValidationEvidence() {
        do {
            let payload = try LocalModelHardwareValidationStore.exportEvidence()
            copyToPasteboard(payload)
            localModelValidationExchangeStatus = "Copied Local MLX validation evidence for sharing with the release validation set."
        } catch {
            localModelValidationExchangeStatus = error.localizedDescription
        }
    }

    private func importLocalModelValidationEvidence() {
        guard let payload = NSPasteboard.general.string(forType: .string) else {
            localModelValidationExchangeStatus = "Copy Local MLX validation evidence from another Mac, then import it here. ASTRA accepts raw JSON or JSON pasted from notes or chat."
            return
        }
        do {
            let result = try LocalModelHardwareValidationStore.mergeEvidence(payload)
            localModelHardwareValidationRevision += 1
            localModelValidationExchangeStatus = "Imported \(result.importedCount) validation samples; \(result.skippedCount) were already present. \(result.report.summary)"
        } catch {
            localModelValidationExchangeStatus = error.localizedDescription
        }
    }

    private func copyLocalAgentBetaSoakEvidence() {
        do {
            let payload = try LocalAgentBetaSoakStore.exportEvidence()
            copyToPasteboard(payload)
            localAgentBetaSoakExchangeStatus = "Copied Local Agent beta-soak evidence for sharing with the release validation set."
        } catch {
            localAgentBetaSoakExchangeStatus = error.localizedDescription
        }
    }

    private func importLocalAgentBetaSoakEvidence() {
        guard let payload = NSPasteboard.general.string(forType: .string) else {
            localAgentBetaSoakExchangeStatus = "Copy Local Agent beta-soak evidence from another Mac, then import it here. ASTRA accepts raw JSON or JSON pasted from notes or chat."
            return
        }
        do {
            let result = try LocalAgentBetaSoakStore.mergeEvidence(payload)
            localAgentBetaSoakRevision += 1
            localAgentBetaSoakExchangeStatus = "Imported \(result.importedCount) beta-soak samples; \(result.skippedCount) were already present. \(result.report.summary)"
        } catch {
            localAgentBetaSoakExchangeStatus = error.localizedDescription
        }
    }

    private func copyLocalModelReleaseValidationEvidence() {
        do {
            let payload = try LocalModelReleaseCandidateValidationStore.exportEvidence()
            copyToPasteboard(payload)
            localModelReleaseValidationExchangeStatus = "Copied Local MLX release-candidate evidence for sharing with the release validation set."
        } catch {
            localModelReleaseValidationExchangeStatus = error.localizedDescription
        }
    }

    private func importLocalModelReleaseValidationEvidence() {
        guard let payload = NSPasteboard.general.string(forType: .string) else {
            localModelReleaseValidationExchangeStatus = "Copy Local MLX release-candidate evidence, then import it here. ASTRA accepts raw JSON or JSON pasted from notes or chat."
            return
        }
        do {
            let result = try LocalModelReleaseCandidateValidationStore.mergeEvidence(payload)
            localModelReleaseValidationRevision += 1
            localModelReleaseValidationExchangeStatus = "Imported \(result.importedCount) release-candidate samples; \(result.skippedCount) were already present. \(result.report.summary)"
        } catch {
            localModelReleaseValidationExchangeStatus = error.localizedDescription
        }
    }

    private func copyLocalModelReleaseReadinessSummary() {
        let payload = LocalModelReleaseReadinessSummaryBuilder.textReport(for: localModelReleaseGateChecks)
        copyToPasteboard(payload)
        localModelReleaseValidationExchangeStatus = "Copied Local MLX release-readiness summary."
    }

    private func copyLocalModelCombinedReleaseEvidence() {
        do {
            let payload = try LocalModelCombinedReleaseEvidenceStore.exportEvidence()
            copyToPasteboard(payload)
            localModelReleaseValidationExchangeStatus = "Copied Local MLX validation bundle with release, beta, and hardware evidence."
        } catch {
            localModelReleaseValidationExchangeStatus = error.localizedDescription
        }
    }

    private func importLocalModelCombinedReleaseEvidence() {
        guard let payload = NSPasteboard.general.string(forType: .string) else {
            localModelReleaseValidationExchangeStatus = "Copy a Local MLX validation bundle from another Mac, then import it here. ASTRA accepts raw JSON or JSON pasted from notes or chat."
            return
        }
        do {
            let result = try LocalModelCombinedReleaseEvidenceStore.mergeEvidence(payload)
            localModelReleaseValidationRevision += 1
            localAgentBetaSoakRevision += 1
            localModelHardwareValidationRevision += 1
            localModelReleaseValidationExchangeStatus = result.summary
        } catch {
            localModelReleaseValidationExchangeStatus = error.localizedDescription
        }
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
        if runtime == .localMLX {
            let preferred = localModelPreferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = preferred.isEmpty ? LocalMLXRuntime.defaultModel : preferred
            defaultModel = resolved
            validationModel = resolved
            return
        }
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
