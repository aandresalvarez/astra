import Foundation
import ASTRACore

enum CapabilityMCPReadinessService {
    static func readinessMessages(
        for package: PluginPackage,
        commandStatuses: [String: HealthStatus]
    ) -> [String] {
        package.mcpServers.compactMap { server in
            guard server.transport == .stdio,
                  let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty,
                  let status = commandStatuses[command] else {
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
        switch source.kind {
        case .npm:
            return " Install npm package \(packageTarget(source)) with npx."
        case .pypi:
            return " Install PyPI package \(packageTarget(source)) with uvx."
        case .dockerImage, .oci:
            return " Install or pull Docker image \(packageTarget(source))."
        case .remoteHTTP:
            return " Review remote MCP URL \(source.identifier)."
        case .mcpb:
            return " Install MCP bundle \(packageTarget(source))."
        case .nuget:
            return " Install NuGet package \(packageTarget(source))."
        case .localBinary:
            return " Install local binary \(source.identifier)."
        case .unknown:
            return " Review the MCP install source before enabling."
        }
    }

    private static func packageTarget(_ source: PluginMCPInstallSource) -> String {
        if let version = source.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            switch source.kind {
            case .pypi:
                return "\(source.identifier)==\(version)"
            default:
                return "\(source.identifier)@\(version)"
            }
        }
        if let digest = source.digest?.trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty {
            return "\(source.identifier)@sha256:\(digest)"
        }
        return source.identifier
    }

    private static func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
