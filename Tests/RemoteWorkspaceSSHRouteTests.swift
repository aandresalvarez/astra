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

    private var relayProfile: AgentRuntimeCapabilityProfile {
        .defaultProfile(for: .codexCLI, providerMCPPolicy: .serversDisabled(policyName: nil))
    }

    private typealias Facts = RemoteWorkspaceSSHRoute.Facts

    // MARK: - The decision

    @Test("The decision table")
    func decisionTable() {
        let cases: [(Facts, HostControlSSHRoute)] = [
            (Facts(), .nativeShell),
            // Ask asks: an ask-first `ssh` is still the shell's route.
            (Facts(shellDisposition: .ask), .nativeShell),
            (Facts(shellDisposition: .denied, shellWithdrawnForHostControl: true), .unavailable(.nativeShellWithdrawn)),
            (Facts(shellDisposition: .denied), .unavailable(.policyDeniesShell)),
            (Facts(shellDisposition: .denied, brokerSSHAvailable: true), .brokerReachabilityOnly),
            (Facts(shellReachesNetwork: false), .unavailable(.shellSandboxBlocksNetwork)),
            (Facts(shellReachesNetwork: false, brokerSSHAvailable: true), .brokerReachabilityOnly),
            (Facts(workspaceIsContainerized: true), .unavailable(.dockerWorkspace)),
            (Facts(workspaceIsContainerized: true, brokerSSHAvailable: true), .brokerReachabilityOnly),
            (Facts(sshClientAvailable: false), .unavailable(.sshClientUnavailable))
        ]
        for (facts, expected) in cases {
            #expect(RemoteWorkspaceSSHRoute.route(for: facts) == expected, "\(facts)")
        }
    }

    @Test("Codex's rendered sandbox reaches the network only through the bypass or the reviewer")
    func codexSandboxNetwork() {
        func reaches(_ policy: PermissionPolicy, _ requirements: CodexRequirementsPolicy) -> Bool {
            CodexCLIRuntime.shellReachesNetwork(
                permissionArguments: CodexCLIRuntime.codexPermissionArguments(policy: policy, requirements: requirements)
            )
        }
        #expect(reaches(.autonomous, .unconstrained))
        // workspace-write with approval_policy="never": connect(2) is denied
        // and nothing can grant an escalated run.
        #expect(!reaches(.restricted, .unconstrained))
        // The incident: clamped to workspace-write, the reviewer escalates.
        #expect(reaches(.autonomous, Self.reviewerBundle))
        #expect(reaches(.restricted, Self.reviewerBundle))
    }

    @Test("An alias-less connection keeps its port and identity, as the connection test runs it")
    func aliasLessTargetKeepsPortAndIdentity() {
        let connection = SSHConnection(
            name: "staging", host: "staging.example.test", user: "agent",
            port: 2222, keyPath: "~/.ssh/staging_ed25519"
        )
        #expect(RemoteWorkspaceSSHRoute.connectTarget(for: connection) == "-p 2222 -i ~/.ssh/staging_ed25519 agent@staging.example.test")
        #expect(connection.sshDestinationArguments(expandingTilde: true).last == "agent@staging.example.test")
        #expect(!connection.sshDestinationArguments(expandingTilde: true).contains("~/.ssh/staging_ed25519"))
        let aliased = SSHConnection(name: "wb", host: "h", user: "u", port: 2222, keyPath: "~/.ssh/k", configAlias: "deid-jsn-workbench")
        #expect(RemoteWorkspaceSSHRoute.connectTarget(for: aliased) == "deid-jsn-workbench")

        let route = RemoteWorkspaceSSHRoute(
            targets: ["deid-jsn-workbench", "-p 2222 -i ~/.ssh/staging_ed25519 agent@staging.example.test"],
            route: .nativeShell
        )
        #expect(route.instruction.contains("`ssh deid-jsn-workbench '<command>'`"))
        #expect(route.instruction.contains("`ssh -p 2222 -i ~/.ssh/staging_ed25519 agent@staging.example.test`"))
        #expect(route.instruction.contains("do not record SSH as disabled"))
    }

    @Test("Rendered targets keep argument boundaries and tilde expansion")
    func renderedTargetsAreShellWords() {
        let spaced = SSHConnection(name: "s", host: "host.example.test", user: "agent", keyPath: "/Users/me/My Keys/id")
        #expect(RemoteWorkspaceSSHRoute.connectTarget(for: spaced) == "-i '/Users/me/My Keys/id' agent@host.example.test")
        let home = SSHConnection(name: "h", host: "host.example.test", user: "agent", keyPath: "~/My Keys/it's")
        #expect(RemoteWorkspaceSSHRoute.connectTarget(for: home) == "-i ~/'My Keys/it'\\''s' agent@host.example.test")
        #expect(RemoteWorkspaceSSHRoute.shellWord("~/.ssh/id_ed25519") == "~/.ssh/id_ed25519")
        #expect(RemoteWorkspaceSSHRoute.shellWord("deid-jsn-workbench") == "deid-jsn-workbench")
    }

    // MARK: - Resolved from the recorded manifest

    /// Records a manifest the way a launch does and resolves the route from it.
    private func recorded(
        _ runtime: AgentRuntimeID,
        profile: AgentRuntimeCapabilityProfile? = nil,
        level: AgentPolicyLevel,
        needsGitHub: Bool = false,
        in context: ModelContext,
        adjust: (inout RunPermissionManifest) -> Void = { _ in },
        helperAvailable: Bool = true
    ) throws -> (manifest: RunPermissionManifest, route: HostControlSSHRoute, requirements: TaskRuntimeRequirementSet) {
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let profile = profile ?? .defaultProfile(for: runtime)
        let workspace = Workspace(name: "SSH render", primaryPath: "/tmp/astra-ssh-route-render")
        workspace.enabledCapabilityIDs = needsGitHub ? [package.id] : []
        context.insert(workspace)
        let contextText = needsGitHub
            ? "Use GitHub to inspect PR metadata, issue links, and checks for this task."
            : "Check disk usage on the remote server."
        let task = AgentTask(title: "Route render", goal: contextText, workspace: workspace, runtime: runtime)
        context.insert(task)
        TaskPolicyStore.recordSelection(level: level, task: task, modelContext: context, source: "test")
        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: contextText),
            executionEnvironment: .host,
            browserBridgeRequired: false
        )
        #expect(requirements.hostControlTools.contains("github") == needsGitHub)
        let run = TaskRun(task: task)
        context.insert(run)
        var manifest = AgentPolicyManifestService.recordPreflightManifest(
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
        adjust(&manifest)
        let resolved = try #require(RemoteWorkspaceSSHRoute.resolve(
            targets: aliases,
            manifest: manifest,
            requirements: requirements,
            environment: .host,
            runtimeCapabilityProfile: profile,
            sshClientAvailable: true,
            hostControlHelperAvailable: helperAvailable
        ))
        return (manifest, resolved.route, requirements)
    }

    /// The route is native only where the recorded render leaves the shell in
    /// place, across levels (Locked included), Ask's host-control withdrawal,
    /// and Codex over MCP and over the CLI relay.
    @Test("The native route never contradicts the recorded manifest", arguments: [
        AgentPolicyLevel.autonomous, AgentPolicyLevel.review, AgentPolicyLevel.locked
    ])
    func nativeRouteMatchesRecordedManifest(level: AgentPolicyLevel) throws {
        let container = try makeContainer()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let profiles: [(AgentRuntimeID, AgentRuntimeCapabilityProfile)] = [
            (.claudeCode, .defaultProfile(for: .claudeCode)),
            (.codexCLI, .defaultProfile(for: .codexCLI)),
            (.codexCLI, relayProfile)
        ]
        for needsGitHub in [false, true] {
            for (runtime, profile) in profiles {
                let result = try recorded(runtime, profile: profile, level: level, needsGitHub: needsGitHub, in: context)
                let render = result.manifest.providerRender
                let label = "\(runtime.rawValue) relay=\(profile.usesHostControlCLIRelay) level=\(level.rawValue) github=\(needsGitHub)"
                if render.deniedTools.contains(where: { ["bash", "shell"].contains($0.lowercased()) }) {
                    #expect(result.route != .nativeShell, "\(label)")
                }
                if level == .locked {
                    #expect(result.route != .nativeShell, "\(label)")
                }
                if level == .autonomous, runtime == .claudeCode {
                    #expect(result.route == .nativeShell, "\(label)")
                }
            }
        }
    }

    @Test("A shell allowlist without ssh is the guard's denial, not a native route")
    func shellAllowlistWithoutSSH() throws {
        let container = try makeContainer()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let narrowed = try recorded(.claudeCode, level: .autonomous, in: context) { manifest in
            manifest.providerRender.allowedTools = ["Read", "Bash"]
            manifest.providerRender.allowedShellPatterns = ["git status:*"]
            manifest.providerRender.usesBroadProviderPermissions = false
        }
        #expect(narrowed.route == .unavailable(.policyDeniesShell))
        let denied = try recorded(.claudeCode, level: .autonomous, in: context) { manifest in
            manifest.providerRender.deniedShellPatterns = ["ssh:*"]
        }
        #expect(denied.route == .unavailable(.policyDeniesShell))
    }

    @Test("Only targets the guard allows are advertised for the native route")
    func perTargetGuardDisposition() throws {
        let container = try makeContainer()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let manifest = try recorded(.claudeCode, level: .autonomous, in: context) { manifest in
            manifest.providerRender.deniedShellPatterns = ["ssh staging:*", "ssh staging *"]
        }.manifest
        func resolve(_ targets: [String]) throws -> RemoteWorkspaceSSHRoute {
            try #require(RemoteWorkspaceSSHRoute.resolve(
                targets: targets,
                manifest: manifest,
                requirements: TaskRuntimeRequirementSet(hostControlTools: [], requiresDockerWorkspaceShell: false, requiresBrowserControl: false),
                environment: .host,
                runtimeCapabilityProfile: .defaultProfile(for: .claudeCode),
                sshClientAvailable: true,
                hostControlHelperAvailable: true
            ))
        }
        let mixed = try resolve(["staging", "deid-jsn-workbench"])
        #expect(mixed.route == .nativeShell)
        #expect(mixed.targets == ["deid-jsn-workbench"])
        #expect(!mixed.instruction.contains("staging"))
        let onlyDenied = try resolve(["staging"])
        #expect(onlyDenied.route == .unavailable(.policyDeniesShell))
    }

    @Test("ASTRA's sandbox without network is never a native route")
    func seatbeltNetworkDenial() throws {
        let container = try makeContainer()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let offline = try recorded(.claudeCode, level: .autonomous, in: context) { manifest in
            manifest.sandboxEvidence?.shellNetworkAllowed = false
        }
        #expect(offline.manifest.sandboxEvidence != nil)
        #expect(offline.route == .unavailable(.shellSandboxBlocksNetwork))
        // Recorded by the manifest itself, from the settings it applied.
        let online = try recorded(.claudeCode, level: .autonomous, in: context)
        #expect(online.manifest.sandboxEvidence?.shellNetworkAllowed != nil)
    }

    @Test("Without the host-control helper there is no reachability-check fallback")
    func missingHelperDropsBrokerFallback() throws {
        let container = try makeContainer()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        let offersSSH: (inout RunPermissionManifest) -> Void = { manifest in
            manifest.sandboxEvidence?.shellNetworkAllowed = false
        }
        // The shell cannot connect, so the route falls back to the broker,
        // but only while the helper that serves it is installed.
        let withHelper = try recorded(.claudeCode, level: .autonomous, in: context, adjust: offersSSH)
        let noHelper = try #require(RemoteWorkspaceSSHRoute.resolve(
            targets: aliases,
            manifest: withHelper.manifest,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: [],
                offeredHostControlTools: ["ssh", "history"],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            ),
            environment: .host,
            runtimeCapabilityProfile: .defaultProfile(for: .claudeCode),
            sshClientAvailable: true,
            hostControlHelperAvailable: false
        ))
        #expect(noHelper.route == .unavailable(.shellSandboxBlocksNetwork))
        let helper = try #require(RemoteWorkspaceSSHRoute.resolve(
            targets: aliases,
            manifest: withHelper.manifest,
            requirements: TaskRuntimeRequirementSet(
                hostControlTools: [],
                offeredHostControlTools: ["ssh", "history"],
                requiresDockerWorkspaceShell: false,
                requiresBrowserControl: false
            ),
            environment: .host,
            runtimeCapabilityProfile: .defaultProfile(for: .claudeCode),
            sshClientAvailable: true,
            hostControlHelperAvailable: true
        ))
        #expect(helper.route == .brokerReachabilityOnly)
    }

    @Test("The launch resolution reads the workspace's connect targets and the shim preconditions")
    func launchResolutionReadsTaskState() throws {
        let fixture = try makeTask(goal: "Check the VM")
        defer { fixture.cleanup() }
        let manifest = try recorded(.codexCLI, level: .autonomous, in: fixture.container.mainContext).manifest
        let resolved = try #require(RemoteWorkspaceSSHRoute.resolve(
            task: fixture.task,
            manifest: manifest,
            requirements: TaskRuntimeRequirementSet(hostControlTools: [], requiresDockerWorkspaceShell: false, requiresBrowserControl: false),
            environment: .host,
            runtimeCapabilityProfile: .defaultProfile(for: .codexCLI),
            hostControlHelperAvailable: true
        ))
        #expect(resolved.targets == ["deid-jsn-workbench", "-p 2222 agent@staging.example.test"])
    }

    @Test("The launch signature changes with the route and stays put without one")
    func signatureTracksRoute() throws {
        let fixture = try makeTask(goal: "Check the VM")
        defer { fixture.cleanup() }
        let manifest = try recorded(.codexCLI, level: .autonomous, in: fixture.container.mainContext).manifest
        var plan = TaskLaunchResourceResolver.resolve(
            task: fixture.task, runID: UUID(), runtime: .codexCLI, phase: .run,
            prompt: "", contextText: "", workspacePath: fixture.root.path, executionEnvironment: .host
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(for: fixture.task, providerLaunchContextText: "")
        func signature() -> String {
            ProviderLaunchSignatureService.make(
                for: fixture.task, manifest: manifest, contextText: "",
                capabilityResolutionSnapshot: snapshot, launchResourcePlan: plan
            ).signatureValue
        }
        let none = signature()
        #expect(!none.contains("ssh="))
        plan.remoteSSHRoute = RemoteWorkspaceSSHRoute(targets: aliases, route: .unavailable(.policyDeniesShell))
        let denied = signature()
        plan.remoteSSHRoute = RemoteWorkspaceSSHRoute(targets: aliases, route: .nativeShell)
        let native = signature()
        #expect(native.hasSuffix("ssh=native_shell|deid-jsn-workbench"))
        #expect(Set([none, denied, native]).count == 3)
    }

    // MARK: - Broker

    @Test("The broker refusal names the route ASTRA resolved and keeps -32602")
    func brokerRefusalNamesResolvedRoute() throws {
        let resolved = RemoteWorkspaceSSHRoute(targets: aliases, route: .nativeShell)
        // Through the same environment the app hands the broker.
        var environment = resolved.hostControlEnvironment
        environment["ASTRA_HOST_CONTROL_ALLOWED_TOOLS"] = "jira,history"
        let configuration = HostControlToolConfiguration.fromEnvironment(environment)
        #expect(configuration.sshRoute == .nativeShell)
        #expect(configuration.sshRouteTargets == aliases)

        let error = try refusal(HostControlMCPServer(configuration: configuration), tool: "ssh")
        #expect(error.code == -32602)
        #expect(error.message.hasPrefix("ssh is not enabled for this task"))
        #expect(error.message.contains("ASTRA resolved this run's SSH route as native shell"))
        #expect(error.message.contains("`ssh deid-jsn-workbench '<command>'` in your shell"))
        #expect(error.message.contains(resolved.instruction))

        let unavailable = HostControlToolConfiguration(
            sshRoute: .unavailable(.nativeShellWithdrawn),
            sshRouteTargets: aliases,
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
        let routed = HostControlToolConfiguration(sshRoute: .nativeShell, sshRouteTargets: aliases, allowedTools: ["github"])
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
        let resolved = RemoteWorkspaceSSHRoute(targets: aliases, route: .nativeShell)
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
        #expect(env[HostControlSSHRoute.targetsEnvironmentKey] == "deid-jsn-workbench")
        let server = try #require(HostControlPlaneMCPProjection.resolvedServer(
            task: fixture.task,
            environment: .host,
            currentDirectory: fixture.root.path,
            runID: nil,
            precomputedRuntimeRequirements: requirements
        ))
        #expect(server.permittedEnvironmentKeys.contains(HostControlSSHRoute.environmentKey))
        #expect(server.permittedEnvironmentKeys.contains(HostControlSSHRoute.targetsEnvironmentKey))
    }

    // MARK: - Manifest

    @Test("The run resource manifest records the route the launch resolved")
    func manifestRecordsRoute() throws {
        let fixture = try makeTask(goal: "Check the VM")
        defer { fixture.cleanup() }
        let resolved = RemoteWorkspaceSSHRoute(targets: aliases, route: .unavailable(.nativeShellWithdrawn))
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
            SSHConnection(name: "staging", host: "staging.example.test", user: "agent", port: 2222, remotePath: "/srv")
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
