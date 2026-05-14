import Foundation
import SwiftData
import ASTRACore

protocol ProviderPolicyAdapter {
    var providerID: AgentRuntimeID { get }
    var adapterVersion: Int { get }
    var supportedFeatures: ProviderPolicyFeatures { get }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender
    func validate(render: ProviderPolicyRender, context: PolicyRenderContext) -> [PolicyDiagnostic]
    func observedEvent(from providerEvent: ParsedEvent) -> PolicyObservedEvent?
}

extension ProviderPolicyAdapter {
    func validate(render: ProviderPolicyRender, context _: PolicyRenderContext) -> [PolicyDiagnostic] {
        render.diagnostics
    }

    func observedEvent(from providerEvent: ParsedEvent) -> PolicyObservedEvent? {
        PolicyObservedEvent(providerEvent: providerEvent)
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
        let allowedTools = policy.providerAllowedTools(requestedTools: context.requestedAllowedTools)
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
                remediation: "Use Locked or Review mode until ASTRA brokered shell execution is enabled for this workspace."
            ))
        }

        let settingsSummary = "Generated .claude/settings.local.json permissions allow=\(allowedTools.count) deny=\(deniedTools.count)"
        let cliSummary = permissionPolicy.cliArguments + (allowedTools.isEmpty ? [] : ["--allowedTools", "\(allowedTools.count) tools"])
        let generatedConfigPreview = ClaudeSettingsStore.generatedConfigPreview(
            policy: permissionPolicy,
            allowedTools: allowedTools
        )

        return ProviderPolicyRender(
            providerID: providerID,
            adapterVersion: adapterVersion,
            policyLevel: policy.level,
            configOwnership: context.providerConfigOwnership,
            permissionMode: permissionPolicy.rawValue,
            allowedTools: allowedTools,
            deniedTools: deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
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
}

struct CopilotPolicyAdapter: ProviderPolicyAdapter {
    let providerID: AgentRuntimeID = .copilotCLI
    let adapterVersion = 1
    var capabilities: CopilotCLICapabilities = .conservative

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
            supportsBroadAllowAll: capabilities.supportsAllowAllTools
        )
    }

    func render(policy: AgentPolicy, context: PolicyRenderContext) -> ProviderPolicyRender {
        let permissionPolicy = PermissionPolicy.fromAgentPolicyLevel(policy.level)
        let allowedTools = policy.providerAllowedTools(requestedTools: context.requestedAllowedTools)
        var diagnostics = diagnostics(for: policy, context: context)
        if !policy.deniedTools.isEmpty || !policy.deniedShellPatterns.isEmpty {
            diagnostics.append(PolicyDiagnostic(
                id: "copilot.deny-provider-native-gap",
                severity: .warning,
                title: "Deny rules require ASTRA enforcement",
                message: "This Copilot CLI adapter records deny intent, but the current command path only renders positive allow-tool grants.",
                affectedCapability: "deny",
                remediation: "Keep the policy at Review or Locked when strict denial must be guaranteed."
            ))
        }
        if policy.level == .autonomous, !capabilities.supportsAllowAllTools {
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
            localToolCommands: context.localToolCommands,
            supportsAllowAllTools: capabilities.supportsAllowAllTools,
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
            deniedTools: policy.deniedTools,
            allowedShellPatterns: policy.allowedShellPatterns,
            deniedShellPatterns: policy.deniedShellPatterns,
            allowedURLPatterns: policy.allowedURLPatterns,
            deniedURLPatterns: policy.deniedURLPatterns,
            cliArgumentsSummary: summarizeCopilotArguments(args),
            settingsSummary: "Generated per-run Copilot CLI permission flags",
            generatedConfigPreview: args.joined(separator: " "),
            enforcementTiers: permissionPolicy == .autonomous ? [.providerNative] : [.providerNative, .astraBrokered],
            diagnostics: diagnostics,
            usesBroadProviderPermissions: args.contains("--allow-all-tools")
        )
    }
}

enum ProviderPolicyAdapterRegistry {
    static func adapter(
        for runtime: AgentRuntimeID,
        copilotCapabilities: CopilotCLICapabilities = .conservative
    ) -> any ProviderPolicyAdapter {
        switch runtime {
        case .claudeCode:
            return ClaudePolicyAdapter()
        case .copilotCLI:
            return CopilotPolicyAdapter(capabilities: copilotCapabilities)
        }
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
            return Resolution(
                level: workspaceDefault,
                scope: .workspaceDefault,
                policy: policy(for: workspaceDefault, workspace: task.workspace)
            )
        }

