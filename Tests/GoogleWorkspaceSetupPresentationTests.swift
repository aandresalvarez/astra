import Testing
@testable import ASTRA
import ASTRACore

@Suite("Google Workspace Setup Presentation")
struct GoogleWorkspaceSetupPresentationTests {
    private let requiredScopes = [
        "https://www.googleapis.com/auth/drive.readonly",
        "https://www.googleapis.com/auth/documents"
    ]

    @Test("no account asks the user to connect Google")
    func noAccountAsksUserToConnectGoogle() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .none,
                requiredScopes: requiredScopes,
                grantedScopes: [],
                mcpAvailability: .available,
                policy: .allowed,
                writeApproval: .notRequired
            )
        )

        #expect(presentation.groupTitle == "Action needed")
        #expect(presentation.summarySubtitle == "Connect account")
        #expect(presentation.primaryAction == .connect)
        #expect(presentation.primaryActionTitle == "Connect")
        #expect(presentation.issues.map(\.kind) == [.noAccount])
        #expect(presentation.issues.first?.message == "Connect a Google account before enabling Workspace tools.")
    }

    @Test("missing scope asks for upgrade without forgetting connected account")
    func missingScopeAsksForUpgrade() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .connected(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: ["https://www.googleapis.com/auth/drive.readonly"],
                mcpAvailability: .available,
                policy: .allowed,
                writeApproval: .notRequired
            )
        )

        #expect(presentation.accountSubtitle == "user@example.com")
        #expect(presentation.summarySubtitle == "Missing scope · 1")
        #expect(presentation.primaryAction == .upgradeScopes)
        #expect(presentation.primaryActionTitle == "Upgrade")
        #expect(presentation.issues.map(\.kind) == [.missingScopes])
        #expect(presentation.issues.first?.detail == "https://www.googleapis.com/auth/documents")
    }

    @Test("expired token asks for reauthorization")
    func expiredTokenAsksForReauthorization() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .expired(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: requiredScopes,
                mcpAvailability: .available,
                policy: .allowed,
                writeApproval: .notRequired
            )
        )

        #expect(presentation.summarySubtitle == "Token expired")
        #expect(presentation.primaryActionTitle == "Reauthorize")
        #expect(presentation.issues.map(\.kind) == [.expiredToken])
    }

    @Test("revoked token asks for reconnect")
    func revokedTokenAsksForReconnect() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .revoked(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: requiredScopes,
                mcpAvailability: .available,
                policy: .allowed,
                writeApproval: .notRequired
            )
        )

        #expect(presentation.summarySubtitle == "Access revoked")
        #expect(presentation.primaryActionTitle == "Reconnect")
        #expect(presentation.issues.map(\.kind) == [.revokedToken])
    }

    @Test("unavailable Google MCP is shown as operational preflight failure")
    func unavailableGoogleMCPIsPreflightFailure() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .connected(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: requiredScopes,
                mcpAvailability: .unavailable(reason: "Remote MCP endpoint did not respond."),
                policy: .allowed,
                writeApproval: .notRequired
            )
        )

        #expect(presentation.summarySubtitle == "MCP unavailable")
        #expect(presentation.primaryAction == .retryPreflight)
        #expect(presentation.primaryActionTitle == "Retry")
        #expect(presentation.issues.map(\.kind) == [.mcpUnavailable])
        #expect(presentation.issues.first?.detail == "Remote MCP endpoint did not respond.")
    }

    @Test("unavailable Google MCP is shown before account setup")
    func unavailableGoogleMCPIsShownBeforeAccountSetup() {
        let presentation = GoogleWorkspaceSetupPresentation.make(state: .setupUnavailable)

        #expect(presentation.summarySubtitle == "MCP unavailable")
        #expect(presentation.primaryAction == .retryPreflight)
        #expect(presentation.issues.map(\.kind) == [.mcpUnavailable])
        #expect(presentation.issues.first?.detail == "Google Workspace remote MCP is not installed in this build.")
    }

    @Test("policy denied blocks setup before account actions")
    func policyDeniedBlocksSetup() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .connected(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: requiredScopes,
                mcpAvailability: .available,
                policy: .denied(messages: ["Capability is blocked by catalog policy."]),
                writeApproval: .notRequired
            )
        )

        #expect(presentation.summarySubtitle == "Policy denied")
        #expect(presentation.primaryActionTitle == nil)
        #expect(presentation.issues.map(\.kind) == [.policyDenied])
        #expect(presentation.issues.first?.detail == "Capability is blocked by catalog policy.")
    }

    @Test("policy bridge carries catalog decision blocker messages")
    func policyBridgeCarriesCatalogDecisionBlockerMessages() {
        let package = PluginPackage(
            id: "google-workspace",
            name: "Google Workspace",
            icon: "externaldrive.connected.to.line.below",
            description: "Google Workspace MCP package",
            author: "Tests",
            category: "Google",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [],
            templates: [],
            governance: CapabilityGovernance(
                approvalStatus: .blocked,
                riskLevel: .high,
                visibility: .everyone,
                requiresAdminApproval: false,
                requiresExplicitUserConsent: false
            )
        )
        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(isAdmin: true)
        )

        #expect(GoogleWorkspaceSetupPolicyState.make(decision: decision) == .denied(messages: [
            "Capability is blocked by catalog policy."
        ]))
    }

    @Test("policy bridge allows approval-only gates")
    func policyBridgeAllowsApprovalOnlyGates() {
        let package = PluginPackage(
            id: "google-workspace",
            name: "Google Workspace",
            icon: "externaldrive.connected.to.line.below",
            description: "Google Workspace MCP package",
            author: "Tests",
            category: "Google",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            mcpServers: [],
            templates: [],
            governance: CapabilityGovernance(
                approvalStatus: .draft,
                riskLevel: .medium,
                visibility: .everyone,
                requiresAdminApproval: false,
                requiresExplicitUserConsent: false
            )
        )
        let decision = CapabilityCatalogPolicy.decision(
            for: package,
            context: CapabilityCatalogPolicyContext(isAdmin: true)
        )

        #expect(!decision.canEnable)
        #expect(decision.requiresApproval)
        #expect(GoogleWorkspaceSetupPolicyState.make(decision: decision) == .allowed)
    }

    @Test("write pending approval points to approval queue")
    func writePendingApprovalPointsToApprovalQueue() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .connected(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: requiredScopes,
                mcpAvailability: .available,
                policy: .allowed,
                writeApproval: .pending(count: 2)
            )
        )

        #expect(presentation.summarySubtitle == "Write approval pending · 2")
        #expect(presentation.primaryAction == .reviewApprovals)
        #expect(presentation.primaryActionTitle == "Review")
        #expect(presentation.issues.map(\.kind) == [.writePendingApproval])
        #expect(presentation.issues.first?.message == "Review 2 pending Google write approvals before destructive actions can run.")
    }

    @Test("ready state stays quiet and offers revoke affordance")
    func readyStateStaysQuiet() {
        let presentation = GoogleWorkspaceSetupPresentation.make(
            state: GoogleWorkspaceSetupState(
                account: .connected(email: "user@example.com"),
                requiredScopes: requiredScopes,
                grantedScopes: requiredScopes,
                mcpAvailability: .available,
                policy: .allowed,
                writeApproval: .approved
            )
        )

        #expect(presentation.groupTitle == "Ready")
        #expect(presentation.summarySubtitle == "Ready · user@example.com")
        #expect(presentation.primaryActionTitle == nil)
        #expect(presentation.secondaryActionTitle == "Revoke")
        #expect(presentation.issues.isEmpty)
    }
}
