import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

/// The one SSH route a run gets, resolved once per launch from its provider
/// render and `TaskRuntimeRequirementSet`, and carried on
/// `AgentRuntimeExecutionPolicy`.
///
/// Before this existed the prompt described SSH from `ssh-connections.json`
/// alone while the launch decided the real route, and the two disagreed: an
/// Auto run with a working shell and the task's SSH wrapper on PATH was told
/// remote commands needed "a reviewed workspace capability", tried the
/// host-control `ssh` tool it was never offered, was refused, and recorded
/// "SSH is disabled" in its own notes for every later turn to trust (task
/// E0F780F8, 2026-10-19). The prompt, the broker refusal, and the run
/// resource manifest now all read this value, and nothing re-derives it.
struct RemoteWorkspaceSSHRoute: Codable, Equatable, Sendable {
    /// What the agent types after `ssh`: each connection's config alias, or
    /// its `user@host` target when it has none.
    let aliases: [String]
    let route: HostControlSSHRoute

    init(aliases: [String], route: HostControlSSHRoute) {
        self.aliases = aliases
        self.route = route
    }

    /// The pure decision, read from the provider render the run launches
    /// with: the render already folds in the task's policy (Locked, custom
    /// shell rules), Ask's host-control withdrawal, and the provider sandbox,
    /// so the route cannot promise a shell the render took away or one that
    /// cannot reach the network. `nil` when the workspace has no SSH
    /// connections.
    static func resolve(
        aliases: [String],
        render: ProviderPolicyRender,
        requirements: TaskRuntimeRequirementSet,
        environment: WorkspaceExecutionEnvironment,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile,
        sshClientAvailable: Bool
    ) -> RemoteWorkspaceSSHRoute? {
        guard !aliases.isEmpty else { return nil }
        let offersBrokerSSH = runtimeCapabilityProfile.canDeliverHostControlPlane
            && requirements.offeredHostControlTools.contains("ssh")
        let withoutNativeShell = { (reason: HostControlSSHRoute.UnavailableReason) -> HostControlSSHRoute in
            offersBrokerSSH ? .brokerReachabilityOnly : .unavailable(reason)
        }
        let route: HostControlSSHRoute
        if environment.isContainerized {
            // Host Bash must not escape the selected execution environment, and
            // a provider running inside the container has neither the host's
            // ~/.ssh nor the task's SSH wrapper, so Docker never gets the
            // native route.
            route = withoutNativeShell(.dockerWorkspace)
        } else if render.deniesNativeShellOrSSH {
            let withdrawnForHostControl = HostControlPlaneMCPProjection.withdrawsNativeShell(
                environment: environment,
                permissionPolicy: render.launchPermissionPolicy,
                requiredTools: requirements.hostControlTools,
                usesHostControlCLIRelay: !requirements.offeredHostControlTools.isEmpty
                    && runtimeCapabilityProfile.usesHostControlCLIRelay
            )
            route = withoutNativeShell(withdrawnForHostControl ? .nativeShellWithdrawn : .policyDeniesShell)
        } else if !render.nativeShellReachesNetwork {
            route = withoutNativeShell(.shellSandboxBlocksNetwork)
        } else if sshClientAvailable {
            route = .nativeShell
        } else {
            route = .unavailable(.sshClientUnavailable)
        }
        return RemoteWorkspaceSSHRoute(aliases: aliases, route: route)
    }

    /// The launch's call, made once the run's manifest is recorded: reads the
    /// task's connections and whether its SSH wrapper can be injected, then
    /// decides with the launch's own values.
    @MainActor
    static func resolve(
        task: AgentTask,
        render: ProviderPolicyRender,
        requirements: TaskRuntimeRequirementSet,
        environment: WorkspaceExecutionEnvironment,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile
    ) -> RemoteWorkspaceSSHRoute? {
        resolve(
            aliases: connectAliases(for: task),
            render: render,
            requirements: requirements,
            environment: environment,
            runtimeCapabilityProfile: runtimeCapabilityProfile,
            sshClientAvailable: AgentRuntimeProcessRunner.canInjectSSHShim(for: task)
        )
    }

    static func connectAlias(for connection: SSHConnection) -> String {
        connection.configAlias.isEmpty ? connection.sshTarget : connection.configAlias
    }

    var instruction: String {
        route.instruction(aliases: aliases)
    }

    /// The host-control environment the broker reads the route from.
    var hostControlEnvironment: [String: String] {
        [
            HostControlSSHRoute.environmentKey: route.wireValue,
            HostControlSSHRoute.aliasesEnvironmentKey: aliases.joined(separator: ",")
        ]
    }

    /// The short, authoritative "this run" line. Appended after everything
    /// else the prompt carries, including task notes the agent wrote on an
    /// earlier turn, and it says it outranks them: an agent-authored
    /// "SSH is disabled" in current_state.json is a stale observation, this
    /// is what the launch actually wired.
    var runGuidance: String {
        """
        SSH route for this run (resolved by ASTRA at launch; it overrides any earlier note in current_state.json, investigation notes, or prior turns about SSH being disabled or available): \(route.summary). \(instruction)
        """
    }

    static func appendingRunGuidance(to prompt: String, route: RemoteWorkspaceSSHRoute?) -> String {
        guard let route else { return prompt }
        return prompt + "\n\n" + route.runGuidance
    }

    @MainActor
    private static func connectAliases(for task: AgentTask) -> [String] {
        guard let workspace = task.workspace else { return [] }
        var seen: Set<String> = []
        return SSHConnectionManager.load(workspacePath: workspace.primaryPath)
            .map(connectAlias(for:))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case aliases
        case route
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        let wireValue = try container.decode(String.self, forKey: .route)
        guard let route = HostControlSSHRoute(wireValue: wireValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .route,
                in: container,
                debugDescription: "Unknown SSH route \(wireValue)"
            )
        }
        self.route = route
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(route.wireValue, forKey: .route)
    }
}

extension ProviderPolicyRender {
    /// The render takes the provider's shell away, or denies `ssh` in it.
    var deniesNativeShellOrSSH: Bool {
        let shellTools: Set<String> = ["bash", "shell"]
        if deniedTools.contains(where: { shellTools.contains($0.lowercased()) }) {
            return true
        }
        return deniedShellPatterns.contains { pattern in
            var command = pattern.trimmingCharacters(in: .whitespaces).lowercased()
            if command.hasPrefix("bash("), command.hasSuffix(")") {
                command = String(command.dropFirst(5).dropLast())
            }
            return command == "ssh" || command.hasPrefix("ssh:") || command.hasPrefix("ssh ")
        }
    }

    /// Whether the provider's own sandbox lets its shell open a connection.
    /// Codex is the runtime whose rendered sandbox is known to block it by
    /// default; the others are taken to reach it.
    var nativeShellReachesNetwork: Bool {
        guard providerID == .codexCLI else { return true }
        return CodexCLIRuntime.shellReachesNetwork(permissionArguments: cliArgumentsSummary)
    }
}
