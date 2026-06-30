import Foundation
import ASTRACore

enum MCPInstallPackageBuilder {
    enum BuildError: LocalizedError, Equatable {
        case blocked([String])
        case missingLaunchTarget
        case requiresGuidedSetup(String)

        var errorDescription: String? {
            switch self {
            case .blocked(let blockers):
                return blockers.joined(separator: "\n")
            case .missingLaunchTarget:
                return "The MCP install target does not include a launch command or URL."
            case .requiresGuidedSetup(let guidance):
                return guidance
            }
        }
    }

    static func package(from intent: MCPInstallIntent) throws -> PluginPackage {
        let policy = MCPInstallPolicy.decision(for: intent)
        if policy.requiresGuidedSetup {
            throw BuildError.requiresGuidedSetup(intent.setupCommand?.guidance ?? policy.summary)
        }
        guard policy.blockers.isEmpty else {
            throw BuildError.blocked(policy.blockers)
        }

        let source = intent.installSource
        let serverID = normalizedServerID(intent.serverID ?? source?.identifier ?? "mcp")
        let display = displayName(from: intent)
        let servers = try servers(from: intent)
        guard !servers.isEmpty else { throw BuildError.missingLaunchTarget }
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
            skills: environmentDeclarationSkills(for: servers),
            connectors: [],
            localTools: [],
            mcpServers: servers,
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
        from spec: MCPInstallServerSpec
    ) throws -> PluginMCPServer {
        let serverID = normalizedServerID(spec.serverID)
        let displayName = displayName(from: spec)
        switch spec.transport {
        case .stdio:
            guard let command = spec.command else { throw BuildError.missingLaunchTarget }
            return PluginMCPServer(
                id: serverID,
                displayName: displayName,
                transport: .stdio,
                command: command,
                arguments: spec.arguments,
                environmentKeys: spec.environmentKeys,
                trustLevel: .high,
                installSource: spec.installSource
            )
        case .http, .sse:
            guard let url = spec.url else { throw BuildError.missingLaunchTarget }
            return PluginMCPServer(
                id: serverID,
                displayName: displayName,
                transport: spec.transport,
                url: url,
                environmentKeys: spec.environmentKeys,
                trustLevel: .medium,
                installSource: spec.installSource
            )
        }
    }

    private static func servers(from intent: MCPInstallIntent) throws -> [PluginMCPServer] {
        let specs = intent.serverSpecs
        guard !specs.isEmpty else { return [] }
        return try specs.map(server(from:))
    }

    private static func prerequisites(for intent: MCPInstallIntent) -> [CLIPrerequisite] {
        var seen = Set<String>()
        return intent.serverSpecs.compactMap { spec in
            guard spec.transport == .stdio,
                  let command = spec.command,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(command).inserted else {
                return nil
            }
            return CLIPrerequisite(
                binary: command,
                livenessArgs: ["--version"],
                displayName: "\(command) runtime",
                purpose: "Launches the pasted MCP server.",
                installHint: installHint(for: spec.installSource)
            )
        }
    }

    private static func environmentDeclarationSkills(for servers: [PluginMCPServer]) -> [PluginSkill] {
        let keys = orderedUnique(servers.flatMap(\.environmentKeys))
        guard !keys.isEmpty else { return [] }
        return [
            PluginSkill(
                name: "MCP Environment",
                icon: "key.fill",
                description: "Declares environment variables requested by imported MCP server configuration.",
                allowedTools: [],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use this capability's MCP servers with the environment variables the imported configuration explicitly declared.",
                environmentKeys: keys,
                environmentValues: Array(repeating: "", count: keys.count)
            )
        ]
    }

    private static func setupGuide(for policy: MCPInstallPolicyDecision) -> String {
        ([policy.summary] + policy.warnings).joined(separator: "\n")
    }

    private static func installHint(for source: PluginMCPInstallSource?) -> String {
        switch source?.installMode {
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
        var result: [CapabilityDataAccessKind] = []
        func append(_ kind: CapabilityDataAccessKind) {
            if !result.contains(kind) {
                result.append(kind)
            }
        }

        for spec in intent.serverSpecs {
            if spec.transport == .stdio {
                append(.workspaceFiles)
            } else {
                append(.network)
                append(.externalService)
            }

            switch spec.installSource?.kind {
            case .npm, .pypi, .nuget, .dockerImage, .oci, .mcpb, .remoteHTTP:
                append(.network)
                append(.externalService)
            case .localBinary, .unknown:
                break
            case .none:
                break
            }
        }

        return result.isEmpty ? [.workspaceFiles] : result
    }

    private static func displayName(from intent: MCPInstallIntent) -> String {
        let value = intent.displayName ?? intent.installSource?.identifier ?? intent.serverID ?? "MCP"
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    private static func displayName(from spec: MCPInstallServerSpec) -> String {
        let value = spec.displayName ?? spec.installSource?.identifier ?? spec.serverID
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

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result.sorted()
    }
}
