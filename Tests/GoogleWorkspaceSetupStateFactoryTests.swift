import Foundation
import ASTRACore
import Testing
@testable import ASTRA

@Suite("Google Workspace Setup State Factory")
struct GoogleWorkspaceSetupStateFactoryTests {
    @Test("missing account is actionable and remote MCP is available")
    func missingAccountIsActionable() {
        let state = GoogleWorkspaceSetupStateFactory.make(
            accounts: [],
            vault: GoogleOAuthCredentialVault(secretStore: RecordingSecretStore())
        )

        #expect(state.account == .none)
        #expect(state.mcpAvailability == .available)
        #expect(state.requiredScopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
    }

    @Test("available vault credentials produce connected state and granted scopes")
    func availableCredentialsProduceConnectedState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = GoogleOAuthAccountProfile(
            subject: "google-sub",
            email: "User@Example.com",
            grantedScopes: ["scope.read"],
            requestedScopes: ["scope.read"],
            updatedAt: now
        )
        let store = RecordingSecretStore()
        let vault = GoogleOAuthCredentialVault(secretStore: store)
        try vault.save(
            GoogleOAuthTokenSet(
                accessToken: "access-secret",
                refreshToken: "refresh-secret",
                expiresAt: now.addingTimeInterval(3600),
                grantedScopes: ["scope.read", "scope.write"]
            ),
            for: profile,
            now: now
        )

        let state = GoogleWorkspaceSetupStateFactory.make(accounts: [profile], vault: vault, now: now)

        #expect(state.account == .connected(email: "user@example.com"))
        #expect(state.grantedScopes == ["scope.read", "scope.write"])
    }

    @Test("expired and revoked profiles map to reauth states")
    func expiredAndRevokedProfilesMapToReauthStates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = GoogleOAuthAccountProfile(subject: "expired", email: "expired@example.com")
        let revoked = GoogleOAuthAccountProfile(subject: "revoked", email: "revoked@example.com", authState: .revoked)
        let expiredStore = RecordingSecretStore()
        let vault = GoogleOAuthCredentialVault(secretStore: expiredStore)
        try vault.save(
            GoogleOAuthTokenSet(
                accessToken: "access-secret",
                refreshToken: "refresh-secret",
                expiresAt: now.addingTimeInterval(-1),
                grantedScopes: ["scope.read"]
            ),
            for: expired,
            now: now
        )

        #expect(GoogleWorkspaceSetupStateFactory.make(accounts: [expired], vault: vault, now: now).account == .expired(email: "expired@example.com"))
        #expect(GoogleWorkspaceSetupStateFactory.make(accounts: [revoked], vault: vault, now: now).account == .revoked(email: "revoked@example.com"))
    }
}

private final class RecordingSecretStore: SecretStore {
    private var storage: [String: [String: String]] = [:]

    func load(key: String, entityID: String) -> String? { storage[entityID]?[key] }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        storage[entityID, default: [:]][key] = value
        return true
    }

    @discardableResult
    func delete(key: String, entityID: String) -> Bool {
        storage[entityID]?[key] = nil
        return true
    }

    func deleteAll(entityID: String) { storage[entityID] = nil }

    func exists(key: String, entityID: String) -> Bool { storage[entityID]?[key] != nil }
}
