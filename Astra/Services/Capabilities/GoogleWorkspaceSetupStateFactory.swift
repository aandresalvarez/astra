import Foundation
import ASTRACore
import ASTRAModels

enum GoogleWorkspaceSetupStateFactory {
    static func make(
        accounts: [GoogleOAuthAccountProfile],
        vault: GoogleOAuthCredentialVault = GoogleOAuthCredentialVault(),
        now: Date = Date()
    ) -> GoogleWorkspaceSetupState {
        let account = selectedAccount(from: accounts)
        let credentialStatus = account.map { vault.credentialStatus(for: $0, now: now) }

        return GoogleWorkspaceSetupState(
            account: accountState(profile: account, credentialStatus: credentialStatus),
            requiredScopes: requiredScopes,
            grantedScopes: grantedScopes(profile: account, credentialStatus: credentialStatus),
            mcpAvailability: GoogleWorkspaceRemoteMCPRegistry.products.isEmpty
                ? .unavailable(reason: "Google Workspace remote MCP is not installed in this build.")
                : .available,
            policy: .allowed,
            writeApproval: .notRequired
        )
    }

    /// Every scope the Workspace products need.
    static var requiredScopes: [String] {
        GoogleOAuthScopeNormalizer.normalized(GoogleWorkspaceRemoteMCPRegistry.products.flatMap(\.requiredScopes))
    }

    /// The required scopes the account lacks, as the setup state counts them
    /// and as the runtime does (`GoogleWorkspaceRemoteMCPVaultTokenResolver`
    /// checks the profile's scopes, then the stored token's): a token missing
    /// one is refused, so the account needs consent again.
    static func missingScopes(
        profile: GoogleOAuthAccountProfile,
        credentialStatus: GoogleOAuthCredentialStatus?
    ) -> [String] {
        GoogleOAuthScopeNormalizer.normalized(
            GoogleOAuthScopeNormalizer.missing(required: requiredScopes, granted: profile.grantedScopes)
                + GoogleOAuthScopeNormalizer.missing(
                    required: requiredScopes,
                    granted: grantedScopes(profile: profile, credentialStatus: credentialStatus)
                )
        )
    }

    static func selectedAccount(from accounts: [GoogleOAuthAccountProfile]) -> GoogleOAuthAccountProfile? {
        accounts.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.email < $1.email
        }.first
    }

    private static func accountState(
        profile: GoogleOAuthAccountProfile?,
        credentialStatus: GoogleOAuthCredentialStatus?
    ) -> GoogleWorkspaceAccountState {
        guard let profile else { return .none }
        switch profile.authState {
        case .revoked:
            return .revoked(email: profile.email)
        case .needsReauth:
            return .expired(email: profile.email)
        case .active:
            break
        }

        switch credentialStatus {
        case .available:
            return .connected(email: profile.email)
        case .expiredToken:
            return .expired(email: profile.email)
        case .revokedToken:
            return .revoked(email: profile.email)
        case .missingAccount, .none:
            return .none
        }
    }

    private static func grantedScopes(
        profile: GoogleOAuthAccountProfile?,
        credentialStatus: GoogleOAuthCredentialStatus?
    ) -> [String] {
        switch credentialStatus {
        case .available(_, let scopes):
            return scopes
        case .expiredToken, .revokedToken, .missingAccount, .none:
            return profile?.grantedScopes ?? []
        }
    }
}
