import Foundation
import SwiftData
import ASTRACore

protocol ProviderPolicyAdapter {
    var providerID: AgentRuntimeID { get }
    var adapterVersion: Int { get }
    var supportedFeatures: ProviderPolicyFeatures { get }
    var runtimeSupportTools: [ProviderRuntimeSupportToolDescriptor] { get }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender
    func validate(render: ProviderPolicyRender, context: PolicyRenderContext) -> [PolicyDiagnostic]
    func observedEvent(from providerEvent: ParsedEvent) -> PolicyObservedEvent?
    func permissionRequest(from providerEvent: ParsedEvent) -> PermissionRequest?
    func providerGrantStrings(for grants: [PermissionGrant]) -> [String]
    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String]
}

extension ProviderPolicyAdapter {
    var runtimeSupportTools: [ProviderRuntimeSupportToolDescriptor] { [] }

    func validate(render: ProviderPolicyRender, context _: PolicyRenderContext) -> [PolicyDiagnostic] {
        render.diagnostics
    }

    func observedEvent(from providerEvent: ParsedEvent) -> PolicyObservedEvent? {
        PolicyObservedEvent(providerEvent: providerEvent)
    }

    func permissionRequest(from providerEvent: ParsedEvent) -> PermissionRequest? {
        observedEvent(from: providerEvent).flatMap(PermissionBroker.permissionRequest)
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        grants.compactMap { grant in
            switch grant {
            case .tool(let name), .providerTool(let name):
                return name.trimmingCharacters(in: .whitespacesAndNewlines)
            case .shellCommand(let executable, let pattern):
                return "shell(\(executable):\(pattern))"
            case .filePath, .networkPattern, .browserAction:
                return nil
            }
        }
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: grants)
    }
}

struct ClaudePolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .claudeCode
    let adapterVersion = 1

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: true,
            supportsDenyTools: true,
            supportsAskFirstMode: true,
            supportsPathScoping: false,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: true,
            supportsGeneratedSettingsFile: true,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: true,
            supportsManagedSettings: true,
            supportsMachineReadableEvents: true,
            supportsBroadAllowAll: true
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let baseAllowedTools = policy.providerAllowedTools(requestedTools: context.requestedAllowedTools)
        let allowedTools = PolicyLocalToolGrants.addClaudeShellGrants(
            to: baseAllowedTools,
            localToolCommands: context.localToolCommands
        )
        let deniedTools = policy.deniedTools
        var diagnostics = diagnostics(for: policy, context: context)
        if context.providerConfigOwnership != .generated, policy.level != .autonomous {
            diagnostics.append(PolicyDiagnostic(
                id: "claude.existing-provider-config",
                severity: .warning,
                title: "Existing Claude settings detected",
                message: context.existingProviderConfigSummary ?? "ASTRA found Claude settings owned outside this render and will preserve unrelated keys.",
                affectedCapability: "provider_config",
                remediation: "Review the generated config preview or reset Claude permissions to ASTRA defaults."
            ))
        }
        if !policy.deniedShellPatterns.isEmpty {
            diagnostics.append(PolicyDiagnostic(
                id: "claude.shell-deny-provider-native-gap",
                severity: .warning,
                title: "Shell deny patterns are advisory",
                message: "Claude tool permissions can allow or deny tools, but ASTRA-owned command brokering is required to enforce individual shell command patterns.",
                affectedCapability: "shell",
                remediation: "Use Ask or a stricter Custom configuration until ASTRA brokered shell execution is enabled for this workspace."
            ))
        }

        let askFirstProviderTools = providerVisibleAskFirstTools(policy.askFirstTools, permissionPolicy: permissionPolicy)
        let providerVisibleTools = Array(Set(allowedTools + askFirstProviderTools)).sorted()
        let settingsSummary = "Generated .claude/settings.local.json permissions allow=\(allowedTools.count) ask=\(askFirstProviderTools.count) deny=\(deniedTools.count)"
        let toolSummary = askFirstProviderTools.isEmpty
            ? "\(allowedTools.count) tools"
            : "\(allowedTools.count) allowed + \(askFirstProviderTools.count) ask-first tools"
        let cliSummary = permissionPolicy.cliArguments + (providerVisibleTools.isEmpty ? [] : ["--allowedTools", toolSummary])
        let generatedConfigPreview = ClaudeSettingsStore.generatedConfigPreview(
            policy: permissionPolicy,
            allowedTools: providerVisibleTools
        )

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: context.providerConfigOwnership,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: allowedTools,
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: cliSummary,
            settingsSummary: settingsSummary,
            generatedConfigPreview: generatedConfigPreview,
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.providerNative, .astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: permissionPolicy == .autonomous
        )
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        PermissionBroker.uniqueProviderGrantStrings(grants.compactMap { grant in
            switch grant {
            case .tool(let name), .providerTool(let name):
                return canonicalClaudeToolName(name)
            case .shellCommand(let executable, let pattern):
                return claudeShellGrant(executable: executable, pattern: pattern)
            case .filePath, .networkPattern, .browserAction:
                return nil
            }
        })
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: ProviderRuntimeGrantCompanions.grants(for: grants))
    }

    private func canonicalClaudeToolName(_ name: String) -> String {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "write": return "Write"
        case "edit": return "Edit"
        case "multiedit", "multi_edit": return "MultiEdit"
        case "bash", "shell": return "Bash"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "agent": return "Agent"
        default: return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func claudeShellGrant(executable: String, pattern: String) -> String {
        let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return "Bash(\(executable) *)"
        }
        return "Bash(\(executable) \(pattern))"
    }

    private func providerVisibleAskFirstTools(_ tools: [String], permissionPolicy: PermissionPolicy) -> [String] {
        guard permissionPolicy == .restricted else { return [] }
        return Array(Set(tools.compactMap(providerVisibleClaudeToolPermission))).sorted()
    }

    private func providerVisibleClaudeToolPermission(_ tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let openParen = trimmed.firstIndex(of: "("),
           trimmed.hasSuffix(")") {
            let rawTool = String(trimmed[..<openParen])
            guard let canonicalTool = safeCanonicalClaudeToolName(rawTool) else { return nil }
            let patternStart = trimmed.index(after: openParen)
            let pattern = String(trimmed[patternStart..<trimmed.index(before: trimmed.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ":", with: " ")
            return pattern.isEmpty ? canonicalTool : "\(canonicalTool)(\(pattern))"
        }

        return safeCanonicalClaudeToolName(trimmed)
    }

    private func safeCanonicalClaudeToolName(_ name: String) -> String? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "write", "create": return "Write"
        case "edit": return "Edit"
        case "multiedit", "multi_edit": return "MultiEdit"
        case "bash", "shell": return "Bash"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "agent": return "Agent"
        default: return nil
        }
    }
}

