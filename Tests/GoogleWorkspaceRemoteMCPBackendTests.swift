import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Google Workspace Remote MCP Backend")
struct GoogleWorkspaceRemoteMCPBackendTests {
    @Test("registry contains official Google Workspace MCP products")
    func registryContainsOfficialGoogleWorkspaceMCPProducts() throws {
        let products = GoogleWorkspaceRemoteMCPRegistry.products

        #expect(products.map(\.id) == [.gmail, .drive, .calendar])
        #expect(products.allSatisfy { $0.transport == .http })
        #expect(products.allSatisfy { $0.developerPreview })

        let gmail = try #require(GoogleWorkspaceRemoteMCPRegistry.product(.gmail))
        #expect(gmail.serverID == "google_workspace_gmail")
        #expect(gmail.endpoint.absoluteString == "https://gmailmcp.googleapis.com/mcp/v1")
        #expect(gmail.requiredScopes == [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose"
        ])
        #expect(gmail.documentedTools == [
            "create_draft",
            "get_thread",
            "label_message",
            "label_thread",
            "list_drafts",
            "list_labels",
            "search_threads",
            "unlabel_message",
            "unlabel_thread"
        ])

        let drive = try #require(GoogleWorkspaceRemoteMCPRegistry.product(.drive))
        #expect(drive.serverID == "google_workspace_drive")
        #expect(drive.endpoint.absoluteString == "https://drivemcp.googleapis.com/mcp/v1")
        #expect(drive.requiredScopes == [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/drive.file"
        ])
        #expect(drive.documentedTools == [
            "copy_file",
            "create_file",
            "download_file_content",
            "get_file_metadata",
            "get_file_permissions",
            "list_recent_files",
            "read_file_content",
            "search_files"
        ])

        let calendar = try #require(GoogleWorkspaceRemoteMCPRegistry.product(.calendar))
        #expect(calendar.serverID == "google_workspace_calendar")
        #expect(calendar.endpoint.absoluteString == "https://calendarmcp.googleapis.com/mcp/v1")
        #expect(calendar.requiredScopes == [
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events.freebusy",
            "https://www.googleapis.com/auth/calendar.events.readonly"
        ])
        #expect(calendar.documentedTools == [
            "create_event",
            "delete_event",
            "get_event",
            "list_calendars",
            "list_events",
            "respond_to_event",
            "suggest_time",
            "update_event"
        ])
    }

    @Test("registry maps tools to policy families")
    func registryMapsToolsToPolicyFamilies() {
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .gmail, toolName: "search_threads") == .read)
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .gmail, toolName: "create_draft") == .draft)
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .drive, toolName: "create_file") == .write)
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .drive, toolName: "get_file_permissions") == .permissionRead)
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .calendar, toolName: "suggest_time") == .availabilityRead)
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .calendar, toolName: "delete_event") == .delete)
        #expect(GoogleWorkspaceRemoteMCPRegistry.toolFamily(product: .calendar, toolName: "missing") == nil)
    }

    @Test("successful route plan uses ASTRA gateway and injected vault token")
    func successfulRoutePlanUsesGatewayAndVaultToken() throws {
        let dependencies = GoogleWorkspaceRemoteMCPBackendDependencies(
            oauthVaultAvailable: true,
            localGatewayAvailable: true,
            policyEnforcerAvailable: true,
            googleMCPAvailable: true,
            accountID: "acct-1",
            grantedScopes: [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.compose"
            ],
            tokenResult: .success("fake-access-token"),
            policyDecision: .allowed,
            gatewayBaseURL: try #require(URL(string: "http://127.0.0.1:48231"))
        )

        let result = GoogleWorkspaceRemoteMCPBackendPlanner.plan(
            product: .gmail,
            toolName: "search_threads",
            dependencies: dependencies
        )

        let plan = try #require(result.success)
        #expect(plan.gatewayURL.absoluteString == "http://127.0.0.1:48231/mcp/google-workspace/gmail")
        #expect(plan.upstreamURL.absoluteString == "https://gmailmcp.googleapis.com/mcp/v1")
        #expect(plan.authorizationHeader == "Bearer fake-access-token")
        #expect(plan.requiredScopes == GoogleWorkspaceRemoteMCPRegistry.product(.gmail)?.requiredScopes)
        #expect(plan.toolFamily == .read)
        #expect(plan.gatewayURL.host?.contains("googleapis.com") == false)
    }

    @Test("backend planner reports dependency and auth failures without routing directly")
    func backendPlannerReportsDependencyAndAuthFailures() throws {
        #expect(failure(with: .fixture(oauthVaultAvailable: false)) == .missingOAuthVault)
        #expect(failure(with: .fixture(localGatewayAvailable: false)) == .missingLocalGateway)
        #expect(failure(with: .fixture(policyEnforcerAvailable: false)) == .missingPolicyEnforcer)
        #expect(failure(with: .fixture(googleMCPAvailable: false)) == .googleMCPUnavailable)
        #expect(failure(with: .fixture(accountID: nil)) == .missingAccount)
        #expect(failure(with: .fixture(grantedScopes: [])) == .missingScopes([
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose"
        ]))
        #expect(failure(with: .fixture(tokenResult: .refreshFailed("invalid_grant"))) == .tokenRefreshFailed("invalid_grant"))
        #expect(failure(with: .fixture(policyDecision: .denied("write tools disabled"))) == .policyDenied("write tools disabled"))

        let unsupported = GoogleWorkspaceRemoteMCPBackendPlanner.plan(
            product: .gmail,
            toolName: "delete_everything",
            dependencies: .availableForGmail()
        )
        #expect(unsupported.failure == .unsupportedTool("delete_everything"))
    }

    @Test("fake remote responses are wrapped by the local gateway contract")
    func fakeRemoteResponsesAreWrappedByLocalGatewayContract() throws {
        let gateway = FakeGoogleWorkspaceGateway()

        let cases: [(GoogleWorkspaceRemoteMCPProductID, String, GoogleWorkspaceRemoteMCPBackendDependencies, String, String)] = [
            (.gmail, "get_thread", .availableForGmail(), "https://gmailmcp.googleapis.com/mcp/v1", "fake-access-token"),
            (.drive, "read_file_content", .availableForDrive(), "https://drivemcp.googleapis.com/mcp/v1", "fake-drive-token"),
            (.calendar, "list_events", .availableForCalendar(), "https://calendarmcp.googleapis.com/mcp/v1", "fake-calendar-token")
        ]

        for (product, tool, dependencies, upstream, token) in cases {
            let plan = try #require(GoogleWorkspaceRemoteMCPBackendPlanner.plan(
                product: product,
                toolName: tool,
                dependencies: dependencies
            ).success)
            let response = gateway.forward(plan: plan, fakeRemoteBody: #"{"content":[{"type":"text","text":"fixture"}]}"#)

            #expect(response.forwardedURL == URL(string: upstream))
            #expect(response.authorizationHeader == "Bearer \(token)")
            #expect(response.body.contains("fixture"))
            #expect(response.policyFamily == .read)
        }
    }

    private func failure(
        with overrides: GoogleWorkspaceRemoteMCPBackendDependencies
    ) -> GoogleWorkspaceRemoteMCPBackendFailure? {
        GoogleWorkspaceRemoteMCPBackendPlanner.plan(
            product: .gmail,
            toolName: "search_threads",
            dependencies: overrides
        ).failure
    }
}

