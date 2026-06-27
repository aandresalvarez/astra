import Foundation

enum GoogleOAuthClientSource: String, Equatable, Sendable {
    case managed
    case custom
    case missing
}

struct GoogleOAuthConfigurationSettings: Equatable {
    static let clientIDDefaultsKey = "astra.googleWorkspace.oauth.clientID"
    static let redirectURIDefaultsKey = "astra.googleWorkspace.oauth.redirectURI"
    static let clientSourceDefaultsKey = "astra.googleWorkspace.oauth.clientSource"
    static let customClientIDEnvironmentKey = "ASTRA_GOOGLE_OAUTH_CLIENT_ID"
    static let managedClientIDEnvironmentKey = "ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID"
    static let redirectURIEnvironmentKey = "ASTRA_GOOGLE_OAUTH_REDIRECT_URI"
    static let managedClientIDInfoKey = "ASTRAGoogleOAuthClientID"
    static let defaultRedirectURI = "http://127.0.0.1:48119/oauth/google/callback"

    var clientID: String
    var redirectURI: String
    var source: GoogleOAuthClientSource

    init(
        clientID: String,
        redirectURI: String,
        source: GoogleOAuthClientSource = .custom
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.source = source
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Self {
        let storedClientID = defaults.string(forKey: clientIDDefaultsKey) ?? ""
        let storedRedirectURI = defaults.string(forKey: redirectURIDefaultsKey) ?? ""
        let storedSource = defaults.string(forKey: clientSourceDefaultsKey)
            .flatMap(GoogleOAuthClientSource.init(rawValue:))
        let redirectURI = firstNonEmpty(
            environment[redirectURIEnvironmentKey],
            storedRedirectURI,
            defaultRedirectURI
        )
        let explicitCustomClientID = firstNonEmpty(environment[customClientIDEnvironmentKey])
        if !explicitCustomClientID.isEmpty {
            return GoogleOAuthConfigurationSettings(
                clientID: explicitCustomClientID,
                redirectURI: redirectURI,
                source: .custom
            )
        }

        if storedSource == .custom, !storedClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GoogleOAuthConfigurationSettings(
                clientID: storedClientID,
                redirectURI: redirectURI,
                source: .custom
            )
        }

        let managedClientID = managedClientID(environment: environment, bundleInfo: bundleInfo)
        if !managedClientID.isEmpty {
            return GoogleOAuthConfigurationSettings(
                clientID: managedClientID,
                redirectURI: redirectURI,
                source: .managed
            )
        }

        if !storedClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GoogleOAuthConfigurationSettings(
                clientID: storedClientID,
                redirectURI: redirectURI,
                source: .custom
            )
        }

        return GoogleOAuthConfigurationSettings(
            clientID: "",
            redirectURI: redirectURI,
            source: .missing
        )
    }

    func save(defaults: UserDefaults = .standard) {
        saveCustom(defaults: defaults)
    }

    func saveCustom(defaults: UserDefaults = .standard) {
        defaults.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDDefaultsKey)
        defaults.set(redirectURI.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.redirectURIDefaultsKey)
        defaults.set(GoogleOAuthClientSource.custom.rawValue, forKey: Self.clientSourceDefaultsKey)
    }

    static func preferManaged(defaults: UserDefaults = .standard) {
        defaults.set(GoogleOAuthClientSource.managed.rawValue, forKey: clientSourceDefaultsKey)
    }

    static func storedCustomClientID(defaults: UserDefaults = .standard) -> String {
        firstNonEmpty(defaults.string(forKey: clientIDDefaultsKey))
    }

    static func managedClientID(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> String {
        firstNonEmpty(
            environment[managedClientIDEnvironmentKey],
            bundleInfo[managedClientIDInfoKey] as? String
        )
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
