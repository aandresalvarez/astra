import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("MCP Runtime Support Matrix")
struct MCPRuntimeSupportMatrixTests {
    @Test("Profiles expose runtime-specific transport binding and delivery facts")
    func profilesExposeRuntimeSpecificDeliveryFacts() throws {
        let profiles = MCPRuntimeSupportMatrix.defaultProfiles()

        let claude = try #require(profiles.profile(for: .claudeCode))
        #expect(claude.supportedTransports == [.stdio, .http, .sse])
        #expect(claude.nativeBindingDestinations == [.environment])
        #expect(claude.gatewayBindingDestinations == [.environment, .httpHeader])
        #expect(claude.configDeliveryOwnership == .astraEphemeralLaunchFile)
        #expect(claude.validationEvidenceKinds.contains(.healthProbe))

        let codex = try #require(profiles.profile(for: .codexCLI))
        #expect(codex.supportedTransports == [.stdio, .http, .sse])
        #expect(codex.nativeBindingDestinations == [.environment])
        #expect(codex.gatewayBindingDestinations == [.environment, .httpHeader])
        #expect(codex.configDeliveryOwnership == .astraInlineLaunchArgument)

        let copilot = try #require(profiles.profile(for: .copilotCLI))
        #expect(!copilot.supportsDelivery)
        let observedCopilot = MCPRuntimeSupportMatrix.copilotProfile(
            for: AgentRuntimeAdapterRegistry.descriptor(for: .copilotCLI),
            supportsAdditionalMCPConfig: true
        )
        #expect(observedCopilot.configDeliveryOwnership == .astraAdditionalLaunchFile)

        let cursor = try #require(profiles.profile(for: .cursorCLI))
        #expect(cursor.supportedTransports.isEmpty)
        #expect(cursor.nativeBindingDestinations.isEmpty)
        #expect(cursor.gatewayBindingDestinations.isEmpty)
        #expect(cursor.configDeliveryOwnership == .unsupported)
    }

    @Test("Planner delivers stdio env bindings to Claude and Codex but not Cursor")
    func plannerDeliversStdioEnvBindingsToSupportedRuntimes() throws {
        let server = PluginMCPServer(
            id: "local_files",
            displayName: "Local Files",
            transport: .stdio,
            command: "/usr/local/bin/local-files",
            environmentKeys: ["LOCAL_FILES_ROOT"]
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            server: server,
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .compatible)
        #expect(claude.deliveryMethod == .directRuntimeConfig)
        #expect(claude.providerFacingTransport == .stdio)
        #expect(claude.deliverableBindingDestinations == [.environment])
        #expect(claude.expectedEvidence.map(\.kind).contains(.runtimeConfigRendered))
        #expect(!claude.expectedEvidence.map(\.kind).contains(.gatewayProjection))

        let codex = try #require(rows.row(for: .codexCLI))
        #expect(codex.compatibility == .compatible)
        #expect(codex.deliveryMethod == .directRuntimeConfig)
        #expect(codex.configDeliveryOwnership == .astraInlineLaunchArgument)
        #expect(codex.expectedEvidence.map(\.kind).contains(.providerAccepted))

        let cursor = try #require(rows.row(for: .cursorCLI))
        #expect(cursor.compatibility == .incompatible)
        #expect(cursor.deliveryMethod == .notDelivered)
        #expect(cursor.incompatibilities == [.runtimeDeliveryUnsupported])
        #expect(cursor.expectedDriftKinds == [.missingServer])
    }

