import Foundation
import ASTRACore
import SwiftData
import Testing
@testable import ASTRA

@Suite("Google OAuth Vault")
@MainActor
struct GoogleOAuthVaultTests {
    @Test("Google account profile persists identity and scope metadata without token material")
    func profilePersistsWithoutTokenMaterial() throws {
        let container = try makeGoogleOAuthContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = GoogleOAuthAccountProfile(
            subject: "google-sub-123",
            email: "alvaro@example.com",
            displayName: "Alvaro",
            hostedDomain: "example.com",
            grantedScopes: [
                "https://www.googleapis.com/auth/drive.metadata.readonly"
            ],
            requestedScopes: [
                "https://www.googleapis.com/auth/drive.metadata.readonly"
            ],
            createdAt: now
        )
        let store = RecordingSecretStore()
        let vault = GoogleOAuthCredentialVault(secretStore: store)

        context.insert(profile)
        try vault.save(
            GoogleOAuthTokenSet(
                accessToken: "ya29.access-secret",
                refreshToken: "1//refresh-secret",
                expiresAt: now.addingTimeInterval(3600),
                grantedScopes: profile.grantedScopes
            ),
            for: profile,
            now: now
        )
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<GoogleOAuthAccountProfile>()).first)
        #expect(fetched.subject == "google-sub-123")
        #expect(fetched.email == "alvaro@example.com")
        #expect(fetched.grantedScopes == ["https://www.googleapis.com/auth/drive.metadata.readonly"])
        #expect(fetched.tokenLeakInspectionStrings().allSatisfy { !$0.contains("access-secret") && !$0.contains("refresh-secret") })
        #expect(store.load(key: GoogleOAuthCredentialVault.accessTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == "ya29.access-secret")
        #expect(store.load(key: GoogleOAuthCredentialVault.refreshTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == "1//refresh-secret")
    }

    @Test("Vault reports missing expired revoked and available token states without exposing values")
    func vaultReportsTokenStatesWithoutExposingValues() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = GoogleOAuthAccountProfile(
            subject: "google-sub-123",
            email: "alvaro@example.com",
            grantedScopes: ["scope.read"],
            requestedScopes: ["scope.read"],
            createdAt: now
        )
        let store = RecordingSecretStore()
        let vault = GoogleOAuthCredentialVault(secretStore: store)

        #expect(vault.credentialStatus(for: profile, now: now) == .missingAccount)

        try vault.save(
            GoogleOAuthTokenSet(
                accessToken: "access-1",
                refreshToken: "refresh-1",
                expiresAt: now.addingTimeInterval(-1),
                grantedScopes: ["scope.read"]
            ),
            for: profile,
            now: now
        )
        #expect(vault.credentialStatus(for: profile, now: now) == .expiredToken)

        try vault.save(
            GoogleOAuthTokenSet(
                accessToken: "access-2",
                refreshToken: "refresh-1",
                expiresAt: now.addingTimeInterval(3600),
                grantedScopes: ["scope.read"]
            ),
            for: profile,
            now: now
        )
        #expect(vault.credentialStatus(for: profile, now: now) == .available(expiresAt: now.addingTimeInterval(3600), grantedScopes: ["scope.read"]))

        try vault.revoke(profile)
        #expect(vault.credentialStatus(for: profile, now: now) == .revokedToken)
        #expect(store.load(key: GoogleOAuthCredentialVault.accessTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == nil)
        #expect(store.load(key: GoogleOAuthCredentialVault.refreshTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == nil)
    }

    @Test("Scope upgrade reauth and revoke transitions are pure profile state changes")
    func scopeUpgradeReauthAndRevokeTransitions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = GoogleOAuthAccountProfile(
            subject: "google-sub-123",
            email: "alvaro@example.com",
            grantedScopes: ["scope.read"],
            requestedScopes: ["scope.read"],
            createdAt: now
        )
        let service = GoogleOAuthAccountStateService()

        #expect(service.authorizationState(account: nil, requiredScopes: ["scope.read"], credentialStatus: .available(expiresAt: now.addingTimeInterval(3600), grantedScopes: ["scope.read"])) == .missingAccount)
        #expect(service.authorizationState(account: profile, requiredScopes: ["scope.read"], credentialStatus: .available(expiresAt: now.addingTimeInterval(3600), grantedScopes: ["scope.read"])) == .ready)
        #expect(service.authorizationState(account: profile, requiredScopes: ["scope.write"], credentialStatus: .available(expiresAt: now.addingTimeInterval(3600), grantedScopes: ["scope.read"])) == .missingScope(["scope.write"]))

        service.requestScopeUpgrade(on: profile, requiredScopes: ["scope.write"], at: now)

        #expect(profile.requestedScopes == ["scope.read", "scope.write"])
        #expect(profile.authState == .needsReauth)
        #expect(profile.authStateReason == "Additional Google scope required: scope.write")
        #expect(service.authorizationState(account: profile, requiredScopes: ["scope.write"], credentialStatus: .available(expiresAt: now.addingTimeInterval(3600), grantedScopes: ["scope.read"])) == .reauthRequired(reason: "Additional Google scope required: scope.write"))

        service.markRevoked(profile, at: now.addingTimeInterval(10))

        #expect(profile.authState == .revoked)
        #expect(profile.revokedAt == now.addingTimeInterval(10))
        #expect(service.authorizationState(account: profile, requiredScopes: ["scope.read"], credentialStatus: .available(expiresAt: now.addingTimeInterval(3600), grantedScopes: ["scope.read"])) == .revokedToken)
    }

    @Test("Fake OAuth client exchanges and refreshes tokens through the vault")
    func fakeOAuthClientExchangeAndRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = GoogleOAuthAccountProfile(
            subject: "google-sub-123",
            email: "alvaro@example.com",
            grantedScopes: [],
            requestedScopes: ["scope.read"],
            createdAt: now
        )
        let store = RecordingSecretStore()
        let vault = GoogleOAuthCredentialVault(secretStore: store)
        let client = FakeGoogleOAuthTokenClient(
            exchangeResponse: GoogleOAuthTokenSet(
                accessToken: "exchange-access",
                refreshToken: "exchange-refresh",
                expiresAt: now.addingTimeInterval(1800),
                grantedScopes: ["scope.read"]
            ),
            refreshResponse: GoogleOAuthTokenSet(
                accessToken: "refresh-access",
                refreshToken: nil,
                expiresAt: now.addingTimeInterval(3600),
                grantedScopes: ["scope.read", "scope.write"]
            )
        )
        let service = GoogleOAuthTokenService(client: client, vault: vault)

        try await service.exchangeAuthorizationCode(
            "fake-auth-code",
            for: profile,
            redirectURI: "http://127.0.0.1/callback",
            codeVerifier: "verifier",
            now: now
        )

        #expect(client.exchangeRequests == [
            .init(code: "fake-auth-code", redirectURI: "http://127.0.0.1/callback", codeVerifier: "verifier")
        ])
        #expect(profile.grantedScopes == ["scope.read"])
        #expect(vault.credentialStatus(for: profile, now: now) == .available(expiresAt: now.addingTimeInterval(1800), grantedScopes: ["scope.read"]))

        try await service.refreshAccessToken(for: profile, now: now.addingTimeInterval(1))

        #expect(client.refreshRequests == [.init(refreshToken: "exchange-refresh", requestedScopes: ["scope.read"])])
        #expect(profile.grantedScopes == ["scope.read", "scope.write"])
        #expect(store.load(key: GoogleOAuthCredentialVault.accessTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == "refresh-access")
        #expect(store.load(key: GoogleOAuthCredentialVault.refreshTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == "exchange-refresh")
    }

    @Test("User-facing credential failures are stable and specific")
    func userFacingCredentialFailures() {
        #expect(GoogleOAuthCredentialFailure.missingAccount.errorDescription == "Connect a Google account before using Google Workspace.")
        #expect(GoogleOAuthCredentialFailure.missingScope(["scope.write"]).errorDescription == "Google needs one more permission: scope.write.")
        #expect(GoogleOAuthCredentialFailure.expiredToken.errorDescription == "The Google access token expired. Refresh the account before continuing.")
        #expect(GoogleOAuthCredentialFailure.revokedToken.errorDescription == "Google access was revoked. Sign in again to continue.")
        #expect(GoogleOAuthCredentialFailure.missingRefreshToken.errorDescription == "Google did not provide a refresh token. Sign in again to restore offline access.")
    }
}

