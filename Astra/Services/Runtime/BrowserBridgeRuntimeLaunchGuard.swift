import Foundation
import ASTRACore

struct BrowserBridgeRuntimeLaunchMetadata: Equatable {
    let isAttached: Bool
    let shellToolSupported: Bool
    let launchBlockReason: String

    var commandPlannedFields: [String: String] {
        [
            "browser_bridge_attached": String(isAttached),
            "browser_bridge_shell_tool_supported": String(shellToolSupported),
            "browser_bridge_launch_block_reason": launchBlockReason
        ]
    }
}

enum BrowserBridgeRuntimeLaunchGuard {
    static let missingShellToolReason = "provider_missing_browser_shell_tool"

    static func planMetadata(
        runtime: AgentRuntimeID,
        environment: [String: String]
    ) -> BrowserBridgeRuntimeLaunchMetadata {
        let isAttached = environment["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let shellToolSupported = supportsShellToolForBrowserBridge(runtime: runtime)
        return BrowserBridgeRuntimeLaunchMetadata(
            isAttached: isAttached,
            shellToolSupported: shellToolSupported,
            launchBlockReason: isAttached && !shellToolSupported ? missingShellToolReason : "none"
        )
    }

    static func launchBlock(for plan: AgentRuntimeProcessLaunchPlan) -> AgentProcessResult? {
        guard plan.environment["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              plan.commandPlannedFields["browser_bridge_launch_block_reason"] == missingShellToolReason else {
            return nil
        }

        let message = """
        ASTRA blocked this browser task before launch because \(plan.runtime.displayName) cannot execute the astra-browser command from the task. The browser bridge requires a provider runtime with a shell/Bash execution tool. Switch this task to a shell-capable runtime, such as Claude Code or Codex CLI, then retry.
        """
        return AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: missingShellToolReason,
            runtimeStopMessage: message
        )
    }

    static func transcriptStop(from event: ParsedEvent) -> (reason: String, message: String)? {
        guard let content = transcriptContent(from: event),
              transcriptIndicatesMissingShellTool(content) else {
            return nil
        }
        return (
            missingShellToolReason,
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
