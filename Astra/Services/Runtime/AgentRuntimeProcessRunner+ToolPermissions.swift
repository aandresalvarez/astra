import Foundation
import ASTRACore
import ASTRAModels

extension AgentRuntimeProcessRunner {
    static func providerAllowedTools(
        for runtime: AgentRuntimeID,
        baseAllowedTools: [String],
        permissionManifest: RunPermissionManifest?
    ) -> [String] {
        guard let permissionManifest,
              permissionManifest.providerID == runtime else {
            return baseAllowedTools
        }
        let manifestAllowedTools = permissionManifest.providerRender.allowedTools
        guard !permissionManifest.approvalGrants.isEmpty else {
            return manifestAllowedTools
        }
        let runtimeGrants = PermissionBroker.providerRuntimeGrantStrings(
            for: permissionManifest.approvalGrants,
            runtime: runtime
        )
        return Array(Set(manifestAllowedTools + runtimeGrants)).sorted()
    }

    static func providerRuntimeSupportToolPermissions(
        for runtime: AgentRuntimeID,
        permissionManifest: RunPermissionManifest?
    ) -> [String] {
        guard let permissionManifest,
              permissionManifest.providerID == runtime else {
            return []
        }
        return Array(Set(permissionManifest.providerRender.runtimeSupportTools.compactMap { descriptor in
            let permission = descriptor.providerNativePermission?.trimmingCharacters(in: .whitespacesAndNewlines)
            return permission?.isEmpty == false ? permission : nil
        })).sorted()
    }

    static func providerAskFirstToolPermissions(
        for runtime: AgentRuntimeID,
        permissionManifest: RunPermissionManifest?
    ) -> [String] {
        guard let permissionManifest,
              permissionManifest.providerID == runtime,
              permissionManifest.providerRender.permissionMode == .restricted else {
            return []
        }

        switch runtime {
        case .claudeCode:
            return Array(Set(permissionManifest.providerRender.askFirstTools.compactMap(claudeProviderToolPermission))).sorted()
        default:
            return []
        }
    }

    private static func claudeProviderToolPermission(_ tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let openParen = trimmed.firstIndex(of: "("),
           trimmed.hasSuffix(")") {
            let rawTool = String(trimmed[..<openParen])
            guard let canonicalTool = canonicalClaudeToolName(rawTool) else { return nil }
            let patternStart = trimmed.index(after: openParen)
            let pattern = String(trimmed[patternStart..<trimmed.index(before: trimmed.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ":", with: " ")
            return pattern.isEmpty ? canonicalTool : "\(canonicalTool)(\(pattern))"
        }

        return canonicalClaudeToolName(trimmed)
    }

    private static func canonicalClaudeToolName(_ tool: String) -> String? {
        switch tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

    static func ensureSubAgentPermissions(
        at workspacePath: String,
        policy: PermissionPolicy,
        allowedTools: [String]
    ) {
        if ClaudeSettingsStore.ensureSubAgentPermissions(
            at: workspacePath,
            policy: policy,
            allowedTools: allowedTools
        ) {
            AppLogger.audit(.workerStarted, category: "Worker", fields: [
                "event": "subagent_permissions_ensured",
                "policy": policy.rawValue
            ])
        }
    }
}
