import Foundation
import Testing
@testable import HostControlToolSupport

/// Schema timeout contracts are kept together without growing the process,
/// output-redaction and credential tests in the original suite file.
extension HostControlToolSupportTests {
    @Test("Host control tool schemas describe the configured timeout cap")
    func hostControlToolSchemasDescribeConfiguredTimeoutCap() throws {
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: 42, outputByteLimit: 1024)
        )

        let list = try schemaJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        for tool in tools {
            let inputSchema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            if ["history", "mail"].contains(tool["name"] as? String ?? "") {
                // App-owned reads have fixed deadlines; callers cannot extend them.
                #expect(properties["timeout_seconds"] == nil)
                continue
            }
            let timeout = try #require(properties["timeout_seconds"] as? [String: Any])
            let description = try #require(timeout["description"] as? String)
            #expect(description.contains("Defaults to 42 seconds"))
            #expect(description.contains("capped at 42 seconds"))
            #expect(!description.contains("Defaults to 120 seconds"))
            #expect(!description.contains("300 seconds"))
        }
    }

    @Test("Host control tool schemas never describe non-finite timeout caps")
    func hostControlToolSchemasNeverDescribeNonFiniteTimeoutCaps() throws {
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: .nan, outputByteLimit: 1024)
        )

        let list = try schemaJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        for tool in tools {
            let inputSchema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            if ["history", "mail"].contains(tool["name"] as? String ?? "") {
                // App-owned reads have fixed deadlines; callers cannot extend them.
                #expect(properties["timeout_seconds"] == nil)
                continue
            }
            let timeout = try #require(properties["timeout_seconds"] as? [String: Any])
            let description = try #require(timeout["description"] as? String)
            #expect(description.contains("capped at 300 seconds"))
            #expect(!description.lowercased().contains("nan"))
        }
    }

    @Test("Host control tool schemas never describe huge finite timeout caps")
    func hostControlToolSchemasNeverDescribeHugeFiniteTimeoutCaps() throws {
        let server = HostControlMCPServer(
            configuration: HostControlToolConfiguration(githubExecutable: "/usr/bin/gh"),
            processLimits: HostControlProcessLimits(maximumTimeoutSeconds: .greatestFiniteMagnitude, outputByteLimit: 1024)
        )

        let list = try schemaJSON(try #require(server.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)))
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        for tool in tools {
            let inputSchema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            if ["history", "mail"].contains(tool["name"] as? String ?? "") {
                // App-owned reads have fixed deadlines; callers cannot extend them.
                #expect(properties["timeout_seconds"] == nil)
                continue
            }
            let timeout = try #require(properties["timeout_seconds"] as? [String: Any])
            let description = try #require(timeout["description"] as? String)
            #expect(description.contains("capped at 86400 seconds"))
            #expect(!description.lowercased().contains("inf"))
            #expect(!description.lowercased().contains("nan"))
        }
    }

    private func schemaJSON(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
