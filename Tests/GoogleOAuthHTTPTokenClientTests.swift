import Foundation
import Testing
@testable import ASTRA

@Suite("Google OAuth HTTP Token Client")
struct GoogleOAuthHTTPTokenClientTests {
    @Test("authorization code exchange posts form fields and parses token set")
    func authorizationCodeExchangePostsFormFields() async throws {
        let transport = RecordingGoogleOAuthTokenTransport(response: .success([
            "access_token": "access-secret",
            "refresh_token": "refresh-secret",
            "expires_in": 3600,
            "scope": "scope.read scope.write",
            "token_type": "Bearer"
        ]))
        let client = GoogleOAuthHTTPTokenClient(
            configuration: configuration(),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let token = try await client.exchangeAuthorizationCode(.init(
            code: "auth-code",
            redirectURI: "http://127.0.0.1:48119/oauth/google/callback",
            codeVerifier: "verifier"
        ))

        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url == URL(string: "https://oauth2.googleapis.com/token"))
        #expect(transport.requests[0].form["grant_type"] == "authorization_code")
        #expect(transport.requests[0].form["code"] == "auth-code")
        #expect(transport.requests[0].form["client_id"] == "client.apps.googleusercontent.com")
        #expect(transport.requests[0].form["redirect_uri"] == "http://127.0.0.1:48119/oauth/google/callback")
        #expect(transport.requests[0].form["code_verifier"] == "verifier")
        #expect(token.accessToken == "access-secret")
        #expect(token.refreshToken == "refresh-secret")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(token.grantedScopes == ["scope.read", "scope.write"])
    }

    @Test("refresh token posts form fields and parses returned scopes")
    func refreshTokenPostsFormFields() async throws {
        let transport = RecordingGoogleOAuthTokenTransport(response: .success([
            "access_token": "new-access",
            "expires_in": 900,
            "scope": "scope.read",
            "token_type": "Bearer"
        ]))
        let client = GoogleOAuthHTTPTokenClient(
            configuration: configuration(),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let token = try await client.refreshAccessToken(.init(
            refreshToken: "refresh-secret",
            requestedScopes: ["scope.read"]
        ))

        #expect(transport.requests[0].form["grant_type"] == "refresh_token")
        #expect(transport.requests[0].form["refresh_token"] == "refresh-secret")
        #expect(transport.requests[0].form["client_id"] == "client.apps.googleusercontent.com")
        #expect(token.accessToken == "new-access")
        #expect(token.refreshToken == nil)
        #expect(token.grantedScopes == ["scope.read"])
    }

    @Test("token errors are stable and redact credential values")
    func tokenErrorsAreStableAndRedacted() async throws {
        let transport = RecordingGoogleOAuthTokenTransport(response: .failure(statusCode: 400, body: [
            "error": "invalid_grant",
            "error_description": "refresh-secret is invalid"
        ]))
        let client = GoogleOAuthHTTPTokenClient(configuration: configuration(), transport: transport)

        do {
            _ = try await client.refreshAccessToken(.init(refreshToken: "refresh-secret", requestedScopes: []))
            Issue.record("Expected refresh to fail")
        } catch let error as GoogleOAuthHTTPTokenClient.Error {
            #expect(error.errorDescription == "Google OAuth token request failed: invalid_grant.")
            #expect(!String(describing: error).contains("refresh-secret"))
        }
    }

    private func configuration() -> GoogleOAuthConfiguration {
        GoogleOAuthConfiguration(
            clientID: "client.apps.googleusercontent.com",
            redirectURI: URL(string: "http://127.0.0.1:48119/oauth/google/callback")!,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
    }
}

private final class RecordingGoogleOAuthTokenTransport: GoogleOAuthTokenTransport {
    enum Response {
        case success([String: Any])
        case failure(statusCode: Int, body: [String: Any])
    }

    struct Request: Equatable {
        var url: URL
        var form: [String: String]
    }

    private let response: Response
    private(set) var requests: [Request] = []

    init(response: Response) {
        self.response = response
    }

    func postForm(url: URL, form: [String: String]) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(url: url, form: form))
        let object: [String: Any]
        let status: Int
        switch response {
        case .success(let body):
            object = body
            status = 200
        case .failure(let statusCode, let body):
            object = body
            status = statusCode
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, http)
    }
}
