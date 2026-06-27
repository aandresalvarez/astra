import Foundation
import ASTRACore

struct MCPInstallPolicyDecision: Equatable {
    var blockers: [String]
    var warnings: [String]
    var riskLevel: CapabilityRiskLevel
    var summary: String

    var canReview: Bool {
        blockers.isEmpty
    }
}

enum MCPInstallPolicy {
    static func decision(for intent: MCPInstallIntent) -> MCPInstallPolicyDecision {
        var blockers: [String] = []
        var warnings: [String] = []
        let source = intent.installSource

        if let command = intent.command {
            let reason = LocalToolSecurityPolicy.unsafeInvocationReason(
                command: command,
                arguments: intent.arguments.joined(separator: " ")
            )
            if let reason {
                blockers.append("The pasted command is not safe to store as an MCP launch command: \(reason).")
            }
        }

        if intent.transport != .stdio {
            guard let url = intent.url,
                  let scheme = url.scheme?.lowercased() else {
                blockers.append("Remote MCP URL is missing or invalid.")
                return decision(blockers, warnings, source)
            }
            if scheme != "https" && !(scheme == "http" && isLoopback(url.host)) {
                blockers.append("Remote MCP URLs must use HTTPS, except loopback HTTP for local development.")
            }
        }

        switch source?.kind {
        case .npm:
            if source?.version == nil || source?.version == "latest" {
                warnings.append("This npm MCP package target is mutable. Prefer an exact version before approval.")
            }
        case .pypi:
            if source?.version == nil || source?.version == "latest" {
                warnings.append("This PyPI MCP package target is mutable. Prefer an exact version before approval.")
            }
        case .dockerImage, .oci:
            if source?.version == nil && source?.digest == nil {
                warnings.append("This Docker MCP image has no explicit tag or digest. Prefer an immutable digest.")
            }
        case .unknown:
            warnings.append("ASTRA could not identify the MCP package source. Treat this as a manual local binary.")
        case .localBinary, .mcpb, .none, .nuget, .remoteHTTP:
            break
        }

        return decision(blockers, warnings, source)
    }

    private static func decision(
        _ blockers: [String],
        _ warnings: [String],
        _ source: PluginMCPInstallSource?
    ) -> MCPInstallPolicyDecision {
        let risk: CapabilityRiskLevel
        if !blockers.isEmpty {
            risk = .restricted
        } else if warnings.isEmpty {
            risk = source?.kind == .remoteHTTP ? .medium : .high
        } else {
            risk = .restricted
        }
        let label = source.map { "\($0.installMode.rawValue) \($0.identifier)" } ?? "manual MCP server"
        return MCPInstallPolicyDecision(
            blockers: blockers,
            warnings: warnings,
            riskLevel: risk,
            summary: "Review MCP install source: \(label)"
        )
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
    }
}
