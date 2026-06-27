import ASTRACore

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
}
