import Foundation

/// The SSH route ASTRA resolved for one run, in the form every reader shares.
///
/// The app resolves it once per launch (`RemoteWorkspaceSSHRoute.resolve`) and
/// hands the same value to the prompt, the run resource manifest, and this
/// broker through the host-control environment. Its wording lives here, next
/// to the broker that has to quote it, so the prompt that tells the agent how
/// to reach the server and the refusal it gets when it tries another way
/// cannot describe two different runs.
public enum HostControlSSHRoute: Equatable, Sendable {
    /// The provider's own shell is available and the task's SSH wrapper is on
    /// PATH, so `ssh <alias> '<command>'` runs remote commands.
    case nativeShell
    /// No provider shell, but ASTRA's host-control `ssh` tool is offered. It
    /// checks reachability and never runs provider-supplied remote commands.
    case brokerReachabilityOnly
    case unavailable(UnavailableReason)

    public enum UnavailableReason: String, CaseIterable, Sendable {
        /// Ask routes this turn's host work through ASTRA's typed tools, which
        /// withdraws the provider shell, and no host-control `ssh` is offered.
        case nativeShellWithdrawn = "native_shell_withdrawn"
        /// The task's permission policy denies the provider shell (Locked, or
        /// a custom rule denying Bash or ssh).
        case policyDeniesShell = "policy_denies_shell"
        /// The provider's own sandbox blocks outbound connections from its
        /// shell, so the SSH wrapper is present but cannot connect.
        case shellSandboxBlocksNetwork = "shell_sandbox_blocks_network"
        /// The workspace runs in Docker, so the provider's shell is not the
        /// host's, and this runtime cannot carry host-control `ssh`.
        case dockerWorkspace = "docker_workspace"
        /// No executable ssh client or no task folder for the SSH wrapper.
        case sshClientUnavailable = "ssh_client_unavailable"

        var explanation: String {
            switch self {
            case .nativeShellWithdrawn:
                return "Ask routes this turn's host work through ASTRA's typed tools, which withdraws the provider shell, and no ASTRA SSH tool is offered. Auto, or a turn that needs no ASTRA host tools, keeps `ssh <alias>` in the shell"
            case .policyDeniesShell:
                return "this task's permission policy denies the provider shell (the Locked preset or a custom rule), and no ASTRA SSH tool is offered"
            case .shellSandboxBlocksNetwork:
                return "this run's provider sandbox blocks outbound connections from the shell, so `ssh` cannot connect, and no ASTRA SSH tool is offered"
            case .dockerWorkspace:
                return "this workspace runs in Docker, so the provider's shell is not the host's SSH, and this runtime cannot carry ASTRA's host-control tools"
            case .sshClientUnavailable:
                return "ASTRA found no executable ssh client (/usr/bin/ssh) or no task folder for the run's SSH wrapper"
            }
        }
    }

    public static let environmentKey = "ASTRA_HOST_CONTROL_SSH_ROUTE"
    /// Newline-separated: a target can hold spaces (`-p 2222 user@host`).
    public static let targetsEnvironmentKey = "ASTRA_HOST_CONTROL_SSH_ROUTE_TARGETS"

    public var wireValue: String {
        switch self {
        case .nativeShell:
            return "native_shell"
        case .brokerReachabilityOnly:
            return "broker_reachability_only"
        case .unavailable(let reason):
            return "unavailable:\(reason.rawValue)"
        }
    }

    public init?(wireValue: String?) {
        let value = wireValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch value {
        case "native_shell":
            self = .nativeShell
        case "broker_reachability_only":
            self = .brokerReachabilityOnly
        default:
            let prefix = "unavailable:"
            guard value.hasPrefix(prefix),
                  let reason = UnavailableReason(rawValue: String(value.dropFirst(prefix.count))) else {
                return nil
            }
            self = .unavailable(reason)
        }
    }

    public var summary: String {
        switch self {
        case .nativeShell:
            return "native shell"
        case .brokerReachabilityOnly:
            return "ASTRA host-control reachability check only"
        case .unavailable:
            return "unavailable"
        }
    }

    /// What the agent should do, said the same way in the prompt and in the
    /// broker's refusal. `targets` is what follows `ssh` for each connection:
    /// its config alias, or the port, identity, and `user@host` it needs.
    public func instruction(targets: [String]) -> String {
        switch self {
        case .nativeShell:
            let example = targets.first ?? "<alias>"
            let others = targets.dropFirst().map { "`ssh \($0)`" }.joined(separator: ", ")
            return "Run remote commands with `ssh \(example) '<command>'` in your shell"
                + (others.isEmpty ? "." : " (other connections: \(others)).")
                + " The `ssh` on your PATH is ASTRA's task wrapper; `astra-host-control ssh` is not this run's route."
                + " If a command is refused or cannot connect, report that error as it is; do not record SSH as disabled for later turns."
        case .brokerReachabilityOnly:
            let subject = targets.count == 1 ? "this connection" : "these connections"
            return "ASTRA host control can check SSH reachability for \(subject), but it does not accept provider-supplied remote commands."
                + " Remote command execution requires a reviewed workspace capability that explicitly supports it."
        case .unavailable(let reason):
            return "This run cannot reach the remote server: \(reason.explanation)."
                + " Do not retry SSH another way; tell the user what this run needs."
        }
    }

    /// The broker's answer to a call for a tool this run was not offered.
    /// Keeps the long-standing first sentence, and for `ssh` adds the route
    /// ASTRA resolved, so a refused reachability check is not read as "SSH
    /// is disabled" when the run's shell can reach the server.
    public static func toolNotEnabledMessage(
        tool: String,
        route: HostControlSSHRoute?,
        targets: [String]
    ) -> String {
        let base = "\(tool) is not enabled for this task"
        guard tool == "ssh", let route else { return base }
        return "\(base). ASTRA resolved this run's SSH route as \(route.summary). \(route.instruction(targets: targets))"
    }
}