struct CopilotPolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .copilotCLI
    let adapterVersion = 1
    var capabilities: AgentRuntimePolicyCapabilities = .conservative

    var runtimeSupportTools: [ProviderRuntimeSupportToolDescriptor] {
        [
            ProviderRuntimeSupportToolDescriptor(
                name: "fetch_copilot_cli_documentation",
                providerNativePermission: "fetch_copilot_cli_documentation",
                purpose: "Read GitHub Copilot CLI help and documentation for self-description questions.",
                allowedInputKeys: [],
                maxSummaryLength: 2
            ),
            ProviderRuntimeSupportToolDescriptor(
                name: "report_intent",
                providerNativePermission: "report_intent",
                purpose: "Report non-mutating provider progress intent to the runtime.",
                allowedInputKeys: ["intent"],
                maxSummaryLength: 240
            )
        ]
    }

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: true,
            supportsDenyTools: false,
            supportsAskFirstMode: capabilities.supportsNoAskUser,
            supportsPathScoping: true,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: capabilities.supportsSecretEnvVars,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: capabilities.supportsNoAskUser,
            supportsManagedSettings: false,
            supportsMachineReadableEvents: capabilities.supportsOutputFormatJSON,
            supportsBroadAllowAll: capabilities.supportsAllowAll || capabilities.supportsAllowAllTools
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let allowedTools = policy.providerAllowedTools(requestedTools: context.requestedAllowedTools)
        let localToolCommands = PolicyLocalToolGrants.shouldGrantLocalToolCommands(allowedTools: allowedTools)
            ? context.localToolCommands
            : []
        var diagnostics = diagnostics(for: policy, context: context)
        if !policy.deniedTools.isEmpty || !policy.deniedShellPatterns.isEmpty {
            diagnostics.append(PolicyDiagnostic(
                id: "copilot.deny-provider-native-gap",
                severity: .warning,
                title: "Deny rules require ASTRA enforcement",
                message: "This Copilot CLI adapter records deny intent, but the current command path only renders positive allow-tool grants.",
                affectedCapability: "deny",
                remediation: "Keep the policy at Ask or a stricter Custom configuration when strict denial must be guaranteed."
            ))
        }
        if policy.level == .autonomous, !capabilities.supportsAllowAll && !capabilities.supportsAllowAllTools {
            diagnostics.append(PolicyDiagnostic(
                id: "copilot.allow-all-unsupported",
                severity: .warning,
                title: "Broad mode falls back to explicit allows",
                message: "This Copilot CLI version does not advertise allow-all support, so ASTRA renders explicit broad allow-tool entries instead.",
                affectedCapability: "autonomous"
            ))
        }

        let args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: permissionPolicy,
            allowedTools: allowedTools,
            localToolCommands: localToolCommands,
            supportsAllowAll: capabilities.supportsAllowAll,
            supportsAllowAllTools: capabilities.supportsAllowAllTools,
            supportsAllowAllPaths: capabilities.supportsAllowAllPaths,
            supportsAllowAllURLs: capabilities.supportsAllowAllURLs,
            requiresAllowAllToolsForPrompt: capabilities.requiresAllowAllToolsForPrompt
        )
        let providerAllowedTools = copilotAllowedTools(from: args, fallback: allowedTools)

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: providerAllowedTools,
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: summarizeCopilotArguments(args),
            settingsSummary: "Generated per-run Copilot CLI permission flags",
            generatedConfigPreview: args.joined(separator: " "),
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.providerNative, .astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: copilotUsesBroadProviderPermissions(args)
        )
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        PermissionBroker.uniqueProviderGrantStrings(grants.compactMap { grant in
            switch grant {
            case .tool(let name), .providerTool(let name):
                return canonicalCopilotToolName(name)
            case .shellCommand(let executable, let pattern):
                return "shell(\(executable):\(pattern))"
            case .filePath, .networkPattern, .browserAction:
                return nil
            }
        })
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: ProviderRuntimeGrantCompanions.grants(for: grants))
    }

    private func canonicalCopilotToolName(_ name: String) -> String {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view": return "read"
        case "grep": return "grep"
        case "glob": return "glob"
        case "write", "create", "edit", "multiedit", "multi_edit": return "write"
        case "bash", "shell": return "shell"
        case "webfetch": return "webfetch"
        case "websearch": return "websearch"
        case "agent": return "agent"
        default: return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct AntigravityPolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .antigravityCLI
    let adapterVersion = 1

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: false,
            supportsDenyTools: false,
            supportsAskFirstMode: false,
            supportsPathScoping: true,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: false,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: false,
            supportsManagedSettings: false,
            supportsMachineReadableEvents: false,
            supportsBroadAllowAll: true
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let args = AntigravityCLIRuntime.antigravityPermissionArguments(policy: permissionPolicy)
        var diagnostics = diagnostics(for: policy, context: context)
        diagnostics = diagnostics.map { diagnostic in
            guard diagnostic.id == "\(providerID.rawValue).secret-redaction-unsupported" else {
                return diagnostic
            }
            return PolicyDiagnostic(
                id: diagnostic.id,
                severity: .warning,
                title: "Credential redaction is ASTRA-managed",
                message: "Antigravity CLI does not expose a secret-env flag, so ASTRA records credential key names only and still passes selected credential environment variables to the provider process.",
                affectedCapability: "credentials",
                remediation: "Use Antigravity only with trusted workspaces when credential capabilities are enabled, or disable unused credential capabilities for this workspace."
            )
        }

        let hasFineGrainedRules = !policy.allowedTools.isEmpty
            || !policy.askFirstTools.isEmpty
            || !policy.deniedTools.isEmpty
            || !policy.allowedShellPatterns.isEmpty
            || !policy.askFirstShellPatterns.isEmpty
            || !policy.deniedShellPatterns.isEmpty
            || !policy.allowedURLPatterns.isEmpty
            || !policy.deniedURLPatterns.isEmpty
        if permissionPolicy != .autonomous, hasFineGrainedRules {
            diagnostics.append(PolicyDiagnostic(
                id: "antigravity.fine-grained-provider-native-gap",
                severity: .warning,
                title: "Fine-grained rules use sandbox mode",
                message: "Antigravity CLI exposes per-run sandbox and full-permission flags, but this adapter cannot render ASTRA's individual allow, deny, and ask-first rules as provider-native flags.",
                affectedCapability: "permissions",
                remediation: "Use Review or Locked mode for sandboxed runs. Use Auto only for trusted or isolated work."
            ))
        }

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: permissionPolicy == .autonomous ? ["*"] : [],
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: args,
            settingsSummary: "Generated per-run Antigravity CLI permission flags",
            generatedConfigPreview: args.joined(separator: " "),
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.providerNative, .astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: permissionPolicy == .autonomous
        )
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        BrokeredProviderGrantStrings.providerGrantStrings(for: grants)
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: ProviderRuntimeGrantCompanions.grants(for: grants))
    }
}

