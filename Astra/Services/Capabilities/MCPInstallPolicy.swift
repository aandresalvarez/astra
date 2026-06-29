import Foundation
import ASTRACore

struct MCPInstallPolicyDecision: Equatable {
    var blockers: [String]
    var warnings: [String]
    var riskLevel: CapabilityRiskLevel
    var summary: String
    var requiresGuidedSetup: Bool

    var canReview: Bool {
        blockers.isEmpty && !requiresGuidedSetup
    }
}

enum MCPInstallPolicy {
    static func decision(for intent: MCPInstallIntent) -> MCPInstallPolicyDecision {
        var blockers: [String] = []
        var warnings: [String] = []
        let source = intent.installSource

        if let setupCommand = intent.setupCommand {
            blockers.append(setupCommand.guidance)
            return decision(
                blockers,
                warnings,
                source,
                requiresGuidedSetup: true,
                summary: "Guided setup required for \(source?.identifier ?? setupCommand.command)"
            )
        }

        for spec in serverSpecs(for: intent) {
            guard spec.transport == .stdio, let command = spec.command else { continue }
            let reason = LocalToolSecurityPolicy.unsafeInvocationReason(
                command: command,
                arguments: spec.arguments.joined(separator: " ")
            )
            if let reason {
                blockers.append("The pasted command is not safe to store as an MCP launch command: \(reason).")
            }
        }

        for spec in serverSpecs(for: intent) where spec.transport != .stdio {
            guard let url = spec.url,
                  let scheme = url.scheme?.lowercased() else {
                blockers.append("Remote MCP URL is missing or invalid.")
                return decision(blockers, warnings, source)
            }
            if scheme != "https" && !(scheme == "http" && isLoopback(url.host)) {
                blockers.append("Remote MCP URLs must use HTTPS, except loopback HTTP for local development.")
            }
        }

        for source in installSources(for: intent) {
            switch source.kind {
            case .npm:
                if source.version == nil || source.version == "latest" {
                    warnings.append("This npm MCP package target is mutable. Prefer an exact version before approval.")
                }
            case .pypi:
                if source.version == nil || source.version == "latest" {
                    warnings.append("This PyPI MCP package target is mutable. Prefer an exact version before approval.")
                }
            case .dockerImage, .oci:
                if source.version == nil && source.digest == nil {
                    warnings.append("This Docker MCP image has no explicit tag or digest. Prefer an immutable digest.")
                }
            case .unknown:
                warnings.append("ASTRA could not identify the MCP package source. Treat this as a manual local binary.")
            case .localBinary, .mcpb, .nuget, .remoteHTTP:
                break
            }
        }

        return decision(blockers, warnings, source)
    }

    private static func serverSpecs(for intent: MCPInstallIntent) -> [MCPInstallServerSpec] {
        if !intent.serverSpecs.isEmpty { return intent.serverSpecs }
        return [
            MCPInstallServerSpec(
                serverID: intent.serverID ?? intent.installSource?.identifier ?? "mcp",
                displayName: intent.displayName,
                transport: intent.transport,
                command: intent.command,
                arguments: intent.arguments,
                url: intent.url,
                environmentKeys: [],
                installSource: intent.installSource
            )
        ]
    }

    private static func installSources(for intent: MCPInstallIntent) -> [PluginMCPInstallSource] {
        let sources = serverSpecs(for: intent).compactMap(\.installSource)
        let fallback = intent.installSource.map { [$0] } ?? []
        var seen = Set<String>()
        return (sources.isEmpty ? fallback : sources).filter { source in
            let key = [
                source.kind.rawValue,
                source.installMode.rawValue,
                source.identifier,
                source.version ?? "",
                source.digest ?? ""
            ].joined(separator: "\u{1F}")
            return seen.insert(key).inserted
        }
    }

    private static func decision(
        _ blockers: [String],
        _ warnings: [String],
        _ source: PluginMCPInstallSource?
    ) -> MCPInstallPolicyDecision {
        decision(
            blockers,
            warnings,
            source,
            requiresGuidedSetup: false,
            summary: nil
        )
    }

    private static func decision(
        _ blockers: [String],
        _ warnings: [String],
        _ source: PluginMCPInstallSource?,
        requiresGuidedSetup: Bool,
        summary explicitSummary: String?
    ) -> MCPInstallPolicyDecision {
        let risk: CapabilityRiskLevel
        if !blockers.isEmpty || requiresGuidedSetup {
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
            summary: explicitSummary ?? "Review MCP install source: \(label)",
            requiresGuidedSetup: requiresGuidedSetup
        )
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
    }
}
