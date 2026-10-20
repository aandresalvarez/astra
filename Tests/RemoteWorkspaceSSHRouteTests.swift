import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

/// Task E0F780F8 (2026-10-19): a Codex Auto run in a workspace with
/// ssh-connections.json had a working shell and the task's SSH wrapper on
/// PATH, but its prompt said remote commands needed "a reviewed workspace
/// capability". It tried `astra-host-control ssh`, which the run was never
/// offered, got "ssh is not enabled for this task", and wrote "SSH is
/// disabled" into its notes for every later turn to trust. These tests pin
/// one resolved route and every reader of it.
@Suite("Remote workspace SSH route")
@MainActor
struct RemoteWorkspaceSSHRouteTests {
    private let aliases = ["deid-jsn-workbench"]

    private static let dockerEnvironment = WorkspaceExecutionEnvironment(
        id: "docker-dev",
        kind: .dockerImage,
        displayName: "Docker dev",
        image: "alpine:3.20"
    )

    private func route(
        runtime: AgentRuntimeID = .codexCLI,
        profile: AgentRuntimeCapabilityProfile? = nil,
        policy: PermissionPolicy,
        required: [String] = [],
        offered: [String]? = nil,
        environment: WorkspaceExecutionEnvironment = .host,
        sshClientAvailable: Bool = true
    ) -> HostControlSSHRoute? {
        RemoteWorkspaceSSHRoute.resolve(
            aliases: aliases,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: required,
                offeredHostControlTools: offered ?? required + ["history"],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            ),
            environment: environment,
            permissionPolicy: policy,
            runtimeCapabilityProfile: profile ?? AgentRuntimeCapabilityProfile.defaultProfile(for: runtime),
            sshClientAvailable: sshClientAvailable
        )?.route
    }

    // MARK: - Derivation

    @Test("Auto on the host gets the native shell route, with or without host tools")
    func autoGetsNativeShell() {
        #expect(route(policy: .autonomous) == .nativeShell)
        #expect(route(runtime: .claudeCode, policy: .autonomous, required: ["github"]) == .nativeShell)
        // The incident's shape: Codex on the CLI relay because the org MCP
        // policy refuses servers, with "ssh" absent from the offered set.
        let relay = AgentRuntimeCapabilityProfile.defaultProfile(
            for: .codexCLI,
            providerMCPPolicy: .serversDisabled(policyName: nil)
        )
        #expect(relay.usesHostControlCLIRelay)
        #expect(route(profile: relay, policy: .autonomous, required: ["jira"]) == .nativeShell)
    }

    @Test("Ask keeps the native route only while the render leaves the shell in place")
    func askFollowsNativeShellWithdrawal() {
        // No ASTRA host tool required: the provider shell stays, and each
        // `ssh` call is a shell command under Ask's own approval.
        #expect(route(runtime: .claudeCode, policy: .restricted) == .nativeShell)
        // A turn that routes host work through ASTRA withdraws the shell.
        #expect(route(runtime: .claudeCode, policy: .restricted, required: ["github"])
            == .unavailable(.nativeShellWithdrawn))
        // ...and falls back to the reachability check when it is offered.
        #expect(route(runtime: .claudeCode, policy: .restricted, required: ["github"], offered: ["github", "ssh"])
            == .brokerReachabilityOnly)
        // The CLI relay is a shell command, so a relay runtime keeps its shell.
        let relay = AgentRuntimeCapabilityProfile.defaultProfile(
            for: .codexCLI,
            providerMCPPolicy: .serversDisabled(policyName: nil)
        )
        #expect(route(profile: relay, policy: .restricted, required: ["github"]) == .nativeShell)
    }

    @Test("Docker never gets the native route")
    func dockerNeverGetsNativeShell() {
        let environment = Self.dockerEnvironment
        #expect(environment.isContainerized)
        #expect(route(runtime: .claudeCode, policy: .autonomous, offered: HostControlPlaneMCPProjection.toolNames,
                      environment: environment) == .brokerReachabilityOnly)
        #expect(route(runtime: .claudeCode, policy: .autonomous, offered: ["history"], environment: environment)
            == .unavailable(.dockerWorkspace))
    }

    @Test("No ssh client means no route, and no connections means no route at all")
    func missingClientOrConnections() {
        #expect(route(policy: .autonomous, sshClientAvailable: false) == .unavailable(.sshClientUnavailable))
        #expect(RemoteWorkspaceSSHRoute.resolve(
            aliases: [],
            requirements: TaskRuntimeRequirementSet(hostControlTools: [], requiresDockerWorkspaceShell: false, requiresBrowserControl: false),
            environment: .host,
            permissionPolicy: .autonomous,
            runtimeCapabilityProfile: .defaultProfile(for: .codexCLI),
            sshClientAvailable: true
        ) == nil)
    }

    @Test("The launch resolution reads the workspace's connect aliases and the shim preconditions")
    func launchResolutionReadsTaskState() throws {
        let fixture = try makeTask(goal: "Check the VM")
        defer { fixture.cleanup() }
        let resolved = try #require(RemoteWorkspaceSSHRoute.resolve(
            task: fixture.task,
            requirements: TaskRuntimeRequirementSet(hostControlTools: [], requiresDockerWorkspaceShell: false, requiresBrowserControl: false),
            environment: .host,
            permissionPolicy: .autonomous,
            runtimeCapabilityProfile: .defaultProfile(for: .codexCLI)
        ))
        #expect(resolved.aliases == ["deid-jsn-workbench", "agent@staging.example.test"])
        #expect(resolved.route == (AgentRuntimeProcessRunner.canInjectSSHShim(for: fixture.task)
            ? .nativeShell : .unavailable(.sshClientUnavailable)))
    }

    // MARK: - The route and the policy render cannot disagree

    /// The route says "native shell" exactly when the policy render leaves the
    /// provider's shell in place. Same inputs the launch hands both of them.
    @Test("The native route matches the policy render's shell withdrawal", arguments: [
        PermissionPolicy.autonomous, PermissionPolicy.restricted
    ])
    func nativeRouteMatchesPolicyRender(policy: PermissionPolicy) throws {
        let container = try makeContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "SSH render", primaryPath: "/tmp/astra-ssh-route-render")
        workspace.enabledCapabilityIDs = [package.id]
        let contextText = "Use GitHub to inspect PR metadata, issue links, and checks for this task."
        let profiles: [(AgentRuntimeID, AgentRuntimeCapabilityProfile)] = [
            (.claudeCode, .defaultProfile(for: .claudeCode)),
            (.codexCLI, .defaultProfile(for: .codexCLI)),
            (.codexCLI, .defaultProfile(for: .codexCLI, providerMCPPolicy: .serversDisabled(policyName: nil)))
        ]
        for (runtime, profile) in profiles {
            let task = AgentTask(title: "Route render", goal: contextText, workspace: workspace, runtime: runtime)
            context.insert(workspace)
            context.insert(task)
            let requirements = TaskRuntimeRequirementSet.derive(
                task: task,
                capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot.capture(
                    for: task,
                    providerLaunchContextText: contextText
                ),
                executionEnvironment: .host,
                browserBridgeRequired: false
            )
            #expect(requirements.hostControlTools.contains("github"))
            let run = TaskRun(task: task)
            context.insert(run)
            let manifest = AgentPolicyManifestService.recordPreflightManifest(
                task: task,
                run: run,
                runtime: runtime,
                model: "default",
                workspacePath: workspace.primaryPath,
                phase: .run,
                permissionPolicy: policy,
                executionPolicy: .default,
                defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                runtimeCapabilityProfile: profile,
                capabilityPackages: [package],
                contextText: contextText,
                precomputedRuntimeRequirements: requirements,
                modelContext: context
            )
            let resolved = try #require(RemoteWorkspaceSSHRoute.resolve(
                aliases: aliases,
                requirements: requirements,
                environment: .host,
                permissionPolicy: PermissionPolicy(providerMode: manifest.providerRender.permissionMode),
                runtimeCapabilityProfile: profile,
                sshClientAvailable: true
            ))
            let renderKeepsShell = !manifest.providerRender.deniedTools.contains("Bash")
            #expect((resolved.route == .nativeShell) == renderKeepsShell,
                    "\(runtime.rawValue) relay=\(profile.usesHostControlCLIRelay) policy=\(policy)")
        }
    }

    // MARK: - Broker

    @Test("The broker refusal names the route ASTRA resolved and keeps -32602")
    func brokerRefusalNamesResolvedRoute() throws {
        let resolved = RemoteWorkspaceSSHRoute(aliases: aliases, route: .nativeShell)
        // Through the same environment the app hands the broker.
        var environment = resolved.hostControlEnvironment
        environment["ASTRA_HOST_CONTROL_ALLOWED_TOOLS"] = "jira,history"
        let configuration = HostControlToolConfiguration.fromEnvironment(environment)
        #expect(configuration.sshRoute == .nativeShell)
        #expect(configuration.sshRouteAliases == aliases)

        let error = try refusal(HostControlMCPServer(configuration: configuration), tool: "ssh")
        #expect(error.code == -32602)
        #expect(error.message.hasPrefix("ssh is not enabled for this task"))
        #expect(error.message.contains("ASTRA resolved this run's SSH route as native shell"))
        #expect(error.message.contains("`ssh deid-jsn-workbench '<command>'` in your shell"))
        #expect(error.message.contains(resolved.instruction))

        let unavailable = HostControlToolConfiguration(
            sshRoute: .unavailable(.nativeShellWithdrawn),
            sshRouteAliases: aliases,
            allowedTools: ["github"]
        )
        let withdrawn = try refusal(HostControlMCPServer(configuration: unavailable), tool: "ssh")
        #expect(withdrawn.message.contains("SSH route as unavailable"))
        #expect(withdrawn.message.contains("withdraws the provider shell"))
    }

    @Test("Without a resolved route the refusal is unchanged, and other tools never quote it")
    func refusalWithoutRouteIsUnchanged() throws {
        let plain = try refusal(HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["github"])), tool: "ssh")
        #expect(plain.message == "ssh is not enabled for this task")
        let routed = HostControlToolConfiguration(sshRoute: .nativeShell, sshRouteAliases: aliases, allowedTools: ["github"])
        let gcloud = try refusal(HostControlMCPServer(configuration: routed), tool: "gcloud")
        #expect(gcloud.message == "gcloud is not enabled for this task")
        #expect(HostControlToolConfiguration.fromEnvironment([:]).sshRoute == nil)
    }

    @Test("Every route survives the wire format")
    func wireFormatRoundTrips() {
        let routes: [HostControlSSHRoute] = [.nativeShell, .brokerReachabilityOnly]
            + HostControlSSHRoute.UnavailableReason.allCases.map { .unavailable($0) }
        for route in routes {
            #expect(HostControlSSHRoute(wireValue: route.wireValue) == route)
        }
        #expect(HostControlSSHRoute(wireValue: "unavailable:made_up") == nil)
        #expect(HostControlSSHRoute(wireValue: nil) == nil)
    }

    @Test("The host-control environment carries the route, and the server is permitted to read it")
    func hostControlEnvironmentCarriesRoute() throws {
        let fixture = try makeTask(goal: "Check the VM")
        defer { fixture.cleanup() }
        let resolved = RemoteWorkspaceSSHRoute(aliases: aliases, route: .nativeShell)
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [],
            offeredHostControlTools: ["history"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
        let env = HostControlPlaneMCPProjection.environmentVariables(
            task: fixture.task,
            environment: .host,
            currentDirectory: fixture.root.path,
            runID: nil,
            precomputedRuntimeRequirements: requirements,
            sshRoute: resolved
        )
        #expect(env[HostControlSSHRoute.environmentKey] == "native_shell")
        #expect(env[HostControlSSHRoute.aliasesEnvironmentKey] == "deid-jsn-workbench")
        let server = try #require(HostControlPlaneMCPProjection.resolvedServer(
            task: fixture.task,
            environment: .host,
            currentDirectory: fixture.root.path,
            runID: nil,
            precomputedRuntimeRequirements: requirements
        ))
        #expect(server.permittedEnvironmentKeys.contains(HostControlSSHRoute.environmentKey))
        #expect(server.permittedEnvironmentKeys.contains(HostControlSSHRoute.aliasesEnvironmentKey))
    }

    // MARK: - Manifest

    @Test("The run resource manifest records the route the launch resolved")
    func manifestRecordsRoute() throws {
        let fixture = try makeTask(goal: "Check the VM")
        defer { fixture.cleanup() }
        let resolved = RemoteWorkspaceSSHRoute(aliases: aliases, route: .unavailable(.nativeShellWithdrawn))
        let plan = TaskLaunchResourceResolver.resolve(
            task: fixture.task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: "",
            contextText: "",
            workspacePath: fixture.root.path,
            executionEnvironment: .host,
            remoteSSHRoute: resolved
        )
        #expect(plan.remoteSSHRoute == resolved)
        #expect(plan.commandPlannedFields["ssh_route"] == "unavailable:native_shell_withdrawn")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(plan)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"route\":\"unavailable:native_shell_withdrawn\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TaskLaunchResourcePlan.self, from: data).remoteSSHRoute == resolved)
    }

    // MARK: - Helpers

    private func refusal(_ server: HostControlMCPServer, tool: String) throws -> (code: Int?, message: String) {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": ["alias": "deid-jsn-workbench"]]
        ]
        let line = try #require(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8))
        let reply = try #require(server.handleLine(line))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        return (error["code"] as? Int, error["message"] as? String ?? "")
    }

    private struct Fixture {
        let container: ModelContainer
        let task: AgentTask
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeTask(goal: String) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-ssh-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SSHConnectionManager.save([
            SSHConnection(
                name: "deid-jsn-workbench",
                host: "deid-as-service-jsn",
                user: "alvaro1_stanford_edu",
                remotePath: "/home/jupyter/project",
                configAlias: "deid-jsn-workbench"
            ),
            SSHConnection(name: "staging", host: "staging.example.test", user: "agent", remotePath: "/srv")
        ], workspacePath: root.path)
        let container = try makeContainer()
        let workspace = Workspace(name: "SSH route", primaryPath: root.path)
        container.mainContext.insert(workspace)
        let task = AgentTask(title: "SSH route", goal: goal, workspace: workspace, runtime: .codexCLI)
        container.mainContext.insert(task)
        try container.mainContext.save()
        return Fixture(container: container, task: task, root: root)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}
