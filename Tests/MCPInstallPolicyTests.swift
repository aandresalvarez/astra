import Testing
@testable import ASTRA

@Suite("MCP Install Policy")
struct MCPInstallPolicyTests {
    @Test("exact npm version is allowed with review")
    func exactNPMVersionAllowedWithReview() throws {
        let intent = try #require(MCPInstallIntentParser.parse("npx -y @acme/mcp-server@1.2.3"))
        let decision = MCPInstallPolicy.decision(for: intent)

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.isEmpty)
        #expect(decision.riskLevel == .high)
        #expect(decision.summary.contains("@acme/mcp-server"))
    }

    @Test("latest npm package warns because it is mutable")
    func latestNPMPackageWarns() throws {
        let intent = try #require(MCPInstallIntentParser.parse("npx -y @acme/mcp-server@latest"))
        let decision = MCPInstallPolicy.decision(for: intent)

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.contains { $0.contains("mutable") })
        #expect(decision.riskLevel == .restricted)
    }

    @Test("versionless pypi package warns because it is mutable")
    func versionlessPyPIPackageWarns() throws {
        let intent = try #require(MCPInstallIntentParser.parse("uvx mcp-server-acme"))
        let decision = MCPInstallPolicy.decision(for: intent)

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.contains { $0.contains("PyPI") && $0.contains("mutable") })
        #expect(decision.riskLevel == .restricted)
    }

    @Test("remote http non-loopback is blocked")
    func remoteHTTPNonLoopbackBlocked() throws {
        let intent = try #require(MCPInstallIntentParser.parse("http://example.com/mcp"))
        let decision = MCPInstallPolicy.decision(for: intent)

        #expect(decision.blockers.contains { $0.contains("HTTPS") })
    }

    @Test("docker untagged image warns")
    func dockerUntaggedImageWarns() throws {
        let intent = try #require(MCPInstallIntentParser.parse("docker run --rm -i ghcr.io/acme/mcp-server"))
        let decision = MCPInstallPolicy.decision(for: intent)

        #expect(decision.blockers.isEmpty)
        #expect(decision.warnings.contains { $0.contains("tag or digest") })
    }
}
