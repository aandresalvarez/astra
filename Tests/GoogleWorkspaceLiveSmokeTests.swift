import Foundation
import Testing
@testable import ASTRA
@testable import MCPGatewaySupport

@Suite("Google Workspace Live Smoke")
struct GoogleWorkspaceLiveSmokeTests {
    @Test(
        "opt-in live Gmail MCP tools/list smoke",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_GOOGLE_WORKSPACE_LIVE_SMOKE"] == "1")
    )
    func liveGmailToolsListSmoke() throws {
        _ = try GoogleOAuthConfiguration.load()
        let accessToken = try #require(ProcessInfo.processInfo.environment["ASTRA_GOOGLE_WORKSPACE_LIVE_ACCESS_TOKEN"])
        let product = try #require(GoogleWorkspaceRemoteMCPRegistry.product(.gmail))
        let client = RemoteMCPHTTPClient()
        let server = RemoteMCPServerDescriptor(
            id: product.serverID,
            displayName: product.displayName,
            transport: .http,
            endpoint: product.endpoint,
            connectorBindings: ["google-workspace"]
        )

        let tools = try client.listTools(for: server, auth: .init(authorizationHeader: "Bearer \(accessToken)"))

        #expect(!tools.isEmpty)
        #expect(!String(describing: tools).contains(accessToken))
    }
}
