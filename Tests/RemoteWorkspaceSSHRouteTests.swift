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

    /// The Codex bundle task E0F780F8 ran under: no `danger-full-access`, no
    /// `approval_policy="never"`, so ASTRA asks for the approval reviewer.
    private static let reviewerBundle = CodexRequirementsPolicy(
        allowedSandboxModes: [.readOnly, .workspaceWrite],
        requiredWindowsSandbox: nil,
        allowedApprovalPolicies: ["on-request"],
        allowedApprovalsReviewers: [CodexRequirementsPolicy.automaticApprovalReviewer],
        evidence: []
    )

    /// A render shaped the way the adapters build one: Codex arguments come
    /// from `codexPermissionArguments`, the shell denials are explicit.
    private func render(
        _ runtime: AgentRuntimeID,
        _ mode: ProviderPermissionMode,
        deniedTools: [String] = [],
        deniedShellPatterns: [String] = [],
        codexRequirements: CodexRequirementsPolicy = .unconstrained
    ) -> ProviderPolicyRender {
        ProviderPolicyRender(
            providerID: runtime,
            adapterVersion: 1,
            policyLevel: mode == .autonomous ? .autonomous : .review,
            configOwnership: .generated,
            permissionMode: mode,
            allowedTools: [],
            deniedTools: deniedTools,
            allowedShellPatterns: [],
            deniedShellPatterns: deniedShellPatterns,
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: runtime == .codexCLI
                ? CodexCLIRuntime.codexPermissionArguments(policy: PermissionPolicy(providerMode: mode), requirements: codexRequirements)
                : [],
            settingsSummary: "",
            generatedConfigPreview: "",
            enforcementTiers: [],
            diagnostics: [],
            usesBroadProviderPermissions: mode == .autonomous
        )
    }

    private func route(
        _ render: ProviderPolicyRender,
        profile: AgentRuntimeCapabilityProfile? = nil,
        required: [String] = [],
        offered: [String]? = nil,
        environment: WorkspaceExecutionEnvironment = .host,
        sshClientAvailable: Bool = true
    ) -> HostControlSSHRoute? {
        RemoteWorkspaceSSHRoute.resolve(
            aliases: aliases,
            render: render,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: required,
                offeredHostControlTools: offered ?? required + ["history"],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            ),
            environment: environment,
            runtimeCapabilityProfile: profile ?? AgentRuntimeCapabilityProfile.defaultProfile(for: render.providerID),
            sshClientAvailable: sshClientAvailable
        )?.route
    }

    private var relayProfile: AgentRuntimeCapabilityProfile {
        .defaultProfile(for: .codexCLI, providerMCPPolicy: .serversDisabled(policyName: nil))
    }

    // MARK: - Derivation

    @Test("Auto on the host gets the native shell route, with or without host tools")
    func autoGetsNativeShell() {
        #expect(route(render(.codexCLI, .autonomous)) == .nativeShell)
        #expect(route(render(.claudeCode, .autonomous), required: ["github"]) == .nativeShell)
        // The incident's shape: Codex on the CLI relay because the org MCP
        // policy refuses servers, under a bundle that clamps it to
        // workspace-write with the approval reviewer, and "ssh" not offered.
        #expect(relayProfile.usesHostControlCLIRelay)
        #expect(route(render(.codexCLI, .autonomous, codexRequirements: Self.reviewerBundle),
                      profile: relayProfile, required: ["jira"]) == .nativeShell)
    }

    @Test("Ask keeps the native route only while the render leaves the shell in place")
    func askFollowsNativeShellWithdrawal() {
        // No ASTRA host tool required: the provider shell stays, and each
        // `ssh` call is a shell command under Ask's own approval.
        #expect(route(render(.claudeCode, .restricted)) == .nativeShell)
        // A turn that routes host work through ASTRA withdraws the shell.
        let withdrawn = render(.claudeCode, .restricted, deniedTools: ["Bash", "shell"])
        #expect(route(withdrawn, required: ["github"]) == .unavailable(.nativeShellWithdrawn))
        // ...and falls back to the reachability check when it is offered.
        #expect(route(withdrawn, required: ["github"], offered: ["github", "ssh"]) == .brokerReachabilityOnly)
        // The CLI relay is a shell command, so a relay runtime keeps its shell.
        #expect(route(render(.codexCLI, .restricted, codexRequirements: Self.reviewerBundle),
                      profile: relayProfile, required: ["github"]) == .nativeShell)
    }

    @Test("A policy that denies the shell, or ssh in it, never gets the native route")
    func policyShellDenialWins() {
        // Locked (or a custom rule) collapses to restricted with no host tool
        // required, so only the render's own denial says the shell is gone.
        let locked = render(.claudeCode, .restricted, deniedTools: AgentPolicy.preset(.locked).deniedTools)
        #expect(locked.deniesNativeShellOrSSH)
        #expect(route(locked) == .unavailable(.policyDeniesShell))
        #expect(route(locked, offered: ["ssh"]) == .brokerReachabilityOnly)
        for pattern in ["ssh", "ssh:*", "Bash(ssh:*)", "ssh *"] {
            #expect(route(render(.claudeCode, .autonomous, deniedShellPatterns: [pattern]))
                == .unavailable(.policyDeniesShell), "\(pattern)")
        }
        #expect(route(render(.claudeCode, .autonomous, deniedShellPatterns: ["sshpass:*", "rm:*"])) == .nativeShell)
    }

    @Test("A Codex sandbox that cannot connect never gets the native route")
    func codexSandboxNetworkDecidesNativeRoute() {
        // workspace-write with approval_policy="never": connect(2) is denied
        // and nothing can grant an escalated run.
        let sandboxed = render(.codexCLI, .restricted)
        #expect(sandboxed.cliArgumentsSummary.contains("workspace-write"))
        #expect(!sandboxed.nativeShellReachesNetwork)
        #expect(route(sandboxed) == .unavailable(.shellSandboxBlocksNetwork))
        #expect(route(sandboxed, offered: ["ssh"]) == .brokerReachabilityOnly)
        // Same sandbox, but the reviewer can approve an escalated run.
        #expect(route(render(.codexCLI, .restricted, codexRequirements: Self.reviewerBundle)) == .nativeShell)
        // Auto without a bundle bypasses the sandbox.
        #expect(render(.codexCLI, .autonomous).nativeShellReachesNetwork)
    }

    @Test("Docker never gets the native route")
    func dockerNeverGetsNativeShell() {
        let environment = Self.dockerEnvironment
        #expect(environment.isContainerized)
        #expect(route(render(.claudeCode, .autonomous), offered: HostControlPlaneMCPProjection.toolNames,
                      environment: environment) == .brokerReachabilityOnly)
        #expect(route(render(.claudeCode, .autonomous), offered: ["history"], environment: environment)
            == .unavailable(.dockerWorkspace))
    }

    @Test("No ssh client means no route, and no connections means no route at all")
    func missingClientOrConnections() {
        #expect(route(render(.codexCLI, .autonomous), sshClientAvailable: false) == .unavailable(.sshClientUnavailable))
        #expect(RemoteWorkspaceSSHRoute.resolve(
            aliases: [],
            render: render(.codexCLI, .autonomous),
            requirements: TaskRuntimeRequirementSet(hostControlTools: [], requiresDockerWorkspaceShell: false, requiresBrowserControl: false),
            environment: .host,
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
            render: render(.codexCLI, .autonomous),
            requirements: TaskRuntimeRequirementSet(hostControlTools: [], requiresDockerWorkspaceShell: false, requiresBrowserControl: false),
            environment: .host,
            runtimeCapabilityProfile: .defaultProfile(for: .codexCLI)
        ))
        #expect(resolved.aliases == ["deid-jsn-workbench", "agent@staging.example.test"])
        #expect(resolved.route == (AgentRuntimeProcessRunner.canInjectSSHShim(for: fixture.task)
            ? .nativeShell : .unavailable(.sshClientUnavailable)))
    }

    // MARK: - The route and the policy render cannot disagree

    /// Rendered by the real manifest path, the way a launch records it: the
    /// route is native only where that render leaves the provider's shell in
    /// place, across policy levels (Locked included), Ask's host-control
    /// withdrawal, and Codex over MCP and over the CLI relay.
    @Test("The native route never contradicts the recorded provider render", arguments: [
        AgentPolicyLevel.autonomous, AgentPolicyLevel.review, AgentPolicyLevel.locked
    ])
    func nativeRouteMatchesRecordedRender(level: AgentPolicyLevel) throws {
        let container = try makeContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let profiles: [(AgentRuntimeID, AgentRuntimeCapabilityProfile)] = [
            (.claudeCode, .defaultProfile(for: .claudeCode)),
            (.codexCLI, .defaultProfile(for: .codexCLI)),
            (.codexCLI, relayProfile)
        ]
        for needsGitHub in [false, true] {
            let workspace = Workspace(name: "SSH render", primaryPath: "/tmp/astra-ssh-route-render")
            workspace.enabledCapabilityIDs = needsGitHub ? [package.id] : []
            context.insert(workspace)
            let contextText = needsGitHub
                ? "Use GitHub to inspect PR metadata, issue links, and checks for this task."
                : "Check disk usage on the remote server."
            for (runtime, profile) in profiles {
                let task = AgentTask(title: "Route render", goal: contextText, workspace: workspace, runtime: runtime)
                context.insert(task)
                TaskPolicyStore.recordSelection(level: level, task: task, modelContext: context, source: "test")
                let requirements = TaskRuntimeRequirementSet.derive(
                    task: task,
                    capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot.capture(
                        for: task,
                        providerLaunchContextText: contextText
                    ),
                    executionEnvironment: .host,
                    browserBridgeRequired: false
                )
                #expect(requirements.hostControlTools.contains("github") == needsGitHub)
                let run = TaskRun(task: task)
                context.insert(run)
                let manifest = AgentPolicyManifestService.recordPreflightManifest(
                    task: task,
                    run: run,
                    runtime: runtime,
                    model: "default",
                    workspacePath: workspace.primaryPath,
                    phase: .run,
                    permissionPolicy: level == .autonomous ? .autonomous : .restricted,
                    executionPolicy: .default,
                    defaultPolicyLevelRaw: level.rawValue,
                    runtimeCapabilityProfile: profile,
                    capabilityPackages: needsGitHub ? [package] : [],
                    contextText: contextText,
                    precomputedRuntimeRequirements: requirements,
                    modelContext: context
                )
                let render = manifest.providerRender
                let resolved = try #require(RemoteWorkspaceSSHRoute.resolve(
                    aliases: aliases,
                    render: render,
                    requirements: requirements,
                    environment: .host,
                    runtimeCapabilityProfile: profile,
                    sshClientAvailable: true
                ))
                let label = "\(runtime.rawValue) relay=\(profile.usesHostControlCLIRelay) level=\(level.rawValue) github=\(needsGitHub)"
                if render.deniedTools.contains(where: { ["bash", "shell"].contains($0.lowercased()) }) {
                    #expect(resolved.route != .nativeShell, "\(label)")
                }
                if level == .locked {
                    // With a host tool required off the relay, Ask's withdrawal is
                    // named first; either way the shell is gone and no SSH is offered.
                    let withdrawn = needsGitHub && !profile.usesHostControlCLIRelay
                    let expected: HostControlSSHRoute.UnavailableReason = withdrawn ? .nativeShellWithdrawn : .policyDeniesShell
                    #expect(resolved.route == .unavailable(expected), "\(label)")
                }
                if level == .autonomous, runtime == .claudeCode {
                    #expect(resolved.route == .nativeShell, "\(label)")
                }
            }
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
        var plan = TaskLaunchResourceResolver.resolve(
            task: fixture.task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: "",
            contextText: "",
            workspacePath: fixture.root.path,
            executionEnvironment: .host
        )
        // The resolver never derives it; the launch records it once the render exists.
        #expect(plan.remoteSSHRoute == nil)
        plan.remoteSSHRoute = resolved
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