struct CodexPolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .codexCLI
    let adapterVersion = 1

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: false,
            supportsDenyTools: false,
            supportsAskFirstMode: false,
            supportsPathScoping: true,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: false,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: false,
            supportsManagedSettings: false,
            supportsMachineReadableEvents: true,
            supportsBroadAllowAll: true
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let args = CodexCLIRuntime.codexPermissionArguments(policy: permissionPolicy)
        var diagnostics = diagnostics(for: policy, context: context)

        let hasFineGrainedRules = !policy.allowedTools.isEmpty
            || !policy.askFirstTools.isEmpty
            || !policy.deniedTools.isEmpty
            || !policy.allowedShellPatterns.isEmpty
            || !policy.askFirstShellPatterns.isEmpty
            || !policy.deniedShellPatterns.isEmpty
            || !policy.allowedURLPatterns.isEmpty
            || !policy.deniedURLPatterns.isEmpty
        if permissionPolicy != .autonomous, hasFineGrainedRules {
            diagnostics.append(PolicyDiagnostic(
                id: "codex_cli.fine-grained-provider-native-gap",
                severity: .warning,
                title: "Fine-grained rules use Codex sandbox mode",
                message: "Codex CLI exposes per-run sandbox and approval policy flags, but this adapter cannot render ASTRA's individual allow, deny, and ask-first rules as provider-native flags.",
                affectedCapability: "permissions",
                remediation: "Use Ask or Locked mode for sandboxed runs. Use Auto only for trusted or isolated work."
            ))
        }

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: permissionPolicy == .autonomous ? ["*"] : [],
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: args,
            settingsSummary: "Generated per-run Codex CLI sandbox and approval flags",
            generatedConfigPreview: args.joined(separator: " "),
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.providerNative, .astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: permissionPolicy == .autonomous
        )
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        BrokeredProviderGrantStrings.providerGrantStrings(for: grants)
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: ProviderRuntimeGrantCompanions.grants(for: grants))
    }
}

struct CursorPolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .cursorCLI
    let adapterVersion = 1

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: false,
            supportsDenyTools: false,
            // Cursor CLI only exposes sandbox/force flags; it cannot surface
            // ask-first checkpoints back to ASTRA, so do not advertise them.
            supportsAskFirstMode: false,
            supportsPathScoping: false,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: false,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: false,
            supportsManagedSettings: false,
            supportsMachineReadableEvents: true,
            supportsBroadAllowAll: true
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let args = CursorCLIRuntime.cursorPermissionArguments(policy: permissionPolicy)
        var diagnostics = diagnostics(for: policy, context: context)

        let hasFineGrainedRules = !policy.allowedTools.isEmpty
            || !policy.askFirstTools.isEmpty
            || !policy.deniedTools.isEmpty
            || !policy.allowedShellPatterns.isEmpty
            || !policy.askFirstShellPatterns.isEmpty
            || !policy.deniedShellPatterns.isEmpty
            || !policy.allowedURLPatterns.isEmpty
            || !policy.deniedURLPatterns.isEmpty
        if permissionPolicy != .autonomous, hasFineGrainedRules {
            diagnostics.append(PolicyDiagnostic(
                id: "cursor_cli.fine-grained-provider-native-gap",
                severity: .warning,
                title: "Fine-grained rules use Cursor sandbox mode",
                message: "Cursor CLI exposes per-run sandbox, ask mode, and force flags, but this adapter cannot render ASTRA's individual allow, deny, and ask-first rules as provider-native flags.",
                affectedCapability: "permissions",
                remediation: "Use Ask or Locked mode for sandboxed runs. Use Auto only for trusted or isolated work."
            ))
        }

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: permissionPolicy == .autonomous ? ["*"] : [],
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: args,
            settingsSummary: "Generated per-run Cursor CLI sandbox and mode flags",
            generatedConfigPreview: args.joined(separator: " "),
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.providerNative, .astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: permissionPolicy == .autonomous
        )
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        BrokeredProviderGrantStrings.providerGrantStrings(for: grants)
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: ProviderRuntimeGrantCompanions.grants(for: grants))
    }
}

