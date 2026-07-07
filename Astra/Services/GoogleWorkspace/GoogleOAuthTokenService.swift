import Foundation
import ASTRAModels

final class GoogleOAuthTokenService {
    private let client: any GoogleOAuthTokenClient
    private let vault: GoogleOAuthCredentialVault

    init(client: any GoogleOAuthTokenClient, vault: GoogleOAuthCredentialVault = GoogleOAuthCredentialVault()) {
        self.client = client
        self.vault = vault
    }

    func exchangeAuthorizationCode(
        _ code: String,
        for profile: GoogleOAuthAccountProfile,
        redirectURI: String,
        codeVerifier: String,
        now: Date = Date()
    ) async throws {
        let token = try await client.exchangeAuthorizationCode(
            GoogleOAuthAuthorizationCodeRequest(
                code: code,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier
            )
        )
        try vault.save(token, for: profile, now: now)
    }

    func refreshAccessToken(for profile: GoogleOAuthAccountProfile, now: Date = Date()) async throws {
        let refreshToken = try vault.refreshToken(for: profile)
        let token = try await client.refreshAccessToken(
            GoogleOAuthRefreshRequest(
                refreshToken: refreshToken,
                requestedScopes: profile.requestedScopes
            )
        )
        try vault.save(token, for: profile, now: now)
    }
}
