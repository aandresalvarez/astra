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
        #expect(config.redirectURI.absoluteString == "http://127.0.0.1:48119/oauth/google/callback")
        #expect(config.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(config.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
    }

    @Test("configuration rejects missing client id")
    func rejectsMissingClientID() {
        #expect(throws: GoogleOAuthConfiguration.Error.self) {
            try GoogleOAuthConfiguration.load(environment: [
                "ASTRA_GOOGLE_OAUTH_REDIRECT_URI": "http://127.0.0.1:48119/oauth/google/callback"
            ])
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
}
