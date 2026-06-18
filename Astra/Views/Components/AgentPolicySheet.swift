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
        let selectedStoredLevel = AgentPolicyLevel.normalized(selectedPolicyLevelRaw.wrappedValue)
        let globalStoredLevel = AgentPolicyLevel.normalized(globalDefaultLevelRaw.wrappedValue)
        let workspaceStoredLevel = AgentPolicyDefaults.workspaceLevel(for: workspace)
        if let workspaceStoredLevel {
            _ = AgentPolicyDefaults.effectiveUserFacingLevel(forStored: workspaceStoredLevel, workspace: workspace)
        } else {
            _ = AgentPolicyDefaults.effectiveUserFacingLevel(forStored: globalStoredLevel, workspace: nil)
        }
        _workspaceDefaultLevelRaw = State(initialValue: workspaceStoredLevel?.userFacingLevel.rawValue ?? "")
        let initialCustomPolicy: AgentPolicy
        if AgentPolicyLevel.customPresetCases.contains(selectedStoredLevel) {
            var policy = AgentPolicy.preset(selectedStoredLevel)
            policy.level = .custom
            initialCustomPolicy = policy
        } else {
            initialCustomPolicy = AgentPolicyDefaults.customPolicy(for: workspace)
        }
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
                Section("Mode") {
                    Picker("Policy", selection: policySelectionBinding) {
                        ForEach(AgentPolicyLevel.primaryCases) { level in
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

                Section("Effective Rules") {
                    policyListRow("Auto-approved", values: policy.allowedTools, color: Stanford.paloAltoGreen)
                    policyListRow("Ask before running", values: policy.askFirstTools + policy.askFirstShellPatterns, color: Stanford.poppy)
                    policyListRow("Blocked", values: policy.deniedTools + policy.deniedShellPatterns + policy.deniedURLPatterns, color: Stanford.cardinalRed)
                }

                Section("Run Scope") {
                    factRow("Workspace", value: workspacePath)
                    factRow("Additional paths", value: additionalPaths.isEmpty ? "None" : "\(additionalPaths.count) configured")
                    factRow("Network", value: networkSummary)
                    factRow("Credentials", value: credentialLabels.isEmpty ? "None injected by policy preview" : credentialLabels.joined(separator: ", "))
                }

                Section("Provider Preview") {
                    factRow("Runtime", value: runtime.displayName)
                    factRow("Permission mode", value: render.permissionMode)
                    askCoverageRow
                    factRow("Config source", value: render.configOwnership.displayName)
                    factRow("Enforcement", value: render.enforcementTiers.map(\.displayName).joined(separator: ", "))
                    factRow("Broad provider permissions", value: render.usesBroadProviderPermissions ? "Yes" : "No")
                    policyListRow("Provider arguments", values: render.cliArgumentsSummary, color: Stanford.coolGrey)
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
                        ForEach(AgentPolicyLevel.primaryCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }

                    Picker("Workspace default", selection: $workspaceDefaultLevelRaw) {
                        Text("Use global default").tag("")
                        ForEach(AgentPolicyLevel.primaryCases) { level in
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
                        Label("Reset policy defaults to Ask", systemImage: "arrow.counterclockwise")
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
                Text("Policy")
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
        skipPermissions ? .autonomous : AgentPolicyLevel.normalized(selectedPolicyLevelRaw).userFacingLevel
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
            customRulesIntro
            customPresetControls

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Tool Rules")
                    .font(Stanford.caption(12).weight(.semibold))
                Text("Auto runs without pausing, Ask creates an approval gate, and Block stops the action.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            ForEach(configurableTools, id: \.self) { tool in
                customToolRow(tool)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("Shell and Network Patterns")
                    .font(Stanford.caption(12).weight(.semibold))
                Text("Add one pattern per line. Shell patterns use `executable:arguments`; network patterns can use URL or host wildcards.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }

            customPatternField(
                "Auto shell patterns",
                text: customAllowedShellPatternsBinding,
                help: "Commands that can run without another approval.",
                placeholder: "git:*\nswift:*"
            )
            customPatternField(
                "Ask shell patterns",
                text: customAskFirstShellPatternsBinding,
                help: "Commands that should pause for approval before running.",
                placeholder: "curl:*"
            )
            customPatternField(
                "Blocked shell patterns",
                text: customDeniedShellPatternsBinding,
                help: "Commands that should always stop.",
                placeholder: "rm:*\nsudo:*"
            )
            customPatternField(
                "Auto network patterns",
                text: customAllowedURLPatternsBinding,
                help: "Network destinations that can be used without another approval.",
                placeholder: "https://api.github.com/*"
            )
            customPatternField(
                "Blocked network patterns",
                text: customDeniedURLPatternsBinding,
                help: "Network destinations that should always stop.",
                placeholder: "*.internal.example.com"
            )
        }
    }

    private var customRulesIntro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(customPolicyScopeTitle, systemImage: "slider.horizontal.3")
                .font(Stanford.caption(12).weight(.semibold))
            Text("Rendered into the provider command/config and ASTRA's runtime guard for every run that uses Custom.")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                customRuleCountPill("Auto", count: policy.allowedTools.count + policy.allowedShellPatterns.count + policy.allowedURLPatterns.count, color: Stanford.paloAltoGreen)
                customRuleCountPill("Ask", count: policy.askFirstTools.count + policy.askFirstShellPatterns.count, color: Stanford.poppy)
                customRuleCountPill("Block", count: policy.deniedTools.count + policy.deniedShellPatterns.count + policy.deniedURLPatterns.count, color: Stanford.cardinalRed)
            }
        }
        .padding(.vertical, 2)
    }

    private var customPresetControls: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Ask") {
                    applyPresetToCustom(.review)
                }
                Button("Read-only") {
                    applyPresetToCustom(.locked)
                }
                Button("Build") {
                    applyPresetToCustom(.build)
                }
                Button("Network-heavy") {
                    applyPresetToCustom(.network)
                }
            } label: {
                Label("Start from preset", systemImage: "square.stack.3d.up")
            }

            Button {
                resetCustomPolicy()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }

            if workspace != nil {
                Button {
                    useGlobalCustomPolicy()
                } label: {
                    Label("Use global", systemImage: "arrow.down.doc")
                }
                Button {
                    AgentPolicyDefaults.setCustomPolicy(customPolicyDraft, for: nil)
                } label: {
                    Label("Save globally", systemImage: "arrow.up.doc")
                }
            }

            Spacer()
        }
    }

    private var policySelectionBinding: Binding<String> {
        Binding(
            get: { selectedLevel.userFacingLevel.rawValue },
            set: { select(level: AgentPolicyLevel.normalized($0)) }
        )
    }

    private var globalDefaultBinding: Binding<String> {
        Binding(
            get: { AgentPolicyLevel.normalized(globalDefaultLevelRaw).userFacingLevel.rawValue },
            set: { globalDefaultLevelRaw = AgentPolicyLevel.normalized($0).userFacingLevel.rawValue }
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

    private var customPolicyScopeTitle: String {
        workspace == nil ? "Global custom policy" : "Workspace custom policy"
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
        AgentRuntimeAdapterRegistry
            .adapterIfRegistered(for: runtime)?
            .providerConfigOwnership(workspacePath: workspacePath) ?? .generated
    }

    private var existingProviderConfigSummary: String? {
        AgentRuntimeAdapterRegistry
            .adapterIfRegistered(for: runtime)?
            .existingProviderConfigSummary(workspacePath: workspacePath)
    }

    private func select(level: AgentPolicyLevel) {
        selectedPolicyLevelRaw = level.rawValue
        skipPermissions = level == .autonomous
        onPolicyLevelChange?(level)
    }

    private func customToolRow(_ tool: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: toolIcon(tool))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(tool)
                .font(Stanford.caption(12).monospaced())
                .frame(minWidth: 100, alignment: .leading)

            Picker(tool, selection: customToolDispositionBinding(for: tool)) {
                ForEach(CustomToolDisposition.allCases) { disposition in
                    Text(disposition.displayName).tag(disposition)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func customPatternField(
        _ title: String,
        text: Binding<String>,
        help: String,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
            // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(Stanford.caption(12).weight(.semibold))
                Text(help)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TextField(placeholder, text: text, axis: .vertical)
                .font(Stanford.mono(11))
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 3)
    }

    private func customRuleCountPill(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .font(Stanford.caption(11).weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }

    private func toolIcon(_ tool: String) -> String {
        switch Self.normalizedPolicyToolKey(tool) {
        case "read": "doc.text"
        case "glob": "folder"
        case "grep": "magnifyingglass"
        case "write", "edit", "multiedit": "square.and.pencil"
        case "bash": "terminal"
        case "webfetch", "websearch": "network"
        case "agent": "person.2"
        default: "wrench.and.screwdriver"
        }
    }

    private func customToolDispositionBinding(for tool: String) -> Binding<CustomToolDisposition> {
        Binding(
            get: { customToolDisposition(for: tool) },
            set: { setCustomTool(tool, disposition: $0) }
        )
    }

    private func customToolDisposition(for tool: String) -> CustomToolDisposition {
        if customPolicyList(customPolicyDraft.deniedTools, containsTool: tool) {
            return .deny
        }
        if customPolicyList(customPolicyDraft.askFirstTools, containsTool: tool) {
            return .askFirst
        }
        if customPolicyList(customPolicyDraft.allowedTools, containsTool: tool) {
            return .allow
        }
        return .deny
    }

    private func setCustomTool(_ tool: String, disposition: CustomToolDisposition) {
        var policy = customPolicyDraft
        policy.allowedTools.removeAll { Self.normalizedPolicyToolKey($0) == Self.normalizedPolicyToolKey(tool) }
        policy.askFirstTools.removeAll { Self.normalizedPolicyToolKey($0) == Self.normalizedPolicyToolKey(tool) }
        policy.deniedTools.removeAll { Self.normalizedPolicyToolKey($0) == Self.normalizedPolicyToolKey(tool) }

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

    private func customPolicyList(_ values: [String], containsTool tool: String) -> Bool {
        let key = Self.normalizedPolicyToolKey(tool)
        return values.contains { Self.normalizedPolicyToolKey($0) == key }
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

    /// Tint the non-tappable Ask-coverage glyph by how strong the guarantee
    /// actually is — never the interactive accent, so a weak guarantee doesn't
    /// read as a green light.
    private func askCoverageTint(_ tier: AskCoverageBadge.Tier) -> Color {
        switch tier {
        case .guaranteed: Stanford.statusHealthy
        case .bestEffort: Stanford.statusWarn
        case .providerManaged: Stanford.statusInfo
        }
    }

    /// Honest, per-(runtime, policy) coverage statement so the sheet never
    /// implies the same Ask guarantee on every runtime. Derived from the same
    /// tier + sandbox logic the worker uses.
    @ViewBuilder
    private var askCoverageRow: some View {
        if let permissionPolicy = PermissionPolicy(rawValue: render.permissionMode) {
            let badge = AskCoverageBadge.resolve(
                runtime: runtime,
                permissionPolicy: permissionPolicy,
                sandboxSettings: ExecutionSandboxSettings.current(permissionPolicy: permissionPolicy)
            )
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: badge.symbolName)
                    .foregroundStyle(askCoverageTint(badge.tier))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask coverage: \(badge.label)")
                        .font(Stanford.caption(12).weight(.semibold))
                    Text(badge.detail)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func factRow(_ title: String, value: String) -> some View {
        // `.top`, not `.firstTextBaseline`: `value` is selectable, and a
        // baseline-aligned HStack querying a hosted SelectionOverlay's baseline
        // live-locks the SwiftUI layout engine. See MarkdownTextView's list-item
        // case in TaskMainView for the full root-cause writeup.
        HStack(alignment: .top) {
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
        default:
            return
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

    private static func normalizedPolicyToolKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        case .blocked: Stanford.statusError
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
        case .allow: "Auto"
        case .askFirst: "Ask"
        case .deny: "Block"
        }
    }
}
