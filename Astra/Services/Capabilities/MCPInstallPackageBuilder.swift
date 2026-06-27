import Foundation
import ASTRACore

enum MCPInstallPackageBuilder {
    enum BuildError: LocalizedError, Equatable {
        case blocked([String])
        case missingLaunchTarget

        var errorDescription: String? {
            switch self {
            case .blocked(let blockers):
                return blockers.joined(separator: "\n")
            case .missingLaunchTarget:
                return "The MCP install target does not include a launch command or URL."
            }
        }
    }

    static func package(from intent: MCPInstallIntent) throws -> PluginPackage {
        let policy = MCPInstallPolicy.decision(for: intent)
        guard policy.blockers.isEmpty else {
            throw BuildError.blocked(policy.blockers)
        }

        let source = intent.installSource
        let serverID = normalizedServerID(intent.serverID ?? source?.identifier ?? "mcp")
        let display = displayName(from: intent)
        let server = try server(from: intent, serverID: serverID, displayName: display)
        return PluginPackage(
            id: "local.mcp.\(serverID)",
            name: "\(display) MCP",
            icon: "server.rack",
            iconDescriptor: .systemSymbol("server.rack"),
            description: "Local MCP capability created from pasted install target.",
            author: "Local",
            category: "MCP",
            tags: ["mcp"],
            version: "1.0.0",
            setupGuide: setupGuide(for: policy),
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [server],
            templates: [],
            prerequisites: prerequisites(for: intent),
            sourceMetadata: .localLibrary(),
            governance: CapabilityGovernance(
                approvalStatus: .draft,
                riskLevel: policy.riskLevel,
                visibility: .adminOnly,
                requiresAdminApproval: true,
                requiresExplicitUserConsent: true,
                dataAccess: dataAccess(for: intent),
                externalEffects: [.readOnly],
                policyNotes: policy.summary
            )
        )
    }

    private static func server(
        from intent: MCPInstallIntent,
        serverID: String,
        displayName: String
    ) throws -> PluginMCPServer {
        switch intent.transport {
        case .stdio:
            guard let command = intent.command else { throw BuildError.missingLaunchTarget }
            return PluginMCPServer(
                id: serverID,
                displayName: displayName,
                transport: .stdio,
                command: command,
                arguments: intent.arguments,
                trustLevel: .high,
                installSource: intent.installSource
            )
        case .http, .sse:
            guard let url = intent.url else { throw BuildError.missingLaunchTarget }
            return PluginMCPServer(
                id: serverID,
                displayName: displayName,
                transport: intent.transport,
                url: url,
                trustLevel: .medium,
                installSource: intent.installSource
            )
        }
    }

    private static func prerequisites(for intent: MCPInstallIntent) -> [CLIPrerequisite] {
        guard intent.transport == .stdio, let command = intent.command else { return [] }
        return [
            CLIPrerequisite(
                binary: command,
                livenessArgs: ["--version"],
                displayName: "\(command) runtime",
                purpose: "Launches the pasted MCP server.",
                installHint: installHint(for: intent)
            )
        ]
    }

    private static func setupGuide(for policy: MCPInstallPolicyDecision) -> String {
        ([policy.summary] + policy.warnings).joined(separator: "\n")
    }

    private static func installHint(for intent: MCPInstallIntent) -> String {
        switch intent.installSource?.installMode {
        case .npx:
            return "Install Node.js and npm so npx can launch this MCP package."
        case .uvx:
            return "Install uv so uvx can launch this MCP package."
        case .dockerGateway, .dockerRun:
            return "Install Docker and ensure the image can be pulled before enabling this server."
        case .remote:
            return "Verify the remote MCP endpoint is reachable and authenticated if required."
        default:
            return "Install the MCP server command and make sure it is on PATH."
        }
    }

    private static func dataAccess(for intent: MCPInstallIntent) -> [CapabilityDataAccessKind] {
        guard intent.transport == .stdio else { return [.network, .externalService] }
        switch intent.installSource?.kind {
        case .npm, .pypi, .nuget, .dockerImage, .oci, .mcpb, .remoteHTTP:
            return [.workspaceFiles, .network, .externalService]
        case .localBinary, .unknown, .none:
            return [.workspaceFiles]
        }
    }

    private static func displayName(from intent: MCPInstallIntent) -> String {
        let value = intent.displayName ?? intent.installSource?.identifier ?? intent.serverID ?? "MCP"
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    private static func normalizedServerID(_ value: String) -> String {
        let lower = value.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
                ? Character(scalar)
                : "-"
        }
        let normalized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return normalized.isEmpty ? "mcp" : normalized
    }
}
