import Foundation
import ASTRACore

struct GoogleOAuthCredentialVault {
    static let accessTokenKey = "GOOGLE_OAUTH_ACCESS_TOKEN"
    static let refreshTokenKey = "GOOGLE_OAUTH_REFRESH_TOKEN"
    static let expiresAtKey = "GOOGLE_OAUTH_EXPIRES_AT"
    static let grantedScopesKey = "GOOGLE_OAUTH_GRANTED_SCOPES"
    static let revokedKey = "GOOGLE_OAUTH_REVOKED"

    private let secretStore: any SecretStore

    init(secretStore: any SecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
    }

    static func entityID(for accountID: UUID) -> String {
        KeychainSecretStore.googleOAuthEntityID(for: accountID)
    }

    func credentialStatus(for profile: GoogleOAuthAccountProfile, now: Date = Date()) -> GoogleOAuthCredentialStatus {
        let entityID = Self.entityID(for: profile.id)
        if secretStore.exists(key: Self.revokedKey, entityID: entityID) {
            return .revokedToken
        }
        guard secretStore.exists(key: Self.accessTokenKey, entityID: entityID) else {
            return .missingAccount
        }
        guard let expiresAt = loadExpiresAt(entityID: entityID) else {
            return .expiredToken
        }
        if expiresAt <= now {
            return .expiredToken
        }
        let grantedScopes = secretStore
            .load(key: Self.grantedScopesKey, entityID: entityID)
            .map { GoogleOAuthScopeNormalizer.normalized([$0]) }
            ?? profile.grantedScopes
        return .available(expiresAt: expiresAt, grantedScopes: grantedScopes)
    }

    func refreshToken(for profile: GoogleOAuthAccountProfile) throws -> String {
        let entityID = Self.entityID(for: profile.id)
        guard let token = secretStore.load(key: Self.refreshTokenKey, entityID: entityID),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleOAuthCredentialFailure.missingRefreshToken
        }
        return token
    }

    func accessToken(for profile: GoogleOAuthAccountProfile, now: Date = Date()) throws -> String {
        switch credentialStatus(for: profile, now: now) {
        case .available:
            let entityID = Self.entityID(for: profile.id)
            guard let token = secretStore.load(key: Self.accessTokenKey, entityID: entityID),
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GoogleOAuthCredentialFailure.tokenUnavailable
            }
            return token
        case .missingAccount:
            throw GoogleOAuthCredentialFailure.missingAccount
        case .expiredToken:
            throw GoogleOAuthCredentialFailure.expiredToken
        case .revokedToken:
            throw GoogleOAuthCredentialFailure.revokedToken
        }
    }

    func save(_ token: GoogleOAuthTokenSet, for profile: GoogleOAuthAccountProfile, now: Date = Date()) throws {
        let entityID = Self.entityID(for: profile.id)
        if secretStore.exists(key: Self.revokedKey, entityID: entityID) {
            guard secretStore.delete(key: Self.revokedKey, entityID: entityID) else {
                throw GoogleOAuthCredentialFailure.tokenUnavailable
            }
        }
        let saved = [
            secretStore.save(key: Self.accessTokenKey, value: token.accessToken, entityID: entityID, label: "Astra Google access token"),
            saveRefreshToken(token.refreshToken, entityID: entityID),
            secretStore.save(key: Self.expiresAtKey, value: String(token.expiresAt.timeIntervalSince1970), entityID: entityID, label: "Astra Google token expiry"),
            secretStore.save(key: Self.grantedScopesKey, value: token.grantedScopes.joined(separator: " "), entityID: entityID, label: "Astra Google granted scopes")
        ]
        guard saved.allSatisfy({ $0 }) else {
            throw GoogleOAuthCredentialFailure.tokenUnavailable
        }
        profile.grantedScopes = token.grantedScopes
        profile.authState = .active
        profile.authStateReason = ""
        profile.lastAuthenticatedAt = now
        profile.revokedAt = nil
        profile.updatedAt = now
    }

    func revoke(_ profile: GoogleOAuthAccountProfile) throws {
        let entityID = Self.entityID(for: profile.id)
        for key in [Self.accessTokenKey, Self.refreshTokenKey, Self.expiresAtKey, Self.grantedScopesKey] {
            guard deleteExisting(key: key, entityID: entityID) else {
                throw GoogleOAuthCredentialFailure.tokenUnavailable
            }
        }
        guard secretStore.save(key: Self.revokedKey, value: "true", entityID: entityID, label: "Astra Google revoked marker") else {
            throw GoogleOAuthCredentialFailure.tokenUnavailable
        }
    }

    private func deleteExisting(key: String, entityID: String) -> Bool {
        guard secretStore.exists(key: key, entityID: entityID) else { return true }
        return secretStore.delete(key: key, entityID: entityID)
    }

    private func saveRefreshToken(_ refreshToken: String?, entityID: String) -> Bool {
        guard let refreshToken, !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return secretStore.save(key: Self.refreshTokenKey, value: refreshToken, entityID: entityID, label: "Astra Google refresh token")
    }

    private func loadExpiresAt(entityID: String) -> Date? {
        secretStore
            .load(key: Self.expiresAtKey, entityID: entityID)
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
    }
}