struct OpenCodePolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .openCodeCLI
    let adapterVersion = 1

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: false,
            supportsDenyTools: false,
            supportsAskFirstMode: false,
            supportsPathScoping: false,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: false,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: false,
            supportsManagedSettings: false,
            supportsMachineReadableEvents: true,
            supportsBroadAllowAll: true
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let args = OpenCodeCLIRuntime.permissionArguments(policy: permissionPolicy)
        let allowedTools = policy.providerAllowedTools(requestedTools: context.requestedAllowedTools)
        var diagnostics = diagnostics(for: policy, context: context)

        let hasFineGrainedRules = !policy.allowedTools.isEmpty
            || !policy.askFirstTools.isEmpty
            || !policy.deniedTools.isEmpty
            || !policy.allowedShellPatterns.isEmpty
            || !policy.askFirstShellPatterns.isEmpty
            || !policy.deniedShellPatterns.isEmpty
            || !policy.allowedURLPatterns.isEmpty
            || !policy.deniedURLPatterns.isEmpty
        if permissionPolicy != .autonomous, hasFineGrainedRules {
            diagnostics.append(PolicyDiagnostic(
                id: "opencode_cli.fine-grained-provider-native-gap",
                severity: .warning,
                title: "Fine-grained rules use ASTRA brokering",
                message: "OpenCode CLI exposes a broad per-run permission skip flag, but this adapter cannot render ASTRA's individual allow, deny, and ask-first rules as provider-native flags.",
                affectedCapability: "permissions",
                remediation: "Use Ask or Locked mode for brokered runs. Use Auto only for trusted or isolated work."
            ))
        }

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: permissionPolicy == .autonomous ? ["*"] : allowedTools,
            runtimeSupportTools: runtimeSupportTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: args,
            settingsSummary: "Generated per-run OpenCode CLI permission flags",
            generatedConfigPreview: args.joined(separator: " "),
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: permissionPolicy == .autonomous
        )
    }

    func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        BrokeredProviderGrantStrings.providerGrantStrings(for: grants)
    }

    func providerRuntimeGrantStrings(for grants: [PermissionGrant]) -> [String] {
        providerGrantStrings(for: ProviderRuntimeGrantCompanions.grants(for: grants))
    }
}

private enum BrokeredProviderGrantStrings {
    static func providerGrantStrings(for grants: [PermissionGrant]) -> [String] {
        PermissionBroker.uniqueProviderGrantStrings(grants.compactMap { grant in
            switch grant {
            case .tool(let name), .providerTool(let name):
                return name.trimmingCharacters(in: .whitespacesAndNewlines)
            case .shellCommand(let executable, let pattern):
                return "shell(\(executable):\(pattern))"
            case .filePath, .networkPattern, .browserAction:
                return nil
            }
        })
    }
}

struct LocalModelPolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .localMLX
    let adapterVersion = 1

    var supportedFeatures: ProviderPolicyFeatures {
        ProviderPolicyFeatures(
            supportsAllowTools: false,
            supportsDenyTools: false,
            supportsAskFirstMode: true,
            supportsPathScoping: true,
            supportsURLAllowlist: false,
            supportsURLDenylist: false,
            supportsSecretEnvRedaction: false,
            supportsGeneratedSettingsFile: false,
            supportsPerRunFlags: true,
            supportsInteractiveCallbacks: true,
            supportsManagedSettings: true,
            supportsMachineReadableEvents: true,
            supportsBroadAllowAll: false
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        var diagnostics = diagnostics(for: policy, context: context)
        diagnostics = diagnostics.map { diagnostic in
            guard diagnostic.id == "\(providerID.rawValue).secret-redaction-unsupported" else {
                return diagnostic
            }
            return PolicyDiagnostic(
                id: diagnostic.id,
                severity: .warning,
                title: "Credential redaction is ASTRA-managed",
                message: "Local MLX runs inside ASTRA's helper process, so ASTRA records credential key names and redacts task history without provider-native secret flags.",
                affectedCapability: "credentials",
                remediation: "Use Local MLX only with trusted workspaces when credential capabilities are enabled, or disable unused credential capabilities for this workspace."
            )
        }
        let hasFineGrainedRules = !policy.allowedTools.isEmpty
            || !policy.askFirstTools.isEmpty
            || !policy.deniedTools.isEmpty
            || !policy.allowedShellPatterns.isEmpty
            || !policy.askFirstShellPatterns.isEmpty
            || !policy.deniedShellPatterns.isEmpty
            || !policy.allowedURLPatterns.isEmpty
            || !policy.deniedURLPatterns.isEmpty
        if hasFineGrainedRules {
            diagnostics.append(PolicyDiagnostic(
                id: "local-mlx.astra-brokered-policy",
                severity: .info,
                title: "Local policy is ASTRA-brokered",
                message: "Local MLX models do not receive provider-native tool grants; ASTRA must broker and record all tool execution.",
                affectedCapability: "permissions",
                remediation: "Keep experimental local tools disabled until the ASTRA tool broker is enabled for this provider."
            ))
        }
        if permissionPolicy == .autonomous {
            diagnostics.append(PolicyDiagnostic(
                id: "local-mlx.autonomous-no-provider-bypass",
                severity: .warning,
                title: "Auto mode stays brokered",
                message: "Local MLX has no separate provider permission bypass. Auto mode only changes ASTRA's broker policy.",
                affectedCapability: "autonomous"
            ))
        }

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: policy.allowedTools,
            askFirstTools: policy.askFirstTools,
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            askFirstShellPatterns: policy.askFirstShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: ["ASTRA-brokered policy"],
            settingsSummary: "Local model provider uses ASTRA-brokered permissions only",
            generatedConfigPreview: #"{"enforcement":"astra_brokered"}"#,
            enforcementTiers: [.astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: false
        )
    }

    func providerGrantStrings(for _: [PermissionGrant]) -> [String] {
        []
    }

    func providerRuntimeGrantStrings(for _: [PermissionGrant]) -> [String] {
        []
    }
}

