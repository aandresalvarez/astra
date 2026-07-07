import Foundation
import ASTRACore

protocol GoogleOAuthTokenTransport: AnyObject {
    func postForm(url: URL, form: [String: String]) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionGoogleOAuthTokenTransport: GoogleOAuthTokenTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postForm(url: URL, form: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuthHTTPTokenClient.formBody(form)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthHTTPTokenClient.Error.invalidResponse
        }
        return (data, http)
    }
}

final class GoogleOAuthHTTPTokenClient: GoogleOAuthTokenClient {
    enum Error: LocalizedError, Equatable {
        case invalidResponse
        case tokenRequestFailed(String)
        case missingAccessToken
        case missingExpiry

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Google OAuth token response was invalid."
            case .tokenRequestFailed(let reason):
                return "Google OAuth token request failed: \(reason)."
            case .missingAccessToken:
                return "Google OAuth token response did not include an access token."
            case .missingExpiry:
                return "Google OAuth token response did not include an expiry."
            }
        }
    }

    private let configuration: GoogleOAuthConfiguration
    private let transport: any GoogleOAuthTokenTransport
    private let now: () -> Date

    init(
        configuration: GoogleOAuthConfiguration,
        transport: (any GoogleOAuthTokenTransport)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionGoogleOAuthTokenTransport()
        self.now = now
    }

    func exchangeAuthorizationCode(_ request: GoogleOAuthAuthorizationCodeRequest) async throws -> GoogleOAuthTokenSet {
        try await token(form: [
            "grant_type": "authorization_code",
            "code": request.code,
            "client_id": configuration.clientID,
            "redirect_uri": request.redirectURI,
            "code_verifier": request.codeVerifier
        ], fallbackScopes: [])
    }

    func refreshAccessToken(_ request: GoogleOAuthRefreshRequest) async throws -> GoogleOAuthTokenSet {
        try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": request.refreshToken,
            "client_id": configuration.clientID
        ], fallbackScopes: request.requestedScopes)
    }

    private func token(form: [String: String], fallbackScopes: [String]) async throws -> GoogleOAuthTokenSet {
        let (data, response) = try await transport.postForm(url: configuration.tokenEndpoint, form: form)
        let object = try parseObject(data)
        guard (200..<300).contains(response.statusCode) else {
            throw Error.tokenRequestFailed(errorReason(from: object))
        }
        guard let accessToken = object["access_token"] as? String,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingAccessToken
        }
        guard let expiresIn = Self.intValue(object["expires_in"]) else {
            throw Error.missingExpiry
        }
        let scopes = (object["scope"] as? String).map { GoogleOAuthScopeNormalizer.normalized([$0]) } ?? fallbackScopes
        return GoogleOAuthTokenSet(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            grantedScopes: scopes
        )
    }

    static func formBody(_ form: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key, allowed: allowed))=\(percentEncode(value, allowed: allowed))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func percentEncode(_ value: String, allowed: CharacterSet) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func parseObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidResponse
        }
        return object
    }

    private func errorReason(from object: [String: Any]) -> String {
        if let error = object["error"] as? String, !error.isEmpty { return error }
        return "http_error"
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
