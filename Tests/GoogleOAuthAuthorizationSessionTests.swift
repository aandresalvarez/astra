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

    @Test("loopback parser extracts code and state from explicit IPv6 callback")
    func loopbackParserExtractsCodeAndStateFromIPv6Callback() throws {
        let request = "GET /oauth/google/callback?code=auth-code&state=state-123 HTTP/1.1\r\nHost: [::1]:48119\r\n\r\n"
        let callback = try #require(GoogleOAuthCallbackParser.callback(
            fromHTTPRequest: request,
            redirectURI: URL(string: "http://[::1]:48119/oauth/google/callback")!
        ))

        #expect(callback.code == "auth-code")
        #expect(callback.state == "state-123")
    }

    @Test("loopback parser rejects callbacks for a different redirect path")
    func loopbackParserRejectsDifferentRedirectPath() throws {
        let request = "GET /wrong/callback?code=auth-code&state=state-123 HTTP/1.1\r\nHost: [::1]:48119\r\n\r\n"
        let callback = GoogleOAuthCallbackParser.callback(
            fromHTTPRequest: request,
            redirectURI: URL(string: "http://[::1]:48119/oauth/google/callback")!
        )

        #expect(callback == nil)
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
        #expect(parameters.allowLocalEndpointReuse)
    }

    @Test("loopback listener binds localhost redirects to IPv4 and IPv6 loopback literals")
    func loopbackListenerBindsLocalhostRedirectsToLoopbackLiterals() throws {
        let redirectURI = URL(string: "http://localhost:48119/oauth/google/callback")!
        let bindings = try #require(GoogleOAuthLoopbackListenerPolicy.bindings(for: redirectURI))
        let endpoints = try bindings.map { binding in
            try #require(binding.parameters.requiredLocalEndpoint)
        }
        let hostsAndPorts = endpoints.compactMap { endpoint -> (String, UInt16)? in
            guard case let .hostPort(host, port) = endpoint else {
                Issue.record("Expected a required hostPort local endpoint, got \(endpoint)")
                return nil
            }
            return (String(describing: host), port.rawValue)
        }

        #expect(hostsAndPorts.map(\.0) == ["127.0.0.1", "::1"])
        #expect(hostsAndPorts.map(\.1) == [48_119, 48_119])
        #expect(bindings.allSatisfy { $0.parameters.allowLocalEndpointReuse })
    }

    @Test("loopback listener failure policy tolerates one localhost family failing")
    func loopbackListenerFailurePolicyToleratesOneLocalhostFamilyFailing() {
        var policy = GoogleOAuthLoopbackListenerFailurePolicy(listenerCount: 2)
        let firstFailureIsTerminal = policy.recordFailure(listenerID: 1)
        let duplicateFailureIsTerminal = policy.recordFailure(listenerID: 1)
        let secondFamilyFailureIsTerminal = policy.recordFailure(listenerID: 0)

        #expect(!firstFailureIsTerminal)
        #expect(!duplicateFailureIsTerminal)
        #expect(secondFamilyFailureIsTerminal)
    }

    @Test("loopback listener failure policy fails explicit single binding immediately")
    func loopbackListenerFailurePolicyFailsSingleBindingImmediately() {
        var policy = GoogleOAuthLoopbackListenerFailurePolicy(listenerCount: 1)
        let failureIsTerminal = policy.recordFailure(listenerID: 0)

        #expect(failureIsTerminal)
    }

    @Test("loopback listener binds explicit IPv6 redirects to IPv6 loopback")
    func loopbackListenerBindsExplicitIPv6RedirectsToIPv6Loopback() throws {
        let redirectURI = URL(string: "http://[::1]:48119/oauth/google/callback")!
        let bindings = try #require(GoogleOAuthLoopbackListenerPolicy.bindings(for: redirectURI))
        let binding = try #require(bindings.first)
        let endpoint = try #require(binding.parameters.requiredLocalEndpoint)

        guard case let .hostPort(host, port) = endpoint else {
            Issue.record("Expected a required hostPort local endpoint, got \(endpoint)")
            return
        }

        #expect(bindings.count == 1)
        #expect(String(describing: host) == "::1")
        #expect(port.rawValue == 48_119)
        #expect(binding.parameters.allowLocalEndpointReuse)
    }

    @Test("loopback listener parameters reject non-loopback redirect hosts")
    func loopbackListenerParametersRejectNonLoopbackHosts() {
        let redirectURI = URL(string: "http://192.0.2.10:48119/oauth/google/callback")!

        #expect(GoogleOAuthLoopbackListenerPolicy.parameters(for: redirectURI) == nil)
    }

    @Test("loopback receiver reports invalid redirect URI policy failures")
    func loopbackReceiverReportsInvalidRedirectURI() async {
        let authorizationURL = URL(string: "https://accounts.example.test/oauth?redirect_uri=http%3A%2F%2F192.0.2.10%3A48119%2Foauth%2Fgoogle%2Fcallback")!

        await #expect(throws: GoogleOAuthAuthorizationSessionError.invalidRedirectURI("http://192.0.2.10:48119/oauth/google/callback")) {
            try await LoopbackGoogleOAuthCallbackReceiver().receiveCallback(authorizationURL: authorizationURL)
        }
    }
}
