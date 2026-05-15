import AppKit
import SwiftUI
import ASTRACore

struct AgentPolicySheet: View {
    let runtime: AgentRuntimeID
    let model: String
    let workspace: Workspace?
    let skills: [Skill]

    @Binding var selectedPolicyLevelRaw: String
    @Binding var globalDefaultLevelRaw: String
    @Binding var skipPermissions: Bool
    var onPolicyLevelChange: ((AgentPolicyLevel) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var workspaceDefaultLevelRaw: String
    @State private var providerSettingsRevision = 0
    @State private var customPolicyDraft: AgentPolicy
    @State private var customAllowedShellPatternsText: String
    @State private var customAskFirstShellPatternsText: String
    @State private var customDeniedShellPatternsText: String
    @State private var customAllowedURLPatternsText: String
    @State private var customDeniedURLPatternsText: String

    init(
        runtime: AgentRuntimeID,
        model: String,
        workspace: Workspace?,
        skills: [Skill],
        selectedPolicyLevelRaw: Binding<String>,
        globalDefaultLevelRaw: Binding<String>,
        skipPermissions: Binding<Bool>,
        onPolicyLevelChange: ((AgentPolicyLevel) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.model = model
        self.workspace = workspace
        self.skills = skills
        self.onPolicyLevelChange = onPolicyLevelChange
        _selectedPolicyLevelRaw = selectedPolicyLevelRaw
        _globalDefaultLevelRaw = globalDefaultLevelRaw
        _skipPermissions = skipPermissions
        _workspaceDefaultLevelRaw = State(initialValue: AgentPolicyDefaults.workspaceLevel(for: workspace)?.rawValue ?? "")
        let initialCustomPolicy = AgentPolicyDefaults.customPolicy(for: workspace)
        _customPolicyDraft = State(initialValue: initialCustomPolicy)
        _customAllowedShellPatternsText = State(initialValue: Self.policyListText(initialCustomPolicy.allowedShellPatterns))
        _customAskFirstShellPatternsText = State(initialValue: Self.policyListText(initialCustomPolicy.askFirstShellPatterns))
        _customDeniedShellPatternsText = State(initialValue: Self.policyListText(initialCustomPolicy.deniedShellPatterns))
        _customAllowedURLPatternsText = State(initialValue: Self.policyListText(initialCustomPolicy.allowedURLPatterns))
        _customDeniedURLPatternsText = State(initialValue: Self.policyListText(initialCustomPolicy.deniedURLPatterns))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("Policy Level") {
                    Picker("Current", selection: policySelectionBinding) {
                        ForEach(AgentPolicyLevel.allCases) { level in
                            Label(level.displayName, systemImage: level.symbolName)
                                .tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(selectedLevel.shortDescription)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }

                if selectedLevel == .custom {
                    customRulesSection
                }

                Section("What Can Happen") {
                    policyListRow("Allowed without asking", values: policy.allowedTools, color: Stanford.paloAltoGreen)
                    policyListRow("Ask first", values: policy.askFirstTools + policy.askFirstShellPatterns, color: Stanford.poppy)
                    policyListRow("Denied", values: policy.deniedTools + policy.deniedShellPatterns + policy.deniedURLPatterns, color: Stanford.cardinalRed)
                }

                Section("Scope") {
                    factRow("Workspace", value: workspacePath)
                    factRow("Additional paths", value: additionalPaths.isEmpty ? "None" : "\(additionalPaths.count) configured")
                    factRow("Network", value: networkSummary)
                    factRow("Credentials", value: credentialLabels.isEmpty ? "None injected by policy preview" : credentialLabels.joined(separator: ", "))
                }

                Section("Provider Render") {
                    factRow("Runtime", value: runtime.displayName)
                    factRow("Permission mode", value: render.permissionMode)
                    factRow("Config source", value: render.configOwnership.displayName)
                    factRow("Enforcement", value: render.enforcementTiers.map(\.displayName).joined(separator: ", "))
                    factRow("Broad provider permissions", value: render.usesBroadProviderPermissions ? "Yes" : "No")
                    policyListRow("Provider arguments", values: render.cliArgumentsSummary, color: Stanford.lagunita)
                    Text(render.settingsSummary)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !render.generatedConfigPreview.isEmpty {
                        Text(render.generatedConfigPreview)
                            .font(Stanford.mono(11))
                            .foregroundStyle(Stanford.coolGrey)
                            .textSelection(.enabled)
                            .lineLimit(8...16)
                    }
                }

                Section("Diagnostics") {
                    if render.diagnostics.isEmpty {
                        Label("No provider policy conflicts detected for this preview.", systemImage: "checkmark.seal")
                            .foregroundStyle(Stanford.paloAltoGreen)
                    } else {
                        ForEach(render.diagnostics) { diagnostic in
                            diagnosticRow(diagnostic)
                        }
                    }
                }

                Section("Defaults") {
                    Picker("Global default", selection: globalDefaultBinding) {
                        ForEach(AgentPolicyLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }

                    Picker("Workspace default", selection: $workspaceDefaultLevelRaw) {
                        Text("Use global default").tag("")
                        ForEach(AgentPolicyLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    .disabled(workspace == nil)
                    .onChange(of: workspaceDefaultLevelRaw) {
                        let level = workspaceDefaultLevelRaw.isEmpty
                            ? nil
                            : AgentPolicyLevel.normalized(workspaceDefaultLevelRaw)
                        AgentPolicyDefaults.setWorkspaceLevel(level, for: workspace)
                    }

                    Button {
                        select(level: .review)
                        globalDefaultLevelRaw = AgentPolicyLevel.review.rawValue
                        workspaceDefaultLevelRaw = ""
                        AgentPolicyDefaults.setWorkspaceLevel(nil, for: workspace)
                    } label: {
                        Label("Reset policy defaults to Review", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("Advanced") {
                    Button {
                        resetProviderSettingsToGeneratedDefaults()
                    } label: {
                        Label("Reset provider settings to generated config", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(runtime != .claudeCode)

                    Button {
                        openProviderDocumentation()
                    } label: {
                        Label("Open provider policy documentation", systemImage: "book")
                    }

                    Text("Provider settings are rendered from ASTRA policy for each run. User-owned provider files are preserved; unsupported or broader provider behavior appears as diagnostics before execution.")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 660, height: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: selectedLevel.symbolName)
                .font(Stanford.ui(22, weight: .semibold))
                .foregroundStyle(policyColor(selectedLevel))
                .frame(width: 34, height: 34)
                .background(policyColor(selectedLevel).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Policy")
                    .font(Stanford.heading(20))
                Text("\(selectedLevel.displayName) for \(runtime.displayName) · \(model)")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding()
    }

    private var selectedLevel: AgentPolicyLevel {
        skipPermissions ? .autonomous : AgentPolicyLevel.normalized(selectedPolicyLevelRaw)
    }

    private var policy: AgentPolicy {
        selectedLevel == .custom ? customPolicyDraft : AgentPolicy.preset(selectedLevel)
    }

    private var render: ProviderPolicyRender {
        _ = providerSettingsRevision
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: runtime)
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: additionalPaths,
            requestedAllowedTools: requestedAllowedTools,
            localToolCommands: localToolCommands,
            environmentKeyNames: environmentKeyNames,
            credentialLabels: credentialLabels,
            providerFeatures: adapter.supportedFeatures,
            providerConfigOwnership: providerConfigOwnership,
            existingProviderConfigSummary: existingProviderConfigSummary
        )
        return adapter.render(policy: policy, context: context)
    }

    private var customRulesSection: some View {
        Section("Custom Rules") {
            Text("Saved \(customPolicyScopeDescription). These rules are rendered into the provider command/config and into ASTRA's runtime guard.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)

            ForEach(configurableTools, id: \.self) { tool in
                customToolRow(tool)
            }

            Divider()

            customPatternField(
                "Allowed shell patterns",
                text: customAllowedShellPatternsBinding,
                placeholder: "git:*\nswift:*"
            )
            customPatternField(
                "Ask-first shell patterns",
                text: customAskFirstShellPatternsBinding,
                placeholder: "curl:*"
            )
            customPatternField(
                "Denied shell patterns",
                text: customDeniedShellPatternsBinding,
                placeholder: "rm:*\nsudo:*"
            )
            customPatternField(
                "Allowed network patterns",
                text: customAllowedURLPatternsBinding,
                placeholder: "https://api.github.com/*"
            )
            customPatternField(
                "Denied network patterns",
                text: customDeniedURLPatternsBinding,
                placeholder: "*.internal.example.com"
            )

            HStack {
                Button("Start From Review") {
                    applyPresetToCustom(.review)
                }
                Button("Start From Build") {
                    applyPresetToCustom(.build)
                }
                Button("Reset To Built-In") {
                    resetCustomPolicy()
                }
                if workspace != nil {
                    Button("Use Global") {
                        useGlobalCustomPolicy()
                    }
                    Button("Save Globally") {
                        AgentPolicyDefaults.setCustomPolicy(customPolicyDraft, for: nil)
                    }
                }
                Spacer()
            }
        }
    }

    private var policySelectionBinding: Binding<String> {
        Binding(
            get: { selectedLevel.rawValue },
            set: { select(level: AgentPolicyLevel.normalized($0)) }
        )
    }

    private var globalDefaultBinding: Binding<String> {
        Binding(
            get: { AgentPolicyLevel.normalized(globalDefaultLevelRaw).rawValue },
            set: { globalDefaultLevelRaw = AgentPolicyLevel.normalized($0).rawValue }
        )
    }

    private var workspacePath: String {
        workspace?.primaryPath ?? FileManager.default.currentDirectoryPath
    }

    private var additionalPaths: [String] {
        Array(Set(workspace?.additionalPaths ?? [])).sorted()
    }

    private var requestedAllowedTools: [String] {
        Array(Set(skills.flatMap(\.allowedTools))).sorted()
    }

    private var localToolCommands: [String] {
        Array(Set(skills.flatMap(\.localTools).map(\.command).filter { !$0.isEmpty })).sorted()
    }

    private var environmentKeyNames: [String] {
        Array(Set(skills.flatMap(\.environmentKeys))).sorted()
    }

    private var credentialLabels: [String] {
        let connectorKeys = skills.flatMap(\.connectors).flatMap(\.credentialKeys)
        return Array(Set(environmentKeyNames + connectorKeys)).sorted()
    }

    private var customPolicyScopeDescription: String {
        workspace == nil ? "as the global custom policy" : "as this workspace's custom policy"
    }

    private var configurableTools: [String] {
        let tools = [
            "Read",
            "Glob",
            "Grep",
            "Write",
            "Edit",
            "MultiEdit",
            "Bash",
            "WebFetch",
            "WebSearch",
            "Agent"
        ] + requestedAllowedTools + customPolicyDraft.allowedTools + customPolicyDraft.askFirstTools + customPolicyDraft.deniedTools
        return Self.uniquePolicyValues(tools)
    }

    private var customAllowedShellPatternsBinding: Binding<String> {
        Binding(
            get: { customAllowedShellPatternsText },
            set: {
                customAllowedShellPatternsText = $0
                updateCustomPolicyList(\.allowedShellPatterns, from: $0)
            }
        )
    }

    private var customAskFirstShellPatternsBinding: Binding<String> {
        Binding(
            get: { customAskFirstShellPatternsText },
            set: {
                customAskFirstShellPatternsText = $0
                updateCustomPolicyList(\.askFirstShellPatterns, from: $0)
            }
        )
    }

    private var customDeniedShellPatternsBinding: Binding<String> {
        Binding(
            get: { customDeniedShellPatternsText },
            set: {
                customDeniedShellPatternsText = $0
                updateCustomPolicyList(\.deniedShellPatterns, from: $0)
            }
        )
    }

    private var customAllowedURLPatternsBinding: Binding<String> {
        Binding(
            get: { customAllowedURLPatternsText },
            set: {
                customAllowedURLPatternsText = $0
                updateCustomPolicyList(\.allowedURLPatterns, from: $0)
            }
        )
    }

    private var customDeniedURLPatternsBinding: Binding<String> {
        Binding(
            get: { customDeniedURLPatternsText },
            set: {
                customDeniedURLPatternsText = $0
                updateCustomPolicyList(\.deniedURLPatterns, from: $0)
            }
        )
    }

    private var networkSummary: String {
        if policy.allowedURLPatterns.isEmpty && policy.deniedURLPatterns.isEmpty {
            return selectedLevel == .autonomous ? "Broad network allowed by provider policy" : "Ask first or connector-scoped"
        }
        let allowed = policy.allowedURLPatterns.isEmpty ? "none" : policy.allowedURLPatterns.joined(separator: ", ")
        let denied = policy.deniedURLPatterns.isEmpty ? "none" : policy.deniedURLPatterns.joined(separator: ", ")
        return "Allow: \(allowed). Deny: \(denied)."
    }

    private var providerConfigOwnership: PolicyConfigOwnership {
        switch runtime {
        case .claudeCode:
            ClaudeSettingsStore.configOwnership(at: workspacePath)
        case .copilotCLI:
            .generated
        }
    }

    private var existingProviderConfigSummary: String? {
        switch runtime {
        case .claudeCode:
            ClaudeSettingsStore.existingConfigSummary(at: workspacePath)
        case .copilotCLI:
            nil
        }
    }

    private func select(level: AgentPolicyLevel) {
        selectedPolicyLevelRaw = level.rawValue
        skipPermissions = level == .autonomous
        onPolicyLevelChange?(level)
    }

    private func customToolRow(_ tool: String) -> some View {
        HStack(spacing: 12) {
            Text(tool)
                .font(Stanford.caption(12).monospaced())
                .frame(minWidth: 92, alignment: .leading)

            Picker(tool, selection: customToolDispositionBinding(for: tool)) {
                ForEach(CustomToolDisposition.allCases) { disposition in
                    Text(disposition.displayName).tag(disposition)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 280)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func customPatternField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Stanford.caption(12).weight(.semibold))
            TextField(placeholder, text: text, axis: .vertical)
                .font(Stanford.mono(11))
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 3)
    }

    private func customToolDispositionBinding(for tool: String) -> Binding<CustomToolDisposition> {
        Binding(
            get: { customToolDisposition(for: tool) },
            set: { setCustomTool(tool, disposition: $0) }
        )
    }

    private func customToolDisposition(for tool: String) -> CustomToolDisposition {
        if customPolicyDraft.deniedTools.contains(tool) {
            return .deny
        }
        if customPolicyDraft.askFirstTools.contains(tool) {
            return .askFirst
        }
        if customPolicyDraft.allowedTools.contains(tool) || requestedAllowedTools.contains(tool) {
            return .allow
        }
        return .deny
    }

    private func setCustomTool(_ tool: String, disposition: CustomToolDisposition) {
        var policy = customPolicyDraft
        policy.allowedTools.removeAll { $0 == tool }
        policy.askFirstTools.removeAll { $0 == tool }
        policy.deniedTools.removeAll { $0 == tool }

        switch disposition {
        case .allow:
            policy.allowedTools.append(tool)
        case .askFirst:
            policy.askFirstTools.append(tool)
        case .deny:
            policy.deniedTools.append(tool)
        }

        policy.allowedTools = Self.uniquePolicyValues(policy.allowedTools)
        policy.askFirstTools = Self.uniquePolicyValues(policy.askFirstTools)
        policy.deniedTools = Self.uniquePolicyValues(policy.deniedTools)
        applyCustomPolicy(policy, syncPatternText: false)
    }

    private func updateCustomPolicyList(
        _ keyPath: WritableKeyPath<AgentPolicy, [String]>,
        from text: String
    ) {
        var policy = customPolicyDraft
        policy[keyPath: keyPath] = Self.normalizedPolicyList(from: text)
        applyCustomPolicy(policy, syncPatternText: false)
    }

    private func applyPresetToCustom(_ level: AgentPolicyLevel) {
        var policy = AgentPolicy.preset(level)
        policy.level = .custom
        applyCustomPolicy(policy)
    }

    private func resetCustomPolicy() {
        let policy = AgentPolicy.preset(.custom)
        AgentPolicyDefaults.resetCustomPolicy(for: workspace)
        applyCustomPolicy(policy)
    }

    private func useGlobalCustomPolicy() {
        let policy = AgentPolicyDefaults.globalCustomPolicy()
        AgentPolicyDefaults.resetCustomPolicy(for: workspace)
        customPolicyDraft = policy
        syncCustomPatternText(from: policy)
    }

    private func applyCustomPolicy(_ policy: AgentPolicy, syncPatternText: Bool = true) {
        var customPolicy = policy
        customPolicy.level = .custom
        customPolicyDraft = customPolicy
        if syncPatternText {
            syncCustomPatternText(from: customPolicy)
        }
        AgentPolicyDefaults.setCustomPolicy(customPolicy, for: workspace)
    }

    private func syncCustomPatternText(from policy: AgentPolicy) {
        customAllowedShellPatternsText = Self.policyListText(policy.allowedShellPatterns)
        customAskFirstShellPatternsText = Self.policyListText(policy.askFirstShellPatterns)
        customDeniedShellPatternsText = Self.policyListText(policy.deniedShellPatterns)
        customAllowedURLPatternsText = Self.policyListText(policy.allowedURLPatterns)
        customDeniedURLPatternsText = Self.policyListText(policy.deniedURLPatterns)
    }

    @ViewBuilder
    private func policyListRow(_ title: String, values: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "circle.fill")
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(color)

            if values.isEmpty {
                Text("None")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(Stanford.caption(11).monospaced())
                            .foregroundStyle(color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func factRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(Stanford.caption(12))
    }

    private func diagnosticRow(_ diagnostic: PolicyDiagnostic) -> some View {
        let color = diagnosticColor(diagnostic.severity)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: diagnosticIcon(diagnostic.severity))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title)
                    .font(Stanford.caption(12).weight(.semibold))
                    .foregroundStyle(color)
                Text(diagnostic.message)
                    .font(Stanford.caption(12))
                if let remediation = diagnostic.remediation {
                    Text(remediation)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func openProviderDocumentation() {
        let urlString: String
        switch runtime {
        case .claudeCode:
            urlString = "https://code.claude.com/docs/en/settings#settings-files"
        case .copilotCLI:
            urlString = "https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func resetProviderSettingsToGeneratedDefaults() {
        guard runtime == .claudeCode,
              let permissionPolicy = PermissionPolicy(rawValue: render.permissionMode) else {
            return
        }
        _ = ClaudeSettingsStore.ensureSubAgentPermissions(
            at: workspacePath,
            policy: permissionPolicy,
            allowedTools: render.allowedTools
        )
        providerSettingsRevision += 1
    }

    private static func policyListText(_ values: [String]) -> String {
        uniquePolicyValues(values).joined(separator: "\n")
    }

    private static func normalizedPolicyList(from text: String) -> [String] {
        uniquePolicyValues(
            text
                .components(separatedBy: CharacterSet(charactersIn: "\n,"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private static func uniquePolicyValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private func policyColor(_ level: AgentPolicyLevel) -> Color {
        switch level {
        case .locked: Stanford.cardinalRed
        case .review: Stanford.paloAltoGreen
        case .build: Stanford.lagunita
        case .network: Stanford.sky
        case .autonomous: Stanford.lagunita
        case .custom: Stanford.plum
        }
    }

    private func diagnosticColor(_ severity: PolicyDiagnosticSeverity) -> Color {
        switch severity {
        case .info: Stanford.sky
        case .warning: Stanford.poppy
        case .blocked: Stanford.cardinalRed
        }
    }

    private func diagnosticIcon(_ severity: PolicyDiagnosticSeverity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocked: "xmark.octagon"
        }
    }
}

private enum CustomToolDisposition: String, CaseIterable, Identifiable {
    case allow
    case askFirst
    case deny

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allow: "Allow"
        case .askFirst: "Ask"
        case .deny: "Deny"
        }
    }
}
