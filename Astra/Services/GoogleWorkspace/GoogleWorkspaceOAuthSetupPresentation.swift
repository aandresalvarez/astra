import Foundation

enum GoogleWorkspaceOAuthSetupMode: Equatable {
    case managed
    case custom
    case customRequired
}

enum GoogleWorkspaceOAuthSetupAction: Equatable {
    case copyRedirectURI
    case copyRequiredScopes
    case openGoogleCloudConsole
    case useManagedOAuth
    case useCustomOAuth
}

struct GoogleWorkspaceOAuthSetupPresentation: Equatable {
    var mode: GoogleWorkspaceOAuthSetupMode
    var primaryTitle: String
    var primaryStatus: String
    var showsCustomFields: Bool
    var actions: [GoogleWorkspaceOAuthSetupAction]

    static func make(
        settings: GoogleOAuthConfigurationSettings,
        managedClientAvailable: Bool? = nil
    ) -> Self {
        let hasManagedClient = managedClientAvailable ?? (settings.source == .managed)
        switch settings.source {
        case .managed:
            return GoogleWorkspaceOAuthSetupPresentation(
                mode: .managed,
                primaryTitle: "ASTRA managed OAuth",
                primaryStatus: "Ready",
                showsCustomFields: false,
                actions: [.useCustomOAuth]
            )
        case .custom:
            var actions: [GoogleWorkspaceOAuthSetupAction] = [
                .copyRedirectURI,
                .copyRequiredScopes,
                .openGoogleCloudConsole
            ]
            if hasManagedClient {
                actions.insert(.useManagedOAuth, at: 0)
            }
            return GoogleWorkspaceOAuthSetupPresentation(
                mode: .custom,
                primaryTitle: "Custom OAuth client",
                primaryStatus: "Configured",
                showsCustomFields: true,
                actions: actions
            )
        case .missing:
            return GoogleWorkspaceOAuthSetupPresentation(
                mode: .customRequired,
                primaryTitle: "Custom OAuth client",
                primaryStatus: "Setup required",
                showsCustomFields: true,
                actions: [
                    .copyRedirectURI,
                    .copyRequiredScopes,
                    .openGoogleCloudConsole
                ]
            )
        }
    }
}
