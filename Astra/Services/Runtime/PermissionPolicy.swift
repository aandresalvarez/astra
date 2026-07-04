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
        // Exhaustive switch, not a rawValue round-trip: PermissionPolicy and
        // ProviderPermissionMode happen to share case names today, but a
        // rawValue-keyed conversion would silently fall back to .restricted
        // if either enum's cases were ever renamed independently, without the
        // compiler ever flagging the drift. readOnly has no dedicated
        // PermissionPolicy case (the CLI-argument vocabulary this type drives
        // doesn't distinguish it from interactive), so it collapses there.
        switch providerMode {
        case .autonomous: self = .autonomous
        case .restricted: self = .restricted
        case .readOnly, .interactive: self = .interactive
        }
    }

    var providerPermissionMode: ProviderPermissionMode {
        switch self {
        case .autonomous: .autonomous
        case .restricted: .restricted
        case .interactive: .interactive
        }
    }
}
