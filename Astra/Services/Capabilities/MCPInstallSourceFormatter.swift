import Foundation
import ASTRACore

enum MCPInstallSourceFormatter {
    static func installDescription(for source: PluginMCPInstallSource) -> String {
        let target = packageTarget(for: source)
        switch source.installMode {
        case .npx:
            return "npm package \(target) with npx"
        case .uvx:
            return "PyPI package \(target) with uvx"
        case .pipx:
            return "PyPI package \(target) with pipx"
        case .dotnetTool:
            return "NuGet package \(target) with dotnet tool"
        case .dockerGateway:
            return "Docker MCP gateway target \(target)"
        case .dockerRun:
            return "Docker image \(target)"
        case .globalBinary:
            return "global binary \(target) on PATH"
        case .localBinary:
            return "local binary \(target)"
        case .remote:
            return "remote MCP server \(target)"
        case .manual:
            return "MCP source \(target) manually"
        }
    }

    private static func packageTarget(for source: PluginMCPInstallSource) -> String {
        let identifier = source.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = identifier.isEmpty ? source.identifier : identifier
        if let version = source.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            return source.kind == .pypi ? "\(base)==\(version)" : "\(base)@\(version)"
        }
        if let digest = source.digest?.trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty {
            return "\(base)@sha256:\(digest)"
        }
        return base
    }
}
