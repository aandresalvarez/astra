import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultModel") private var defaultModel = "claude-sonnet-4-6"
    @AppStorage("defaultTokenBudget") private var defaultTokenBudget = 50000
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("workspacesRoot") private var workspacesRoot = ""
    @AppStorage("timeoutSeconds") private var timeoutSeconds = 600
    @AppStorage("validationModel") private var validationModel = "claude-haiku-4-5-20251001"
    @AppStorage("workerPoolSize") private var workerPoolSize = 3
    @AppStorage(AppLogger.sensitiveModeKey) private var sensitiveMode = true
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue

    private let models = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
    private let budgetPresets = [10000, 25000, 50000, 100000, 200000, 500000, 1000000, 0]

    @State private var detectedPath = ""

    var body: some View {
        Form {
            Section("Claude CLI") {
                HStack {
                    TextField("Path", text: $claudePath, prompt: Text("Auto-detected"))
                    Button("Detect") {
                        detectCLI()
                    }
                }
                if !detectedPath.isEmpty {
                    Text("Detected: \(detectedPath)")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Defaults") {
                Picker("Model", selection: $defaultModel) {
                    ForEach(models, id: \.self) { m in
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
                              prompt: Text("~/Documents/Astra/Workspaces"))
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
                    ForEach(models, id: \.self) { m in
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

            Section("Data Locations") {
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
            detectCLI()
        }
    }

    private var resolvedWorkspacesRoot: String {
        workspacesRoot.isEmpty ? NSHomeDirectory() + "/Documents/Astra/Workspaces" : workspacesRoot
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

    private func detectCLI() {
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
