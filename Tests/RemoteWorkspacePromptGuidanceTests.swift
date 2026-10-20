import Testing
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport
@testable import ASTRA

@Suite("Remote workspace prompt guidance")
@MainActor
struct RemoteWorkspacePromptGuidanceTests {
    @Test("Prompt explains SSH aliases and bounds long-running remote work")
    func promptExplainsSSHConfigAliasesForRemoteWorkspaces() throws {
        let root = try makeRoot("single")
        defer { try? FileManager.default.removeItem(at: root) }
        SSHConnectionManager.save([
            SSHConnection(
                name: "deid-jsn-workbench",
                host: "deid-as-service-jsn",
                user: "alvaro1_stanford_edu",
                remotePath: "/home/jupyter/users/alvaro1_stanford_edu/project",
                keyPath: "~/.ssh/google_compute_engine",
                configAlias: "deid-jsn-workbench"
            )
        ], workspacePath: root.path)

        let prompt = try buildPrompt(workspaceName: "JSL", root: root, goal: "Deploy files to the remote")

        #expect(prompt.contains("Connect with: ssh deid-jsn-workbench"))
        #expect(prompt.contains("requires ~/.ssh/config"))
        #expect(prompt.contains("ProxyCommand/IAP"))
        #expect(prompt.contains("Identity file: ~/.ssh/google_compute_engine"))
        #expect(prompt.contains("prefer the alias over the raw hostname"))
        assertLongRunningCommandContract(in: prompt)
        // The base prompt is built before the render exists: no claim about
        // how to reach the server, only a pointer to the run line.
        assertNoRouteClaim(in: prompt)
        #expect(!prompt.contains("cd /home/jupyter/users/alvaro1_stanford_edu/project && <command>"))
    }

    @Test("Multiple SSH connections receive the same bounded-work contract")
    func promptDoesNotAdvertiseSSHCommandExecutionForMultipleRemoteWorkspaces() throws {
        let root = try makeRoot("multiple")
        defer { try? FileManager.default.removeItem(at: root) }
        SSHConnectionManager.save([
            SSHConnection(
                name: "dev",
                host: "dev.example.test",
                user: "agent",
                remotePath: "/srv/app",
                configAlias: "dev-box"
            ),
            SSHConnection(
                name: "staging",
                host: "staging.example.test",
                user: "agent",
                remotePath: "/srv/staging",
                configAlias: "staging-box"
            )
        ], workspacePath: root.path)

        let prompt = try buildPrompt(workspaceName: "Remote", root: root, goal: "Check the remote servers")

        #expect(prompt.contains("Available SSH Connections:"))
        #expect(prompt.contains("ssh dev-box"))
        #expect(prompt.contains("ssh staging-box"))
        assertLongRunningCommandContract(in: prompt)
        assertNoRouteClaim(in: prompt)
        #expect(!prompt.contains("via Bash with ssh"))
    }

    @Test("A native-shell route tells the run to use ssh in its shell, and nothing about host control")
    func nativeShellRoutePrompt() throws {
        let prompt = try launchPrompt(suffix: "native", route: .nativeShell)

        #expect(prompt.contains("Run remote commands with `ssh deid-jsn-workbench '<command>'` in your shell."))
        #expect(prompt.contains("`astra-host-control ssh` is not this run's route"))
        // Never advertise a tool the run was not offered.
        #expect(!prompt.contains("ASTRA host control can check SSH reachability"))
        #expect(!prompt.contains("Remote command execution requires a reviewed workspace capability"))
        assertLongRunningCommandContract(in: prompt)
    }

    @Test("A reachability-only route keeps the host-control wording")
    func brokerReachabilityRoutePrompt() throws {
        let prompt = try launchPrompt(suffix: "broker", route: .brokerReachabilityOnly)

        #expect(prompt.contains("ASTRA host control can check SSH reachability for this alias"))
        #expect(prompt.contains("Remote command execution requires a reviewed workspace capability"))
        #expect(!prompt.contains("ssh deid-jsn-workbench '<command>'"))
    }

