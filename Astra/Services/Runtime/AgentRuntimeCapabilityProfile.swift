import Foundation
import ASTRACore

enum AgentRuntimeTaskScopedMCPDelivery: String, Equatable, Sendable {
    case unsupported
    case claudeStrictConfigFile
    case codexInlineConfig
    case copilotAdditionalConfigFile
}

struct AgentRuntimeCapabilityProfile: Equatable, Sendable {
    var runtime: AgentRuntimeID
    var displayName: String
    var taskScopedMCPDelivery: AgentRuntimeTaskScopedMCPDelivery
    var supportsNativeContinuation: Bool
    var supportsShellToolForBrowserBridge: Bool
    var supportsHostControlCLIRelay: Bool
    /// What the provider itself last said about running MCP servers ASTRA
    /// hands it. Defaults to `.unknown`, which behaves exactly as it did
    /// before this existed.
    var providerMCPPolicy: RuntimeProviderMCPPolicy = .unknown
    var observedEvidence: [String]

    /// True when ASTRA knows how to deliver task-scoped MCP configuration to
    /// this runtime before launch, ignoring whether the provider will accept
    /// it. Use this to describe ASTRA's side of the contract only.
    var hasTaskScopedMCPDeliveryMechanism: Bool {
        taskScopedMCPDelivery != .unsupported
    }

    /// True when ASTRA can deliver task-scoped MCP configuration *and* the
    /// provider has not told us it will refuse it. This does not prove any
    /// feature-specific MCP server was selected, rendered, or accepted for a
    /// run — only that the route is not already known to be closed.
    var supportsTaskScopedMCPDelivery: Bool {
        hasTaskScopedMCPDeliveryMechanism && !providerMCPPolicy.refusesServers
    }

    /// Pre-render eligibility for delivering the host-control MCP server to
    /// the runtime. The launch resolver still owns selecting and rendering the
    /// concrete server for a run.
    var canDeliverHostControlPlaneMCP: Bool {
        supportsTaskScopedMCPDelivery
    }

    var canDeliverHostControlPlane: Bool {
        canDeliverHostControlPlaneMCP || supportsHostControlCLIRelay
    }

    var usesHostControlCLIRelay: Bool {
        !canDeliverHostControlPlaneMCP && supportsHostControlCLIRelay
    }

    /// Pre-render eligibility for delivering the Docker workspace shell MCP
    /// server to the runtime. This is not evidence that a run projected it.
    var canDeliverDockerWorkspaceShellMCP: Bool {
        supportsTaskScopedMCPDelivery
    }

    /// Pre-render eligibility for delivering the browser bridge MCP tool. A
    /// run still must verify either a shell transport or a rendered browser MCP
    /// server before treating browser bridge access as available.
    var canDeliverBrowserBridgeMCPTool: Bool {
        supportsTaskScopedMCPDelivery
    }

    /// True when the runtime has at least one possible browser bridge transport.
    /// Per-run launch still must verify shell-tool access or rendered browser
    /// MCP server availability before enabling browser control.
    var canUseBrowserBridgeTransport: Bool {
        supportsShellToolForBrowserBridge || canDeliverBrowserBridgeMCPTool
    }

