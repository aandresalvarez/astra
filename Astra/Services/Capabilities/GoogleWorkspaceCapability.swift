import ASTRACore
import ASTRAModels

enum GoogleWorkspaceCapability {
    static let packageID = "google-workspace"
    static let connectorBinding = "google-workspace"
    static let setupRequirementID = "google-workspace-oauth"

    static func isPackage(_ package: PluginPackage) -> Bool {
        package.id == packageID
    }

    static func usesGoogleWorkspaceOAuthSetup(_ package: PluginPackage) -> Bool {
        package.setupRequirements.contains { requirement in
            requirement.kind == .oauthAccount
                && requirement.provider == connectorBinding
        }
    }

    /// Whether the account a Google Workspace plugin runs as can still get a
    /// usable token: the profile is active, its Keychain token was neither
    /// revoked nor lost, and it holds every scope the Workspace products need
    /// (`GoogleWorkspaceSetupStateFactory.missingScopes`). An expired access
    /// token refreshes on use (`GoogleWorkspaceRemoteMCPVaultTokenResolver`),
    /// so it still counts while a refresh token is stored; without one the
    /// refresh fails (`missingRefreshToken`) and the account must reconnect.
    /// An unchecked one (nil) is judged by the profile.
    static func isAccountConnected(
        _ profile: GoogleOAuthAccountProfile?,
        credentialStatus: GoogleOAuthCredentialStatus?,
        hasRefreshToken: Bool
    ) -> Bool {
        guard let profile, profile.authState == .active else { return false }
        switch credentialStatus {
        case .missingAccount, .revokedToken: return false
        case .expiredToken where !hasRefreshToken: return false
        case .available, .expiredToken, nil:
            return GoogleWorkspaceSetupStateFactory.missingScopes(profile: profile, credentialStatus: credentialStatus).isEmpty
        }
    }
}
