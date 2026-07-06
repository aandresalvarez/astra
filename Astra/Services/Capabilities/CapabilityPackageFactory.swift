import Foundation
import ASTRACore
import ASTRAModels

struct CapabilityPackageFactory {
    static func makePackage(
        name: String,
        icon: String = "puzzlepiece.extension",
        description: String,
        author: String = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName(),
        category: String = "Custom",
        tags: [String] = [],
        version: String = "1.0.0",
        behaviorInstructions: String = "",
        allowedTools: [String] = [],
        connectors: [Connector] = [],
        localTools: [LocalTool] = [],
        mcpServers: [PluginMCPServer] = [],
        prerequisites: [CLIPrerequisite] = []
    ) -> PluginPackage {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? "New Capability" : trimmedName
        let trimmedBehavior = behaviorInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAllowed = allowedTools
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let pluginSkill = makeSkill(
            name: safeName,
            icon: icon,
            description: description,
            behaviorInstructions: trimmedBehavior,
            allowedTools: normalizedAllowed
        )

        return PluginPackage(
            id: packageID(for: safeName),
            name: safeName,
            icon: icon,
            description: description,
            author: author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Local" : author,
            category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : category,
            tags: tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            version: version,
            skills: pluginSkill.map { [$0] } ?? [],
            connectors: connectors.map(makeConnector),
            localTools: localTools.map(makeLocalTool),
            mcpServers: mcpServers,
            templates: [],
            prerequisites: prerequisites,
            sourceMetadata: .localLibrary()
        )
    }

    static func packageID(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let lowercased = name.lowercased()
        let mapped = lowercased.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                Character(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "_" {
                "-"
            } else {
                "-"
            }
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "custom-capability" : "local.\(collapsed)"
    }

    private static func makeSkill(
        name: String,
        icon: String,
        description: String,
        behaviorInstructions: String,
        allowedTools: [String]
    ) -> PluginSkill? {
        guard !behaviorInstructions.isEmpty || !allowedTools.isEmpty else { return nil }
        return PluginSkill(
            name: name,
            icon: icon,
            description: description,
            allowedTools: allowedTools.isEmpty ? Skill.defaultAllowed : allowedTools,
            disallowedTools: [],
            customTools: [],
            behaviorInstructions: behaviorInstructions,
            environmentKeys: [],
            environmentValues: []
        )
    }

    static func makeConnector(_ connector: Connector) -> PluginConnector {
        PluginConnector(
            name: connector.name,
            serviceType: connector.serviceType,
            icon: connector.icon,
            description: connector.connectorDescription,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod,
            credentialHints: connector.credentialKeys.map {
                PluginConnector.CredentialHint(key: $0, hint: "Required credential")
            },
            configHints: connector.configKeys.map {
                PluginConnector.ConfigHint(key: $0, hint: "Configuration value", isList: false)
            },
            notes: connector.notes
        )
    }

    static func makeLocalTool(_ tool: LocalTool) -> PluginLocalTool {
        PluginLocalTool(
            name: tool.name,
            description: tool.toolDescription,
            icon: tool.icon,
            toolType: tool.toolType,
            command: tool.command,
            arguments: tool.arguments
        )
    }
}
