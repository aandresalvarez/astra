import Foundation

struct MCPInstallChatRequest: Identifiable, Equatable {
    let id = UUID()
    var intent: MCPInstallIntent
    var explicit: Bool
}

struct MCPInstallChatFailure: Equatable {
    var message: String
}

struct MCPInstallChatTurnOutcome: Equatable {
    var assistantMessage: String
    var request: MCPInstallChatRequest?
}

enum MCPInstallChatCommandResult: Equatable {
    case request(MCPInstallChatRequest)
    case failure(MCPInstallChatFailure)
}

enum MCPInstallChatCommand {
    private static let commandToken = "/mcp"

    static func installRequest(input: String) -> MCPInstallChatRequest? {
        guard case .request(let request) = installResult(input: input) else { return nil }
        return request
    }

    static func installResult(input: String) -> MCPInstallChatCommandResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower == commandToken || lower.hasPrefix(commandToken + " ") {
            let payload = String(trimmed.dropFirst(commandToken.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let intent = MCPInstallIntentParser.parse(payload) else {
                return .failure(parseFailure(explicit: true))
            }
            return .request(MCPInstallChatRequest(intent: intent, explicit: true))
        }

        guard looksLikeMCPInstall(trimmed) else {
            return nil
        }
        guard let intent = MCPInstallIntentParser.parse(trimmed) else {
            return .failure(parseFailure(explicit: false))
        }
        return .request(MCPInstallChatRequest(intent: intent, explicit: false))
    }

    static func installTurnOutcome(input: String, hasWorkspace: Bool) -> MCPInstallChatTurnOutcome? {
        guard let result = installResult(input: input) else { return nil }
        switch result {
        case .failure(let failure):
            return MCPInstallChatTurnOutcome(assistantMessage: failure.message, request: nil)
        case .request(let request):
            guard hasWorkspace else {
                return MCPInstallChatTurnOutcome(
                    assistantMessage: "Select a workspace first - MCP capabilities are workspace-scoped.",
                    request: nil
                )
            }
            return MCPInstallChatTurnOutcome(
                assistantMessage: "I found an MCP install target. Review it before ASTRA saves or enables anything.",
                request: request
            )
        }
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

    private static func parseFailure(explicit: Bool) -> MCPInstallChatFailure {
        let prefix = explicit ? "ASTRA could not parse that /mcp target." : "ASTRA could not parse that MCP install target."
        let supportedFormats = "Supported MCP install target formats are npx, uvx, docker run, npm: package shorthand, remote MCP URL, or mcpServers JSON."
        return MCPInstallChatFailure(
            message: "\(prefix) \(supportedFormats) For mcpServers JSON, every declared server must include either a command or a remote URL, and ASTRA imports the full set only when all entries are valid."
        )
    }
}
