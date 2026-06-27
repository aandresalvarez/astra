import Foundation

struct MCPInstallChatRequest: Identifiable, Equatable {
    let id = UUID()
    var intent: MCPInstallIntent
    var explicit: Bool
}

enum MCPInstallChatCommand {
    private static let commandToken = "/mcp"

    static func installRequest(input: String) -> MCPInstallChatRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower == commandToken || lower.hasPrefix(commandToken + " ") {
            let payload = String(trimmed.dropFirst(commandToken.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let intent = MCPInstallIntentParser.parse(payload) else { return nil }
            return MCPInstallChatRequest(intent: intent, explicit: true)
        }

        guard looksLikeMCPInstall(trimmed),
              let intent = MCPInstallIntentParser.parse(trimmed) else {
            return nil
        }
        return MCPInstallChatRequest(intent: intent, explicit: false)
    }

    private static func looksLikeMCPInstall(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.hasPrefix("npx ")
            || lower.hasPrefix("uvx ")
            || lower.hasPrefix("docker run ")
            || lower.hasPrefix("npm:")
            || lower.contains("\"mcpservers\"")
            || (lower.hasPrefix("https://") && lower.contains("mcp"))
            || (lower.hasPrefix("http://localhost") && lower.contains("mcp"))
    }
}
