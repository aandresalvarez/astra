import Foundation
import ASTRACore

enum MCPRuntimeDeliveryCompatibility: Equatable, Sendable {
    case compatible
    case incompatible
}

enum MCPRuntimeDeliveryMethod: Equatable, Sendable {
    case directRuntimeConfig
    case gatewayProjection
    case notDelivered
}

enum MCPRuntimeDeliveryIncompatibility: Equatable, Sendable {
    case runtimeDeliveryUnsupported
    case unsupportedTransport(PluginMCPServer.Transport)
    case unsupportedBindingDestination(MCPRuntimeBindingDestination)
    case runtimeBindingProjectionUnsupported(MCPRuntimeBindingDestination)
    case untrustedCredentialEndpoint(String)
    case missingControlPlaneBindings
    case missingRemoteEndpoint
    case missingStdioCommand
}

struct MCPRuntimeDeliveryPlanRow: Equatable, Sendable {
    var runtimeID: AgentRuntimeID
    var displayName: String
    var compatibility: MCPRuntimeDeliveryCompatibility
    var deliveryMethod: MCPRuntimeDeliveryMethod
    var configDeliveryOwnership: MCPRuntimeConfigDeliveryOwnership
    var providerFacingTransport: PluginMCPServer.Transport?
    var deliverableBindingDestinations: [MCPRuntimeBindingDestination]
    var expectedEvidence: [MCPRuntimeDeliveryEvidence]
    var expectedDriftKinds: [MCPValidationDriftKind]
    var incompatibilities: [MCPRuntimeDeliveryIncompatibility]
}

enum MCPRuntimeDeliveryPlanner {
    static func plan(
        package: PluginPackage,
        server: PluginMCPServer,
        controlPlane explicitControlPlane: MCPControlPlaneMetadata? = nil,
        profiles: [MCPRuntimeSupportProfile] = MCPRuntimeSupportMatrix.defaultProfiles()
    ) -> [MCPRuntimeDeliveryPlanRow] {
        plan(
            server: server,
            packageID: package.id,
            packageSourceMetadata: package.sourceMetadata,
            controlPlane: explicitControlPlane,
            profiles: profiles
        )
    }

    static func plan(
        server: PluginMCPServer,
        packageID: String? = nil,
        packageSourceMetadata: CapabilitySourceMetadata? = nil,
        controlPlane explicitControlPlane: MCPControlPlaneMetadata? = nil,
        profiles: [MCPRuntimeSupportProfile] = MCPRuntimeSupportMatrix.defaultProfiles()
    ) -> [MCPRuntimeDeliveryPlanRow] {
        let controlPlane = explicitControlPlane ?? server.controlPlane ?? MCPControlPlaneMetadata()
        let declaredControlPlaneBindingDestinations = orderedUnique(controlPlane.runtimeBindings.map(\.destination))
        let projectableGatewayBindingDestinations = RemoteMCPGatewayProjection.projectableGatewayBindingDestinations(
            controlPlane: controlPlane
        )
        let requiresGateway = server.transport != .stdio && !server.connectorBindings.isEmpty

        return profiles.map { profile in
            row(
                for: profile,
                server: server,
                packageID: packageID,
                packageSourceMetadata: packageSourceMetadata,
                controlPlane: controlPlane,
                declaredControlPlaneBindingDestinations: declaredControlPlaneBindingDestinations,
                projectableGatewayBindingDestinations: projectableGatewayBindingDestinations,
                requiresGateway: requiresGateway
            )
        }
    }

    private static func row(
        for profile: MCPRuntimeSupportProfile,
        server: PluginMCPServer,
        packageID: String?,
        packageSourceMetadata: CapabilitySourceMetadata?,
        controlPlane: MCPControlPlaneMetadata,
        declaredControlPlaneBindingDestinations: [MCPRuntimeBindingDestination],
        projectableGatewayBindingDestinations: [MCPRuntimeBindingDestination],
        requiresGateway: Bool
    ) -> MCPRuntimeDeliveryPlanRow {
        let incompatibilities = incompatibilities(
            for: profile,
            server: server,
            packageID: packageID,
            packageSourceMetadata: packageSourceMetadata,
            controlPlane: controlPlane,
            declaredControlPlaneBindingDestinations: declaredControlPlaneBindingDestinations,
            projectableGatewayBindingDestinations: projectableGatewayBindingDestinations,
            requiresGateway: requiresGateway
        )
        let compatible = incompatibilities.isEmpty
        let deliveryMethod = compatible
            ? (requiresGateway ? MCPRuntimeDeliveryMethod.gatewayProjection : .directRuntimeConfig)
            : .notDelivered
        let providerFacingTransport: PluginMCPServer.Transport? = compatible
            ? (requiresGateway ? .stdio : server.transport)
            : nil
        let deliverableBindings = compatible ? deliverableBindingDestinations(
            server: server,
            projectableGatewayBindingDestinations: projectableGatewayBindingDestinations,
            requiresGateway: requiresGateway
        ) : []
        let evidence = expectedEvidence(
            for: profile,
            serverID: server.id,
            deliveryMethod: deliveryMethod,
            compatible: compatible
        )

        return MCPRuntimeDeliveryPlanRow(
            runtimeID: profile.runtimeID,
            displayName: profile.displayName,
            compatibility: compatible ? .compatible : .incompatible,
            deliveryMethod: deliveryMethod,
            configDeliveryOwnership: profile.configDeliveryOwnership,
            providerFacingTransport: providerFacingTransport,
            deliverableBindingDestinations: deliverableBindings,
            expectedEvidence: evidence,
            expectedDriftKinds: expectedDriftKinds(for: incompatibilities),
            incompatibilities: incompatibilities
        )
    }