    static func defaultProfile(
        for runtime: AgentRuntimeID,
        providerMCPPolicy: RuntimeProviderMCPPolicy = .unknown
    ) -> AgentRuntimeCapabilityProfile {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)
        let mcpProfile = MCPRuntimeSupportMatrix.profile(for: descriptor)
        let supportsRelay = defaultHostControlCLIRelaySupport(for: runtime)
        // Mirrors `usesHostControlCLIRelay` on the built value, which cannot be
        // read yet. MCP wins whenever it is both deliverable and not refused.
        let usesRelay = supportsRelay
            && (mcpProfile.configDeliveryOwnership == .unsupported || providerMCPPolicy.refusesServers)
        var evidence = defaultEvidence(
            for: runtime,
            delivery: mcpProfile.configDeliveryOwnership,
            usesHostControlCLIRelay: usesRelay
        )
        if providerMCPPolicy != .unknown {
            evidence.append(providerMCPPolicy.evidence)
        }
        return AgentRuntimeCapabilityProfile(
            descriptor: descriptor,
            mcpProfile: mcpProfile,
            supportsShellToolForBrowserBridge: defaultShellToolSupport(for: runtime),
            supportsHostControlCLIRelay: defaultHostControlCLIRelaySupport(for: runtime),
            providerMCPPolicy: providerMCPPolicy,
            observedEvidence: evidence
        )
    }

    static func copilotProfile(supportsAdditionalMCPConfig: Bool) -> AgentRuntimeCapabilityProfile {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: .copilotCLI)
        let mcpProfile = MCPRuntimeSupportMatrix.copilotProfile(
            for: descriptor,
            supportsAdditionalMCPConfig: supportsAdditionalMCPConfig
        )
        return AgentRuntimeCapabilityProfile(
            descriptor: descriptor,
            mcpProfile: mcpProfile,
            supportsShellToolForBrowserBridge: false,
            supportsHostControlCLIRelay: false,
            providerMCPPolicy: .unknown,
            observedEvidence: [
                supportsAdditionalMCPConfig
                    ? "copilot-help:additional-mcp-config"
                    : "copilot-help:missing-additional-mcp-config"
            ]
        )
    }

    private init(
        descriptor: AgentRuntimeDescriptor,
        mcpProfile: MCPRuntimeSupportProfile,
        supportsShellToolForBrowserBridge: Bool,
        supportsHostControlCLIRelay: Bool,
        providerMCPPolicy: RuntimeProviderMCPPolicy,
        observedEvidence: [String]
    ) {
        self.runtime = descriptor.id
        self.displayName = descriptor.displayName
        self.taskScopedMCPDelivery = AgentRuntimeTaskScopedMCPDelivery(
            deliveryOwnership: mcpProfile.configDeliveryOwnership
        )
        self.supportsNativeContinuation = descriptor.supportsNativeContinuation
        self.supportsShellToolForBrowserBridge = supportsShellToolForBrowserBridge
        self.supportsHostControlCLIRelay = supportsHostControlCLIRelay
        self.providerMCPPolicy = providerMCPPolicy
        self.observedEvidence = observedEvidence
    }

    private static func defaultShellToolSupport(for runtime: AgentRuntimeID) -> Bool {
        runtime != .copilotCLI && AgentRuntimeAdapterRegistry.hasAdapter(for: runtime)
    }

    /// Runtimes whose shell can carry the typed `astra-host-control` relay.
    ///
    /// For Cursor, OpenCode, and Antigravity this is the only host-control
    /// route they have — they cannot be handed an MCP server at all. Codex is
    /// here for the opposite reason: it *can* be handed one, and an enterprise
    /// requirements bundle can still refuse to run it (`[mcp_servers]` with
    /// nothing allowed). Listing Codex does not move it off MCP —
    /// `usesHostControlCLIRelay` prefers MCP wherever MCP actually works, and
    /// only reaches for the relay once the provider has said it will not run
    /// the server. Without this the refusal has no second route to fall to,
    /// and a connector turn on Codex fails having never left ASTRA.
    private static func defaultHostControlCLIRelaySupport(for runtime: AgentRuntimeID) -> Bool {
        [.cursorCLI, .openCodeCLI, .antigravityCLI, .codexCLI].contains(runtime)
    }

    private static func defaultEvidence(
        for runtime: AgentRuntimeID,
        delivery: MCPRuntimeConfigDeliveryOwnership,
        usesHostControlCLIRelay: Bool
    ) -> [String] {
        // The route taken, not the routes available. Codex supports the relay
        // and inline MCP both, so claiming the relay whenever it is *supported*
        // would report the fallback on every ordinary run.
        if usesHostControlCLIRelay {
            return ["adapter:process-bound-host-control-cli-relay"]
        }
        switch delivery {
        case .astraEphemeralLaunchFile:
            return ["descriptor:claude-mcp-config"]
        case .astraInlineLaunchArgument:
            return ["descriptor:codex-inline-mcp"]
        case .astraAdditionalLaunchFile:
            return ["descriptor:additional-mcp-config"]
        case .unsupported:
            if runtime == .copilotCLI {
                return ["copilot-help:missing-additional-mcp-config"]
            } else {
                return ["adapter:no-task-scoped-mcp-projection"]
            }
        }
    }
}

