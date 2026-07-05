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
    var observedEvidence: [String]

    /// True when ASTRA knows how to deliver task-scoped MCP configuration to
    /// this runtime before launch. This does not prove any feature-specific
    /// MCP server was selected, rendered, or accepted for a run.
    var supportsTaskScopedMCPDelivery: Bool {
        taskScopedMCPDelivery != .unsupported
    }

    /// Pre-render eligibility for delivering the host-control MCP server to
    /// the runtime. The launch resolver still owns selecting and rendering the
    /// concrete server for a run.
    var canDeliverHostControlPlaneMCP: Bool {
        supportsTaskScopedMCPDelivery
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

    static func defaultProfile(for runtime: AgentRuntimeID) -> AgentRuntimeCapabilityProfile {
        let descriptor = AgentRuntimeAdapterRegistry.descriptor(for: runtime)
        let mcpProfile = MCPRuntimeSupportMatrix.profile(for: descriptor)
        return AgentRuntimeCapabilityProfile(
            descriptor: descriptor,
            mcpProfile: mcpProfile,
            supportsShellToolForBrowserBridge: defaultShellToolSupport(for: runtime),
            observedEvidence: defaultEvidence(for: runtime, delivery: mcpProfile.configDeliveryOwnership)
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
        observedEvidence: [String]
    ) {
        self.runtime = descriptor.id
        self.displayName = descriptor.displayName
        self.taskScopedMCPDelivery = AgentRuntimeTaskScopedMCPDelivery(
            deliveryOwnership: mcpProfile.configDeliveryOwnership
        )
        self.supportsNativeContinuation = descriptor.supportsNativeContinuation
        self.supportsShellToolForBrowserBridge = supportsShellToolForBrowserBridge
        self.observedEvidence = observedEvidence
    }

    private static func defaultShellToolSupport(for runtime: AgentRuntimeID) -> Bool {
        runtime != .copilotCLI && AgentRuntimeAdapterRegistry.hasAdapter(for: runtime)
    }

    private static func defaultEvidence(
        for runtime: AgentRuntimeID,
        delivery: MCPRuntimeConfigDeliveryOwnership
    ) -> [String] {
        switch delivery {
        case .astraEphemeralLaunchFile:
            ["descriptor:claude-mcp-config"]
        case .astraInlineLaunchArgument:
            ["descriptor:codex-inline-mcp"]
        case .astraAdditionalLaunchFile:
            ["descriptor:additional-mcp-config"]
        case .unsupported:
            if runtime == .copilotCLI {
                ["copilot-help:missing-additional-mcp-config"]
            } else {
                ["adapter:no-task-scoped-mcp-projection"]
            }
        }
    }
}

enum AgentRuntimeCapabilityProfileService {
    static func defaultProfile(for runtime: AgentRuntimeID) -> AgentRuntimeCapabilityProfile {
        AgentRuntimeCapabilityProfile.defaultProfile(for: runtime)
    }

    static func profile(
        for runtime: AgentRuntimeID,
        executablePath: String
    ) -> AgentRuntimeCapabilityProfile {
        guard runtime == .copilotCLI else {
            return AgentRuntimeCapabilityProfile.defaultProfile(for: runtime)
        }

        let capabilities = CopilotCLIRuntime.capabilities(executablePath: executablePath)
        return AgentRuntimeCapabilityProfile.copilotProfile(
            supportsAdditionalMCPConfig: capabilities.supportsAdditionalMCPConfig
        )
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
