import Foundation
import SwiftData

final class GoogleOAuthAccountService {
    private let configuration: GoogleOAuthConfiguration
    private var authorizationSession: any GoogleOAuthAuthorizationSession
    private let tokenClient: any GoogleOAuthTokenClient
    private let identityProvider: any GoogleOAuthIdentityProvider
    private let vault: GoogleOAuthCredentialVault

    init(
        configuration: GoogleOAuthConfiguration,
        authorizationSession: any GoogleOAuthAuthorizationSession = LoopbackGoogleOAuthAuthorizationSession(),
        tokenClient: (any GoogleOAuthTokenClient)? = nil,
        identityProvider: any GoogleOAuthIdentityProvider = GoogleOAuthHTTPIdentityProvider(),
        vault: GoogleOAuthCredentialVault = GoogleOAuthCredentialVault()
    ) {
        self.configuration = configuration
        self.authorizationSession = authorizationSession
        self.tokenClient = tokenClient ?? GoogleOAuthHTTPTokenClient(configuration: configuration)
        self.identityProvider = identityProvider
        self.vault = vault
    }

    @MainActor
    func connectAccount(
        in context: ModelContext,
        requestedScopes: [String],
        now: Date = Date()
    ) async throws -> GoogleOAuthAccountProfile {
        let normalizedScopes = GoogleOAuthScopeNormalizer.normalized(requestedScopes)
        let pkce = try GoogleOAuthPKCE.generate()
        let grant = try await authorizationSession.authorize(GoogleOAuthAuthorizationSessionRequest(
            configuration: configuration,
            scopes: normalizedScopes,
            pkce: pkce
        ))
        let token = try await tokenClient.exchangeAuthorizationCode(.init(
            code: grant.code,
            redirectURI: grant.redirectURI.absoluteString,
            codeVerifier: grant.codeVerifier
        ))
        let identity = try await identityProvider.identity(accessToken: token.accessToken)
        let profile = try upsertProfile(identity: identity, requestedScopes: normalizedScopes, in: context, now: now)
        try vault.save(token, for: profile, now: now)
        try context.save()
        return profile
    }

    func refreshAccessToken(for profile: GoogleOAuthAccountProfile, now: Date = Date()) async throws {
        let refreshToken = try vault.refreshToken(for: profile)
        let token = try await tokenClient.refreshAccessToken(.init(
            refreshToken: refreshToken,
            requestedScopes: profile.requestedScopes
        ))
        try vault.save(token, for: profile, now: now)
    }

    func revoke(_ profile: GoogleOAuthAccountProfile, now: Date = Date()) throws {
        try vault.revoke(profile)
        profile.authState = .revoked
        profile.revokedAt = now
        profile.updatedAt = now
    }

    @MainActor
    private func upsertProfile(
        identity: GoogleOAuthIdentity,
        requestedScopes: [String],
        in context: ModelContext,
        now: Date
    ) throws -> GoogleOAuthAccountProfile {
        let subject = identity.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try context.fetch(FetchDescriptor<GoogleOAuthAccountProfile>())
            .first { $0.subject == subject }
        let profile = existing ?? GoogleOAuthAccountProfile(
            subject: subject,
            email: identity.email,
            createdAt: now
        )
        if existing == nil {
            context.insert(profile)
        }
        profile.email = identity.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        profile.displayName = identity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.avatarURLString = identity.avatarURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.hostedDomain = identity.hostedDomain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        profile.requestedScopes = GoogleOAuthScopeNormalizer.normalized(profile.requestedScopes + requestedScopes)
        profile.authState = .active
        profile.authStateReason = ""
        profile.updatedAt = now
        return profile
    }
}
