import Foundation
import ASTRACore

// GoogleOAuthScopeNormalizer moved to ASTRACore/GoogleOAuthScopeNormalizer.swift
// as part of Track A3 - Astra/Models/GoogleOAuthAccountProfile.swift needs it.

struct GoogleOAuthTokenSet: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let grantedScopes: [String]

    init(accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.grantedScopes = GoogleOAuthScopeNormalizer.normalized(grantedScopes)
    }
}

enum GoogleOAuthCredentialStatus: Equatable, Sendable {
    case missingAccount
    case expiredToken
    case revokedToken
    case available(expiresAt: Date, grantedScopes: [String])
}

enum GoogleOAuthAuthorizationState: Equatable, Sendable {
    case missingAccount
    case missingScope([String])
    case ready
    case expiredToken
    case revokedToken
    case reauthRequired(reason: String)
}

enum GoogleOAuthCredentialFailure: LocalizedError, Equatable {
    case missingAccount
    case missingScope([String])
    case expiredToken
    case revokedToken
    case missingRefreshToken
    case tokenUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return "Connect a Google account before using Google Workspace."
        case .missingScope(let scopes):
            let joined = GoogleOAuthScopeNormalizer.normalized(scopes).joined(separator: ", ")
            return "Google needs one more permission: \(joined)."
        case .expiredToken:
            return "The Google access token expired. Refresh the account before continuing."
        case .revokedToken:
            return "Google access was revoked. Sign in again to continue."
        case .missingRefreshToken:
            return "Google did not provide a refresh token. Sign in again to restore offline access."
        case .tokenUnavailable:
            return "Google credentials are unavailable. Sign in again to continue."
        }
    }
}

struct GoogleOAuthAuthorizationCodeRequest: Equatable, Sendable {
    let code: String
    let redirectURI: String
    let codeVerifier: String
}

struct GoogleOAuthRefreshRequest: Equatable, Sendable {
    let refreshToken: String
    let requestedScopes: [String]

    init(refreshToken: String, requestedScopes: [String]) {
        self.refreshToken = refreshToken
        self.requestedScopes = GoogleOAuthScopeNormalizer.normalized(requestedScopes)
    }
}

protocol GoogleOAuthTokenClient: AnyObject {
    func exchangeAuthorizationCode(_ request: GoogleOAuthAuthorizationCodeRequest) async throws -> GoogleOAuthTokenSet
    func refreshAccessToken(_ request: GoogleOAuthRefreshRequest) async throws -> GoogleOAuthTokenSet
}
