import Foundation
import ASTRACore
import SwiftData
import Testing
@testable import ASTRA

@Suite("Google OAuth Account Service")
@MainActor
struct GoogleOAuthAccountServiceTests {
    @Test("connect creates profile from live authorization and stores tokens only in vault")
    func connectCreatesProfileAndStoresTokensInVault() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = RecordingSecretStore()
        let vault = GoogleOAuthCredentialVault(secretStore: store)
        let authorizer = RecordingGoogleOAuthAuthorizationSession(code: "auth-code", verifier: "verifier")
        let tokenClient = RecordingAccountTokenClient(exchangeToken: .init(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            expiresAt: now.addingTimeInterval(3600),
            grantedScopes: ["scope.read", "scope.write"]
        ))
        let identityProvider = RecordingGoogleOAuthIdentityProvider(identity: .init(
            subject: "google-sub-1",
            email: "Alvaro@Example.com",
            displayName: "Alvaro",
            avatarURLString: "https://profiles.example/avatar.png",
            hostedDomain: "Example.com"
        ))
        let service = GoogleOAuthAccountService(
            configuration: .fixture(),
            authorizationSession: authorizer,
            tokenClient: tokenClient,
            identityProvider: identityProvider,
            vault: vault
        )

        let profile = try await service.connectAccount(
            in: context,
            requestedScopes: ["scope.read", "scope.write"],
            now: now
        )

        #expect(profile.subject == "google-sub-1")
        #expect(profile.email == "alvaro@example.com")
        #expect(profile.hostedDomain == "example.com")
        #expect(profile.requestedScopes == ["scope.read", "scope.write"])
        #expect(profile.grantedScopes == ["scope.read", "scope.write"])
        #expect(authorizer.requests.first?.scopes == ["scope.read", "scope.write"])
        #expect(tokenClient.exchangeRequests == [.init(code: "auth-code", redirectURI: "http://127.0.0.1:48119/oauth/google/callback", codeVerifier: "verifier")])
        #expect(identityProvider.accessTokens == ["access-secret"])
        #expect(profile.tokenLeakInspectionStrings().allSatisfy { !$0.contains("secret") })
        #expect(store.load(key: GoogleOAuthCredentialVault.accessTokenKey, entityID: GoogleOAuthCredentialVault.entityID(for: profile.id)) == "access-secret")
    }

    @Test("connect updates existing subject instead of creating duplicate account")
    func connectUpdatesExistingAccount() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let existing = GoogleOAuthAccountProfile(
            subject: "google-sub-1",
            email: "old@example.com",
            requestedScopes: ["scope.read"],
            createdAt: now
        )
        context.insert(existing)
        try context.save()

        let service = GoogleOAuthAccountService(
            configuration: .fixture(),
            authorizationSession: RecordingGoogleOAuthAuthorizationSession(code: "auth-code", verifier: "verifier"),
            tokenClient: RecordingAccountTokenClient(exchangeToken: .init(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                expiresAt: now.addingTimeInterval(3600),
                grantedScopes: ["scope.read", "scope.write"]
            )),
            identityProvider: RecordingGoogleOAuthIdentityProvider(identity: .init(
                subject: "google-sub-1",
                email: "new@example.com",
                displayName: "New Name",
                avatarURLString: nil,
                hostedDomain: nil
            )),
            vault: GoogleOAuthCredentialVault(secretStore: RecordingSecretStore())
        )

        let profile = try await service.connectAccount(
            in: context,
            requestedScopes: ["scope.write"],
            now: now.addingTimeInterval(10)
        )

        let profiles = try context.fetch(FetchDescriptor<GoogleOAuthAccountProfile>())
        #expect(profiles.count == 1)
        #expect(profile.id == existing.id)
        #expect(profile.email == "new@example.com")
        #expect(profile.displayName == "New Name")
        #expect(profile.requestedScopes == ["scope.read", "scope.write"])
    }
}

private final class RecordingGoogleOAuthAuthorizationSession: GoogleOAuthAuthorizationSession {
    var code: String
    var verifier: String
    private(set) var requests: [GoogleOAuthAuthorizationSessionRequest] = []

    init(code: String, verifier: String) {
        self.code = code
        self.verifier = verifier
    }

    func authorize(_ request: GoogleOAuthAuthorizationSessionRequest) async throws -> GoogleOAuthAuthorizationGrant {
        requests.append(request)
        #expect(request.authorizationURL.absoluteString.contains("code_challenge="))
        #expect(request.authorizationURL.absoluteString.contains("access_type=offline"))
        return GoogleOAuthAuthorizationGrant(code: code, redirectURI: request.configuration.redirectURI, codeVerifier: verifier)
    }
}

private final class RecordingAccountTokenClient: GoogleOAuthTokenClient {
    var exchangeToken: GoogleOAuthTokenSet
    private(set) var exchangeRequests: [GoogleOAuthAuthorizationCodeRequest] = []

    init(exchangeToken: GoogleOAuthTokenSet) {
        self.exchangeToken = exchangeToken
    }

    func exchangeAuthorizationCode(_ request: GoogleOAuthAuthorizationCodeRequest) async throws -> GoogleOAuthTokenSet {
        exchangeRequests.append(request)
        return exchangeToken
    }

    func refreshAccessToken(_ request: GoogleOAuthRefreshRequest) async throws -> GoogleOAuthTokenSet {
        throw GoogleOAuthCredentialFailure.tokenUnavailable
    }
}

private final class RecordingGoogleOAuthIdentityProvider: GoogleOAuthIdentityProvider {
    var identity: GoogleOAuthIdentity
    private(set) var accessTokens: [String] = []

    init(identity: GoogleOAuthIdentity) {
        self.identity = identity
    }

    func identity(accessToken: String) async throws -> GoogleOAuthIdentity {
        accessTokens.append(accessToken)
        return identity
    }
}

private extension GoogleOAuthConfiguration {
    static func fixture() -> Self {
        GoogleOAuthConfiguration(
            clientID: "client.apps.googleusercontent.com",
            redirectURI: URL(string: "http://127.0.0.1:48119/oauth/google/callback")!,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }
}

private func makeContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
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
