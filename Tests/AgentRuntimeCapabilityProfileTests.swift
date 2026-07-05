import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Runtime Capability Profile")
struct AgentRuntimeCapabilityProfileTests {
    @Test("Codex and Claude expose task-scoped MCP delivery")
    func codexAndClaudeExposeTaskScopedMCPDelivery() {
        let codex = AgentRuntimeCapabilityProfile.defaultProfile(for: .codexCLI)
        let claude = AgentRuntimeCapabilityProfile.defaultProfile(for: .claudeCode)

        #expect(codex.taskScopedMCPDelivery == .codexInlineConfig)
        #expect(codex.supportsTaskScopedMCPDelivery)
        #expect(codex.canDeliverHostControlPlaneMCP)
        #expect(codex.canDeliverDockerWorkspaceShellMCP)

        #expect(claude.taskScopedMCPDelivery == .claudeStrictConfigFile)
        #expect(claude.supportsTaskScopedMCPDelivery)
        #expect(claude.canDeliverHostControlPlaneMCP)
        #expect(claude.canDeliverDockerWorkspaceShellMCP)
    }

    @Test("Copilot MCP delivery is version observed not descriptor implied")
    func copilotMCPDeliveryIsObserved() {
        let oldCopilot = AgentRuntimeCapabilityProfile.copilotProfile(supportsAdditionalMCPConfig: false)
        let newCopilot = AgentRuntimeCapabilityProfile.copilotProfile(supportsAdditionalMCPConfig: true)

        #expect(oldCopilot.taskScopedMCPDelivery == .unsupported)
        #expect(!oldCopilot.supportsTaskScopedMCPDelivery)
        #expect(!oldCopilot.canDeliverHostControlPlaneMCP)
        #expect(!oldCopilot.canDeliverDockerWorkspaceShellMCP)

        #expect(newCopilot.taskScopedMCPDelivery == .copilotAdditionalConfigFile)
        #expect(newCopilot.supportsTaskScopedMCPDelivery)
        #expect(newCopilot.canDeliverHostControlPlaneMCP)
        #expect(newCopilot.canDeliverDockerWorkspaceShellMCP)
    }

    @Test("Copilot profile service observes installed CLI help")
    func copilotProfileServiceObservesInstalledCLIHelp() throws {
        let oldCopilot = try withTemporaryCopilotExecutable(helpText: "Usage: copilot --prompt <prompt>") { executablePath in
            AgentRuntimeCapabilityProfileService.profile(
                for: .copilotCLI,
                executablePath: executablePath
            )
        }
        let newCopilot = try withTemporaryCopilotExecutable(helpText: "Usage: copilot --additional-mcp-config <path>") { executablePath in
            AgentRuntimeCapabilityProfileService.profile(
                for: .copilotCLI,
                executablePath: executablePath
            )
        }

        #expect(oldCopilot.taskScopedMCPDelivery == .unsupported)
        #expect(!oldCopilot.canDeliverHostControlPlaneMCP)

        #expect(newCopilot.taskScopedMCPDelivery == .copilotAdditionalConfigFile)
        #expect(newCopilot.canDeliverHostControlPlaneMCP)
    }

    @Test("Cursor OpenCode and Antigravity remain unsupported until task scoped delivery exists")
    func nonProjectedRuntimesDoNotClaimTaskScopedMCP() {
        for runtime in [AgentRuntimeID.cursorCLI, .openCodeCLI, .antigravityCLI] {
            let profile = AgentRuntimeCapabilityProfile.defaultProfile(for: runtime)
            #expect(profile.taskScopedMCPDelivery == .unsupported)
            #expect(!profile.supportsTaskScopedMCPDelivery)
            #expect(!profile.canDeliverHostControlPlaneMCP)
            #expect(!profile.canDeliverDockerWorkspaceShellMCP)
        }
    }

    @Test("Provider global MCP management commands do not imply task scoped delivery")
    func providerGlobalMCPManagementDoesNotImplyTaskScopedDelivery() {
        let providerMCPManagementCommands: [(runtime: AgentRuntimeID, commands: [String])] = [
            (.cursorCLI, ["mcp list", "mcp add", "mcp remove"]),
            (.openCodeCLI, ["mcp list", "mcp add", "mcp remove"]),
            (.antigravityCLI, ["mcp list", "mcp add", "mcp remove"])
        ]

        for provider in providerMCPManagementCommands {
            let profile = AgentRuntimeCapabilityProfile.defaultProfile(for: provider.runtime)
            #expect(!provider.commands.isEmpty)
            #expect(profile.taskScopedMCPDelivery == .unsupported)
            #expect(!profile.supportsTaskScopedMCPDelivery)
            #expect(!profile.canDeliverHostControlPlaneMCP)
            #expect(!profile.canDeliverDockerWorkspaceShellMCP)
            #expect(!profile.canDeliverBrowserBridgeMCPTool)
            #expect(profile.observedEvidence == ["adapter:no-task-scoped-mcp-projection"])
        }
    }

    @Test("Browser bridge transport does not prove browser MCP was rendered")
    func browserBridgeTransportDoesNotProveBrowserMCPWasRendered() {
        let cursor = AgentRuntimeCapabilityProfile.defaultProfile(for: .cursorCLI)
        let oldCopilot = AgentRuntimeCapabilityProfile.copilotProfile(supportsAdditionalMCPConfig: false)

        #expect(!cursor.supportsTaskScopedMCPDelivery)
        #expect(!cursor.canDeliverBrowserBridgeMCPTool)
        #expect(cursor.supportsShellToolForBrowserBridge)
        #expect(cursor.canUseBrowserBridgeTransport)

        #expect(!oldCopilot.supportsTaskScopedMCPDelivery)
        #expect(!oldCopilot.supportsShellToolForBrowserBridge)
        #expect(!oldCopilot.canDeliverBrowserBridgeMCPTool)
        #expect(!oldCopilot.canUseBrowserBridgeTransport)
    }

    private func withTemporaryCopilotExecutable<T>(
        helpText: String,
        _ body: (String) throws -> T
    ) throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("copilot")
        let escapedHelpText = helpText.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s\\n' '\(escapedHelpText)'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return try body(executable.path)
    }
}