private extension GoogleWorkspaceRemoteMCPBackendDependencies {
    static func fixture(
        oauthVaultAvailable: Bool = true,
        localGatewayAvailable: Bool = true,
        policyEnforcerAvailable: Bool = true,
        googleMCPAvailable: Bool = true,
        accountID: String? = "acct-1",
        grantedScopes: Set<String> = [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose"
        ],
        tokenResult: GoogleWorkspaceRemoteMCPTokenResult = .success("fake-access-token"),
        policyDecision: GoogleWorkspaceRemoteMCPPolicyDecision = .allowed,
        gatewayBaseURL: URL = URL(string: "http://127.0.0.1:48231")!
    ) -> Self {
        Self(
            oauthVaultAvailable: oauthVaultAvailable,
            localGatewayAvailable: localGatewayAvailable,
            policyEnforcerAvailable: policyEnforcerAvailable,
            googleMCPAvailable: googleMCPAvailable,
            accountID: accountID,
            grantedScopes: grantedScopes,
            tokenResult: tokenResult,
            policyDecision: policyDecision,
            gatewayBaseURL: gatewayBaseURL
        )
    }

    static func availableForGmail() -> Self {
        fixture()
    }

    static func availableForDrive() -> Self {
        fixture(
            grantedScopes: [
                "https://www.googleapis.com/auth/drive.readonly",
                "https://www.googleapis.com/auth/drive.file"
            ],
            tokenResult: .success("fake-drive-token")
        )
    }

    static func availableForCalendar() -> Self {
        fixture(
            grantedScopes: [
                "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                "https://www.googleapis.com/auth/calendar.events.freebusy",
                "https://www.googleapis.com/auth/calendar.events.readonly"
            ],
            tokenResult: .success("fake-calendar-token")
        )
    }
}

private struct FakeGoogleWorkspaceGateway {
    struct Response: Equatable {
        var forwardedURL: URL
        var authorizationHeader: String
        var body: String
        var policyFamily: GoogleWorkspaceRemoteMCPToolFamily
    }

    func forward(
        plan: GoogleWorkspaceRemoteMCPRoutePlan,
        fakeRemoteBody: String
    ) -> Response {
        Response(
            forwardedURL: plan.upstreamURL,
            authorizationHeader: plan.authorizationHeader,
            body: fakeRemoteBody,
            policyFamily: plan.toolFamily
        )
    }
}
