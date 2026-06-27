import Foundation

struct GoogleOAuthConfigurationSettings: Equatable {
    static let clientIDDefaultsKey = "astra.googleWorkspace.oauth.clientID"
    static let redirectURIDefaultsKey = "astra.googleWorkspace.oauth.redirectURI"
    static let defaultRedirectURI = "http://127.0.0.1:48119/oauth/google/callback"

    var clientID: String
    var redirectURI: String

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Self {
        let storedClientID = defaults.string(forKey: clientIDDefaultsKey) ?? ""
        let storedRedirectURI = defaults.string(forKey: redirectURIDefaultsKey) ?? ""
        return GoogleOAuthConfigurationSettings(
            clientID: firstNonEmpty(environment["ASTRA_GOOGLE_OAUTH_CLIENT_ID"], storedClientID),
            redirectURI: firstNonEmpty(
                environment["ASTRA_GOOGLE_OAUTH_REDIRECT_URI"],
                storedRedirectURI,
                defaultRedirectURI
            )
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDDefaultsKey)
        defaults.set(redirectURI.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.redirectURIDefaultsKey)
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }
}
