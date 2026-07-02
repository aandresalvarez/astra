import Foundation
import ASTRACore

enum PermissionPolicy: String, Codable, CaseIterable {
    case autonomous
    case restricted
    case interactive

    var cliArguments: [String] {
        switch self {
        case .autonomous:
            return ["--dangerously-skip-permissions"]
        case .restricted, .interactive:
            return []
        }
    }

    func subAgentPermissions(allowedTools: [String]) -> [[String: Any]] {
        switch self {
        case .autonomous:
            return [
                ["allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Grep(*)", "Glob(*)"],
                 "deny": [] as [String]]
            ]
        case .restricted:
            let allow = allowedTools.isEmpty
                ? ["Read(*)", "Glob(*)", "Grep(*)"]
                : allowedTools.compactMap(Self.permissionEntry)
            return [
                ["allow": allow, "deny": [] as [String]]
            ]
        case .interactive:
            return []
        }
    }

    private static func permissionEntry(for tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("("), trimmed.hasSuffix(")") {
            return trimmed
        }
        return "\(trimmed)(*)"
    }

    var agentPolicyLevel: AgentPolicyLevel {
        switch self {
        case .autonomous:
            .autonomous
        case .restricted:
            .review
        case .interactive:
            .review
        }
    }

    static func fromAgentPolicyLevel(_ level: AgentPolicyLevel) -> PermissionPolicy {
        switch level {
        case .autonomous:
            .autonomous
        case .locked, .review, .build, .network, .custom:
            .restricted
        }
    }

    init(providerMode: ProviderPermissionMode) {
        self = PermissionPolicy(rawValue: providerMode.rawValue) ?? .restricted
    }

    var providerPermissionMode: ProviderPermissionMode {
        ProviderPermissionMode(rawValue: rawValue) ?? .restricted
    }
}
