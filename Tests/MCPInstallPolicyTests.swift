import Foundation
import Testing
import ASTRACore
@testable import ASTRA

/// The install-source rules the package validator applies to every declared
/// MCP server (`CapabilityPackageValidator.validateMCPInstallSource`).
@Suite("MCP Install Policy")
struct MCPInstallPolicyTests {
    @Test("exact npm version is allowed with review")
    func exactNPMVersionAllowedWithReview() {
        let decision = MCPInstallPolicy.decision(for: stdio(
            "npx", ["-y", "@acme/mcp-server@1.2.3"],
            source: PluginMCPInstallSource(kind: .npm, identifier: "@acme/mcp-server", version: "1.2.3", installMode: .npx)
        ))

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.isEmpty)
        #expect(decision.riskLevel == .high)
        #expect(decision.summary.contains("@acme/mcp-server"))
    }

    @Test("latest npm package warns because it is mutable")
    func latestNPMPackageWarns() {
        let decision = MCPInstallPolicy.decision(for: stdio(
            "npx", ["-y", "@acme/mcp-server@latest"],
            source: PluginMCPInstallSource(kind: .npm, identifier: "@acme/mcp-server", version: "latest", installMode: .npx)
        ))

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.contains { $0.contains("mutable") })
        #expect(decision.riskLevel == .restricted)
    }

    @Test("versionless pypi package warns because it is mutable")
    func versionlessPyPIPackageWarns() {
        let decision = MCPInstallPolicy.decision(for: stdio(
            "uvx", ["mcp-server-acme"],
            source: PluginMCPInstallSource(kind: .pypi, identifier: "mcp-server-acme", installMode: .uvx)
        ))

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.contains { $0.contains("PyPI") && $0.contains("mutable") })
        #expect(decision.riskLevel == .restricted)
    }

    @Test("remote http non-loopback is blocked")
    func remoteHTTPNonLoopbackBlocked() {
        let url = URL(string: "http://example.com/mcp")!
        let decision = MCPInstallPolicy.decision(for: MCPInstallIntent(
            serverID: "example", displayName: nil,
            transport: .http, command: nil, arguments: [], url: url,
            installSource: PluginMCPInstallSource(kind: .remoteHTTP, identifier: url.absoluteString, installMode: .remote)
        ))

        #expect(decision.blockers.contains { $0.contains("HTTPS") })
    }

    @Test("docker untagged image warns")
    func dockerUntaggedImageWarns() {
        let decision = MCPInstallPolicy.decision(for: stdio(
            "docker", ["run", "--rm", "-i", "ghcr.io/acme/mcp-server"],
            source: PluginMCPInstallSource(kind: .dockerImage, identifier: "ghcr.io/acme/mcp-server", installMode: .dockerRun)
        ))

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.contains { $0.contains("tag or digest") })
    }

    @Test("shell syntax in a launch command is blocked")
    func shellSyntaxBlocked() {
        let decision = MCPInstallPolicy.decision(for: stdio("npx", ["-y", "pkg;", "rm", "-rf", "/"], source: nil))

        #expect(decision.blockers.contains { $0.contains("not safe") })
    }

    private func stdio(_ command: String, _ arguments: [String], source: PluginMCPInstallSource?) -> MCPInstallIntent {
        MCPInstallIntent(
            serverID: source?.identifier ?? "mcp", displayName: nil, transport: .stdio,
            command: command, arguments: arguments, url: nil, installSource: source
        )
    }
}
