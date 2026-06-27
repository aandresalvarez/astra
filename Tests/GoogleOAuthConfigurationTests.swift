import Foundation
import Testing
@testable import ASTRA

@Suite("Google OAuth Configuration")
struct GoogleOAuthConfigurationTests {
    @Test("configuration loads explicit client id and loopback redirect uri")
    func loadsExplicitConfiguration() throws {
        let config = try GoogleOAuthConfiguration.load(environment: [
            "ASTRA_GOOGLE_OAUTH_CLIENT_ID": "client.apps.googleusercontent.com",
            "ASTRA_GOOGLE_OAUTH_REDIRECT_URI": "http://127.0.0.1:48119/oauth/google/callback"
        ])

        #expect(config.clientID == "client.apps.googleusercontent.com")
        #expect(config.clientSource == .custom)
        #expect(config.redirectURI.absoluteString == "http://127.0.0.1:48119/oauth/google/callback")
        #expect(config.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(config.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
    }

    @Test("configuration prefers ASTRA-managed client from app bundle")
    func loadsManagedClientFromBundle() throws {
        let config = try GoogleOAuthConfiguration.load(
            environment: [:],
            defaults: try isolatedDefaults(),
            bundleInfo: [
                GoogleOAuthConfigurationSettings.managedClientIDInfoKey: "managed-client.apps.googleusercontent.com"
            ]
        )

        #expect(config.clientID == "managed-client.apps.googleusercontent.com")
        #expect(config.clientSource == .managed)
        #expect(config.redirectURI.absoluteString == GoogleOAuthConfigurationSettings.defaultRedirectURI)
    }

    @Test("saved custom client does not override managed client unless custom mode is selected")
    func savedCustomClientRequiresExplicitCustomModeWhenManagedClientExists() throws {
        let defaults = try isolatedDefaults()
        defaults.set(" saved-client.apps.googleusercontent.com ", forKey: GoogleOAuthConfigurationSettings.clientIDDefaultsKey)
        defaults.set(GoogleOAuthClientSource.managed.rawValue, forKey: GoogleOAuthConfigurationSettings.clientSourceDefaultsKey)

        let managed = GoogleOAuthConfigurationSettings.load(
            environment: [:],
            defaults: defaults,
            bundleInfo: [
                GoogleOAuthConfigurationSettings.managedClientIDInfoKey: "managed-client.apps.googleusercontent.com"
            ]
        )

        #expect(managed.clientID == "managed-client.apps.googleusercontent.com")
        #expect(managed.source == .managed)

        defaults.set(GoogleOAuthClientSource.custom.rawValue, forKey: GoogleOAuthConfigurationSettings.clientSourceDefaultsKey)

        let custom = GoogleOAuthConfigurationSettings.load(
            environment: [:],
            defaults: defaults,
            bundleInfo: [
                GoogleOAuthConfigurationSettings.managedClientIDInfoKey: "managed-client.apps.googleusercontent.com"
            ]
        )

        #expect(custom.clientID == "saved-client.apps.googleusercontent.com")
        #expect(custom.source == .custom)
    }

    @Test("legacy saved custom client loads normalized without a source marker")
    func legacySavedCustomClientLoadsNormalizedWithoutSourceMarker() throws {
        let defaults = try isolatedDefaults()
        defaults.set(" saved-client.apps.googleusercontent.com ", forKey: GoogleOAuthConfigurationSettings.clientIDDefaultsKey)

        let settings = GoogleOAuthConfigurationSettings.load(
            environment: [:],
            defaults: defaults,
            bundleInfo: [:]
        )

        #expect(settings.clientID == "saved-client.apps.googleusercontent.com")
        #expect(settings.source == .custom)
    }

    @Test("stored custom client remains available while managed client is preferred")
    func storedCustomClientRemainsAvailableWhileManagedClientIsPreferred() throws {
        let defaults = try isolatedDefaults()
        defaults.set(" saved-client.apps.googleusercontent.com ", forKey: GoogleOAuthConfigurationSettings.clientIDDefaultsKey)
        defaults.set(GoogleOAuthClientSource.managed.rawValue, forKey: GoogleOAuthConfigurationSettings.clientSourceDefaultsKey)

        let settings = GoogleOAuthConfigurationSettings.load(
            environment: [:],
            defaults: defaults,
            bundleInfo: [
                GoogleOAuthConfigurationSettings.managedClientIDInfoKey: "managed-client.apps.googleusercontent.com"
            ]
        )

        #expect(settings.source == .managed)
        #expect(GoogleOAuthConfigurationSettings.storedCustomClientID(defaults: defaults) == "saved-client.apps.googleusercontent.com")
    }

    @Test("missing managed and custom client keeps guided setup in missing state")
    func missingManagedAndCustomClientIsRepresented() throws {
        let settings = GoogleOAuthConfigurationSettings.load(
            environment: [:],
            defaults: try isolatedDefaults(),
            bundleInfo: [:]
        )

        #expect(settings.clientID.isEmpty)
        #expect(settings.source == .missing)
        #expect(settings.redirectURI == GoogleOAuthConfigurationSettings.defaultRedirectURI)
    }

    @Test("configuration loads client id saved by capability setup")
    func loadsSavedCapabilitySetupConfiguration() throws {
        let defaults = try isolatedDefaults()
        defaults.set("saved-client.apps.googleusercontent.com", forKey: GoogleOAuthConfigurationSettings.clientIDDefaultsKey)
        defaults.set("http://127.0.0.1:48119/oauth/google/callback", forKey: GoogleOAuthConfigurationSettings.redirectURIDefaultsKey)

        let config = try GoogleOAuthConfiguration.load(environment: [:], defaults: defaults)

        #expect(config.clientID == "saved-client.apps.googleusercontent.com")
        #expect(config.clientSource == .custom)
        #expect(config.redirectURI.absoluteString == "http://127.0.0.1:48119/oauth/google/callback")
    }

    @Test("configuration rejects missing client id")
    func rejectsMissingClientID() {
        #expect(throws: GoogleOAuthConfiguration.Error.self) {
            try GoogleOAuthConfiguration.load(
                environment: [
                    "ASTRA_GOOGLE_OAUTH_REDIRECT_URI": "http://127.0.0.1:48119/oauth/google/callback"
                ],
                defaults: try isolatedDefaults()
            )
        }
    }

    @Test("configuration rejects non loopback redirect uri")
    func rejectsNonLoopbackRedirectURI() {
        #expect(throws: GoogleOAuthConfiguration.Error.self) {
            try GoogleOAuthConfiguration.load(environment: [
                "ASTRA_GOOGLE_OAUTH_CLIENT_ID": "client.apps.googleusercontent.com",
                "ASTRA_GOOGLE_OAUTH_REDIRECT_URI": "https://example.com/oauth/callback"
            ])
        }
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "GoogleOAuthConfigurationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
