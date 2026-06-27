import Testing
@testable import ASTRA
import ASTRACore

@Suite("CapabilityHealthService")
struct CapabilityHealthServiceTests {
    @Test("unauthenticated prerequisite creates actionable health issue")
    func unauthenticatedPrerequisiteCreatesActionableHealthIssue() {
        let prerequisite = CLIPrerequisite(
            binary: "example-cli",
            livenessArgs: ["auth", "status"],
            displayName: "Example login",
            purpose: "Authenticate example CLI.",
            installHint: "Install example-cli.",
            authHint: "Run `example-cli auth login`."
        )
        let package = PluginPackage(
            id: "example-workflow",
            name: "Example Workflow",
            icon: "terminal",
            description: "Example CLI-backed workflow",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let issues = CapabilityHealthService.prerequisiteIssues(
            for: package,
            statuses: [prerequisite.id: .unauthenticated(detail: "not logged in")]
        )

        #expect(issues.map(\.kind) == [.unauthenticated])
        #expect(issues.first?.resourceName == "Example login")
        #expect(issues.first?.message.contains("Run `example-cli auth login`.") == true)
    }

    @Test("healthy prerequisites do not create health issues")
    func healthyPrerequisitesDoNotCreateHealthIssues() {
        let prerequisite = CommonCLIPrerequisites.githubAuth
        let package = PluginPackage(
            id: "healthy-workflow",
            name: "Healthy Workflow",
            icon: "checkmark.circle",
            description: "Healthy package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            prerequisites: [prerequisite],
            governance: .builtInApproved()
        )

        let issues = CapabilityHealthService.prerequisiteIssues(
            for: package,
            statuses: [prerequisite.id: .healthy(path: "/opt/bin/gh", version: "ok")]
        )

        #expect(issues.isEmpty)
    }

    @Test("readiness messages include supplied MCP command status")
    func readinessMessagesIncludeSuppliedMCPCommandStatus() {
        let package = PluginPackage(
            id: "mcp-workflow",
            name: "MCP Workflow",
            icon: "server.rack",
            description: "MCP workflow",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [
                PluginMCPServer(
                    id: "github",
                    displayName: "GitHub MCP",
                    transport: .stdio,
                    command: "github-mcp-server"
                )
            ],
            templates: [],
            governance: .builtInApproved()
        )

        let messages = CapabilityHealthService.readinessMessages(
            for: package,
            statuses: ["github-mcp-server": .missingBinary]
        )

        #expect(messages == ["GitHub MCP: command github-mcp-server is not installed."])
    }
}