    @Test("An unavailable route says why and offers no route", arguments: HostControlSSHRoute.UnavailableReason.allCases)
    func unavailableRoutePrompt(reason: HostControlSSHRoute.UnavailableReason) throws {
        let prompt = try launchPrompt(suffix: "unavailable-\(reason.rawValue)", route: .unavailable(reason))

        #expect(prompt.contains("SSH route for this run (resolved by ASTRA"))
        #expect(prompt.contains("This run cannot reach the remote server: "))
        #expect(!prompt.contains("ssh deid-jsn-workbench '<command>'"))
        #expect(!prompt.contains("ASTRA host control can check SSH reachability"))
    }

    @Test("The run line is authoritative over earlier task notes")
    func runGuidanceOverridesStaleNotes() {
        let route = RemoteWorkspaceSSHRoute(aliases: ["deid-jsn-workbench"], route: .nativeShell)
        let stale = "Current state: SSH is disabled for this task; do not retry."
        let prompt = RemoteWorkspaceSSHRoute.appendingRunGuidance(to: stale, route: route)

        #expect(prompt.hasPrefix(stale))
        #expect(prompt.hasSuffix(route.runGuidance))
        #expect(route.runGuidance.contains("SSH route for this run (resolved by ASTRA at launch; it overrides any earlier note in current_state.json"))
        #expect(route.runGuidance.contains("native shell. \(route.instruction)"))
        #expect(RemoteWorkspaceSSHRoute.appendingRunGuidance(to: stale, route: nil) == stale)
    }

    /// What a launch hands the provider: the built prompt plus the run line
    /// the worker appends once the render exists.
    private func launchPrompt(suffix: String, route: HostControlSSHRoute) throws -> String {
        let root = try saveSingleConnection(suffix)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try buildPrompt(workspaceName: "JSL", root: root, goal: "Check the VM")
        assertNoRouteClaim(in: base)
        return RemoteWorkspaceSSHRoute.appendingRunGuidance(
            to: base,
            route: RemoteWorkspaceSSHRoute(aliases: ["deid-jsn-workbench"], route: route)
        )
    }

    private func saveSingleConnection(_ suffix: String) throws -> URL {
        let root = try makeRoot(suffix)
        SSHConnectionManager.save([
            SSHConnection(
                name: "deid-jsn-workbench",
                host: "deid-as-service-jsn",
                user: "alvaro1_stanford_edu",
                remotePath: "/home/jupyter/project",
                configAlias: "deid-jsn-workbench"
            )
        ], workspacePath: root.path)
        return root
    }

    private func assertNoRouteClaim(in prompt: String) {
        #expect(prompt.contains(RemoteWorkspacePromptGuidance.routeReference))
        #expect(!prompt.contains("ASTRA host control can check SSH reachability"))
        #expect(!prompt.contains("Remote command execution requires a reviewed workspace capability"))
        #expect(!prompt.contains("'<command>'"))
        #expect(!prompt.contains("SSH route for this run (resolved by ASTRA"))
    }

    private func makeRoot(_ suffix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-prompt-ssh-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func buildPrompt(workspaceName: String, root: URL, goal: String) throws -> String {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let workspace = Workspace(name: workspaceName, primaryPath: root.path)
        context.insert(workspace)
        let task = AgentTask(title: "Remote work", goal: goal, workspace: workspace)
        context.insert(task)
        try context.save()
        return AgentPromptBuilder.buildPrompt(for: task)
    }

    private func assertLongRunningCommandContract(in prompt: String) {
        #expect(prompt.contains("only launch multi-hour remote work when a reviewed workspace capability explicitly authorizes remote execution"))
        #expect(prompt.contains("Launch it detached with file-backed logs or status files"))
        #expect(prompt.contains("never hold a tool call open with `sleep` or an internal polling loop"))
        #expect(prompt.contains("Do not replace a long wait with rapid repeated checks"))
        #expect(prompt.contains("Return the durable external handle, latest verified status, and recovery paths"))
        #expect(prompt.contains("Do not claim ASTRA will continue monitoring unless an explicit ASTRA operation-monitoring capability registered the job"))
        #expect(!prompt.contains("use an ASTRA routine"))
    }
}
