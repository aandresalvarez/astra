import Foundation
import ASTRACore

enum MCPInstallSetupCommandClassifier {
    static func setupCommand(
        command: String,
        arguments: [String],
        source: PluginMCPInstallSource
    ) -> MCPInstallSetupCommand? {
        guard let purpose = purpose(arguments: arguments, source: source) else { return nil }
        return MCPInstallSetupCommand(
            purpose: purpose,
            command: command,
            arguments: arguments,
            installSource: source,
            guidance: guidance(
                purpose: purpose,
                command: command,
                arguments: arguments
            )
        )
    }

    private static func purpose(
        arguments: [String],
        source: PluginMCPInstallSource
    ) -> MCPInstallSetupCommand.Purpose? {
        var seenLaunchTarget = source.kind == .localBinary || source.kind == .unknown
        var index = 0
        while index < arguments.count {
            let argument = arguments[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = argument.lowercased()
            if let purpose = setupFlagPurpose(normalized) {
                return purpose
            }
            if !seenLaunchTarget {
                if isLaunchTarget(argument, source: source) {
                    seenLaunchTarget = true
                }
                index += 1
                continue
            }
            if normalized.hasPrefix("-") {
                if index + 1 < arguments.count,
                   !arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            return setupVerbPurpose(normalized)
        }
        return nil
    }

    private static func setupFlagPurpose(_ argument: String) -> MCPInstallSetupCommand.Purpose? {
        switch argument {
        case "--generate", "--gen":
            return .generateConfig
        case "--import":
            return .importConfig
        case "--setup":
            return .guidedSetup
        default:
            return nil
        }
    }

    private static func setupVerbPurpose(_ argument: String) -> MCPInstallSetupCommand.Purpose? {
        switch argument {
        case "generate", "gen":
            return .generateConfig
        case "import":
            return .importConfig
        case "setup", "configure", "init", "install", "login", "auth":
            return .guidedSetup
        default:
            return nil
        }
    }

    private static func isLaunchTarget(
        _ argument: String,
        source: PluginMCPInstallSource
    ) -> Bool {
        let normalizedArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifier = source.identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identifier.isEmpty else { return false }
        return normalizedArgument == identifier
            || normalizedArgument.hasPrefix("\(identifier)@")
            || normalizedArgument.hasPrefix("\(identifier)==")
            || normalizedArgument.hasPrefix("\(identifier):")
            || normalizedArgument.hasPrefix("\(identifier)@sha256:")
    }

    private static func guidance(
        purpose: MCPInstallSetupCommand.Purpose,
        command: String,
        arguments: [String]
    ) -> String {
        let action: String
        switch purpose {
        case .generateConfig:
            action = "generate an MCP configuration"
        case .importConfig:
            action = "import an MCP configuration"
        case .guidedSetup:
            action = "complete setup"
        }
        let commandLine = ([command] + arguments).joined(separator: " ")
        return "This command appears to \(action), not launch a long-running MCP server: \(commandLine). Run the setup flow first, then paste or import the generated mcpServers JSON so ASTRA can review the declared servers."
    }
}
