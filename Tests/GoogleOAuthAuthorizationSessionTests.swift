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

    @Test("loopback listener treats cancellation as terminal")
    func loopbackListenerCancellationIsTerminal() throws {
        let error = try #require(LoopbackGoogleOAuthCallbackReceiver.terminalError(for: .cancelled))

        #expect(error is CancellationError)
        #expect(LoopbackGoogleOAuthCallbackReceiver.terminalError(for: .ready) == nil)
    }

    @Test("loopback listener only accepts loopback peer endpoints")
    func loopbackListenerOnlyAcceptsLoopbackPeers() throws {
        let loopbackIPv4 = NWEndpoint.hostPort(host: .ipv4(try #require(IPv4Address("127.0.0.1"))), port: 48119)
        let loopbackIPv4Range = NWEndpoint.hostPort(host: .ipv4(try #require(IPv4Address("127.10.20.30"))), port: 48119)
        let loopbackIPv6 = NWEndpoint.hostPort(host: .ipv6(try #require(IPv6Address("::1"))), port: 48119)
        let localhost = NWEndpoint.hostPort(host: .name("localhost", nil), port: 48119)
        let privateNetwork = NWEndpoint.hostPort(host: .ipv4(try #require(IPv4Address("192.168.1.50"))), port: 48119)

        #expect(LoopbackGoogleOAuthCallbackReceiver.isLoopbackEndpoint(loopbackIPv4))
        #expect(LoopbackGoogleOAuthCallbackReceiver.isLoopbackEndpoint(loopbackIPv4Range))
        #expect(LoopbackGoogleOAuthCallbackReceiver.isLoopbackEndpoint(loopbackIPv6))
        #expect(LoopbackGoogleOAuthCallbackReceiver.isLoopbackEndpoint(localhost))
        #expect(!LoopbackGoogleOAuthCallbackReceiver.isLoopbackEndpoint(privateNetwork))
    }
}
