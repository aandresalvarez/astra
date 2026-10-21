import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport

/// The one SSH route a run gets, resolved once per launch from its recorded
/// permission manifest and carried on `AgentRuntimeExecutionPolicy`.
///
/// Before this existed the prompt described SSH from `ssh-connections.json`
/// alone while the launch decided the real route, and the two disagreed: an
/// Auto run with a working shell and the task's SSH wrapper on PATH was told
/// remote commands needed "a reviewed workspace capability", tried the
/// host-control `ssh` tool it was never offered, was refused, and recorded
/// "SSH is disabled" in its own notes for every later turn to trust (task
/// E0F780F8, 2026-10-19). The run line, the broker refusal, the run resource
/// manifest, and the launch signature now all read this value, and nothing
/// re-derives it.
///
/// It decides from two authorities rather than re-deriving any of their
/// rules: the policy guard's own disposition for the `ssh` command the agent
/// would run (Locked, custom allow/deny rules, Ask's host-control
/// withdrawal), and the sandbox the process gets (Codex's rendered sandbox,
/// ASTRA's Seatbelt network setting).
struct RemoteWorkspaceSSHRoute: Codable, Equatable, Sendable {
    /// What follows `ssh` for each connection: its config alias, or the port,
    /// identity, and `user@host` an alias-less connection needs.
    let targets: [String]
    let route: HostControlSSHRoute

    init(targets: [String], route: HostControlSSHRoute) {
        self.targets = targets
        self.route = route
    }

    /// The facts the decision reads, each from its own owner.
    struct Facts: Equatable {
        var workspaceIsContainerized = false
        /// The policy guard's answer for `ssh <target> true` as a shell command.
        var shellDisposition: AgentRuntimePolicyGuard.CommandDisposition = .allowed
        /// The shell is withdrawn because Ask routes this turn through ASTRA's
        /// host tools; only picks the reason when the guard denies the command.
        var shellWithdrawnForHostControl = false
        var shellReachesNetwork = true
        var sshClientAvailable = true
        /// The runtime can carry host control, it offers `ssh`, and the
        /// `astra-host-control` helper is installed.
        var brokerSSHAvailable = false
    }

    static func route(for facts: Facts) -> HostControlSSHRoute {
        let withoutNativeShell = { (reason: HostControlSSHRoute.UnavailableReason) -> HostControlSSHRoute in
            facts.brokerSSHAvailable ? .brokerReachabilityOnly : .unavailable(reason)
        }
        // Host Bash must not escape the selected execution environment, and a
        // provider inside the container has neither the host's ~/.ssh nor the
        // task's SSH wrapper, so Docker never gets the native route.
        if facts.workspaceIsContainerized { return withoutNativeShell(.dockerWorkspace) }
        if facts.shellDisposition == .denied {
            return withoutNativeShell(facts.shellWithdrawnForHostControl ? .nativeShellWithdrawn : .policyDeniesShell)
        }
        if !facts.shellReachesNetwork { return withoutNativeShell(.shellSandboxBlocksNetwork) }
        return facts.sshClientAvailable ? .nativeShell : .unavailable(.sshClientUnavailable)
    }

    /// Gathers the facts from the manifest the launch recorded. `nil` when the
    /// workspace has no SSH connections.
    static func resolve(
        targets: [String],
        manifest: RunPermissionManifest,
        requirements: TaskRuntimeRequirementSet,
        environment: WorkspaceExecutionEnvironment,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile,
        sshClientAvailable: Bool,
        hostControlHelperAvailable: Bool
    ) -> RemoteWorkspaceSSHRoute? {
        guard !targets.isEmpty else { return nil }
        // Every advertised target is asked about, so a policy that allows ssh to
        // one host does not get the others advertised as reachable.
        let guardPolicy = AgentRuntimePolicyGuard(manifest: manifest)
        let shellTargets = targets.filter {
            guardPolicy.disposition(toolName: "Bash", command: "ssh \($0) true") != .denied
        }
        let facts = Facts(
            workspaceIsContainerized: environment.isContainerized,
            shellDisposition: shellTargets.isEmpty ? .denied : .allowed,
            shellWithdrawnForHostControl: HostControlPlaneMCPProjection.withdrawsNativeShell(
                environment: environment,
                permissionPolicy: manifest.providerRender.launchPermissionPolicy,
                requiredTools: requirements.hostControlTools,
                usesHostControlCLIRelay: !requirements.offeredHostControlTools.isEmpty
                    && runtimeCapabilityProfile.usesHostControlCLIRelay
            ),
            shellReachesNetwork: manifest.nativeShellReachesNetwork,
            sshClientAvailable: sshClientAvailable,
            brokerSSHAvailable: hostControlHelperAvailable
                && runtimeCapabilityProfile.canDeliverHostControlPlane
                && requirements.offeredHostControlTools.contains("ssh")
        )
        let route = route(for: facts)
        return RemoteWorkspaceSSHRoute(targets: route == .nativeShell ? shellTargets : targets, route: route)
    }

