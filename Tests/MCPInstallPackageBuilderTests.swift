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

    @Test("a docker run server checks the Docker daemon, not just the client")
    func dockerServerChecksTheDaemon() async throws {
        let json = """
        {"mcpServers": {"github": {"type": "stdio", "command": "docker", "args": ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"]}}}
        """
        let intent = try #require(MCPInstallIntentParser.parse(json))
        let package = try MCPInstallPackageBuilder.package(from: intent)
        let prerequisite = try #require(package.prerequisites.first)
        #expect(prerequisite.binary == "docker")
        #expect(prerequisite.livenessArgs == CommonCLIPrerequisites.docker.livenessArgs)
        #expect(prerequisite.semantic == .stderrNoDaemonError)
        #expect(prerequisite.id == CommonCLIPrerequisites.docker.id)
        #expect(HealthCheckPolicy.isReadOnly(binary: prerequisite.binary, arguments: prerequisite.livenessArgs))
        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
        #expect(report.blockers.isEmpty)
        // With Docker Desktop stopped the client still answers; the check fails.
        let stub = StubBinaryRunner()
        await stub.setResponse(forKey: "/usr/bin/env which docker", result: .exited(code: 0, stdout: "/usr/local/bin/docker\n", stderr: ""))
        await stub.setResponse(
            forKey: "/usr/local/bin/docker version --format {{.Client.Version}}",
            result: .exited(code: 0, stdout: "27.0.0\n", stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
        )
        let status = await EnvironmentHealthChecker(runner: stub, fallbackDirectories: []).check(
            binary: prerequisite.binary, livenessArgs: prerequisite.livenessArgs, semantic: prerequisite.semantic
        )
        #expect(!status.isUsable)
    }

    @Test("an unknown server command is only found, never run; a missing one is a pending step")
    func unknownServerCommandIsFoundNotRun() async throws {
        let json = """
        {"mcpServers": {"acme": {"type": "stdio", "command": "acme-mcp", "args": ["serve"]}}}
        """
        let intent = try #require(MCPInstallIntentParser.parse(json))
        let package = try MCPInstallPackageBuilder.package(from: intent)
        // `acme-mcp --version` would run unasked on every scan: no arguments, found only.
        let prerequisite = try #require(package.prerequisites.first)
        #expect(prerequisite.binary == "acme-mcp")
        #expect(prerequisite.livenessArgs.isEmpty)
        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
        #expect(!report.blockers.contains { $0.title == "Unsafe health check" })
        // Found: usable, and the binary never started. Missing: pending.
        let stub = StubBinaryRunner()
        await stub.setResponse(forKey: "/usr/bin/env which acme-mcp", result: .exited(code: 0, stdout: "/usr/local/bin/acme-mcp\n", stderr: ""))
        let found = await EnvironmentHealthChecker(runner: stub, fallbackDirectories: []).check(binary: "acme-mcp", livenessArgs: [])
        #expect(found.isUsable)
        #expect(await stub.recordedCalls().map(\.args) == [["which", "acme-mcp"]])
        let missing = await EnvironmentHealthChecker(runner: StubBinaryRunner(), fallbackDirectories: []).check(binary: "acme-mcp", livenessArgs: [])
        #expect(missing == .missingBinary)
        #expect(PluginsSurfacePresentation.pendingSetupChecks(for: package, statuses: [prerequisite.id: missing]) == 1)
        // A relative path is neither found nor run.
        #expect(!HealthCheckPolicy.isExistenceOnly(binary: "./acme-mcp", arguments: []))
        #expect(!HealthCheckPolicy.isExistenceOnly(binary: "acme-mcp", arguments: ["serve"]))
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
