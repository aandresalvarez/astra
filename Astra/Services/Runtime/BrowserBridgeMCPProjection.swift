import Foundation
import ASTRACore
import ASTRAModels

enum BrowserBridgeMCPProjection {
    static let serverID = "astra_browser"
    static let toolName = "browser"
    static let providerToolPermission = "mcp__\(serverID)__\(toolName)"

    static let environmentKeys = [
        "ASTRA_BROWSER_URL",
        "ASTRA_BROWSER_TOKEN",
        "ASTRA_BROWSER_DEBUG_CAPTURE",
        "ASTRA_BROWSER_REQUIRED_ENGINE"
    ]

    /// The launch environment is the ground truth for whether this run carries
    /// the bridge. `ASTRA_BROWSER_URL` is injected from the *reachable* set, so
    /// a turn whose wording never named the browser still gets the endpoint —
    /// and deciding the server from turn text alone leaves that run holding an
    /// endpoint with no transport to reach it. On a runtime with no shell,
    /// `BrowserBridgeRuntimeLaunchGuard` then aborts a turn that never asked for
    /// a browser. Offered routes attach where the transport can carry them.
    static func resolvedServer(
        for task: AgentTask,
        contextText: String,
        taskEnvironment: [String: String] = [:]
    ) -> MCPRuntimeProjection.ResolvedServer? {
        guard BrowserBridgeRuntimeLaunchGuard.isBrowserBridgeAttached(environment: taskEnvironment)
            || TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) else {
            return nil
        }
        return MCPRuntimeProjection.ResolvedServer(
            packageID: "astra-builtin",
            server: PluginMCPServer(
                id: serverID,
                displayName: "ASTRA Browser",
                transport: .stdio,
                command: astraBrowserToolPath(),
                arguments: ["mcp"],
                environmentKeys: environmentKeys,
                allowedTools: [toolName],
                trustLevel: .high
            ),
            permittedEnvironmentKeys: Set(environmentKeys)
        )
    }

    private static func astraBrowserToolPath() -> String {
        (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent("astra-browser")
    }
}