    /// The launch's call, made once the run's manifest is recorded.
    @MainActor
    static func resolve(
        task: AgentTask,
        manifest: RunPermissionManifest,
        requirements: TaskRuntimeRequirementSet,
        environment: WorkspaceExecutionEnvironment,
        runtimeCapabilityProfile: AgentRuntimeCapabilityProfile,
        hostControlHelperAvailable: Bool
    ) -> RemoteWorkspaceSSHRoute? {
        resolve(
            targets: connectTargets(for: task),
            manifest: manifest,
            requirements: requirements,
            environment: environment,
            runtimeCapabilityProfile: runtimeCapabilityProfile,
            sshClientAvailable: AgentRuntimeProcessRunner.canInjectSSHShim(for: task),
            hostControlHelperAvailable: hostControlHelperAvailable
        )
    }

    /// `ssh <target>` for one connection, as the agent types it into a shell:
    /// each argument quoted where it needs to be, so an identity path with a
    /// space stays one argument, and a leading `~/` left for the shell to expand.
    static func connectTarget(for connection: SSHConnection) -> String {
        connection.sshDestinationArguments(expandingTilde: false).map(shellWord).joined(separator: " ")
    }

    static func shellWord(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        func quoted(_ text: String) -> String {
            text.unicodeScalars.allSatisfy(safe.contains) && !text.isEmpty
                ? text
                : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if argument.hasPrefix("~/") { return "~/" + quoted(String(argument.dropFirst(2))) }
        return quoted(argument)
    }

    var instruction: String {
        route.instruction(targets: targets)
    }

    /// The host-control environment the broker reads the route from.
    var hostControlEnvironment: [String: String] {
        [
            HostControlSSHRoute.environmentKey: route.wireValue,
            HostControlSSHRoute.targetsEnvironmentKey: targets.joined(separator: "\n")
        ]
    }

    /// What the launch signature records: a change of route or of the
    /// connections it names drops a native session that remembers the old one.
    var signatureComponent: String {
        ([route.wireValue] + targets).joined(separator: "|")
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
    private static func connectTargets(for task: AgentTask) -> [String] {
        guard let workspace = task.workspace else { return [] }
        var seen: Set<String> = []
        return SSHConnectionManager.load(workspacePath: workspace.primaryPath)
            .map(connectTarget(for:))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case targets
        case route
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targets = try container.decodeIfPresent([String].self, forKey: .targets) ?? []
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
        try container.encode(targets, forKey: .targets)
        try container.encode(route.wireValue, forKey: .route)
    }
}

extension RunPermissionManifest {
    /// Whether anything the provider's shell runs can open a connection:
    /// ASTRA's Seatbelt profile allows network (recorded with the sandbox
    /// evidence), and the provider's own rendered sandbox does too. Codex is
    /// the runtime whose rendered sandbox is known to block it by default.
    var nativeShellReachesNetwork: Bool {
        guard sandboxEvidence?.shellNetworkAllowed != false else { return false }
        guard providerRender.providerID == .codexCLI else { return true }
        return CodexCLIRuntime.shellReachesNetwork(permissionArguments: providerRender.cliArgumentsSummary)
    }
}