private enum ProviderRuntimeGrantCompanions {
    static func grants(for grants: [PermissionGrant]) -> [PermissionGrant] {
        let sanitized = PermissionBroker.sanitizeApprovedGrants(grants)
        guard sanitized.contains(where: isShellCommandGrant) else {
            return sanitized
        }

        var companions: [PermissionGrant] = [
            .shellCommand(executable: "mkdir", pattern: "-p *")
        ]
        for grant in sanitized {
            guard case .shellCommand(let executable, _) = grant else { continue }
            switch executable.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "gh":
                companions.append(.shellCommand(executable: "gh", pattern: "auth status *"))
            case "gcloud":
                companions.append(.shellCommand(executable: "gcloud", pattern: "auth list *"))
            case "git":
                companions.append(.shellCommand(executable: "git", pattern: "status *"))
            default:
                continue
            }
        }
        return PermissionBroker.sanitizeApprovedGrants(sanitized + companions)
    }

    private static func isShellCommandGrant(_ grant: PermissionGrant) -> Bool {
        if case .shellCommand = grant {
            return true
        }
        return false
    }
}

private enum PolicyLocalToolGrants {
    static func addClaudeShellGrants(
        to allowedTools: [String],
        localToolCommands: [String]
    ) -> [String] {
        guard shouldGrantLocalToolCommands(allowedTools: allowedTools) else {
            return unique(allowedTools)
        }
        return unique(allowedTools + localToolCommands.compactMap(claudeShellGrant))
    }

    static func shouldGrantLocalToolCommands(allowedTools: [String]) -> Bool {
        allowedTools.contains { tool in
            tool.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Bash") == .orderedSame
        }
    }

    private static func claudeShellGrant(for command: String) -> String? {
        guard let executable = shellExecutableToken(command) else { return nil }
        return "Bash(\(executable) *)"
    }

    private static func shellExecutableToken(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        let executable = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !executable.isEmpty,
              executable.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r)")) == nil else {
            return nil
        }
        return executable
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

enum ProviderPolicyAdapterRegistry {
    static func adapter(
        for runtime: AgentRuntimeID,
        runtimeCapabilities: AgentRuntimePolicyCapabilities = .conservative
    ) -> any ProviderPolicyAdapter {
        AgentRuntimeAdapterRegistry
            .adapter(for: runtime)
            .policyAdapter(runtimeCapabilities: runtimeCapabilities)
    }
}

enum TaskPolicyStore {
    static let selectedPolicyEventType = "astra.policy.selected"

    struct Resolution: Equatable {
        let level: AgentPolicyLevel
        let scope: AgentPolicyScope
        let policy: AgentPolicy
    }

    @MainActor
    static func recordSelection(
        level: AgentPolicyLevel,
        task: AgentTask,
        modelContext: ModelContext,
        source: String
    ) {
        let payload = PolicySelectionPayload(level: level.rawValue, source: source)
        let event = TaskEvent(
            task: task,
            type: selectedPolicyEventType,
            payload: (try? payload.encodedString()) ?? level.rawValue
        )
        modelContext.insert(event)
    }

    @MainActor
    static func resolve(
        for task: AgentTask,
        globalDefaultLevel: AgentPolicyLevel,
        fallbackPermissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy
    ) -> Resolution {
        let effectivePermissionPolicy = executionPolicy.permissionPolicy(default: fallbackPermissionPolicy)
        if effectivePermissionPolicy == .autonomous {
            let policy = AgentPolicy.preset(.autonomous)
            return Resolution(
                level: .autonomous,
                scope: executionPolicy.permissionPolicyOverride == nil ? .globalDefault : .oneRunEscalation,
                policy: policy
            )
        }

        if let selected = latestSelectedLevel(for: task) {
            return Resolution(level: selected, scope: .taskOverride, policy: policy(for: selected, workspace: task.workspace))
        }

        if let workspaceDefault = AgentPolicyDefaults.workspaceLevel(for: task.workspace) {
            let effectiveWorkspaceDefault = AgentPolicyDefaults.effectiveUserFacingLevel(
                forStored: workspaceDefault,
                workspace: task.workspace
            )
            return Resolution(
                level: effectiveWorkspaceDefault,
                scope: .workspaceDefault,
                policy: policy(for: effectiveWorkspaceDefault, workspace: task.workspace)
            )
        }

        let effectiveGlobalDefault = AgentPolicyDefaults.effectiveUserFacingLevel(
            forStored: globalDefaultLevel,
            workspace: nil
        )
        return Resolution(
            level: effectiveGlobalDefault,
            scope: .globalDefault,
            policy: policy(for: effectiveGlobalDefault, workspace: nil)
        )
    }

    @MainActor
    static func latestSelectedLevel(for task: AgentTask) -> AgentPolicyLevel? {
        task.events
            .filter { $0.type == selectedPolicyEventType }
            .sorted { $0.timestamp < $1.timestamp }
            .last
            .flatMap { event in
                if let data = event.payload.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(PolicySelectionPayload.self, from: data) {
                    return AgentPolicyLevel(rawValue: payload.level)
                }
                return AgentPolicyLevel(rawValue: event.payload)
            }
    }

