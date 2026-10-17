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
    /// token: the profile is active and its Keychain token was neither revoked
    /// nor lost. An expired access token refreshes on use
    /// (`GoogleWorkspaceRemoteMCPVaultTokenResolver`), so it still counts; an
    /// unchecked one (nil) is judged by the profile alone.
    static func isAccountConnected(
        _ profile: GoogleOAuthAccountProfile?,
        credentialStatus: GoogleOAuthCredentialStatus?
    ) -> Bool {
        guard let profile, profile.authState == .active else { return false }
        switch credentialStatus {
        case .missingAccount, .revokedToken: return false
        case .available, .expiredToken, nil: return true
        }
    }
}
