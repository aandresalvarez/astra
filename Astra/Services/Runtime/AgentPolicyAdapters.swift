import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

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
            case .filePath, .networkPattern, .credential, .sandboxPath, .gitPublish:
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
        let permissionMode = ProviderPolicyModeResolver.mode(for: policy, runtime: providerID)
        let permissionPolicy = PermissionPolicy(providerMode: permissionMode)
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
            permissionMode: permissionMode,
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
            case .filePath, .networkPattern, .credential, .sandboxPath, .gitPublish:
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
        let permissionMode = ProviderPolicyModeResolver.mode(for: policy, runtime: providerID)
        let permissionPolicy = PermissionPolicy(providerMode: permissionMode)
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

        let runtimeSupportToolNames = copilotRuntimeSupportToolNames(runtimeSupportTools)
        let args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: permissionPolicy,
            allowedTools: allowedTools,
            localToolCommands: localToolCommands,
            runtimeSupportTools: runtimeSupportToolNames,
            supportsAllowAll: capabilities.supportsAllowAll,
            supportsAllowAllTools: capabilities.supportsAllowAllTools,
            supportsAllowAllPaths: capabilities.supportsAllowAllPaths,
            supportsAllowAllURLs: capabilities.supportsAllowAllURLs,
            requiresAllowAllToolsForPrompt: capabilities.requiresAllowAllToolsForPrompt
        )
        let providerAllowedTools = copilotAllowedTools(from: args, fallback: allowedTools).filter {
            !runtimeSupportToolNames.contains($0)
        }

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: .generated,
            permissionMode: permissionMode,
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
            case .filePath, .networkPattern, .credential, .sandboxPath, .gitPublish:
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
        let permissionMode = ProviderPolicyModeResolver.mode(for: policy, runtime: providerID)
        let permissionPolicy = PermissionPolicy(providerMode: permissionMode)
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
            permissionMode: permissionMode,
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
        let permissionMode = ProviderPolicyModeResolver.mode(for: policy, runtime: providerID)
        let permissionPolicy = PermissionPolicy(providerMode: permissionMode)
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
            permissionMode: permissionMode,
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
        let permissionMode = ProviderPolicyModeResolver.mode(for: policy, runtime: providerID)
        let permissionPolicy = PermissionPolicy(providerMode: permissionMode)
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
            permissionMode: permissionMode,
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
        let permissionMode = ProviderPolicyModeResolver.mode(for: policy, runtime: providerID)
        let permissionPolicy = PermissionPolicy(providerMode: permissionMode)
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
            permissionMode: permissionMode,
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
            case .filePath, .networkPattern, .credential, .sandboxPath, .gitPublish:
                return nil
            }
        })
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
        // An explicit one-run escalation is launch authority and therefore wins.
        // The fallback permission policy, however, is the legacy global
        // `skipPermissions` projection. It must not erase a task or workspace
        // selection made through the current policy UI.
        if executionPolicy.permissionPolicyOverride == .autonomous {
            let policy = AgentPolicy.preset(.autonomous)
            return Resolution(
                level: .autonomous,
                scope: .oneRunEscalation,
                policy: policy
            )
        }

        let baseResolution: Resolution
        if let selected = latestSelectedLevel(for: task) {
            baseResolution = Resolution(
                level: selected,
                scope: .taskOverride,
                policy: policy(for: selected, workspace: task.workspace)
            )
        } else if let workspaceDefault = AgentPolicyDefaults.workspaceLevel(for: task.workspace) {
            let effectiveWorkspaceDefault = AgentPolicyDefaults.effectiveUserFacingLevel(
                forStored: workspaceDefault,
                workspace: task.workspace
            )
            baseResolution = Resolution(
                level: effectiveWorkspaceDefault,
                scope: .workspaceDefault,
                policy: policy(for: effectiveWorkspaceDefault, workspace: task.workspace)
            )
        } else if fallbackPermissionPolicy == .autonomous {
            let policy = AgentPolicy.preset(.autonomous)
            baseResolution = Resolution(
                level: .autonomous,
                scope: .globalDefault,
                policy: policy
            )
        } else {
            let effectiveGlobalDefault = AgentPolicyDefaults.effectiveUserFacingLevel(
                forStored: globalDefaultLevel,
                workspace: nil
            )
            baseResolution = Resolution(
                level: effectiveGlobalDefault,
                scope: .globalDefault,
                policy: policy(for: effectiveGlobalDefault, workspace: nil)
            )
        }

        // A scoped approval may narrow Auto, but never broaden an already
        // narrower task/workspace selection. Treat restricted/interactive
        // one-run overrides as an execution cap so legacy global Auto cannot
        // silently turn an exact approval into unrestricted provider authority.
        guard executionPolicy.permissionPolicyOverride != nil,
              executionPolicy.permissionPolicyOverride != .autonomous,
              baseResolution.level == .autonomous else {
            return baseResolution
        }
        return Resolution(
            level: .review,
            scope: .oneRunEscalation,
            policy: AgentPolicy.preset(.review)
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
        phase: RunPhase,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        defaultPolicyLevelRaw: String,
        providerVersion: String? = nil,
        providerCapabilities: AgentRuntimePolicyCapabilities = .conservative,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile? = nil,
        capabilityPackages: [PluginPackage]? = nil,
        approvalRecords: [CapabilityApprovalRecord]? = nil,
        contextText: String = "",
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot? = nil,
        launchResourcePlan: TaskLaunchResourcePlan? = nil,
        sandboxSettingsDefaults: UserDefaults = .standard,
        // When the caller already ran the task through
        // AgentRuntimeLaunchRuntimeResolver (the normal launch path), pass its
        // TaskRuntimeRequirementSet here so the policy render's host-control-tools
        // determination reuses that single derivation instead of independently
        // re-deriving it from a second capability scope. The two derivations must
        // agree — see Tests/HostControlRequirementDerivationConsistencyTests.swift.
        precomputedRuntimeRequirements: TaskRuntimeRequirementSet? = nil,
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
        let taskScopedGrants = TaskRuntimePermissionGrants.approvedGrants(for: task)
        let executionGrants = executionPolicy.permissionGrantsOverride ?? []
        let taskCapabilityResolver = TaskCapabilityResolver(
            task: task,
            additionalCredentialGrants: executionGrants
        )
        let capabilityResolutionSnapshot = capabilityResolutionSnapshot ?? TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText,
            additionalCredentialGrants: executionGrants
        )
        let taskCapabilityScope = capabilityResolutionSnapshot.providerLaunch
        let effectiveGrants = PermissionBroker.sanitizeApprovedGrants(taskScopedGrants + executionGrants)
        let taskScopedProviderGrants = PermissionBroker.providerRuntimeGrantStrings(for: taskScopedGrants, runtime: runtime)
        let effectiveProviderGrants = PermissionBroker.providerRuntimeGrantStrings(for: effectiveGrants, runtime: runtime)
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
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)
        // Single source of truth for "which host-control tools does this run
        // need": reuse the launch resolver's already-computed requirement set
        // when available (the normal launch path) rather than re-deriving it
        // from a second, independently-captured capability scope.
        let hostControlTools = precomputedRuntimeRequirements?.hostControlTools ?? HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: executionEnvironment,
            contextText: contextText,
            capabilityScope: taskCapabilityScope
        )
        let envKeys = uniqueStrings(
            Array(taskCapabilityScope.resolver.resolvedEnvironmentVariables.keys)
                + dockerCredentialEnvironmentKeyNames(environment: executionEnvironment)
        )
        let manifestCredentialLabels = uniqueStrings(
            credentialLabels(for: task, capabilityScope: taskCapabilityScope)
                + dockerCredentialLabels(environment: executionEnvironment)
                + gitCredentialLabels(
                    task: task,
                    contextText: contextText,
                    executionEnvironment: executionEnvironment,
                    capabilityScope: taskCapabilityScope
                )
        )
        let launchResourceExposure = launchResourcePlan
            .map { LaunchResourcePolicyExposure(contract: LaunchResourceContract(plan: $0)) }
            ?? .absent
        let runtimeAdapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)
        let runtimeCapabilityProfile = runtimeCapabilityProfile
            ?? AgentRuntimeCapabilityProfileService.profile(for: runtime, executablePath: "")
        let providerPolicyAdapter = runtimeAdapter.policyAdapter(runtimeCapabilities: providerCapabilities)
        let configOwnership = runtimeAdapter.providerConfigOwnership(workspacePath: workspacePath)
        let runtimePaths = runtimeWritablePaths(for: task)
        let additionalReadOnlyPaths = brokeredReadOnlyPaths(from: launchResourcePlan)
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: runtimePaths,
            requestedAllowedTools: requestedAllowedTools,
            localToolCommands: localToolCommands(
                for: task,
                capabilityScope: taskCapabilityScope,
                contextText: contextText
            ),
            environmentKeyNames: envKeys,
            credentialLabels: manifestCredentialLabels,
            providerFeatures: providerPolicyAdapter.supportedFeatures,
            launchResourceContractAvailable: launchResourceExposure.launchResourceContractAvailable,
            providerEnvironmentSecretResourceLabels: launchResourceExposure.providerEnvironmentSecretResourceLabels,
            providerFileCredentialResourceLabels: launchResourceExposure.providerFileCredentialResourceLabels,
            providerUnenforcedFileCredentialResourceLabels: launchResourceExposure.providerUnenforcedFileCredentialResourceLabels,
            providerConfigOwnership: configOwnership,
            existingProviderConfigSummary: runtimeAdapter.existingProviderConfigSummary(workspacePath: workspacePath)
        )
        var render = providerPolicyAdapter.render(policy: policy, context: context)
        render = applyingHostControlPlaneManifestSupport(
            to: render,
            runtime: runtime,
            runtimeCapabilityProfile: runtimeCapabilityProfile,
            executionEnvironment: executionEnvironment,
            hostControlTools: hostControlTools
        )
        render = applyingArtifactBootstrapManifestSupport(to: render, task: task)
        render.allowedShellPatterns = uniqueStrings(
            render.allowedShellPatterns
                + runtimeSupportAllowedShellPatterns(environmentKeyNames: envKeys)
                + (AskGitPullRequestWorkflowPolicy.isActive(
                    task: task,
                    permissionPolicy: permissionPolicy,
                    contextText: contextText
                ) ? AskGitPullRequestWorkflowPolicy.allowedLocalInspectionShellPatterns : [])
        )
        render = refreshingCopilotLaunchArgumentEvidence(
            to: render,
            providerCapabilities: providerCapabilities,
            localToolCommands: context.localToolCommands,
            task: task,
            executionEnvironment: executionEnvironment,
            contextText: contextText,
            capabilityScope: taskCapabilityScope,
            hostControlTools: hostControlTools
        )
        render.diagnostics = providerPolicyAdapter.validate(render: render, context: context)
        if shouldProjectGitCredentials(
            task: task,
            contextText: contextText,
            executionEnvironment: executionEnvironment,
            capabilityScope: taskCapabilityScope
        ) {
            render.diagnostics.append(PolicyDiagnostic(
                id: "git.credential-projection",
                severity: .info,
                title: "Git credentials projected",
                message: "Network Git intent was detected, so ASTRA will project Git config and credential files through the active sandbox for this run.",
                affectedCapability: "git",
                remediation: "Review the requested Git operation if this was unexpected."
            ))
        }
        // Reflect ASTRA's OS-level Seatbelt sandbox in the declared enforcement
        // tiers — but only when the run will both be wrapped (runtime in scope)
        // AND the sandbox would actually apply (enforcement on, usable workspace,
        // sandbox-exec present). Without the second check the manifest would
        // claim "OS Sandboxed" for a best-effort run that silently falls back to
        // unconfined at launch. Display-only; application + fallbacks are audited
        // at launch time.
        // The process runner launches with `executionPolicy.applyingProviderRender`,
        // so the final provider render is the source of truth for the effective
        // permission mode after task defaults, one-run grants, and runtime clamps.
        let effectiveSandboxPolicy = PermissionPolicy(providerMode: render.permissionMode)
        let sandboxResolution = ExecutionSandboxSettings.resolve(
            permissionPolicy: effectiveSandboxPolicy,
            defaults: sandboxSettingsDefaults
        )
        let sandboxSettings = sandboxResolution.effectiveSettings
        if !executionEnvironment.providerRunsInsideContainer,
           sandboxSettings.shouldWrap(runtime: runtime),
           ExecutionSandbox.willLikelyApply(workspacePath: workspacePath, settings: sandboxSettings),
           !render.enforcementTiers.contains(.osSandboxed) {
            render.enforcementTiers.append(.osSandboxed)
        }
        if executionEnvironment.isContainerized {
            let message = executionEnvironment.workspaceCommandsRunInsideContainer
                ? "This run keeps the provider on macOS and routes workspace shell commands through ASTRA's Docker command executor."
                : "This run launches the provider inside ASTRA's Docker execution environment; host Seatbelt sandboxing is not reported for the container workload."
            render.diagnostics.append(PolicyDiagnostic(
                id: "container.execution-environment",
                severity: .info,
                title: "Container execution environment",
                message: message,
                affectedCapability: "execution_environment",
                remediation: "Review the selected image, mounts, network mode, and allowed environment keys before running credentialed work."
            ))
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
            credentialLabels: manifestCredentialLabels,
            mcpServers: hostControlPlaneAugmentedMCPServers(
                base: capabilityPackages.map {
                    TaskCapabilityResolver.enabledMCPServerManifests(
                        for: task.workspace,
                        packages: $0,
                        approvalRecords: approvalRecords ?? CapabilityApprovalStore().records()
                    )
                } ?? taskCapabilityResolver.enabledMCPServerManifests,
                runtime: runtime,
                runtimeCapabilityProfile: runtimeCapabilityProfile,
                executionEnvironment: executionEnvironment,
                hostControlTools: hostControlTools
            ),
            approvalsGranted: approvals,
            approvalGrants: effectiveGrants,
            additionalReadOnlyPaths: additionalReadOnlyPaths,
            sandboxEvidence: RunPermissionManifest.SandboxEvidence(
                storedEnforcement: sandboxResolution.storedEnforcement.rawValue,
                effectiveEnforcement: sandboxSettings.enforcement.rawValue,
                effectiveReadScope: sandboxSettings.readScope.rawValue,
                resolutionReason: sandboxResolution.reason?.rawValue
            )
        )
        insertManifestEvent(manifest, type: preflightEventType, task: task, run: run, modelContext: modelContext)
        AppLogger.audit(.runtimeCommandPlanned, category: "Worker", taskID: task.id, fields: [
            "phase": phase.rawValue,
            "runtime": runtime.rawValue,
            "policy_level": resolution.level.rawValue,
            "policy_scope": manifest.policyScope.rawValue,
            "provider_adapter_version": String(render.adapterVersion),
            "enforcement": render.enforcementTiers.map(\.rawValue).joined(separator: ","),
            "sandbox_stored_enforcement": sandboxResolution.storedEnforcement.rawValue,
            "sandbox_effective_enforcement": sandboxSettings.enforcement.rawValue,
            "sandbox_resolution_reason": sandboxResolution.reason?.rawValue ?? "none",
            "brokered_read_only_path_count": String(additionalReadOnlyPaths.count),
            "diagnostics_blocked": String(render.diagnostics.filter { $0.severity == .blocked }.count),
            "diagnostics_warning": String(render.diagnostics.filter { $0.severity == .warning }.count),
            "uses_broad_provider_permissions": String(render.usesBroadProviderPermissions)
        ], level: render.diagnostics.contains(where: { $0.severity == .blocked }) ? .warning : .debug)
        return manifest
    }

    private static func runtimeWritablePaths(for task: AgentTask) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        var paths = access.runtimeWritablePaths
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

    private static func brokeredReadOnlyPaths(from plan: TaskLaunchResourcePlan?) -> [String] {
        guard let plan else { return [] }
        var seen: Set<String> = []
        return plan.hostPathGrants.compactMap { grant in
            guard grant.access == .read else { return nil }
            switch grant.source {
            case .taskInput, .userAttachment, .sandboxApproval:
                // `.sandboxApproval` grants only ever reach `hostPathGrants` with
                // `access == .read` (see `appendRuntimePermissionGrants`), so
                // widening the in-app read scope here is safe: without this, a
                // user-approved Seatbelt file-read retry (e.g. `Read` on an
                // out-of-scope path) still gets rejected by
                // `AgentRuntimePolicyGuard` because the OS-sandbox projection
                // alone doesn't widen ASTRA's own readable-scope check.
                let path = (grant.path as NSString).expandingTildeInPath
                guard !path.isEmpty, seen.insert(path).inserted else { return nil }
                return path
            case .workspace, .remoteWorkspace, .gitCredential, .dockerEnvironment,
                 .dockerCredential, .controlPlane, .connector, .browser, .provider:
                return nil
            }
        }.sorted()
    }

    private static func applyingHostControlPlaneManifestSupport(
        to render: ProviderPolicyRender,
        runtime: AgentRuntimeID,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile,
        executionEnvironment: WorkspaceExecutionEnvironment,
        hostControlTools: [String]
    ) -> ProviderPolicyRender {
        let usesDockerWorkspaceExecutor = DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)
            && runtimeCapabilityProfile.canDeliverDockerWorkspaceShellMCP
        let permissionPolicy = PermissionPolicy(providerMode: render.permissionMode)
        let deniesNativeShellForHostControl = HostControlPlaneMCPProjection.requiresNativeShellDenial(
            environment: executionEnvironment,
            permissionPolicy: permissionPolicy,
            requiredTools: hostControlTools
        )
        guard usesDockerWorkspaceExecutor || !hostControlTools.isEmpty else {
            return render
        }

        var updated = render
        if deniesNativeShellForHostControl {
            updated.allowedTools = DockerWorkspaceMCPProjection.removingNativeShellTools(updated.allowedTools)
            updated.askFirstTools = DockerWorkspaceMCPProjection.removingNativeShellTools(updated.askFirstTools)
        }
        if usesDockerWorkspaceExecutor {
            updated.allowedTools = uniqueStrings(
                updated.allowedTools + DockerWorkspaceMCPProjection.toolNames.map {
                    DockerWorkspaceMCPProjection.providerToolPermission(for: $0)
                }
            )
        }
        if !hostControlTools.isEmpty {
            updated.allowedTools = uniqueStrings(
                updated.allowedTools + hostControlTools.map {
                    HostControlPlaneMCPProjection.providerToolPermission(for: $0)
                }
            )
            if !runtimeCapabilityProfile.canDeliverHostControlPlaneMCP {
                updated.diagnostics.append(PolicyDiagnostic(
                    id: "\(runtime.rawValue).host-control-plane-unsupported",
                    severity: .blocked,
                    title: "Host control-plane route is unavailable",
                    message: HostControlPlaneRuntimeLaunchGuard.unsupportedRuntimeDetail(
                        runtime: runtime,
                        requiredTools: hostControlTools
                    ),
                    affectedCapability: "control_plane",
                    remediation: HostControlPlaneRuntimeLaunchGuard.unsupportedRuntimeRemediation(
                        requiredTools: hostControlTools
                    )
                ))
            }
        }
        if deniesNativeShellForHostControl {
            updated.deniedTools = uniqueStrings(updated.deniedTools + ["Bash", "shell"])
        }
        updated.diagnostics.append(PolicyDiagnostic(
            id: "container.host-control-plane-routing",
            severity: .info,
            title: deniesNativeShellForHostControl
                ? "Host control plane routed through ASTRA"
                : "Host inspection available alongside Auto developer tools",
            message: deniesNativeShellForHostControl
                ? "Project shell commands run in Docker through ASTRA's workspace MCP tools. Host services such as GitHub, Jira, Google Cloud, SSH, browser, and Keychain access must use enabled ASTRA capabilities rather than native provider Bash or Docker workspace shell."
                : "ASTRA's host-control tools remain constrained to their declared operations. Auto keeps provider-native developer tools available for explicit user-requested host work.",
            affectedCapability: "control_plane",
            remediation: deniesNativeShellForHostControl
                ? "Enable or repair the relevant capability before asking the provider to use host credentials or host services."
                : "Use Ask when host mutations should require confirmation."
        ))

        if usesDockerWorkspaceExecutor {
            for descriptor in DockerWorkspaceMCPProjection.runtimeSupportToolDescriptors(
                runtimeProfile: runtimeCapabilityProfile
            )
                where !updated.runtimeSupportTools.contains(where: { $0.name == descriptor.name }) {
                updated.runtimeSupportTools.append(descriptor)
            }
        }
        for descriptor in HostControlPlaneMCPProjection.runtimeSupportToolDescriptors(
            runtimeProfile: runtimeCapabilityProfile,
            tools: hostControlTools
        )
            where !updated.runtimeSupportTools.contains(where: { $0.name == descriptor.name }) {
            updated.runtimeSupportTools.append(descriptor)
        }
        updated.runtimeSupportTools.sort { $0.name < $1.name }
        return updated
    }

    private static func applyingArtifactBootstrapManifestSupport(
        to render: ProviderPolicyRender,
        task: AgentTask
    ) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy(providerMode: render.permissionMode)
        let launchTools = ProviderArtifactBootstrapPolicy.launchTools(
            task: task,
            permissionPolicy: permissionPolicy,
            providerAllowedTools: render.allowedTools,
            askFirstTools: render.askFirstTools
        )
        guard !launchTools.isEmpty else { return render }
        var updated = render
        updated.allowedTools = uniqueStrings(updated.allowedTools + launchTools)
        return updated
    }

    @MainActor
    private static func refreshingCopilotLaunchArgumentEvidence(
        to render: ProviderPolicyRender,
        providerCapabilities: AgentRuntimePolicyCapabilities,
        localToolCommands: [String],
        task: AgentTask,
        executionEnvironment: WorkspaceExecutionEnvironment,
        contextText: String,
        capabilityScope: TaskCapabilityPromptScope,
        hostControlTools: [String]
    ) -> ProviderPolicyRender {
        guard render.providerID == .copilotCLI else { return render }
        let scopedLocalToolCommands = hostControlTools.isEmpty
            ? localToolCommands
            : HostControlPlaneRuntimeLaunchGuard.removingNativeLocalToolCommands(
                localToolCommands,
                requiredTools: hostControlTools
            )
        let shouldAllowAllPaths = shouldProjectGitCredentials(
            task: task,
            contextText: contextText,
            executionEnvironment: executionEnvironment,
            capabilityScope: capabilityScope
        )
            || AgentRuntimeProcessRunner.hasWorkspaceSSHConnections(for: task)
        var updated = render
        let launchPermissionMode = AgentRuntimeProviderLaunchPolicy.mode(
            runtime: render.providerID,
            effectiveProviderMode: render.permissionMode,
            executionEnvironment: executionEnvironment
        )
        updated.permissionMode = launchPermissionMode
        let args = copilotLaunchPermissionArguments(
            render: updated,
            providerCapabilities: providerCapabilities,
            localToolCommands: scopedLocalToolCommands,
            allowAllPaths: shouldAllowAllPaths
        )
        let runtimeSupportToolNames = Set(updated.runtimeSupportTools.flatMap {
            [$0.name, $0.providerNativePermission ?? ""]
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        updated.allowedTools = uniqueStrings(
            copilotAllowedTools(from: args, fallback: updated.allowedTools).filter {
                let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized != "*" && !runtimeSupportToolNames.contains(normalized)
            }
        )
        updated.cliArgumentsSummary = summarizeCopilotArguments(args)
        updated.generatedConfigPreview = args.joined(separator: " ")
        updated.usesBroadProviderPermissions = copilotUsesBroadProviderPermissions(args)
        return updated
    }

    private static func copilotLaunchPermissionArguments(
        render: ProviderPolicyRender,
        providerCapabilities: AgentRuntimePolicyCapabilities,
        localToolCommands: [String],
        allowAllPaths: Bool
    ) -> [String] {
        let policy = PermissionPolicy(providerMode: render.permissionMode)
        var args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: policy,
            allowedTools: render.allowedTools,
            localToolCommands: localToolCommands,
            runtimeSupportTools: copilotRuntimeSupportToolNames(render.runtimeSupportTools),
            supportsAllowAll: providerCapabilities.supportsAllowAll,
            supportsAllowAllTools: providerCapabilities.supportsAllowAllTools,
            supportsAllowAllPaths: providerCapabilities.supportsAllowAllPaths,
            supportsAllowAllURLs: providerCapabilities.supportsAllowAllURLs,
            requiresAllowAllToolsForPrompt: providerCapabilities.requiresAllowAllToolsForPrompt
        )
        if allowAllPaths,
           policy != .autonomous,
           providerCapabilities.supportsAllowAllPaths,
           !args.contains("--allow-all-paths") {
            args.append("--allow-all-paths")
        }
        return args
    }

    private static func hostControlPlaneAugmentedMCPServers(
        base: [RunPermissionManifest.MCPServer],
        runtime: AgentRuntimeID,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile,
        executionEnvironment: WorkspaceExecutionEnvironment,
        hostControlTools: [String]
    ) -> [RunPermissionManifest.MCPServer] {
        let usesDockerWorkspaceExecutor = DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)
            && runtimeCapabilityProfile.canDeliverDockerWorkspaceShellMCP
        var servers = base
        if usesDockerWorkspaceExecutor {
            servers.append(DockerWorkspaceMCPProjection.manifestServer())
        }
        if !hostControlTools.isEmpty, runtimeCapabilityProfile.canDeliverHostControlPlaneMCP {
            servers.append(HostControlPlaneMCPProjection.manifestServer(allowedTools: hostControlTools))
        }
        return uniqueMCPServers(servers)
    }

    private static func uniqueMCPServers(
        _ servers: [RunPermissionManifest.MCPServer]
    ) -> [RunPermissionManifest.MCPServer] {
        var seen: Set<String> = []
        return servers.filter { server in
            seen.insert("\(server.packageID):\(server.id)").inserted
        }
    }

    private static func dockerCredentialEnvironmentKeyNames(
        environment: WorkspaceExecutionEnvironment
    ) -> [String] {
        uniqueStrings(Array(DockerExecutionPlanner.credentialProjectionEnvironment(environment: environment).keys))
    }

    private static func dockerCredentialLabels(
        environment: WorkspaceExecutionEnvironment
    ) -> [String] {
        uniqueStrings(environment.effectiveCredentialProjections.map {
            "docker:\($0.displayName):\($0.access.rawValue):\($0.containerPath)"
        })
    }

    private static func gitCredentialLabels(
        task: AgentTask,
        contextText: String,
        executionEnvironment: WorkspaceExecutionEnvironment,
        capabilityScope: TaskCapabilityPromptScope
    ) -> [String] {
        shouldProjectGitCredentials(
            task: task,
            contextText: contextText,
            executionEnvironment: executionEnvironment,
            capabilityScope: capabilityScope
        )
            ? ["git:credential-context:read-only"]
            : []
    }

    private static func shouldProjectGitCredentials(
        task: AgentTask,
        contextText: String,
        executionEnvironment: WorkspaceExecutionEnvironment,
        capabilityScope: TaskCapabilityPromptScope
    ) -> Bool {
        let hostControlGitHubAvailable = HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: executionEnvironment,
            contextText: contextText,
            capabilityScope: capabilityScope
        ).contains("github")
        return GitOperationIntentDetector.detectsNativeGitCredentialOperation(
            prompt: "",
            task: task,
            contextText: contextText,
            prefersHostControlGitHub: hostControlGitHubAvailable
        )
    }

    @MainActor
    static func recordPostRunSummary(task: AgentTask, run: TaskRun, modelContext: ModelContext) {
        let runEvents = task.events.filter { $0.run?.id == run.id }
        let manifest = latestManifest(in: runEvents)
        let deniedActionValues = deniedActions(from: runEvents)
        let explicitDeniedEventCount = runEvents.filter {
            $0.type == "permission.denied" || $0.type == "permission.approval.requested"
        }.count
        let summary = PolicyRunSummary(
            runID: run.id,
            status: run.status.rawValue,
            stopReason: run.stopReason,
            toolUseCount: runEvents.filter { $0.type == "tool.use" }.count,
            deniedCount: max(explicitDeniedEventCount, deniedActionValues.count),
            fileChangeCount: run.fileChanges.count,
            toolsUsed: toolsUsed(from: runEvents),
            commandsRun: commandsRun(from: runEvents),
            deniedActions: deniedActionValues,
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
    private static func localToolCommands(for task: AgentTask, contextText: String) -> [String] {
        let capabilityScope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        return localToolCommands(for: task, capabilityScope: capabilityScope, contextText: contextText)
    }

    private static func localToolCommands(
        for task: AgentTask,
        capabilityScope: TaskCapabilityPromptScope,
        contextText: String
    ) -> [String] {
        var commands: [String] = capabilityScope.localTools.compactMap { tool in
            guard tool.toolType != "mcp" else { return nil }
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        if capabilityScope.exposesBrowserBridge ||
            TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) {
            commands.append("astra-browser")
        }
        return Array(Set(commands)).sorted()
    }

    @MainActor
    private static func credentialLabels(for task: AgentTask, contextText: String) -> [String] {
        let capabilityScope = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: contextText
        ).providerLaunch
        return credentialLabels(for: task, capabilityScope: capabilityScope)
    }

    private static func credentialLabels(for task: AgentTask, capabilityScope: TaskCapabilityPromptScope) -> [String] {
        let skillKeys = capabilityScope.behaviorSkills.flatMap(\.environmentKeys)
        let connectorLabels = ConnectorRuntimeProjection(
            connectors: capabilityScope.connectors,
            credentialExposurePolicy: .approvedLabels(
                Set(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task))
            )
        ).configuredCredentialLabels()
        return Array(Set(skillKeys + connectorLabels)).sorted()
    }

    private static func runtimeSupportAllowedShellPatterns(environmentKeyNames: [String]) -> [String] {
        guard environmentKeyNames.contains("ASTRA_CONNECTORS") else { return [] }
        return [
            #"echo "$ASTRA_CONNECTORS""#,
            #"echo "$ASTRA_CONNECTORS" | head"#,
            #"echo "$ASTRA_CONNECTORS" | head -50"#,
            #"echo "$ASTRA_CONNECTORS" | head -n 50"#,
            #"echo $ASTRA_CONNECTORS"#,
            #"echo $ASTRA_CONNECTORS | head"#,
            #"echo $ASTRA_CONNECTORS | head -50"#,
            #"echo $ASTRA_CONNECTORS | head -n 50"#,
            #"printf "%s\n" "$ASTRA_CONNECTORS""#,
            #"printf "%s\n" "$ASTRA_CONNECTORS" | head"#,
            #"printf "%s\n" "$ASTRA_CONNECTORS" | head -50"#,
            #"printf "%s\n" "$ASTRA_CONNECTORS" | head -n 50"#,
            #"printf '%s\n' "$ASTRA_CONNECTORS""#,
            #"printf '%s\n' "$ASTRA_CONNECTORS" | head"#,
            #"printf '%s\n' "$ASTRA_CONNECTORS" | head -50"#,
            #"printf '%s\n' "$ASTRA_CONNECTORS" | head -n 50"#
        ]
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
            approvals.append("permission_mode:\(render.permissionMode.rawValue)")
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
        let explicitActions: [String] = events.compactMap { event -> String? in
            guard event.type == "permission.denied" || event.type == "permission.approval.requested" else { return nil }
            return LogSanitizer.sanitize(event.payload, maxLength: 240)
        }
        let providerSandboxActions: [String] = events.compactMap(providerSandboxDeniedAction(from:))
        let osSandboxActions: [String] = events.compactMap(osSandboxDeniedAction(from:))
        return uniqueLimited(explicitActions + providerSandboxActions + osSandboxActions)
    }

    private static func providerSandboxDeniedAction(from event: TaskEvent) -> String? {
        guard event.type == "agent.response" || event.type == "agent.thinking" else { return nil }
        let lower = event.payload.lowercased()
        guard lower.contains("write") || lower.contains("create") else { return nil }
        guard lower.contains("blocked") || lower.contains("rejected") || lower.contains("denied") else { return nil }
        guard lower.contains("sandbox") || lower.contains("outside") || lower.contains("workspace") else { return nil }
        guard let path = filesystemPaths(in: event.payload).first else { return nil }
        return "provider_sandbox_blocked_write path=\(path)"
    }

    private static func osSandboxDeniedAction(from event: TaskEvent) -> String? {
        guard event.type == "tool.result" || event.type == "agent.response" || event.type == "agent.thinking" else {
            return nil
        }
        return RuntimeSandboxDenialDiagnostics.fileDenial(in: event.payload)?.deniedActionValue
    }

    private static func filesystemPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:~|/)[^\s`"'<>]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            let value = String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);:"))
            return value.isEmpty ? nil : value
        }
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
    let environmentSecretLabels = context.providerEnvironmentSecretResourceLabels
    if !environmentSecretLabels.isEmpty, !context.providerFeatures.supportsSecretEnvRedaction {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).secret-redaction-unsupported",
            severity: .blocked,
            title: "Secret redaction is unsupported",
            message: "This provider render cannot mark provider-visible credential environment values as secrets.",
            affectedCapability: "credentials",
            remediation: "Remove provider environment credential injection or use a provider/version with secret env support."
        ))
    }
    if !context.providerUnenforcedFileCredentialResourceLabels.isEmpty {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).credential-file-enforcement-unsupported",
            severity: .blocked,
            title: "Credential file enforcement is unsupported",
            message: "This provider render would expose credential files without a safe launch-resource enforcement boundary.",
            affectedCapability: "credentials",
            remediation: "Use a runtime path with launch-resource file projection, route the credential through a host control-plane tool, or remove the file credential grant."
        ))
    }
    if !context.launchResourceContractAvailable {
        let credentialLabels = Array(Set(policy.credentialLabels + context.credentialLabels)).sorted()
        if !credentialLabels.isEmpty {
            diagnostics.append(PolicyDiagnostic(
                id: "\(context.runtimeID.rawValue).credential-contract-unavailable",
                severity: .blocked,
                title: "Credential exposure contract is unavailable",
                message: "This provider render includes credential labels but no launch-resource contract to classify environment versus file exposure.",
                affectedCapability: "credentials",
                remediation: "Resolve and attach the launch-resource contract before launching credentialed provider work."
            ))
        }
    }
    if !context.providerFileCredentialResourceLabels.isEmpty,
       context.providerFeatures.supportsPathScoping == false,
       context.providerUnenforcedFileCredentialResourceLabels.isEmpty {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).credential-file-projected",
            severity: .info,
            title: "Credential files use launch-resource projection",
            message: "ASTRA will expose selected credential files through its launch-resource boundary instead of provider environment secret injection.",
            affectedCapability: "credentials",
            remediation: "Review the launch resource manifest if credential file projection was unexpected."
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
    args
}

private func copilotRuntimeSupportToolNames(
    _ descriptors: [ProviderRuntimeSupportToolDescriptor]
) -> [String] {
    Array(Set(descriptors.map(\.name).filter { !$0.isEmpty })).sorted()
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
