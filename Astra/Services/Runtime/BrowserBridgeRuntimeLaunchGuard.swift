import Foundation
import ASTRACore

struct BrowserBridgeRuntimeLaunchMetadata: Equatable {
    let isAttached: Bool
    let shellToolSupported: Bool
    let mcpToolSupported: Bool
    let launchBlockReason: String

    var commandPlannedFields: [String: String] {
        [
            "browser_bridge_attached": String(isAttached),
            "browser_bridge_shell_tool_supported": String(shellToolSupported),
            "browser_bridge_mcp_tool_supported": String(mcpToolSupported),
            "browser_bridge_tool_transport": toolTransport,
            "browser_bridge_launch_block_reason": launchBlockReason
        ]
    }

    private var toolTransport: String {
        guard isAttached else { return "none" }
        if mcpToolSupported { return "mcp" }
        if shellToolSupported { return "cli" }
        return "unsupported"
    }
}

enum BrowserBridgeRuntimeLaunchGuard {
    static let missingBrowserControlToolReason = "provider_missing_browser_control_tool"

    static func planMetadata(
        runtime: AgentRuntimeID,
        environment: [String: String],
        mcpToolSupported: Bool = false
    ) -> BrowserBridgeRuntimeLaunchMetadata {
        let isAttached = isBrowserBridgeAttached(environment: environment)
        let shellToolSupported = supportsShellToolForBrowserBridge(runtime: runtime)
        let launchSupported = shellToolSupported || mcpToolSupported
        return BrowserBridgeRuntimeLaunchMetadata(
            isAttached: isAttached,
            shellToolSupported: shellToolSupported,
            mcpToolSupported: mcpToolSupported,
            launchBlockReason: isAttached && !launchSupported ? missingBrowserControlToolReason : "none"
        )
    }

    static func isBrowserBridgeAttached(environment: [String: String]) -> Bool {
        environment["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func launchBlock(for plan: AgentRuntimeProcessLaunchPlan) -> AgentProcessResult? {
        guard isBrowserBridgeAttached(environment: plan.environment),
              plan.commandPlannedFields["browser_bridge_launch_block_reason"] == missingBrowserControlToolReason else {
            return nil
        }

        let message = """
        ASTRA blocked this browser task before launch because \(plan.runtime.displayName) cannot access a browser-control transport from the task. The browser bridge requires either a provider runtime with a shell/Bash execution tool or a provider-native ASTRA browser MCP tool. Switch this task to a runtime that supports one of those transports, such as Claude Code or Codex CLI, then retry.
        """
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: missingBrowserControlToolReason,
            runtimeStopMessage: message
        )
    }

    static func transcriptStop(from event: ParsedEvent) -> (reason: String, message: String)? {
        guard let content = transcriptContent(from: event),
              transcriptIndicatesMissingShellTool(content) else {
            return nil
        }
        return (
            missingBrowserControlToolReason,
            "ASTRA stopped browser control because the selected provider reported that it cannot execute the astra-browser command: no shell/Bash execution tool is available. Switch to a shell-capable runtime, such as Claude Code or Codex CLI, then retry the browser task."
        )
    }

    private static func supportsShellToolForBrowserBridge(runtime: AgentRuntimeID) -> Bool {
        runtime != .copilotCLI
    }

    private static func transcriptContent(from event: ParsedEvent) -> String? {
        switch event {
        case .text(let text), .thinking(let text):
            return text
        case .result(let text, _, _, _, _, _, _):
            return text
        case .toolResult(_, let text):
            return text
        default:
            return nil
        }
    }

    private static func transcriptIndicatesMissingShellTool(_ content: String) -> Bool {
        let lower = content.lowercased()
        guard lower.contains("astra-browser"),
              lower.contains("bash") || lower.contains("shell") else {
            return false
        }

        return [
            "don't have a bash execution tool",
            "do not have a bash execution tool",
            "no bash execution tool",
            "without a bash execution tool",
            "don't have bash",
            "do not have bash",
            "cannot run shell commands",
            "can't run shell commands",
            "unable to run shell commands",
            "unable to execute shell commands",
            "not able to run shell commands",
            "not able to execute shell commands",
            "no shell execution tool",
            "no shell tool"
        ].contains { lower.contains($0) }
    }
}
