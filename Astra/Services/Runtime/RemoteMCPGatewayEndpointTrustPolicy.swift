import Foundation
import ASTRACore

enum RemoteMCPGatewayEndpointTrustPolicy {
    static let missingCredentialEndpointReason = "credentialed remote MCP endpoint URL is missing or invalid"
    static let untrustedCredentialEndpointReason = "credentialed remote MCP endpoint must match a trusted ASTRA registry entry before ASTRA will forward connector bearer tokens"

    static func credentialForwardingEndpointViolation(
        package: PluginPackage,
        server: PluginMCPServer,
        controlPlane: MCPControlPlaneMetadata? = nil
    ) -> String? {
        credentialForwardingEndpointViolation(
            packageID: package.id,
            packageSourceMetadata: package.sourceMetadata,
            server: server,
            controlPlane: controlPlane
        )
    }

    static func credentialForwardingEndpointViolation(
        packageID: String,
        packageSourceMetadata: CapabilitySourceMetadata?,
        server: PluginMCPServer,
        controlPlane: MCPControlPlaneMetadata? = nil
    ) -> String? {
        guard isCredentialForwardingGatewayCandidate(server, controlPlane: controlPlane) else {
            return nil
        }
        guard server.url != nil else {
            return missingCredentialEndpointReason
        }
        guard trustedCredentialEndpoint(
            packageID: packageID,
            packageSourceMetadata: packageSourceMetadata,
            server: server
        ) else {
            return untrustedCredentialEndpointReason
        }
        return nil
    }

    static func isCredentialForwardingGatewayCandidate(
        _ server: PluginMCPServer,
        controlPlane: MCPControlPlaneMetadata? = nil
    ) -> Bool {
        server.transport != .stdio
            && !server.connectorBindings.isEmpty
            && gatewayAccessTokenBinding(in: controlPlane ?? server.controlPlane) != nil
    }

    static func gatewayAccessTokenBinding(
        in controlPlane: MCPControlPlaneMetadata?
    ) -> MCPRuntimeBindingTemplate? {
        gatewayAccessTokenBinding(in: controlPlane?.runtimeBindings ?? [])
    }

    static func gatewayAccessTokenBinding(
        in bindings: [MCPRuntimeBindingTemplate]
    ) -> MCPRuntimeBindingTemplate? {
        bindings.first { gatewayAccessTokenBinding($0) != nil }
    }

    static func gatewayAccessTokenBinding(
        _ binding: MCPRuntimeBindingTemplate
    ) -> MCPRuntimeBindingTemplate? {
        guard binding.destination == .httpHeader,
              binding.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Authorization") == .orderedSame,
              binding.template.count == 2 else {
            return nil
        }
        guard binding.template[0].kind == .literal,
              binding.template[0].literal == "Bearer ",
              binding.template[0].reference == nil else {
            return nil
        }
        guard binding.template[1].kind == .reference,
              binding.template[1].literal == nil,
              binding.template[1].reference?.kind == .secretRef,
              binding.template[1].reference?.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return binding
    }

    private static func trustedCredentialEndpoint(
        packageID: String,
        packageSourceMetadata: CapabilitySourceMetadata?,
        server: PluginMCPServer
    ) -> Bool {
        trustedGoogleWorkspaceEndpoint(
            packageID: packageID,
            packageSourceMetadata: packageSourceMetadata,
            server: server
        )
    }

    private static func trustedGoogleWorkspaceEndpoint(
        packageID: String,
        packageSourceMetadata: CapabilitySourceMetadata?,
        server: PluginMCPServer
    ) -> Bool {
        guard packageID == GoogleWorkspaceCapability.packageID,
              hasBuiltInSourceTrust(packageSourceMetadata),
              server.connectorBindings.contains(GoogleWorkspaceCapability.connectorBinding),
              let endpoint = server.url else {
            return false
        }
        guard let product = GoogleWorkspaceRemoteMCPRegistry.products.first(where: {
            $0.serverID == server.id && $0.transport == server.transport
        }) else {
            return false
        }
        return endpointsMatch(endpoint, product.endpoint)
    }

    private static func hasBuiltInSourceTrust(_ sourceMetadata: CapabilitySourceMetadata?) -> Bool {
        let builtInSource = CapabilitySourceMetadata.builtIn()
        return sourceMetadata?.id == builtInSource.id
            && sourceMetadata?.kind == builtInSource.kind
            && sourceMetadata?.trustLevel == builtInSource.trustLevel
    }

    private static func endpointsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsComponents = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let rhsComponents = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else {
            return lhs.absoluteString == rhs.absoluteString
        }

        let lhsScheme = lhsComponents.scheme?.lowercased()
        let rhsScheme = rhsComponents.scheme?.lowercased()
        return lhsScheme == rhsScheme
            && lhsComponents.host?.lowercased() == rhsComponents.host?.lowercased()
            && normalizedPort(lhsComponents.port, scheme: lhsScheme) == normalizedPort(rhsComponents.port, scheme: rhsScheme)
            && lhsComponents.percentEncodedPath == rhsComponents.percentEncodedPath
            && lhsComponents.percentEncodedQuery == rhsComponents.percentEncodedQuery
    }

    private static func normalizedPort(_ port: Int?, scheme: String?) -> Int? {
        switch (scheme, port) {
        case ("http", nil):
            return 80
        case ("https", nil):
            return 443
        default:
            return port
        }
    }
}
