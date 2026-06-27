import Foundation

struct GoogleOAuthConfiguration: Equatable, Sendable {
    enum Error: LocalizedError, Equatable {
        case missingClientID
        case invalidRedirectURI(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Google OAuth client id is not configured."
            case .invalidRedirectURI(let value):
                return "Google OAuth redirect URI is invalid: \(value)"
            }
        }
    }

    var clientID: String
    var clientSource: GoogleOAuthClientSource
    var redirectURI: URL
    var authorizationEndpoint: URL
    var tokenEndpoint: URL

    init(
        clientID: String,
        clientSource: GoogleOAuthClientSource = .custom,
        redirectURI: URL,
        authorizationEndpoint: URL,
        tokenEndpoint: URL
    ) {
        self.clientID = clientID
        self.clientSource = clientSource
        self.redirectURI = redirectURI
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) throws -> Self {
        let settings = GoogleOAuthConfigurationSettings.load(
            environment: environment,
            defaults: defaults,
            bundleInfo: bundleInfo
        )
        return try load(settings: settings)
    }

    static func load(settings: GoogleOAuthConfigurationSettings) throws -> Self {
        let clientID = settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw Error.missingClientID }

        let redirectText = settings.redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let redirectURI = URL(string: redirectText),
              redirectURI.scheme?.lowercased() == "http",
              isLoopback(redirectURI.host) else {
            throw Error.invalidRedirectURI(redirectText)
        }

        return GoogleOAuthConfiguration(
            clientID: clientID,
            clientSource: settings.source,
            redirectURI: redirectURI,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
