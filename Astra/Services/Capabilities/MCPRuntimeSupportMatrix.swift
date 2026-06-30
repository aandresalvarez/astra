import Foundation
import ASTRACore

enum MCPRuntimeConfigDeliveryOwnership: Equatable, Sendable {
    case astraEphemeralLaunchFile
    case astraAdditionalLaunchFile
    case astraInlineLaunchArgument
    case unsupported
}

struct MCPRuntimeSupportProfile: Equatable, Sendable {
    var runtimeID: AgentRuntimeID
    var displayName: String
    var supportedTransports: [PluginMCPServer.Transport]
    var nativeBindingDestinations: [MCPRuntimeBindingDestination]
    var gatewayBindingDestinations: [MCPRuntimeBindingDestination]
    var configDeliveryOwnership: MCPRuntimeConfigDeliveryOwnership
    var validationEvidenceKinds: [MCPRuntimeDeliveryEvidenceKind]

    var supportsDelivery: Bool {
        configDeliveryOwnership != .unsupported && !supportedTransports.isEmpty
    }

    func supportsTransport(_ transport: PluginMCPServer.Transport) -> Bool {
        supportedTransports.contains(transport)
    }

    func supportsNativeBinding(_ destination: MCPRuntimeBindingDestination) -> Bool {
        nativeBindingDestinations.contains(destination)
    }

    func supportsGatewayBinding(_ destination: MCPRuntimeBindingDestination) -> Bool {
        gatewayBindingDestinations.contains(destination)
    }
}

enum MCPRuntimeSupportMatrix {
    static func defaultProfiles() -> [MCPRuntimeSupportProfile] {
        profiles(for: AgentRuntimeAdapterRegistry.descriptors)
    }

    static func profiles(
        for descriptors: [AgentRuntimeDescriptor]
    ) -> [MCPRuntimeSupportProfile] {
        descriptors.map(profile(for:))
    }

    static func profile(
        for descriptor: AgentRuntimeDescriptor
    ) -> MCPRuntimeSupportProfile {
        guard descriptor.supportsMCPServers else {
            return unsupportedProfile(for: descriptor)
        }

        switch descriptor.id {
        case .claudeCode:
            return supportedProfile(
                for: descriptor,
                ownership: .astraEphemeralLaunchFile
            )
        case .copilotCLI:
            return unsupportedProfile(for: descriptor)
        case .codexCLI:
            return supportedProfile(
                for: descriptor,
                ownership: .astraInlineLaunchArgument
            )
        default:
            return unsupportedProfile(for: descriptor)
        }
    }

    private static func supportedProfile(
        for descriptor: AgentRuntimeDescriptor,
        ownership: MCPRuntimeConfigDeliveryOwnership
    ) -> MCPRuntimeSupportProfile {
        MCPRuntimeSupportProfile(
            runtimeID: descriptor.id,
            displayName: descriptor.displayName,
            supportedTransports: [.stdio, .http, .sse],
            nativeBindingDestinations: [.environment],
            gatewayBindingDestinations: [.environment, .httpHeader],
            configDeliveryOwnership: ownership,
            validationEvidenceKinds: [.providerAccepted, .healthProbe]
        )
    }

    static func copilotProfile(
        for descriptor: AgentRuntimeDescriptor,
        supportsAdditionalMCPConfig: Bool
    ) -> MCPRuntimeSupportProfile {
        guard supportsAdditionalMCPConfig else {
            return unsupportedProfile(for: descriptor)
        }
        return supportedProfile(
            for: descriptor,
            ownership: .astraAdditionalLaunchFile
        )
    }

    private static func unsupportedProfile(
        for descriptor: AgentRuntimeDescriptor
    ) -> MCPRuntimeSupportProfile {
        MCPRuntimeSupportProfile(
            runtimeID: descriptor.id,
            displayName: descriptor.displayName,
            supportedTransports: [],
            nativeBindingDestinations: [],
            gatewayBindingDestinations: [],
            configDeliveryOwnership: .unsupported,
            validationEvidenceKinds: []
        )
    }
}