enum AgentRuntimeCapabilityProfileService {
    /// The static table, plus the one dynamic fact that costs nothing to read.
    ///
    /// Codex's MCP policy decides which host-control route a run gets, so a
    /// profile that omits it answers `canDeliverHostControlPlaneMCP == true`
    /// on a machine where the provider refuses every server — and the relay
    /// fallback then never engages. Unlike Copilot's capability lookup this is
    /// a `UserDefaults` read, so it is cheap enough for the plain
    /// `defaultProfile` path.
    static func defaultProfile(
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard
    ) -> AgentRuntimeCapabilityProfile {
        guard runtime == .codexCLI else {
            return AgentRuntimeCapabilityProfile.defaultProfile(for: runtime)
        }
        return AgentRuntimeCapabilityProfile.defaultProfile(
            for: runtime,
            providerMCPPolicy: CodexMCPPolicyService.cachedPolicy(defaults: defaults)
        )
    }

    static func profile(
        for runtime: AgentRuntimeID,
        executablePath: String,
        defaults: UserDefaults = .standard
    ) -> AgentRuntimeCapabilityProfile {
        if runtime == .copilotCLI {
            let capabilities = CopilotCLIRuntime.capabilities(executablePath: executablePath)
            return AgentRuntimeCapabilityProfile.copilotProfile(
                supportsAdditionalMCPConfig: capabilities.supportsAdditionalMCPConfig
            )
        }
        // Cache-only, like Copilot's capability lookup above: this is called
        // once per candidate runtime on the main-actor admission path, and the
        // Codex probe is a subprocess. `CodexMCPPolicyService.warmBeforeLaunch`
        // is what makes sure there is something fresh to read.
        return defaultProfile(for: runtime, defaults: defaults)
    }

    /// The profile for a runtime whose launch settings the caller does not hold.
    ///
    /// `defaultProfile` is a static table: for Copilot it always answers "no
    /// MCP", which is a guess about the installed binary and not a fact about
    /// it. Anything that describes the run to the agent has to agree with what
    /// the launch actually attaches, so it resolves the binary instead of
    /// assuming. Only Copilot varies, and its probe is memoised per binary, so
    /// this costs a few `stat`s rather than a process spawn. Callers that
    /// already hold `launchSettings` should pass that path to
    /// `profile(for:executablePath:)` - a user-configured path can differ from
    /// the detected one.
    static func detectedProfile(for runtime: AgentRuntimeID) -> AgentRuntimeCapabilityProfile {
        guard runtime == .copilotCLI else {
            return defaultProfile(for: runtime)
        }
        return profile(for: runtime, executablePath: CopilotCLIRuntime.detectPath())
    }
}

private extension AgentRuntimeTaskScopedMCPDelivery {
    init(deliveryOwnership: MCPRuntimeConfigDeliveryOwnership) {
        switch deliveryOwnership {
        case .astraEphemeralLaunchFile:
            self = .claudeStrictConfigFile
        case .astraInlineLaunchArgument:
            self = .codexInlineConfig
        case .astraAdditionalLaunchFile:
            self = .copilotAdditionalConfigFile
        case .unsupported:
            self = .unsupported
        }
    }
}
