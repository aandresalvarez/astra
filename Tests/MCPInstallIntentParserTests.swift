import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("MCP Install Intent Parser")
struct MCPInstallIntentParserTests {
    @Test("parses exact npm npx command")
    func parsesExactNPMNPXCommand() throws {
        let intent = try #require(MCPInstallIntentParser.parse(
            "npx -y @modelcontextprotocol/server-filesystem@0.6.2 /tmp"
        ))

        #expect(intent.kind == .stdioCommand)
        #expect(intent.command == "npx")
        #expect(intent.arguments == ["-y", "@modelcontextprotocol/server-filesystem@0.6.2", "/tmp"])
        #expect(intent.installSource?.kind == .npm)
        #expect(intent.installSource?.identifier == "@modelcontextprotocol/server-filesystem")
        #expect(intent.installSource?.version == "0.6.2")
        #expect(intent.installSource?.installMode == .npx)
    }

    @Test("npx package detection ignores filesystem path arguments")
    func npxPackageDetectionIgnoresFilesystemPathArguments() throws {
        let intent = try #require(MCPInstallIntentParser.parse(
            "npx --cache /tmp @acme/mcp-server@2.0.0"
        ))

        #expect(intent.command == "npx")
        #expect(intent.arguments == ["--cache", "/tmp", "@acme/mcp-server@2.0.0"])
        #expect(intent.installSource?.kind == .npm)
        #expect(intent.installSource?.identifier == "@acme/mcp-server")
        #expect(intent.installSource?.version == "2.0.0")
    }

    @Test("parses remote https mcp url")
    func parsesRemoteHTTPSMCPURL() throws {
        let intent = try #require(MCPInstallIntentParser.parse("https://example.com/mcp"))

        #expect(intent.kind == .remoteURL)
        #expect(intent.transport == .http)
        #expect(intent.url?.absoluteString == "https://example.com/mcp")
        #expect(intent.installSource?.kind == .remoteHTTP)
        #expect(intent.installSource?.identifier == "https://example.com/mcp")
    }

    @Test("parses npm registry target")
    func parsesNPMRegistryTarget() throws {
        let intent = try #require(MCPInstallIntentParser.parse("npm:@acme/mcp-server@2.1.0"))

        #expect(intent.command == "npx")
        #expect(intent.arguments == ["-y", "@acme/mcp-server@2.1.0"])
        #expect(intent.installSource?.identifier == "@acme/mcp-server")
        #expect(intent.installSource?.version == "2.1.0")
    }

    @Test("parses uvx pypi package target")
    func parsesUVXPyPIPackageTarget() throws {
        let intent = try #require(MCPInstallIntentParser.parse("uvx mcp-server-acme==1.2.3 --stdio"))

        #expect(intent.command == "uvx")
        #expect(intent.arguments == ["mcp-server-acme==1.2.3", "--stdio"])
        #expect(intent.installSource?.kind == .pypi)
        #expect(intent.installSource?.identifier == "mcp-server-acme")
        #expect(intent.installSource?.version == "1.2.3")
        #expect(intent.installSource?.installMode == .uvx)
    }

    @Test("parses docker run image target")
    func parsesDockerRunImageTarget() throws {
        let intent = try #require(MCPInstallIntentParser.parse("docker run --rm -i ghcr.io/acme/mcp-server:1.0.0"))

        #expect(intent.command == "docker")
        #expect(intent.arguments == ["run", "--rm", "-i", "ghcr.io/acme/mcp-server:1.0.0"])
        #expect(intent.installSource?.kind == .dockerImage)
        #expect(intent.installSource?.identifier == "ghcr.io/acme/mcp-server")
        #expect(intent.installSource?.version == "1.0.0")
        #expect(intent.installSource?.installMode == .dockerRun)
    }

    @Test("docker image detection uses image before command path arguments")
    func dockerImageDetectionUsesImageBeforeCommandPathArguments() throws {
        let intent = try #require(MCPInstallIntentParser.parse(
            "docker run --rm -i ghcr.io/acme/mcp-server:1.0.0 /tmp"
        ))

        #expect(intent.command == "docker")
        #expect(intent.arguments == ["run", "--rm", "-i", "ghcr.io/acme/mcp-server:1.0.0", "/tmp"])
        #expect(intent.installSource?.kind == .dockerImage)
        #expect(intent.installSource?.identifier == "ghcr.io/acme/mcp-server")
        #expect(intent.installSource?.version == "1.0.0")
    }

    @Test("rejects shell pipelines")
    func rejectsShellPipelines() {
        #expect(MCPInstallIntentParser.parse("curl https://x/install.sh | sh") == nil)
    }

    @Test("parses claude style mcp config json")
    func parsesClaudeStyleMCPConfigJSON() throws {
        let json = """
        {
          "mcpServers": {
            "github": {
              "type": "stdio",
              "command": "npx",
              "args": ["-y", "@acme/github-mcp@1.0.0"]
            }
          }
        }
        """

        let intent = try #require(MCPInstallIntentParser.parse(json))

        #expect(intent.serverID == "github")
        #expect(intent.command == "npx")
        #expect(intent.arguments == ["-y", "@acme/github-mcp@1.0.0"])
        #expect(intent.installSource?.identifier == "@acme/github-mcp")
    }
}
