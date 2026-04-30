import AppKit
import SwiftUI
import ASTRACore

struct SettingsView: View {
    @ObservedObject var appUpdateController: AppUpdateController
    @AppStorage("defaultModel") private var defaultModel = "claude-sonnet-4-6"
    @AppStorage("defaultTokenBudget") private var defaultTokenBudget = 50000
    @AppStorage("defaultRuntimeID") private var defaultRuntimeID = AgentRuntimeID.claudeCode.rawValue
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("copilotPath") private var copilotPath = ""
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @AppStorage("timeoutSeconds") private var timeoutSeconds = 600
    @AppStorage("validationModel") private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage("workerPoolSize") private var workerPoolSize = 3
    @AppStorage(AppLogger.sensitiveModeKey) private var sensitiveMode = true
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue

    private let budgetPresets = [10000, 25000, 50000, 100000, 200000, 500000, 1000000, 0]

    @State private var detectedPath = ""
    @State private var detectedCopilotPath = ""

    @MainActor
    init(appUpdateController: AppUpdateController) {
        self.appUpdateController = appUpdateController
    }

    var body: some View {
        Form {
            Section("Agent Runtime") {
                Picker("Default Provider", selection: $defaultRuntimeID) {
                    ForEach(AgentRuntimeID.allCases) { runtime in
                        Text(runtime.displayName).tag(runtime.rawValue)
                    }
                }
                .onChange(of: defaultRuntimeID) {
                    let runtime = AgentRuntimeID(rawValue: defaultRuntimeID) ?? .claudeCode
                    if !runtime.defaultModels.contains(defaultModel) {
                        defaultModel = runtime.defaultModel
                    }
                }
                Text("New tasks use this provider. Existing tasks keep the provider they were created with.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
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

            Section("Defaults") {
                Picker("Model", selection: $defaultModel) {
                    ForEach(runtimeModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }

                Picker("Token Budget", selection: $defaultTokenBudget) {
                    ForEach(budgetPresets, id: \.self) { b in
                        Text(b == 0 ? "Unlimited" : "\(b / 1000)k tokens").tag(b)
                    }
                }

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

            Section("Appearance") {
                // Segmented picker so the three options are visible without
                // a click — this is the kind of setting people scan for.
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

            Section("Execution") {
                HStack {
                    Text("Timeout")
                    Spacer()
                    TextField("Seconds", value: $timeoutSeconds, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

                Picker("Validation Model", selection: $validationModel) {
                    ForEach(AgentRuntimeID.claudeCode.defaultModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }

                HStack {
                    Text("Parallel Workers")
                    Spacer()
                    Picker("", selection: $workerPoolSize) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                        Text("5").tag(5)
                    }
                    .frame(width: 60)
                }
                Text("Number of tasks that can run simultaneously. Restart app to apply.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy & Logging") {
                Toggle("Sensitive Mode", isOn: $sensitiveMode)
                Text("When enabled, operational logs omit prompts, model output, full paths, commands, secret identifiers, and credential values. Task history remains available as product data for review.")
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

            Section("Data Locations") {
                dataLocationRow("App Channel", path: AppChannel.current.displayName, canOpen: false)
                dataLocationRow("App Support", path: WorkspaceRecoveryService.applicationSupportDirectory.path)
                dataLocationRow("SwiftData Store", path: WorkspaceRecoveryService.storeURL.path)
                dataLocationRow("Workspaces", path: resolvedWorkspacesRoot)
                dataLocationRow("Workspace Support", path: "<workspace>/.astra", canOpen: false)
                dataLocationRow("Logs", path: AppLogger.mainLogFile.deletingLastPathComponent().path)
                dataLocationRow("Claude Sessions", path: NSHomeDirectory() + "/.claude/projects")
                dataLocationRow("ASTRA Tools", path: NSHomeDirectory() + "/.astra")
                if FileManager.default.fileExists(atPath: WorkspaceRecoveryService.legacyStoreURL.path) {
                    dataLocationRow("Legacy Store", path: WorkspaceRecoveryService.legacyStoreURL.path)
                }
                Text("App state, workspace artifacts, logs, secrets, and Claude sessions intentionally live in separate macOS-standard locations.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .navigationTitle("Settings")
        .onAppear {
            detectClaudeCLI()
            detectCopilotCLI()
        }
    }

    private var resolvedWorkspacesRoot: String {
        workspacesRoot.isEmpty ? AppChannel.current.defaultWorkspacesRoot : workspacesRoot
    }

    private var runtimeModels: [String] {
        (AgentRuntimeID(rawValue: defaultRuntimeID) ?? .claudeCode).defaultModels
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
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                detectedPath = path
                if claudePath.isEmpty { claudePath = path }
                return
            }
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
}