private func makeGoogleOAuthContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private final class RecordingSecretStore: SecretStore {
    private var storage: [String: [String: String]] = [:]

    func load(key: String, entityID: String) -> String? {
        storage[entityID]?[key]
    }

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

    func deleteAll(entityID: String) {
        storage[entityID] = nil
    }

    func exists(key: String, entityID: String) -> Bool {
        storage[entityID]?[key] != nil
    }
}

private final class FakeGoogleOAuthTokenClient: GoogleOAuthTokenClient {
    var exchangeResponse: GoogleOAuthTokenSet
    var refreshResponse: GoogleOAuthTokenSet
    private(set) var exchangeRequests: [GoogleOAuthAuthorizationCodeRequest] = []
    private(set) var refreshRequests: [GoogleOAuthRefreshRequest] = []

    init(exchangeResponse: GoogleOAuthTokenSet, refreshResponse: GoogleOAuthTokenSet) {
        self.exchangeResponse = exchangeResponse
        self.refreshResponse = refreshResponse
    }

    func exchangeAuthorizationCode(_ request: GoogleOAuthAuthorizationCodeRequest) async throws -> GoogleOAuthTokenSet {
        exchangeRequests.append(request)
        return exchangeResponse
    }

    func refreshAccessToken(_ request: GoogleOAuthRefreshRequest) async throws -> GoogleOAuthTokenSet {
        refreshRequests.append(request)
        return refreshResponse
    }
}
