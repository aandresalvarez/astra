import Foundation
import Testing
@testable import ASTRA

@Suite("Google Workspace Remote MCP Runtime Service")
struct GoogleWorkspaceRemoteMCPRuntimeServiceTests {
    @Test("runtime service refreshes expired tokens before producing local gateway route")
    func refreshesExpiredTokensBeforeRoute() async throws {
        let profile = GoogleOAuthAccountProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            subject: "google-sub-1",
            email: "alvaro@example.com",
            grantedScopes: [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.compose"
            ],
            requestedScopes: [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.compose"
            ]
        )
        let resolver = RecordingRuntimeTokenResolver(result: .success("fresh-access-token"), refreshed: true)
        let service = GoogleWorkspaceRemoteMCPRuntimeService(
            tokenResolver: resolver,
            policyEnforcer: AllowingGoogleWorkspaceMCPPolicyEnforcer(),
            gatewayBaseURL: URL(string: "http://127.0.0.1:48231")!
        )

        let plan = try await service.routePlan(
            product: .gmail,
            toolName: "search_threads",
            account: profile
        )

        #expect(plan.gatewayURL.absoluteString == "http://127.0.0.1:48231/mcp/google-workspace/gmail")
        #expect(plan.authorizationHeader == "Bearer fresh-access-token")
        #expect(resolver.refreshedProfiles == [profile.id])
        #expect(plan.gatewayURL.host() == "127.0.0.1")
        #expect(plan.upstreamURL.host()?.contains("googleapis.com") == true)
    }

    @Test("runtime service denies tools before resolving access tokens")
    func deniesBeforeTokenResolution() async throws {
        let profile = GoogleOAuthAccountProfile(
            subject: "google-sub-1",
            email: "alvaro@example.com",
            grantedScopes: [
                "https://www.googleapis.com/auth/drive.readonly",
                "https://www.googleapis.com/auth/drive.file"
            ],
            requestedScopes: [
                "https://www.googleapis.com/auth/drive.readonly",
                "https://www.googleapis.com/auth/drive.file"
            ]
        )
        let resolver = RecordingRuntimeTokenResolver(result: .success("should-not-load"), refreshed: false)
        let service = GoogleWorkspaceRemoteMCPRuntimeService(
            tokenResolver: resolver,
            policyEnforcer: DenyingGoogleWorkspaceMCPPolicyEnforcer(reason: "write tools disabled"),
            gatewayBaseURL: URL(string: "http://127.0.0.1:48231")!
        )

        do {
            _ = try await service.routePlan(product: .drive, toolName: "create_file", account: profile)
            Issue.record("Expected policy denial")
        } catch let failure as GoogleWorkspaceRemoteMCPBackendFailure {
            #expect(failure == .policyDenied("write tools disabled"))
            #expect(resolver.refreshedProfiles.isEmpty)
        }
    }
}

private final class RecordingRuntimeTokenResolver: GoogleWorkspaceRemoteMCPTokenResolving {
    var result: GoogleWorkspaceRemoteMCPTokenResult
    var refreshed: Bool
    private(set) var refreshedProfiles: [UUID] = []

    init(result: GoogleWorkspaceRemoteMCPTokenResult, refreshed: Bool) {
        self.result = result
        self.refreshed = refreshed
    }

    func accessToken(for profile: GoogleOAuthAccountProfile, requiredScopes: [String]) async -> GoogleWorkspaceRemoteMCPTokenResult {
        if refreshed {
            refreshedProfiles.append(profile.id)
        }
        return result
    }
}
