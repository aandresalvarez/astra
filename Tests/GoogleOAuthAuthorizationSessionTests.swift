import Foundation
import Network
import Testing
@testable import ASTRA

@Suite("Google OAuth Authorization Session")
struct GoogleOAuthAuthorizationSessionTests {
    @Test("authorization URL includes PKCE offline access and requested scopes")
    func authorizationURLIncludesPKCE() throws {
        let request = GoogleOAuthAuthorizationSessionRequest(
            configuration: GoogleOAuthConfiguration(
                clientID: "client.apps.googleusercontent.com",
                redirectURI: URL(string: "http://127.0.0.1:48119/oauth/google/callback")!,
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
            ),
            scopes: ["scope.read", "scope.write"],
            pkce: .init(codeVerifier: "verifier", codeChallenge: "challenge", state: "state-123")
        )
        let components = try #require(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(items["client_id"] == "client.apps.googleusercontent.com")
        #expect(items["redirect_uri"] == "http://127.0.0.1:48119/oauth/google/callback")
        #expect(items["scope"] == "scope.read scope.write")
        #expect(items["code_challenge"] == "challenge")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["access_type"] == "offline")
    }

    @Test("loopback parser extracts code and state from HTTP callback")
    func loopbackParserExtractsCodeAndState() throws {
        let request = "GET /oauth/google/callback?code=auth-code&state=state-123 HTTP/1.1\r\nHost: 127.0.0.1:48119\r\n\r\n"
        let callback = try #require(GoogleOAuthCallbackParser.callback(
            fromHTTPRequest: request,
            redirectURI: URL(string: "http://127.0.0.1:48119/oauth/google/callback")!
        ))

        #expect(callback.code == "auth-code")
        #expect(callback.state == "state-123")
    }

    @Test("loopback listener parameters bind to the redirect host and port")
    func loopbackListenerParametersBindToRedirectHostAndPort() throws {
        let redirectURI = URL(string: "http://127.0.0.1:48119/oauth/google/callback")!
        let parameters = try #require(GoogleOAuthLoopbackListenerPolicy.parameters(for: redirectURI))
        let endpoint = try #require(parameters.requiredLocalEndpoint)

        guard case let .hostPort(host, port) = endpoint else {
            Issue.record("Expected a required hostPort local endpoint, got \(endpoint)")
            return
        }

        #expect(String(describing: host) == "127.0.0.1")
        #expect(port.rawValue == 48_119)
    }

    @Test("loopback listener normalizes localhost redirects to an IP literal bind")
    func loopbackListenerNormalizesLocalhostRedirects() throws {
        let redirectURI = URL(string: "http://localhost:48119/oauth/google/callback")!
        let parameters = try #require(GoogleOAuthLoopbackListenerPolicy.parameters(for: redirectURI))
        let endpoint = try #require(parameters.requiredLocalEndpoint)

        guard case let .hostPort(host, port) = endpoint else {
            Issue.record("Expected a required hostPort local endpoint, got \(endpoint)")
            return
        }

        #expect(String(describing: host) == "127.0.0.1")
        #expect(port.rawValue == 48_119)
    }

    @Test("loopback listener parameters reject non-loopback redirect hosts")
    func loopbackListenerParametersRejectNonLoopbackHosts() {
        let redirectURI = URL(string: "http://192.0.2.10:48119/oauth/google/callback")!

        #expect(GoogleOAuthLoopbackListenerPolicy.parameters(for: redirectURI) == nil)
    }
}