    private struct PolicySelectionPayload: Codable, Equatable {
        var level: String
        var source: String
        var selectedAt: Date = Date()

        func encodedString() throws -> String {
            let data = try JSONEncoder().encode(self)
            return String(data: data, encoding: .utf8) ?? level
        }
    }

    private static func policy(for level: AgentPolicyLevel, workspace: Workspace?) -> AgentPolicy {
        level == .custom ? AgentPolicyDefaults.customPolicy(for: workspace) : AgentPolicy.preset(level)
    }
}

enum AgentPolicyManifestService {
    static let preflightEventType = "astra.permission_manifest"
    static let summaryEventType = "astra.permission_summary"

    @MainActor
    @discardableResult
    static func recordPreflightManifest(
        task: AgentTask,
        run: TaskRun,
        runtime: AgentRuntimeID,
        model: String,
        workspacePath: String,
        phase: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        defaultPolicyLevelRaw: String,
        providerVersion: String? = nil,
        providerCapabilities: AgentRuntimePolicyCapabilities = .conservative,
        capabilityPackages: [PluginPackage]? = nil,
        approvalRecords: [CapabilityApprovalRecord]? = nil,
        modelContext: ModelContext
    ) -> RunPermissionManifest {
        let defaultLevel = AgentPolicyDefaults.effectiveUserFacingLevel(
            forStored: AgentPolicyLevel.normalized(defaultPolicyLevelRaw),
            workspace: nil
        )
        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: defaultLevel,
            fallbackPermissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy
        )
        let basePolicy = resolution.policy
        let taskCapabilityResolver = TaskCapabilityResolver(task: task)
        let taskCapabilityScope = taskCapabilityResolver.promptScope()
        let taskScopedGrants = TaskRuntimePermissionGrants.approvedGrants(for: task)
        let executionGrants = executionPolicy.permissionGrantsOverride ?? []
        let effectiveGrants = PermissionBroker.sanitizeApprovedGrants(taskScopedGrants + executionGrants)
        let taskScopedProviderGrants = PermissionBroker.providerGrantStrings(for: taskScopedGrants, runtime: runtime)
        let effectiveProviderGrants = PermissionBroker.providerGrantStrings(for: effectiveGrants, runtime: runtime)
        let policyApprovedTools = uniqueStrings((executionPolicy.allowedToolsOverride ?? []) + effectiveProviderGrants)
        let policy = policyApprovedTools.isEmpty
            ? basePolicy
            : basePolicy.applyingOneRunAllowedTools(policyApprovedTools)
        let requestedAllowedTools = uniqueStrings(
            executionPolicy.allowedTools(default: taskCapabilityScope.resolver.resolvedProviderAllowedTools)
                + taskScopedProviderGrants
        )
        let manifestExecutionPolicy = AgentRuntimeExecutionPolicy(
            permissionPolicyOverride: executionPolicy.permissionPolicyOverride,
            allowedToolsOverride: policyApprovedTools.isEmpty ? executionPolicy.allowedToolsOverride : policyApprovedTools,
            permissionGrantsOverride: effectiveGrants.isEmpty ? executionPolicy.permissionGrantsOverride : effectiveGrants
        )
        let envKeys = Array(taskCapabilityScope.resolver.resolvedEnvironmentVariables.keys).sorted()
        let runtimeAdapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)
        let providerPolicyAdapter = runtimeAdapter.policyAdapter(runtimeCapabilities: providerCapabilities)
        let configOwnership = runtimeAdapter.providerConfigOwnership(workspacePath: workspacePath)
        let runtimePaths = runtimeAdditionalPaths(for: task)
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: runtimePaths,
            requestedAllowedTools: requestedAllowedTools,
            localToolCommands: localToolCommands(for: task),
            environmentKeyNames: envKeys,
            credentialLabels: credentialLabels(for: task),
            providerFeatures: providerPolicyAdapter.supportedFeatures,
            providerConfigOwnership: configOwnership,
            existingProviderConfigSummary: runtimeAdapter.existingProviderConfigSummary(workspacePath: workspacePath)
        )
        var render = providerPolicyAdapter.render(policy: policy, context: context)
        render.diagnostics = providerPolicyAdapter.validate(render: render, context: context)
        // Reflect ASTRA's OS-level Seatbelt sandbox in the declared enforcement
        // tiers — but only when the run will both be wrapped (runtime in scope)
        // AND the sandbox would actually apply (enforcement on, usable workspace,
        // sandbox-exec present). Without the second check the manifest would
        // claim "OS Sandboxed" for a best-effort run that silently falls back to
        // unconfined at launch. Display-only; application + fallbacks are audited
        // at launch time.
        let effectiveSandboxPolicy = manifestExecutionPolicy.permissionPolicyOverride ?? permissionPolicy
        let sandboxSettings = ExecutionSandboxSettings.current(permissionPolicy: effectiveSandboxPolicy)
        if sandboxSettings.shouldWrap(runtime: runtime),
           ExecutionSandbox.willLikelyApply(workspacePath: workspacePath, settings: sandboxSettings),
           !render.enforcementTiers.contains(.osSandboxed) {
            render.enforcementTiers.append(.osSandboxed)
        }
        let approvals = approvalsGranted(executionPolicy: manifestExecutionPolicy, render: render)
        let policyScope = if executionPolicy.allowedToolsOverride != nil || !executionGrants.isEmpty {
            AgentPolicyScope.oneRunEscalation
        } else if !taskScopedGrants.isEmpty {
            AgentPolicyScope.taskApproval
        } else {
            resolution.scope
        }
        let manifest = RunPermissionManifest(
            taskID: task.id,
            runID: run.id,
            phase: phase,
            providerID: runtime,
            providerVersion: providerVersion,
            model: model,
            policyLevel: resolution.level,
            policyScope: policyScope,
            providerRender: render,
            workspacePath: workspacePath,
            additionalPaths: runtimePaths,
            environmentKeyNames: envKeys,
            credentialLabels: credentialLabels(for: task),
            mcpServers: capabilityPackages.map {
                TaskCapabilityResolver.enabledMCPServerManifests(
                    for: task.workspace,
                    packages: $0,
                    approvalRecords: approvalRecords ?? CapabilityApprovalStore().records()
                )
            } ?? taskCapabilityResolver.enabledMCPServerManifests,
            approvalsGranted: approvals,
            approvalGrants: effectiveGrants
        )
        insertManifestEvent(manifest, type: preflightEventType, task: task, run: run, modelContext: modelContext)
        AppLogger.audit(.runtimeCommandPlanned, category: "Worker", taskID: task.id, fields: [
            "phase": phase,
            "runtime": runtime.rawValue,
            "policy_level": resolution.level.rawValue,
            "policy_scope": manifest.policyScope.rawValue,
            "provider_adapter_version": String(render.adapterVersion),
            "enforcement": render.enforcementTiers.map(\.rawValue).joined(separator: ","),
            "diagnostics_blocked": String(render.diagnostics.filter { $0.severity == .blocked }.count),
            "diagnostics_warning": String(render.diagnostics.filter { $0.severity == .warning }.count),
            "uses_broad_provider_permissions": String(render.usesBroadProviderPermissions)
        ], level: render.diagnostics.contains(where: { $0.severity == .blocked }) ? .warning : .debug)
        return manifest
    }

    private static func runtimeAdditionalPaths(for task: AgentTask) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        var paths = access.runtimeAdditionalPaths
        if !access.effectiveWorkspacePath.isEmpty {
            paths.append(access.effectiveWorkspacePath)
        }
        if !access.taskFolder.isEmpty {
            paths.append(access.taskFolder)
        }
        var seen: Set<String> = []
        return paths.compactMap { rawPath in
            let path = (rawPath as NSString).expandingTildeInPath
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            return path
        }
    }

    @MainActor
    static func recordPostRunSummary(task: AgentTask, run: TaskRun, modelContext: ModelContext) {
        let runEvents = task.events.filter { $0.run?.id == run.id }
        let manifest = latestManifest(in: runEvents)
        let summary = PolicyRunSummary(
            runID: run.id,
            status: run.status.rawValue,
            stopReason: run.stopReason,
            toolUseCount: runEvents.filter { $0.type == "tool.use" }.count,
            deniedCount: runEvents.filter { $0.type == "permission.denied" || $0.type == "permission.approval.requested" }.count,
            fileChangeCount: run.fileChanges.count,
            toolsUsed: toolsUsed(from: runEvents),
            commandsRun: commandsRun(from: runEvents),
            deniedActions: deniedActions(from: runEvents),
            filesChanged: run.fileChanges.map(\.path).sorted(),
            externalDomains: externalDomains(from: runEvents),
            environmentKeyNames: manifest?.environmentKeyNames ?? [],
            approvalsGranted: manifest?.approvalsGranted ?? [],
            approvalGrantDescriptions: manifest?.approvalGrants.map(\.displayName) ?? [],
            usedBroadProviderPermissions: manifest?.providerRender.usesBroadProviderPermissions ?? false,
            exceededInitialPermissionLevel: manifest?.policyScope == .oneRunEscalation || manifest?.providerRender.usesBroadProviderPermissions == true,
            completedAt: run.completedAt ?? Date()
        )
        let payload = (try? summary.encodedString()) ?? "{}"
        modelContext.insert(TaskEvent(task: task, type: summaryEventType, payload: payload, run: run))
    }

    @MainActor
    private static func localToolCommands(for task: AgentTask) -> [String] {
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope()
        var commands: [String] = capabilityScope.localTools.compactMap { tool in
            guard tool.toolType != "mcp" else { return nil }
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        if !ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id).isEmpty {
            commands.append("astra-browser")
        }
        return Array(Set(commands)).sorted()
    }

    @MainActor
    private static func credentialLabels(for task: AgentTask) -> [String] {
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope()
        let skillKeys = capabilityScope.behaviorSkills.flatMap(\.environmentKeys)
        let connectorKeys = capabilityScope.connectors.flatMap(\.credentialKeys)
        return Array(Set(skillKeys + connectorKeys)).sorted()
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private static func approvalsGranted(
        executionPolicy: AgentRuntimeExecutionPolicy,
        render: ProviderPolicyRender
    ) -> [String] {
        var approvals: [String] = []
        if let override = executionPolicy.allowedToolsOverride {
            approvals.append("allowed_tools:\(override.sorted().joined(separator: ","))")
        }
        if let grants = executionPolicy.permissionGrantsOverride, !grants.isEmpty {
            let providerGrants = ProviderPolicyAdapterRegistry
                .adapter(for: render.providerID)
                .providerGrantStrings(for: grants)
            approvals.append("permission_grants:\(providerGrants.sorted().joined(separator: ","))")
        }
        if executionPolicy.permissionPolicyOverride != nil {
            approvals.append("permission_mode:\(render.permissionMode)")
        }
        return approvals
    }

    @MainActor
    private static func insertManifestEvent(
        _ manifest: RunPermissionManifest,
        type: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        guard let data = try? JSONEncoder().encode(manifest),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        modelContext.insert(TaskEvent(task: task, type: type, payload: payload, run: run))
    }

    private struct PolicyRunSummary: Codable {
        var runID: UUID
        var status: String
        var stopReason: String
        var toolUseCount: Int
        var deniedCount: Int
        var fileChangeCount: Int
        var toolsUsed: [String]
        var commandsRun: [String]
        var deniedActions: [String]
        var filesChanged: [String]
        var externalDomains: [String]
        var environmentKeyNames: [String]
        var approvalsGranted: [String]
        var approvalGrantDescriptions: [String]
        var usedBroadProviderPermissions: Bool
        var exceededInitialPermissionLevel: Bool
        var completedAt: Date

        func encodedString() throws -> String {
            let data = try JSONEncoder().encode(self)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    private static func latestManifest(in events: [TaskEvent]) -> RunPermissionManifest? {
        events
            .filter { $0.type == preflightEventType }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { event -> RunPermissionManifest? in
                guard let data = event.payload.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(RunPermissionManifest.self, from: data)
            }
            .last
    }

    private static func toolsUsed(from events: [TaskEvent]) -> [String] {
        uniqueLimited(events.compactMap { event in
            guard event.type == "tool.use" else { return nil }
            return toolName(fromToolUsePayload: event.payload)
        })
    }

    private static func commandsRun(from events: [TaskEvent]) -> [String] {
        uniqueLimited(events.compactMap { event in
            guard event.type == "tool.use",
                  let tool = toolName(fromToolUsePayload: event.payload)?.lowercased(),
                  tool == "bash" || tool == "shell",
                  let summary = toolSummary(fromToolUsePayload: event.payload) else {
                return nil
            }
            return LogSanitizer.sanitize(summary, maxLength: 240)
        })
    }

    private static func deniedActions(from events: [TaskEvent]) -> [String] {
        uniqueLimited(events.compactMap { event in
            guard event.type == "permission.denied" || event.type == "permission.approval.requested" else { return nil }
            return LogSanitizer.sanitize(event.payload, maxLength: 240)
        })
    }

    private static func externalDomains(from events: [TaskEvent]) -> [String] {
        let observedURLs = events.flatMap { urls(in: $0.payload) }
        return uniqueLimited(observedURLs.compactMap { URL(string: $0)?.host?.lowercased() }, limit: 20)
    }

    private static func toolName(fromToolUsePayload payload: String) -> String? {
        guard payload.hasPrefix("Using tool:") else { return nil }
        let remainder = payload.dropFirst("Using tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = remainder.split(separator: ":", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private static func toolSummary(fromToolUsePayload payload: String) -> String? {
        guard let range = payload.range(of: ": ") else { return nil }
        let afterToolPrefix = payload[range.upperBound...]
        guard let secondColon = afterToolPrefix.firstIndex(of: ":") else { return nil }
        let summaryStart = afterToolPrefix.index(after: secondColon)
        let summary = afterToolPrefix[summaryStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    private static func urls(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"')<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    private static func uniqueLimited(_ values: [String], limit: Int = 12) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }
}

private func diagnostics(for policy: AgentPolicy, context: PolicyRenderContext) -> [PolicyDiagnostic] {
    var diagnostics: [PolicyDiagnostic] = []
    if !policy.allowedURLPatterns.isEmpty, !context.providerFeatures.supportsURLAllowlist {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).url-allowlist-unsupported",
            severity: .warning,
            title: "URL allowlist is not provider-native",
            message: "\(context.runtimeID.displayName) cannot fully express ASTRA URL allowlists through this adapter.",
            affectedCapability: "network",
            remediation: "Use connector-specific credentials and ASTRA brokered network tools for strict enforcement."
        ))
    }
    let credentialLabels = Array(Set(policy.credentialLabels + context.credentialLabels)).sorted()
    if !credentialLabels.isEmpty, !context.providerFeatures.supportsSecretEnvRedaction {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).secret-redaction-unsupported",
            severity: .blocked,
            title: "Secret redaction is unsupported",
            message: "This provider render cannot mark injected environment keys as secrets.",
            affectedCapability: "credentials",
            remediation: "Remove credential injection or use a provider/version with secret env support."
        ))
    }
    let usesAskCheckpoints = policy.level == .review
        || !policy.askFirstTools.isEmpty
        || !policy.askFirstShellPatterns.isEmpty
    if usesAskCheckpoints, !context.providerFeatures.supportsInteractiveCallbacks {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).ask-checkpoints-brokered",
            severity: .warning,
            title: "Ask checkpoints are brokered by ASTRA",
            message: "\(context.runtimeID.displayName) cannot ask for live approval mid-run. Blocked actions pause the task; approving resumes it in a new provider run.",
            affectedCapability: "permissions",
            remediation: "Approve requested permissions when the task pauses, or pick a runtime with live approval support for ask-heavy work."
        ))
    }
    if policy.level == .autonomous {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).autonomous-broad-permissions",
            severity: .warning,
            title: "Broad provider permissions",
            message: "Auto mode grants broad provider permissions and should be used only for trusted or isolated work.",
            affectedCapability: "autonomous"
        ))
    }
    return diagnostics
}

private func summarizeCopilotArguments(_ args: [String]) -> [String] {
    guard !args.isEmpty else { return [] }
    var summary: [String] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--allow-tool" {
            let values = args[(index + 1)..<args.count].filter { !$0.hasPrefix("--") }
            summary.append("--allow-tool \(values.count) entries")
            break
        }
        summary.append(arg)
        index += 1
    }
    return summary
}

private func copilotAllowedTools(from args: [String], fallback: [String]) -> [String] {
    guard let allowIndex = args.firstIndex(of: "--allow-tool") else {
        return copilotUsesBroadProviderPermissions(args) ? ["*"] : fallback
    }
    let start = args.index(after: allowIndex)
    guard start < args.endIndex else { return fallback }
    let values = args[start...].prefix { !$0.hasPrefix("--") }
    let rendered = Array(Set(values)).sorted()
    return rendered.isEmpty ? fallback : rendered
}

private func copilotUsesBroadProviderPermissions(_ args: [String]) -> Bool {
    args.contains("--allow-all") || args.contains("--allow-all-tools")
}