        return Resolution(
            level: globalDefaultLevel,
            scope: .globalDefault,
            policy: policy(for: globalDefaultLevel, workspace: nil)
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
        copilotCapabilities: CopilotCLICapabilities = .conservative,
        modelContext: ModelContext
    ) -> RunPermissionManifest {
        let defaultLevel = AgentPolicyLevel.normalized(defaultPolicyLevelRaw)
        let resolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: defaultLevel,
            fallbackPermissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy
        )
        let basePolicy = resolution.policy
        let policy = executionPolicy.allowedToolsOverride
            .map { basePolicy.applyingOneRunAllowedTools($0) }
            ?? basePolicy
        let envKeys = Array(TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables.keys).sorted()
        let configOwnership = providerConfigOwnership(for: runtime, workspacePath: workspacePath)
        let context = PolicyRenderContext(
            runtimeID: runtime,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: TaskWorkspaceAccess(task: task).runtimeAdditionalPaths,
            requestedAllowedTools: executionPolicy.allowedTools(default: TaskCapabilityResolver(task: task).resolver.resolvedProviderAllowedTools),
            localToolCommands: localToolCommands(for: task),
            environmentKeyNames: envKeys,
            credentialLabels: credentialLabels(for: task),
            providerFeatures: providerFeatures(for: runtime, copilotCapabilities: copilotCapabilities),
            providerConfigOwnership: configOwnership,
            existingProviderConfigSummary: existingProviderConfigSummary(for: runtime, workspacePath: workspacePath)
        )
        let adapter = ProviderPolicyAdapterRegistry.adapter(for: runtime, copilotCapabilities: copilotCapabilities)
        var render = adapter.render(policy: policy, context: context)
        render.diagnostics = adapter.validate(render: render, context: context)
        let approvals = approvalsGranted(executionPolicy: executionPolicy, render: render)
        let manifest = RunPermissionManifest(
            taskID: task.id,
            runID: run.id,
            phase: phase,
            providerID: runtime,
            providerVersion: providerVersion,
            model: model,
            policyLevel: resolution.level,
            policyScope: executionPolicy.allowedToolsOverride == nil ? resolution.scope : .oneRunEscalation,
            providerRender: render,
            workspacePath: workspacePath,
            additionalPaths: TaskWorkspaceAccess(task: task).runtimeAdditionalPaths,
            environmentKeyNames: envKeys,
            credentialLabels: credentialLabels(for: task),
            approvalsGranted: approvals
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
            usedBroadProviderPermissions: manifest?.providerRender.usesBroadProviderPermissions ?? false,
            exceededInitialPermissionLevel: manifest?.policyScope == .oneRunEscalation || manifest?.providerRender.usesBroadProviderPermissions == true,
            completedAt: run.completedAt ?? Date()
        )
        let payload = (try? summary.encodedString()) ?? "{}"
        modelContext.insert(TaskEvent(task: task, type: summaryEventType, payload: payload, run: run))
    }

    private static func providerFeatures(
        for runtime: AgentRuntimeID,
        copilotCapabilities: CopilotCLICapabilities
    ) -> ProviderPolicyFeatures {
        switch runtime {
        case .claudeCode:
            return ClaudePolicyAdapter().supportedFeatures
        case .copilotCLI:
            return CopilotPolicyAdapter(capabilities: copilotCapabilities).supportedFeatures
        }
    }

    private static func providerConfigOwnership(
        for runtime: AgentRuntimeID,
        workspacePath: String
    ) -> PolicyConfigOwnership {
        switch runtime {
        case .claudeCode:
            return ClaudeSettingsStore.configOwnership(at: workspacePath)
        case .copilotCLI:
            return .generated
        }
    }

    private static func existingProviderConfigSummary(
        for runtime: AgentRuntimeID,
        workspacePath: String
    ) -> String? {
        switch runtime {
        case .claudeCode:
            return ClaudeSettingsStore.existingConfigSummary(at: workspacePath)
        case .copilotCLI:
            return nil
        }
    }

    @MainActor
    private static func localToolCommands(for task: AgentTask) -> [String] {
        TaskCapabilityResolver(task: task).allLocalTools.compactMap { tool in
            guard tool.toolType != "mcp" else { return nil }
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
    }

    @MainActor
    private static func credentialLabels(for task: AgentTask) -> [String] {
        let skillKeys = task.skills.flatMap(\.environmentKeys)
        let connectorKeys = TaskCapabilityResolver(task: task).allConnectors.flatMap(\.credentialKeys)
        return Array(Set(skillKeys + connectorKeys)).sorted()
    }

    private static func approvalsGranted(
        executionPolicy: AgentRuntimeExecutionPolicy,
        render: ProviderPolicyRender
    ) -> [String] {
        var approvals: [String] = []
        if let override = executionPolicy.allowedToolsOverride {
            approvals.append("allowed_tools:\(override.sorted().joined(separator: ","))")
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
    if policy.level == .autonomous {
        diagnostics.append(PolicyDiagnostic(
            id: "\(context.runtimeID.rawValue).autonomous-broad-permissions",
            severity: .warning,
            title: "Broad provider permissions",
            message: "Autonomous mode grants broad provider permissions and should be used only for trusted or isolated work.",
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
        return args.contains("--allow-all-tools") ? ["*"] : fallback
    }
    let start = args.index(after: allowIndex)
    guard start < args.endIndex else { return fallback }
    let values = args[start...].prefix { !$0.hasPrefix("--") }
    let rendered = Array(Set(values)).sorted()
    return rendered.isEmpty ? fallback : rendered
}
