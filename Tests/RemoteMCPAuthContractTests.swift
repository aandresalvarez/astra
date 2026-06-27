import Foundation
import Testing
import ASTRACore

@Suite("Remote MCP auth contracts")
struct RemoteMCPAuthContractTests {
    @Test("remote Google Workspace MCP registry metadata round trips without credentials")
    func googleWorkspaceRegistryMetadataRoundTripsWithoutCredentials() throws {
        let registry = RemoteMCPServerRegistryMetadata(
            registryID: "google-workspace",
            providerID: "googleWorkspace",
            providerDisplayName: "Google Workspace",
            endpoint: URL(string: "https://mcp.astra.local/google-workspace"),
            authProfile: RemoteMCPAuthProfile(
                id: "google-workspace-primary",
                providerID: "googleWorkspace",
                authorizationKind: .astraOwnedOAuth,
                account: OAuthAccountIdentity(
                    providerSubject: "google-oauth2|12345",
                    email: "owner@example.com",
                    displayName: "Owner Example",
                    hostedDomain: "example.com"
                ),
                scopes: [
                    OAuthScope(
                        value: "https://www.googleapis.com/auth/drive.metadata.readonly",
                        purpose: "Read Drive metadata for generated app contract responses.",
                        sensitivity: .restricted,
                        required: true
                    )
                ],
                consentRequired: true,
                auditEventNamespace: "google.workspace"
            ),
            contractIDs: [.googleWorkspaceDriveRead, .googleWorkspaceDocsRead],
            toolClassifications: [
                RemoteMCPToolClassification(
                    toolName: "drive.files.list",
                    contractID: .googleWorkspaceDriveRead,
                    effect: .read,
                    dataAccess: [.externalService],
                    riskLevel: .medium,
                    requiresExplicitUserConsent: false,
                    auditEventName: "google.workspace.drive.files.list"
                )
            ]
        )
        let server = PluginMCPServer(
            id: "google-workspace",
            displayName: "Google Workspace Remote MCP",
            transport: .http,
            url: URL(string: "https://mcp.astra.local/google-workspace"),
            allowedTools: ["drive.files.list"],
            trustLevel: .high,
            remoteRegistry: registry
        )

        let data = try JSONEncoder().encode(server)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(PluginMCPServer.self, from: data)

        #expect(decoded.remoteRegistry == registry)
        #expect(decoded.remoteRegistry?.authProfile?.authorizationKind == .astraOwnedOAuth)
        #expect(!json.localizedCaseInsensitiveContains("accessToken"))
        #expect(!json.localizedCaseInsensitiveContains("refreshToken"))
        #expect(!json.contains("ya29.secret-token"))
        #expect(registry.invariantViolations().isEmpty)
    }

    @Test("remote registry metadata decodes secure defaults from older manifests")
    func registryMetadataDecodesSecureDefaults() throws {
        let json = """
        {
          "registryID": "google-workspace",
          "providerID": "googleWorkspace",
          "providerDisplayName": "Google Workspace",
          "contractIDs": ["googleWorkspace.drive.read"],
          "toolClassifications": []
        }
        """

        let decoded = try JSONDecoder().decode(
            RemoteMCPServerRegistryMetadata.self,
            from: Data(json.utf8)
        )

        #expect(decoded.tokenDelivery == .astraBrokered)
        #expect(decoded.exposesRawProviderToolsToGeneratedApps == false)
        #expect(decoded.contractIDs == [.googleWorkspaceDriveRead])
        #expect(decoded.invariantViolations().isEmpty)
    }

    @Test("Google Workspace contract IDs are generated app facing and stable")
    func googleWorkspaceContractIDsAreStable() {
        #expect(RemoteMCPContractID.googleWorkspaceDriveRead.rawValue == "googleWorkspace.drive.read")
        #expect(RemoteMCPContractID.googleWorkspaceDocsRead.rawValue == "googleWorkspace.docs.read")
        #expect(RemoteMCPContractID.googleWorkspaceGmailRead.rawValue == "googleWorkspace.gmail.read")
        #expect(RemoteMCPContractID.googleWorkspaceCalendarRead.rawValue == "googleWorkspace.calendar.read")
        #expect(GoogleWorkspaceContractID.allCases.map(\.contractID).allSatisfy {
            $0.rawValue.hasPrefix("googleWorkspace.")
        })
    }

    @Test("tool classification invariants block raw tool exposure and unconsented writes")
    func toolClassificationInvariantsBlockUnsafeContracts() {
        let safeRead = RemoteMCPToolClassification(
            toolName: "docs.documents.get",
            contractID: .googleWorkspaceDocsRead,
            effect: .read,
            dataAccess: [.externalService],
            riskLevel: .medium,
            requiresExplicitUserConsent: false,
            auditEventName: "google.workspace.docs.documents.get"
        )
        let unsafeWrite = RemoteMCPToolClassification(
            toolName: "gmail.messages.send",
            contractID: .googleWorkspaceGmailSend,
            effect: .send,
            dataAccess: [.externalService],
            riskLevel: .high,
            requiresExplicitUserConsent: false,
            auditEventName: ""
        )
        let unsafeRegistry = RemoteMCPServerRegistryMetadata(
            registryID: "google-workspace",
            providerID: "googleWorkspace",
            providerDisplayName: "Google Workspace",
            contractIDs: [.googleWorkspaceDocsRead, .googleWorkspaceGmailSend],
            toolClassifications: [safeRead, unsafeWrite],
            exposesRawProviderToolsToGeneratedApps: true
        )

        #expect(safeRead.invariantViolations().isEmpty)
        #expect(unsafeWrite.invariantViolations().contains(.mutatingToolRequiresConsent))
        #expect(unsafeWrite.invariantViolations().contains(.auditEventNameRequired))
        #expect(unsafeRegistry.invariantViolations().contains(.rawProviderToolsHiddenFromGeneratedApps))
        #expect(unsafeRegistry.invariantViolations().contains(.invalidToolClassification("gmail.messages.send", .mutatingToolRequiresConsent)))
    }
}
