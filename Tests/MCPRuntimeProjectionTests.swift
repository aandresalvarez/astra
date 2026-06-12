import Testing
import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

// Phase 2: MCP delivery. These tests pin the projection from enabled
// capability packages to the Claude Code launch configuration — server
// resolution and governance gating, config rendering with secret-free env
// indirection, tool permission naming, preflight, and a real stdio
// handshake against the rendered config.

private func mcpTempDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeMCPContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func mcpPackage(
    id: String = "mcp-pkg",
    approved: Bool = true,
    servers: [PluginMCPServer]
) -> PluginPackage {
    var package = PluginPackage(
        id: id, name: "MCP Package", icon: "server.rack", description: "d",
        author: "a", category: "Integrations", tags: [], version: "1.0.0",
        skills: [], connectors: [], localTools: [],
        mcpServers: servers, templates: []
    )
    package.governance = approved ? .builtInApproved(riskLevel: .medium) : .localDraft()
    return package
}

private func stdioServer(
    id: String = "files",
    command: String? = "/bin/cat",
    arguments: [String] = [],
    environmentKeys: [String] = [],
    allowedTools: [String] = [],
    excludedTools: [String] = [],
    trustLevel: PluginMCPServer.TrustLevel = .medium
) -> PluginMCPServer {
    PluginMCPServer(
        id: id,
        displayName: id,
        transport: .stdio,
        command: command,
        arguments: arguments,
        environmentKeys: environmentKeys,
        allowedTools: allowedTools,
        excludedTools: excludedTools,
        trustLevel: trustLevel
    )
}

@Suite("MCP Runtime Projection")
@MainActor
struct MCPRuntimeProjectionTests {

    @Test("Enabled approved package projects its servers; draft package does not")
    func governanceGatesProjection() throws {
        let container = try makeMCPContainer()
        let workspace = Workspace(name: "MCP", primaryPath: "/tmp/mcp")
        container.mainContext.insert(workspace)
        workspace.enabledCapabilityIDs = ["approved-pkg", "draft-pkg"]

        let approved = mcpPackage(id: "approved-pkg", approved: true, servers: [stdioServer(id: "alpha")])
        let draft = mcpPackage(id: "draft-pkg", approved: false, servers: [stdioServer(id: "beta")])

        let servers = MCPRuntimeProjection.enabledServers(
            for: workspace,
            packages: [approved, draft],
            approvalRecords: []
        )
        #expect(servers.map(\.server.id) == ["alpha"])
        #expect(servers.map(\.packageID) == ["approved-pkg"])
    }

    @Test("Disabled package projects nothing")
    func disabledPackageProjectsNothing() throws {
        let container = try makeMCPContainer()
        let workspace = Workspace(name: "MCP", primaryPath: "/tmp/mcp-disabled")
        container.mainContext.insert(workspace)

        let approved = mcpPackage(id: "approved-pkg", approved: true, servers: [stdioServer(id: "alpha")])
        let servers = MCPRuntimeProjection.enabledServers(
            for: workspace,
            packages: [approved],
            approvalRecords: []
        )
        #expect(servers.isEmpty)
    }

    @Test("Duplicate server IDs across packages keep the first occurrence")
    func duplicateServerIDsDeduplicated() throws {
        let container = try makeMCPContainer()
        let workspace = Workspace(name: "MCP", primaryPath: "/tmp/mcp-dupe")
        container.mainContext.insert(workspace)
        workspace.enabledCapabilityIDs = ["a-pkg", "b-pkg"]

        let first = mcpPackage(id: "a-pkg", servers: [stdioServer(id: "shared")])
        let second = mcpPackage(id: "b-pkg", servers: [stdioServer(id: "shared")])
        let servers = MCPRuntimeProjection.enabledServers(
            for: workspace,
            packages: [first, second],
            approvalRecords: []
        )
        #expect(servers.count == 1)
        #expect(servers[0].packageID == "a-pkg")
    }

