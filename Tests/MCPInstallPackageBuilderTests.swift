import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("MCP Install Package Builder")
struct MCPInstallPackageBuilderTests {
    @Test("builds local draft package from exact npm intent")
    func buildsLocalDraftPackageFromExactNPMIntent() throws {
        let intent = try #require(MCPInstallIntentParser.parse("npx -y @acme/github-mcp@1.0.0"))
        let package = try MCPInstallPackageBuilder.package(from: intent)

        #expect(package.id == "local.mcp.acme-github-mcp")
        #expect(package.name == "github-mcp MCP")
        #expect(package.governance.approvalStatus == .draft)
        #expect(package.governance.riskLevel == .high)
        #expect(package.governance.dataAccess.contains(.workspaceFiles))
        #expect(package.governance.dataAccess.contains(.network))
        #expect(package.mcpServers.count == 1)
        #expect(package.mcpServers.first?.installSource?.identifier == "@acme/github-mcp")
        #expect(package.mcpServers.first?.command == "npx")
        #expect(package.prerequisites.first?.binary == "npx")
    }

    @Test("refuses Audity generator command instead of building runnable server")
    func refusesAudityGeneratorCommandInsteadOfBuildingRunnableServer() throws {
        let intent = try #require(MCPInstallIntentParser.parse("npx @auditynow/connect --generate"))

        do {
            _ = try MCPInstallPackageBuilder.package(from: intent)
            Issue.record("Audity generator command must require setup/import guidance, not a runnable MCP package")
        } catch MCPInstallPackageBuilder.BuildError.requiresGuidedSetup(let guidance) {
            #expect(guidance.contains("@auditynow/connect"))
            #expect(guidance.contains("--generate"))
        }
    }

    @Test("builds every server from Claude config without serializing inline env values")
    func buildsEveryServerFromClaudeConfigWithoutSerializingInlineEnvValues() throws {
        let json = """
        {
          "mcpServers": {
            "github": {
              "type": "stdio",
              "command": "npx",
              "args": ["-y", "@acme/github-mcp@1.0.0"],
              "env": {
                "GITHUB_TOKEN": "ghp_inline_secret"
              }
            },
            "linear": {
              "type": "sse",
              "url": "https://mcp.linear.app/sse"
            }
          }
        }
        """
        let intent = try #require(MCPInstallIntentParser.parse(json))
        let package = try MCPInstallPackageBuilder.package(from: intent)

        #expect(package.mcpServers.map(\.id) == ["github", "linear"])
        #expect(package.mcpServers[0].command == "npx")
        #expect(package.mcpServers[0].arguments == ["-y", "@acme/github-mcp@1.0.0"])
        #expect(package.mcpServers[0].environmentKeys == ["GITHUB_TOKEN"])
        #expect(package.mcpServers[1].transport == .sse)
        #expect(package.mcpServers[1].url?.absoluteString == "https://mcp.linear.app/sse")
        #expect(package.skills.first?.environmentKeys == ["GITHUB_TOKEN"])

        let encoded = try JSONEncoder().encode(package)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("GITHUB_TOKEN"))
        #expect(!text.contains("ghp_inline_secret"))
    }

    @Test("refuses blocked remote http intent")
    func refusesBlockedRemoteHTTPIntent() throws {
        let intent = try #require(MCPInstallIntentParser.parse("http://example.com/mcp"))

        #expect(throws: MCPInstallPackageBuilder.BuildError.self) {
            try MCPInstallPackageBuilder.package(from: intent)
        }
    }

    @Test("review package validates through capability validator")
    func reviewPackageValidatesThroughCapabilityValidator() throws {
        let intent = try #require(MCPInstallIntentParser.parse("npx -y @acme/github-mcp@1.0.0"))
        let package = try MCPInstallPackageBuilder.package(from: intent)

        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)

        #expect(report.blockers.isEmpty)
        #expect(report.package?.mcpServers.first?.installSource?.identifier == "@acme/github-mcp")
    }

    @Test("review package with imported env keys validates through capability validator")
    func reviewPackageWithImportedEnvKeysValidatesThroughCapabilityValidator() throws {
        let json = """
        {
          "mcpServers": {
            "github": {
              "type": "stdio",
              "command": "npx",
              "args": ["-y", "@acme/github-mcp@1.0.0"],
              "env": {
                "GITHUB_TOKEN": "ghp_inline_secret"
              }
            }
          }
        }
        """
        let intent = try #require(MCPInstallIntentParser.parse(json))
        let package = try MCPInstallPackageBuilder.package(from: intent)

        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)

        #expect(report.blockers.isEmpty)
        #expect(report.package?.skills.first?.environmentKeys == ["GITHUB_TOKEN"])
        #expect(report.package?.mcpServers.first?.environmentKeys == ["GITHUB_TOKEN"])
    }
}
