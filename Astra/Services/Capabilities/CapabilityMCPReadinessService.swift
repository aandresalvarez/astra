import Foundation
import ASTRACore

enum CapabilityMCPReadinessService {
    static func readinessMessages(
        for package: PluginPackage,
        prerequisiteStatuses: [String: HealthStatus]
    ) -> [String] {
        package.mcpServers.compactMap { server in
            guard server.transport == .stdio,
                  let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty,
                  let status = readinessStatus(
                      for: command,
                      in: package,
                      prerequisiteStatuses: prerequisiteStatuses
                  ) else {
                return nil
            }
            return readinessMessage(for: server, command: command, status: status)
        }
    }

    private static func readinessMessage(
        for server: PluginMCPServer,
        command: String,
        status: HealthStatus
    ) -> String? {
        let name = displayName(server.displayName, fallback: server.id)
        switch status {
        case .healthy:
            return nil
        case .missingBinary:
            return "\(name): command \(command) is not installed.\(installHint(for: server))"
        case .unauthenticated(let detail):
            return "\(name): command \(command) needs login. \(detail)"
        case .unresponsive(let detail):
            return "\(name): command \(command) did not respond. \(detail)"
        }
    }

    private static func installHint(for server: PluginMCPServer) -> String {
        guard let source = server.installSource else { return "" }
        return " Install \(MCPInstallSourceFormatter.installDescription(for: source))."
    }

    private static func readinessStatus(
        for command: String,
        in package: PluginPackage,
        prerequisiteStatuses: [String: HealthStatus]
    ) -> HealthStatus? {
        let statuses = package.prerequisites
            .filter { $0.binary.trimmingCharacters(in: .whitespacesAndNewlines) == command }
            .compactMap { prerequisiteStatuses[$0.id] }
        return statuses.min { priority($0) < priority($1) }
    }

    private static func priority(_ status: HealthStatus) -> Int {
        switch status {
        case .missingBinary:
            return 0
        case .unauthenticated:
            return 1
        case .unresponsive:
            return 2
        case .healthy:
            return 3
        }
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
