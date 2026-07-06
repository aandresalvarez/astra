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

    static func resolvedServer(
        for task: AgentTask,
        contextText: String
    ) -> MCPRuntimeProjection.ResolvedServer? {
        guard TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) else {
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
