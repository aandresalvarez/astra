import Foundation
import ASTRACore

struct CapabilityMCPServerDraft: Identifiable, Equatable {
    enum ValidationError: Error, Equatable {
        case invalidName(String)
        case unsafeInvocation(String)
        case missingRemoteURL
        case unsafeRemoteURL(String)
        case undeclaredEnvironmentKeys([String])
    }

    var id = UUID()
    var serverID = ""
    var displayName = ""
    var transport: PluginMCPServer.Transport = .stdio
    var command = ""
    var argumentsText = ""
    var urlText = ""
    var environmentKeysText = ""
    var connectorBindingsText = ""
    var allowedToolsText = ""
    var excludedToolsText = ""
    var resourcesEnabled = false
    var promptsEnabled = false
    var trustLevel: PluginMCPServer.TrustLevel = .medium
    var installSource: PluginMCPInstallSource?

    func makeServer(declaredEnvironmentKeys: Set<String> = []) throws -> PluginMCPServer {
        let normalizedID = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentKeys = Self.parsedList(environmentKeysText)
        let undeclaredKeys = environmentKeys.filter { !declaredEnvironmentKeys.contains($0) }
        if !undeclaredKeys.isEmpty {
            throw ValidationError.undeclaredEnvironmentKeys(undeclaredKeys.sorted())
        }

        let server = try PluginMCPServer(
            id: normalizedID,
            displayName: normalizedDisplayName.isEmpty ? normalizedID : normalizedDisplayName,
            transport: transport,
            command: normalizedCommand(),
            arguments: normalizedArguments(),
            url: normalizedURL(),
            environmentKeys: environmentKeys,
            connectorBindings: Self.parsedList(connectorBindingsText),
            allowedTools: Self.parsedList(allowedToolsText),
            excludedTools: Self.parsedList(excludedToolsText),
            resourcesEnabled: resourcesEnabled,
            promptsEnabled: promptsEnabled,
            trustLevel: trustLevel,
            installSource: installSource
        )

        if let nameReason = MCPEnvironmentKeyPolicy.invalidNameReason(server: server) {
            throw ValidationError.invalidName(nameReason)
        }
        return server
    }

    private func normalizedCommand() throws -> String? {
        guard transport == .stdio else { return nil }
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(
            command: normalized,
            arguments: normalizedArguments().joined(separator: " ")
        ) {
            throw ValidationError.unsafeInvocation(reason)
        }
        return normalized
    }

    private func normalizedArguments() -> [String] {
        guard transport == .stdio else { return [] }
        return Self.parsedLineList(argumentsText)
    }

    private func normalizedURL() throws -> URL? {
        guard transport != .stdio else { return nil }
        let normalized = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased() else {
            throw ValidationError.missingRemoteURL
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http", isLoopback(url.host) {
            return url
        }
        throw ValidationError.unsafeRemoteURL("remote MCP URLs must use HTTPS, except loopback HTTP for local development")
    }

    private static func parsedList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parsedLineList(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