    private static func incompatibilities(
        for profile: MCPRuntimeSupportProfile,
        server: PluginMCPServer,
        packageID: String?,
        packageSourceMetadata: CapabilitySourceMetadata?,
        controlPlane: MCPControlPlaneMetadata,
        declaredControlPlaneBindingDestinations: [MCPRuntimeBindingDestination],
        projectableGatewayBindingDestinations: [MCPRuntimeBindingDestination],
        requiresGateway: Bool
    ) -> [MCPRuntimeDeliveryIncompatibility] {
        guard profile.supportsDelivery else {
            return [.runtimeDeliveryUnsupported]
        }

        if let shapeIssue = shapeIncompatibility(for: server) {
            return [shapeIssue]
        }

        var issues: [MCPRuntimeDeliveryIncompatibility] = []
        if requiresGateway {
            if let reason = RemoteMCPGatewayEndpointTrustPolicy.credentialForwardingEndpointViolation(
                packageID: packageID ?? "",
                packageSourceMetadata: packageSourceMetadata,
                server: server,
                controlPlane: controlPlane
            ) {
                issues.append(.untrustedCredentialEndpoint(reason))
            }
            if declaredControlPlaneBindingDestinations.isEmpty {
                issues.append(.missingControlPlaneBindings)
            }
            if !profile.supportsTransport(.stdio) {
                issues.append(.unsupportedTransport(.stdio))
            }
            let unprojectable = declaredControlPlaneBindingDestinations.filter {
                !projectableGatewayBindingDestinations.contains($0)
            }
            issues.append(contentsOf: unprojectable.map { .runtimeBindingProjectionUnsupported($0) })
            issues.append(contentsOf: projectableGatewayBindingDestinations
                .filter { !profile.supportsGatewayBinding($0) }
                .map { .unsupportedBindingDestination($0) })
        } else {
            if !profile.supportsTransport(server.transport) {
                issues.append(.unsupportedTransport(server.transport))
            }
            if !declaredControlPlaneBindingDestinations.isEmpty {
                issues.append(contentsOf: declaredControlPlaneBindingDestinations
                    .map { .runtimeBindingProjectionUnsupported($0) })
            } else if !server.environmentKeys.isEmpty, !profile.supportsNativeBinding(.environment) {
                issues.append(.unsupportedBindingDestination(.environment))
            }
        }
        return orderedUnique(issues)
    }

    private static func deliverableBindingDestinations(
        server: PluginMCPServer,
        projectableGatewayBindingDestinations: [MCPRuntimeBindingDestination],
        requiresGateway: Bool
    ) -> [MCPRuntimeBindingDestination] {
        if requiresGateway {
            return projectableGatewayBindingDestinations
        }
        return server.environmentKeys.isEmpty ? [] : [.environment]
    }

    private static func shapeIncompatibility(
        for server: PluginMCPServer
    ) -> MCPRuntimeDeliveryIncompatibility? {
        switch server.transport {
        case .stdio:
            guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                return .missingStdioCommand
            }
            return nil
        case .http, .sse:
            guard server.url != nil else {
                return .missingRemoteEndpoint
            }
            return nil
        }
    }

    private static func expectedEvidence(
        for profile: MCPRuntimeSupportProfile,
        serverID: String,
        deliveryMethod: MCPRuntimeDeliveryMethod,
        compatible: Bool
    ) -> [MCPRuntimeDeliveryEvidence] {
        var kinds: [MCPRuntimeDeliveryEvidenceKind] = [.manifestDeclared]
        if compatible {
            if deliveryMethod == .gatewayProjection {
                kinds.append(.gatewayProjection)
            }
            kinds.append(.runtimeConfigRendered)
            kinds.append(contentsOf: profile.validationEvidenceKinds)
        }
        return orderedUnique(kinds).map { kind in
            MCPRuntimeDeliveryEvidence(
                id: "\(profile.runtimeID.rawValue):\(serverID):\(kind.rawValue)",
                serverID: serverID,
                kind: kind,
                status: .pending,
                diagnosticRefIDs: ["runtime:\(profile.runtimeID.rawValue)"]
            )
        }
    }

    private static func expectedDriftKinds(
        for incompatibilities: [MCPRuntimeDeliveryIncompatibility]
    ) -> [MCPValidationDriftKind] {
        if incompatibilities.isEmpty {
            return []
        }
        if incompatibilities.contains(.runtimeDeliveryUnsupported) {
            return [.missingServer]
        }
        if incompatibilities.contains(.missingControlPlaneBindings) {
            return [.authProfileMismatch, .runtimeBindingMismatch]
        }
        if incompatibilities.contains(.missingRemoteEndpoint)
            || incompatibilities.contains(.missingStdioCommand) {
            return [.manifestShapeMismatch]
        }
        if incompatibilities.contains(where: { issue in
            if case .unsupportedTransport = issue { return true }
            return false
        }) {
            return [.runtimeCapabilityMismatch]
        }
        if incompatibilities.contains(where: { issue in
            if case .unsupportedBindingDestination = issue { return true }
            if case .runtimeBindingProjectionUnsupported = issue { return true }
            if case .untrustedCredentialEndpoint = issue { return true }
            return false
        }) {
            return [.runtimeBindingMismatch]
        }
        return [.missingServer]
    }

    private static func orderedUnique<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
