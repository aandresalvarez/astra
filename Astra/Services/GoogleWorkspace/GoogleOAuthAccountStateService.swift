import Foundation

struct GoogleOAuthAccountStateService {
    func authorizationState(
        account profile: GoogleOAuthAccountProfile?,
        requiredScopes: [String],
        credentialStatus: GoogleOAuthCredentialStatus
    ) -> GoogleOAuthAuthorizationState {
        guard let profile else { return .missingAccount }

        switch profile.authState {
        case .revoked:
            return .revokedToken
        case .needsReauth:
            return .reauthRequired(reason: profile.authStateReason)
        case .active:
            break
        }

        switch credentialStatus {
        case .missingAccount:
            return .missingAccount
        case .expiredToken:
            return .expiredToken
        case .revokedToken:
            return .revokedToken
        case .available(_, let grantedScopes):
            let missing = GoogleOAuthScopeNormalizer.missing(required: requiredScopes, granted: grantedScopes)
            return missing.isEmpty ? .ready : .missingScope(missing)
        }
    }

    func requestScopeUpgrade(on profile: GoogleOAuthAccountProfile, requiredScopes: [String], at date: Date = Date()) {
        let merged = GoogleOAuthScopeNormalizer.normalized(profile.requestedScopes + requiredScopes)
        let missing = GoogleOAuthScopeNormalizer.missing(required: requiredScopes, granted: profile.grantedScopes)
        profile.requestedScopes = merged
        guard !missing.isEmpty else {
            profile.updatedAt = date
            return
        }
        profile.authState = .needsReauth
        profile.authStateReason = "Additional Google scope required: \(missing.joined(separator: ", "))"
        profile.updatedAt = date
    }

    func markNeedsReauth(_ profile: GoogleOAuthAccountProfile, reason: String, at date: Date = Date()) {
        profile.authState = .needsReauth
        profile.authStateReason = reason
        profile.updatedAt = date
    }

    func markRevoked(_ profile: GoogleOAuthAccountProfile, at date: Date = Date()) {
        profile.authState = .revoked
        profile.authStateReason = "Google access was revoked."
        profile.revokedAt = date
        profile.updatedAt = date
    }
}