    @Test("Claude config renders stdio command, args, and secret-free env indirection")
    func claudeConfigRendersStdio() throws {
        let server = stdioServer(
            id: "files",
            command: "/usr/local/bin/mcp-files",
            arguments: ["--root", "."],
            environmentKeys: ["FILES_TOKEN"]
        )
        let data = try #require(MCPRuntimeProjection.claudeConfigJSON(
            servers: [.init(packageID: "p", server: server)]
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serversDict = try #require(object["mcpServers"] as? [String: Any])
        let entry = try #require(serversDict["files"] as? [String: Any])
        #expect(entry["type"] as? String == "stdio")
        #expect(entry["command"] as? String == "/usr/local/bin/mcp-files")
        #expect(entry["args"] as? [String] == ["--root", "."])
        let env = try #require(entry["env"] as? [String: String])
        // ${KEY} indirection: the file must never carry credential values.
        #expect(env["FILES_TOKEN"] == "${FILES_TOKEN}")
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
    }

    @Test("Claude config renders http server URL and skips command-less stdio")
    func claudeConfigRendersHTTPAndSkipsInvalid() throws {
        let http = PluginMCPServer(
            id: "remote",
            displayName: "Remote",
            transport: .http,
            url: URL(string: "https://mcp.example.com/v1")
        )
        let broken = stdioServer(id: "broken", command: nil)
        let data = try #require(MCPRuntimeProjection.claudeConfigJSON(servers: [
            .init(packageID: "p", server: http),
            .init(packageID: "p", server: broken)
        ]))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serversDict = try #require(object["mcpServers"] as? [String: Any])
        #expect(serversDict.count == 1)
        let entry = try #require(serversDict["remote"] as? [String: Any])
        #expect(entry["type"] as? String == "http")
        #expect(entry["url"] as? String == "https://mcp.example.com/v1")
    }

    @Test("Empty server set renders no config and writes no file")
    func emptyServersRenderNothing() {
        #expect(MCPRuntimeProjection.claudeConfigJSON(servers: []) == nil)
        #expect(MCPRuntimeProjection.writeClaudeConfig(servers: [], taskID: UUID()) == nil)
    }

    @Test("Tool permissions use server wildcard or per-tool names; exclusions become denies")
    func toolPermissionNaming() {
        let open = MCPRuntimeProjection.ResolvedServer(
            packageID: "p", server: stdioServer(id: "open")
        )
        let scoped = MCPRuntimeProjection.ResolvedServer(
            packageID: "p",
            server: stdioServer(id: "scoped", allowedTools: ["read", "list"], excludedTools: ["delete"])
        )
        #expect(MCPRuntimeProjection.allowedToolPermissions(servers: [open]) == ["mcp__open"])
        #expect(MCPRuntimeProjection.allowedToolPermissions(servers: [scoped]) == ["mcp__scoped__read", "mcp__scoped__list"])
        #expect(MCPRuntimeProjection.deniedToolPermissions(servers: [open, scoped]) == ["mcp__scoped__delete"])
    }

    @Test("Preflight flags missing stdio executables and passes resolvable ones")
    func preflightChecksExecutables() {
        let present = MCPRuntimeProjection.ResolvedServer(
            packageID: "p", server: stdioServer(id: "present", command: "/bin/cat")
        )
        let absolute = MCPRuntimeProjection.ResolvedServer(
            packageID: "p", server: stdioServer(id: "gone", command: "/nonexistent/mcp-server")
        )
        let named = MCPRuntimeProjection.ResolvedServer(
            packageID: "p", server: stdioServer(id: "named", command: "definitely-not-a-binary")
        )
        let http = MCPRuntimeProjection.ResolvedServer(
            packageID: "p",
            server: PluginMCPServer(id: "web", displayName: "web", transport: .http, url: URL(string: "https://x.example"))
        )
        let issues = MCPRuntimeProjection.preflightIssues(
            servers: [present, absolute, named, http],
            detectExecutable: { _ in "" }
        )
        #expect(issues == [
            .missingExecutable(serverID: "gone", command: "/nonexistent/mcp-server"),
            .missingExecutable(serverID: "named", command: "definitely-not-a-binary")
        ])
    }

    @Test("Rendered stdio config launches a server that completes an MCP initialize handshake")
    func renderedConfigHandshake() throws {
        let root = try mcpTempDirectory(named: "astra-mcp-handshake")
        defer { try? FileManager.default.removeItem(at: root) }

        // Stub MCP server: answers one JSON-RPC initialize request on stdio.
        let stub = root.appendingPathComponent("stub-mcp.sh")
        try """
        #!/bin/bash
        read -r line
        id=$(echo "$line" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"stub","version":"%s"}}}\\n' "$id" "$STUB_MARKER"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let server = stdioServer(id: "stub", command: stub.path, environmentKeys: ["STUB_MARKER"])
        let configURL = try #require(MCPRuntimeProjection.writeClaudeConfig(
            servers: [.init(packageID: "p", server: server)],
            taskID: UUID()
        ))
        defer { try? FileManager.default.removeItem(at: configURL) }

        // Launch the server exactly as the rendered config instructs,
        // expanding ${KEY} env indirection the way the runtime would.
        let configData = try Data(contentsOf: configURL)
        let object = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let entry = try #require((object["mcpServers"] as? [String: Any])?["stub"] as? [String: Any])
        let command = try #require(entry["command"] as? String)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = (entry["args"] as? [String]) ?? []
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in (entry["env"] as? [String: String]) ?? [:] {
            let expanded = value.hasPrefix("${") && value.hasSuffix("}")
                ? String(value.dropFirst(2).dropLast(1))
                : value
            environment[key] = key == expanded ? "marker-42" : value
        }
        process.environment = environment

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"astra-test","version":"1.0"}}}"# + "\n"
        stdin.fileHandleForWriting.write(Data(request.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let firstLine = try #require(output.split(separator: "\n").first)
        let response = try #require(JSONSerialization.jsonObject(
            with: Data(firstLine.utf8)
        ) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "stub")
        // The env indirection round-tripped from process environment.
        #expect(serverInfo["version"] as? String == "marker-42")
    }
}

@Suite("MCP Runtime Parity")
@MainActor
struct MCPRuntimeParityTests {

    @Test("Claude Code is the only runtime declaring MCP support today")
    func claudeDeclaresMCPSupport() {
        let descriptors = CapabilityRuntimeSupportPresentation.allRuntimeDescriptors()
        let supporting = CapabilityRuntimeSupportPresentation.mcpSupportingRuntimes(descriptors: descriptors)
        #expect(supporting.map(\.id) == [.claudeCode])
    }

    @Test("Catalog subtitle names the delivering runtimes")
    func catalogSubtitleNamesRuntimes() {
        let subtitle = CapabilityRuntimeSupportPresentation.mcpSupportSubtitle()
        #expect(subtitle.contains("Claude Code"))
        #expect(subtitle.contains("skip"))
    }

    @Test("MCP-only package counts as having runtime payload")
    func mcpOnlyPackageHasPayload() throws {
        let package = mcpPackage(servers: [stdioServer(id: "solo")])
        #expect(package.contentSummary == "1 MCP server")
        #expect(!package.requiresSetup)
    }

    @Test("MCP-only package enables, projects, and disables cleanly")
    func mcpOnlyPackageLifecycle() throws {
        let root = try mcpTempDirectory(named: "astra-mcp-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let container = try makeMCPContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "MCP Lifecycle", primaryPath: root.path)
        context.insert(workspace)

        let package = mcpPackage(id: "mcp-only", servers: [stdioServer(id: "solo")])
        let installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        _ = try installer.install(package, into: workspace, modelContext: context)

        #expect(workspace.enabledCapabilityIDs.contains("mcp-only"))
        let projected = MCPRuntimeProjection.enabledServers(
            for: workspace,
            packages: [package],
            approvalRecords: []
        )
        #expect(projected.map(\.server.id) == ["solo"])

        let capabilities = WorkspaceCapabilities(workspace: workspace)
        CapabilityActivationDisabler().disable(
            package,
            in: workspace,
            capabilities: capabilities,
            modelContext: context,
            availablePackages: [package]
        )
        #expect(!workspace.enabledCapabilityIDs.contains("mcp-only"))
        #expect(MCPRuntimeProjection.enabledServers(
            for: workspace,
            packages: [package],
            approvalRecords: []
        ).isEmpty)
    }
}
