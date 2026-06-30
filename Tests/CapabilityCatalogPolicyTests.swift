import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability catalog policy")
struct CapabilityCatalogPolicyTests {
    @Test("Approved everyone package is visible and enableable")
    func approvedEveryonePackageIsVisibleAndEnableable() {
        let package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(decision.isVisible)
        #expect(decision.canInstall)
        #expect(decision.canEnable)
        #expect(!decision.canRun)
        #expect(decision.blockers.isEmpty)
    }

    @Test("Enabled approved package can run")
    func enabledApprovedPackageCanRun() {
        let package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id]
            )
        )

        #expect(decision.canRun)
    }

    @Test("Draft package requires approval")
    func draftPackageRequiresApproval() {
        let package = makePolicyPackage(governance: .localDraft())

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(!decision.isVisible)
        #expect(!decision.canInstall)
        #expect(!decision.canEnable)
        #expect(decision.requiresApproval)
        #expect(decision.blockers.contains(.draftRequiresApproval))
        #expect(decision.blockers.contains(.adminApprovalRequired))
    }

    @Test("Admin can see draft package but cannot enable before approval")
    func adminCanSeeDraftPackageButCannotEnableBeforeApproval() {
        let package = makePolicyPackage(governance: .localDraft())

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(decision.isVisible)
        #expect(!decision.canEnable)
        #expect(decision.requiresApproval)
        #expect(decision.blockers.contains(.draftRequiresApproval))
    }

    @Test("Approved local approval record makes draft package enableable")
    func approvedLocalApprovalRecordMakesDraftPackageEnableable() throws {
        let package = makePolicyPackage(governance: .localDraft())
        let record = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: .approved,
            approvedBy: "Security",
            approvedAt: Date(),
            reviewNotes: "Reviewed",
            sourceDigest: try CapabilityApprovalDigest.digest(for: package)
        )

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                approvalRecords: [record]
            )
        )

        #expect(decision.isVisible)
        #expect(decision.canEnable)
        #expect(!decision.requiresApproval)
    }

    @Test("Approval digest mismatch blocks enablement")
    func approvalDigestMismatchBlocksEnablement() throws {
        var package = makePolicyPackage(governance: .localDraft())
        let record = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: .approved,
            approvedBy: "Security",
            approvedAt: Date(),
            reviewNotes: "Reviewed",
            sourceDigest: try CapabilityApprovalDigest.digest(for: package)
        )
        package.localTools = [
            PluginLocalTool(
                name: "Changed",
                description: "Changed command",
                icon: "terminal",
                toolType: "cli",
                command: "gh",
                arguments: ""
            )
        ]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0),
                approvalRecords: [record]
            )
        )

        #expect(!decision.canEnable)
        #expect(decision.requiresApproval)
        #expect(decision.blockers.contains(CapabilityCatalogBlocker.approvalDigestMismatch))
    }

    @Test("Blocked package is hidden from non-admins and blocked for admins")
    func blockedPackageVisibility() {
        let package = makePolicyPackage(governance: CapabilityGovernance(
            approvalStatus: .blocked,
            riskLevel: .high,
            visibility: .everyone,
            requiresAdminApproval: false,
            requiresExplicitUserConsent: false,
            dataAccess: [.network],
            externalEffects: [.readOnly]
        ))

        let userDecision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )
        let adminDecision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(!userDecision.isVisible)
        #expect(userDecision.blockers.contains(.blockedApprovalStatus))
        #expect(adminDecision.isVisible)
        #expect(!adminDecision.canEnable)
        #expect(adminDecision.blockers.contains(.blockedApprovalStatus))
    }

    @Test("Hidden package is hidden from admins and users")
    func hiddenPackageIsHiddenFromAdminsAndUsers() {
        let package = makePolicyPackage(governance: CapabilityGovernance(
            approvalStatus: .approved,
            riskLevel: .low,
            visibility: .hidden,
            requiresAdminApproval: false,
            requiresExplicitUserConsent: false
        ))

        let userDecision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )
        let adminDecision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(!userDecision.isVisible)
        #expect(!adminDecision.isVisible)
        #expect(userDecision.blockers.contains(.hiddenFromUser))
        #expect(adminDecision.blockers.contains(.hiddenFromUser))
    }

    @Test("Role scoped package requires matching role")
    func roleScopedPackageRequiresMatchingRole() {
        let package = makePolicyPackage(governance: .builtInApproved(
            riskLevel: .medium,
            allowedRoles: ["researcher"],
            visibility: .roleScoped
        ))

        let denied = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                userRoleIDs: ["engineer"],
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )
        let allowed = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                userRoleIDs: ["Researcher"],
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(!denied.isVisible)
        #expect(denied.blockers.contains(.missingRole(["researcher"])))
        #expect(allowed.isVisible)
        #expect(allowed.canEnable)
    }

    @Test("Workspace scoped package requires matching workspace tag")
    func workspaceScopedPackageRequiresMatchingTag() {
        let package = makePolicyPackage(governance: .builtInApproved(
            riskLevel: .medium,
            allowedWorkspaceTags: ["clinical-research"],
            visibility: .workspaceScoped
        ))

        let denied = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                workspaceTags: ["engineering"],
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )
        let allowed = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                workspaceTags: ["Clinical-Research"],
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(!denied.isVisible)
        #expect(denied.blockers.contains(.missingWorkspaceTag(["clinical-research"])))
        #expect(allowed.isVisible)
        #expect(allowed.canEnable)
    }

    @Test("Deprecated package cannot be newly enabled but can keep running when already enabled")
    func deprecatedPackageCanRunWhenAlreadyEnabled() {
        let package = makePolicyPackage(governance: CapabilityGovernance(
            approvalStatus: .deprecated,
            riskLevel: .medium,
            visibility: .everyone,
            requiresAdminApproval: false,
            requiresExplicitUserConsent: false,
            dataAccess: [.network],
            externalEffects: [.readOnly]
        ))

        let disabled = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )
        let enabled = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id]
            )
        )

        #expect(disabled.isVisible)
        #expect(!disabled.canEnable)
        #expect(disabled.blockers.contains(.deprecatedForNewEnablement))
        #expect(enabled.canRun)
        #expect(enabled.warnings.contains(.deprecated))
    }

    @Test("Dependencies conflicts and app versions are blockers")
    func dependenciesConflictsAndAppVersionsAreBlockers() {
        var package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))
        package.minAppVersion = "2.0.0"
        package.requires = ["base-capability"]
        package.conflicts = ["conflicting-capability"]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: ["conflicting-capability"]
            )
        )

        #expect(!decision.canEnable)
        #expect(decision.blockers.contains(.appTooOld(required: "2.0.0", current: "1.0.0")))
        #expect(decision.blockers.contains(.missingDependency("base-capability")))
        #expect(decision.blockers.contains(.conflictsWith("conflicting-capability")))
    }

    @Test("Unsafe local tool blocks package")
    func unsafeLocalToolBlocksPackage() {
        var package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))
        package.localTools = [
            PluginLocalTool(
                name: "Unsafe",
                description: "Unsafe command",
                icon: "terminal",
                toolType: "cli",
                command: "curl;rm",
                arguments: ""
            )
        ]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(!decision.canEnable)
        #expect(decision.blockers.contains(.unsafeLocalTool(name: "Unsafe", reason: "command contains shell metacharacters")))
    }

    @Test("Unsafe credentialed connector blocks package")
    func unsafeConnectorBlocksPackage() {
        var package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))
        package.connectors = [
            PluginConnector(
                name: "Unsafe API",
                serviceType: "unsafe",
                icon: "network",
                description: "Unsafe connector",
                baseURL: "http://example.com",
                authMethod: "bearer",
                credentialHints: [.init(key: "TOKEN", hint: "Token")],
                configHints: [],
                notes: ""
            )
        ]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(!decision.canEnable)
        #expect(decision.blockers.contains(.unsafeConnector(
            name: "Unsafe API",
            reason: "Connector base URL must be HTTPS, or loopback HTTP, before credentials can be used."
        )))
    }

    @Test("Unsafe MCP servers block package")
    func unsafeMCPServersBlockPackage() {
        var package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))
        package.mcpServers = [
            PluginMCPServer(
                id: "unsafe",
                displayName: "Unsafe MCP",
                transport: .stdio,
                command: "python3",
                arguments: ["-c", "print"]
            )
        ]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(!decision.canEnable)
        #expect(decision.blockers.contains(.unsafeMCPServer(
            name: "Unsafe MCP",
            reason: "interpreter execution flag -c is not allowed in package defaults"
        )))
    }

    @Test("Unsafe MCP control-plane metadata blocks package")
    func unsafeMCPControlPlaneMetadataBlocksPackage() {
        var package = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))
        package.mcpServers = [
            PluginMCPServer(
                id: "google-workspace",
                displayName: "Google Workspace",
                transport: .http,
                url: URL(string: "https://mcp.example.com/google"),
                controlPlane: MCPControlPlaneMetadata(
                    runtimeBindings: [
                        MCPRuntimeBindingTemplate(
                            id: "authorization-header",
                            destination: .httpHeader,
                            name: "Authorization",
                            template: [
                                .literal("Bearer ya29.raw-access-token-that-must-not-serialize")
                            ]
                        )
                    ]
                )
            )
        ]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(!decision.canEnable)
        #expect(!decision.canRun)
        #expect(decision.blockerMessages.contains { $0.contains("control-plane") })
        #expect(decision.blockerMessages.contains {
            $0.contains("runtime binding authorization-header is invalid: literal value must not contain a raw secret")
        })
        #expect(!decision.blockerMessages.contains { $0.contains("literalValueMustNotContainRawSecret") })
    }

    @Test("Remote MCP servers require HTTPS unless loopback")
    func remoteMCPServersRequireHTTPSUnlessLoopback() {
        var remote = makePolicyPackage(governance: .builtInApproved(riskLevel: .medium))
        remote.mcpServers = [
            PluginMCPServer(
                id: "remote",
                displayName: "Remote MCP",
                transport: .http,
                url: URL(string: "http://example.com/mcp")
            )
        ]

        var loopback = remote
        loopback.mcpServers[0].url = URL(string: "http://localhost:3333/mcp")

        let remoteDecision = CapabilityCatalogPolicy.decision(
            for: remote,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )
        let loopbackDecision = CapabilityCatalogPolicy.decision(
            for: loopback,
            context: CapabilityCatalogPolicyContext(currentAppVersion: SemanticVersion(1, 0, 0))
        )

        #expect(!remoteDecision.canEnable)
        #expect(loopbackDecision.canEnable)
    }

    @Test("Credentialed remote MCP gateway requires trusted package provenance at runtime")
    func credentialedRemoteMCPGatewayRequiresTrustedPackageProvenanceAtRuntime() {
        var package = makePolicyPackage(governance: .builtInApproved(riskLevel: .high))
        package.id = GoogleWorkspaceCapability.packageID
        package.sourceMetadata = .localLibrary()
        package.mcpServers = [
            PluginMCPServer(
                id: "google_workspace_drive",
                displayName: "Google Workspace Drive",
                transport: .http,
                url: URL(string: "https://drivemcp.googleapis.com/mcp/v1"),
                connectorBindings: [GoogleWorkspaceCapability.connectorBinding],
                controlPlane: policyGatewayAuthorizationControlPlane()
            )
        ]

        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(
                currentAppVersion: SemanticVersion(1, 0, 0),
                enabledPackageIDs: [package.id]
            )
        )

        #expect(!decision.canEnable)
        #expect(!decision.canRun)
        #expect(decision.blockers.contains(.unsafeMCPServer(
            name: "Google Workspace Drive",
            reason: RemoteMCPGatewayEndpointTrustPolicy.untrustedCredentialEndpointReason
        )))
    }
}

private func makePolicyPackage(governance: CapabilityGovernance) -> PluginPackage {
    PluginPackage(
        id: "policy-package",
        name: "Policy Package",
        icon: "puzzlepiece.extension",
        description: "Policy test package",
        author: "Tests",
        category: "Tests",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [],
        templates: [],
        governance: governance
    )
}

private func policyGatewayAuthorizationControlPlane() -> MCPControlPlaneMetadata {
    MCPControlPlaneMetadata(
        secretRefs: [
            MCPSecretRef(id: "google-access-token", purpose: "Short-lived gateway access token.")
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
}
