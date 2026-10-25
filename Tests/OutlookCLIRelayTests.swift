import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Outlook typed relay routes")
struct OutlookCLIRelayTests {
    @Test("Every typed mail read crosses the relay shell policy", arguments: [
        "astra-host-control mail accounts",
        "astra-host-control mail folders --account mailbox --limit 10",
        "astra-host-control mail search --account mailbox --query 'project protocol' --limit 5",
        "astra-host-control mail get --account mailbox --message-id 'encoded/id+value'"
    ])
    func readCommandsAreAdmitted(command: String) {
        let manifest = runtimePolicyManifest(allowedTools: ["Read"], askFirstTools: ["Bash"],
            deniedTools: ["Bash"], allowedShellPatterns: [HostControlCLIRelayPolicy.manifestMarker],
            deniedShellPatterns: ["*"], providerID: .cursorCLI)
        #expect(HostControlCLIRelayPolicy.allows(command))
        #expect(AgentRuntimePolicyGuard(manifest: manifest).disposition(toolName: "Bash", command: command) == .allowed)
        #expect(!HostControlCLIRelayPolicy.isTypedExternalAction(command))
    }

    @Test("The relay refuses writes, alternate authority and shell composition", arguments: [
        "astra-host-control mail send --account mailbox",
        "astra-host-control mail folders --keychain-service other",
        "astra-host-control mail folders --url https://other.example",
        "astra-host-control mail accounts --account other",
        "astra-host-control mail folders --limit 0",
        "astra-host-control mail accounts && env",
        "astra-host-control mail accounts | cat",
        "astra-host-control mail search --query $(env)"
    ])
    func invalidCommandsAreRefused(command: String) {
        #expect(!HostControlCLIRelayPolicy.allows(command))
    }

    @Test("Line breaks cannot hide a second command inside a typed relay", arguments: ["\n", "\r", "\r\n"])
    func lineBreaksAreRejectedByActualGuard(separator: String) {
        let manifest = runtimePolicyManifest(allowedTools: ["Read"], askFirstTools: ["Bash"],
            deniedTools: ["Bash"], allowedShellPatterns: [HostControlCLIRelayPolicy.manifestMarker],
            deniedShellPatterns: ["*"], providerID: .cursorCLI)
        let guardUnderTest = AgentRuntimePolicyGuard(manifest: manifest)
        for command in ["astra-host-control mail search --query" + separator + "id",
                        "astra-host-control github -- pr list" + separator + "id",
                        "astra-host-control mail search --query 'literal" + separator + "text'"] {
            #expect(!HostControlCLIRelayPolicy.allows(command))
            #expect(guardUnderTest.disposition(toolName: "Bash", command: command) == .denied)
        }
    }

    @Test("Narrated and offered mail prompts name the actual typed route", arguments: [false, true])
    func mailPromptUsesValidOperation(narrated: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let account = Connector(name: "Mailbox Alpha")
        account.applyStanfordOutlookDefaults()
        account.workspace = env.workspace
        let task = AgentTask(title: "Task", goal: narrated ? "Read Mailbox Alpha inbox" : "Bake a chocolate cake", workspace: env.workspace)
        env.context.insert(account)
        env.context.insert(task)
        try env.context.save()
        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: task.goal).providerLaunch
        #expect(scope.connectors.contains { $0.id == account.id } == narrated)
        for runtime in [AgentRuntimeID.cursorCLI, .claudeCode] {
            let section = try #require(AgentPromptConnectorContextBuilder.section(from: scope, task: task,
                runtime: runtime, runtimeCapabilityProfile: .defaultProfile(for: runtime)))
            if runtime == .cursorCLI {
                let command = "astra-host-control mail folders --account " + account.id.uuidString
                #expect(section.text.contains(command))
                #expect(HostControlCLIRelayPolicy.allows(command))
            } else {
                #expect(section.text.contains("mcp__astra_host__mail"))
                #expect(section.text.contains(#""operation":"folders","account":""# + account.id.uuidString))
            }
            #expect(!section.text.contains("--operation status"))
            #expect(!section.text.contains("ASTRA_MAIL_REGISTRY_PATH"))
        }
    }
}
