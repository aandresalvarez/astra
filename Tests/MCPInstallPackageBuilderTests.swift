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
}