    @Test("Planner routes remote HTTP header bindings through the ASTRA gateway")
    func plannerRoutesRemoteHTTPHeaderBindingsThroughGateway() throws {
        let server = PluginMCPServer(
            id: "google_workspace_drive",
            displayName: "Google Drive",
            transport: .http,
            url: URL(string: "https://drivemcp.googleapis.com/mcp/v1")!,
            connectorBindings: ["google-workspace"]
        )
        let controlPlane = MCPControlPlaneMetadata(
            secretRefs: [
                MCPSecretRef(id: "google-access-token", purpose: "Short-lived access token.")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "auth-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .literal("Bearer "),
                        .reference(.secret("google-access-token"))
                    ]
                )
            ]
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            package: trustedGoogleWorkspacePackage(server: server),
            server: server,
            controlPlane: controlPlane,
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .compatible)
        #expect(claude.deliveryMethod == .gatewayProjection)
        #expect(claude.providerFacingTransport == .stdio)
        #expect(claude.deliverableBindingDestinations == [.httpHeader])
        #expect(claude.expectedEvidence.map(\.kind).contains(.gatewayProjection))
        #expect(claude.expectedEvidence.map(\.kind).contains(.healthProbe))

        let codex = try #require(rows.row(for: .codexCLI))
        #expect(codex.compatibility == .compatible)
        #expect(codex.deliveryMethod == .gatewayProjection)
        #expect(codex.configDeliveryOwnership == .astraInlineLaunchArgument)
        #expect(codex.expectedEvidence.map(\.kind).contains(.runtimeConfigRendered))
    }

    @Test("Planner rejects copied Google Workspace gateway identity without trusted package provenance")
    func plannerRejectsCopiedGoogleWorkspaceGatewayIdentityWithoutTrustedPackageProvenance() throws {
        let server = PluginMCPServer(
            id: "google_workspace_drive",
            displayName: "Google Drive",
            transport: .http,
            url: URL(string: "https://drivemcp.googleapis.com/mcp/v1")!,
            connectorBindings: ["google-workspace"]
        )
        let controlPlane = MCPControlPlaneMetadata(
            secretRefs: [
                MCPSecretRef(id: "google-access-token", purpose: "Short-lived access token.")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "auth-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .literal("Bearer "),
                        .reference(.secret("google-access-token"))
                    ]
                )
            ]
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            server: server,
            packageID: "google-workspace",
            packageSourceMetadata: .localLibrary(),
            controlPlane: controlPlane,
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .incompatible)
        #expect(claude.deliveryMethod == .notDelivered)
        #expect(claude.incompatibilities == [
            .untrustedCredentialEndpoint(RemoteMCPGatewayEndpointTrustPolicy.untrustedCredentialEndpointReason)
        ])
        #expect(claude.expectedDriftKinds == [.runtimeBindingMismatch])
    }

    @Test("Planner does not claim remote HTTP header support without gateway ownership")
    func plannerRejectsRemoteHTTPHeaderBindingsWithoutGatewayOwnership() throws {
        let server = PluginMCPServer(
            id: "direct_remote",
            displayName: "Direct Remote",
            transport: .http,
            url: URL(string: "https://mcp.example.com/direct")!
        )
        let controlPlane = MCPControlPlaneMetadata(
            secretRefs: [
                MCPSecretRef(id: "remote-token", purpose: "Remote bearer token.")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "auth-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [.reference(.secret("remote-token"))]
                )
            ]
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            server: server,
            controlPlane: controlPlane,
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .incompatible)
        #expect(claude.deliveryMethod == .notDelivered)
        #expect(claude.incompatibilities == [.runtimeBindingProjectionUnsupported(.httpHeader)])
        #expect(claude.expectedEvidence.map(\.kind) == [.manifestDeclared])
        #expect(claude.expectedDriftKinds == [.runtimeBindingMismatch])

        let cursor = try #require(rows.row(for: .cursorCLI))
        #expect(cursor.incompatibilities == [.runtimeDeliveryUnsupported])
    }

    @Test("Planner keeps remote HTTP without bindings as direct runtime config")
    func plannerKeepsUnboundRemoteHTTPDirect() throws {
        let server = PluginMCPServer(
            id: "public_remote",
            displayName: "Public Remote",
            transport: .http,
            url: URL(string: "https://mcp.example.com/public")!
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            server: server,
            controlPlane: MCPControlPlaneMetadata(),
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .compatible)
        #expect(claude.deliveryMethod == .directRuntimeConfig)
        #expect(claude.providerFacingTransport == .http)
        #expect(claude.deliverableBindingDestinations.isEmpty)
        #expect(!claude.expectedEvidence.map(\.kind).contains(.gatewayProjection))
    }

    @Test("Planner does not claim connector-bound gateway auth without control-plane bindings")
    func plannerRequiresControlPlaneBindingsForConnectorBoundGatewayAuth() throws {
        let server = PluginMCPServer(
            id: "google_drive",
            displayName: "Google Drive",
            transport: .http,
            url: URL(string: "https://mcp.example.com/google")!,
            connectorBindings: ["google-workspace"]
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            server: server,
            controlPlane: MCPControlPlaneMetadata(),
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .incompatible)
        #expect(claude.incompatibilities == [.missingControlPlaneBindings])
        #expect(claude.expectedDriftKinds == [.authProfileMismatch, .runtimeBindingMismatch])
    }

    @Test("Planner rejects gateway bindings the renderer cannot project")
    func plannerRejectsGatewayBindingsTheRendererCannotProject() throws {
        let server = PluginMCPServer(
            id: "google_drive",
            displayName: "Google Drive",
            transport: .http,
            url: URL(string: "https://mcp.example.com/google")!,
            connectorBindings: ["google-workspace"]
        )
        let controlPlane = MCPControlPlaneMetadata(
            secretRefs: [
                MCPSecretRef(id: "google-access-token", purpose: "Short-lived access token.")
            ],
            runtimeBindings: [
                MCPRuntimeBindingTemplate(
                    id: "auth-header",
                    destination: .httpHeader,
                    name: "Authorization",
                    template: [
                        .reference(.secret("google-access-token"))
                    ]
                )
            ]
        )

        let rows = MCPRuntimeDeliveryPlanner.plan(
            server: server,
            controlPlane: controlPlane,
            profiles: focusedProfiles()
        )

        let claude = try #require(rows.row(for: .claudeCode))
        #expect(claude.compatibility == .incompatible)
        #expect(claude.incompatibilities == [.runtimeBindingProjectionUnsupported(.httpHeader)])
        #expect(claude.expectedDriftKinds == [.runtimeBindingMismatch])
    }

    @Test("Planner keeps manifest shape and runtime support root causes distinct")
    func plannerKeepsRootCauseSpecificDriftKinds() throws {
        let missingCommand = PluginMCPServer(
            id: "missing-command",
            displayName: "Missing Command",
            transport: .stdio
        )
        let missingURL = PluginMCPServer(
            id: "missing-url",
            displayName: "Missing URL",
            transport: .http
        )
        let httpOnlyProfile = MCPRuntimeSupportProfile(
            runtimeID: .claudeCode,
            displayName: "Claude Code",
            supportedTransports: [.stdio],
            nativeBindingDestinations: [.environment],
            gatewayBindingDestinations: [.environment, .httpHeader],
            configDeliveryOwnership: .astraEphemeralLaunchFile,
            validationEvidenceKinds: []
        )
        let unsupportedTransport = PluginMCPServer(
            id: "http",
            displayName: "HTTP",
            transport: .http,
            url: URL(string: "https://mcp.example.com/http")!
        )

        let missingCommandRow = try #require(MCPRuntimeDeliveryPlanner.plan(
            server: missingCommand,
            profiles: focusedProfiles()
        ).row(for: .claudeCode))
        let missingURLRow = try #require(MCPRuntimeDeliveryPlanner.plan(
            server: missingURL,
            profiles: focusedProfiles()
        ).row(for: .claudeCode))
        let unsupportedTransportRow = try #require(MCPRuntimeDeliveryPlanner.plan(
            server: unsupportedTransport,
            profiles: [httpOnlyProfile]
        ).row(for: .claudeCode))

        #expect(missingCommandRow.incompatibilities == [.missingStdioCommand])
        #expect(missingCommandRow.expectedDriftKinds == [.manifestShapeMismatch])
        #expect(missingURLRow.incompatibilities == [.missingRemoteEndpoint])
        #expect(missingURLRow.expectedDriftKinds == [.manifestShapeMismatch])
        #expect(unsupportedTransportRow.incompatibilities == [.unsupportedTransport(.http)])
        #expect(unsupportedTransportRow.expectedDriftKinds == [.runtimeCapabilityMismatch])
    }
}

private func focusedProfiles() -> [MCPRuntimeSupportProfile] {
    MCPRuntimeSupportMatrix.defaultProfiles()
        .filter { [.claudeCode, .codexCLI, .cursorCLI].contains($0.runtimeID) }
}

private func trustedGoogleWorkspacePackage(server: PluginMCPServer) -> PluginPackage {
    PluginPackage(
        id: GoogleWorkspaceCapability.packageID,
        name: "Google Workspace",
        icon: "doc.richtext",
        description: "Google Workspace",
        author: "ASTRA",
        category: "Integrations",
        tags: ["google"],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [],
        mcpServers: [server],
        templates: [],
        sourceMetadata: .builtIn()
    )
}

private extension Array where Element == MCPRuntimeSupportProfile {
    func profile(for runtimeID: AgentRuntimeID) -> MCPRuntimeSupportProfile? {
        first { $0.runtimeID == runtimeID }
    }
}

private extension Array where Element == MCPRuntimeDeliveryPlanRow {
    func row(for runtimeID: AgentRuntimeID) -> MCPRuntimeDeliveryPlanRow? {
        first { $0.runtimeID == runtimeID }
    }
}
