import Foundation

struct GoogleOAuthIdentity: Equatable, Sendable {
    var subject: String
    var email: String
    var displayName: String
    var avatarURLString: String?
    var hostedDomain: String?
}

protocol GoogleOAuthIdentityProvider: AnyObject {
    func identity(accessToken: String) async throws -> GoogleOAuthIdentity
}

protocol GoogleOAuthIdentityTransport: AnyObject {
    func getJSON(from url: URL, authorizationHeader: String) async throws -> (statusCode: Int, body: [String: Any])
}

final class URLSessionGoogleOAuthIdentityTransport: GoogleOAuthIdentityTransport {
    func getJSON(from url: URL, authorizationHeader: String) async throws -> (statusCode: Int, body: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthIdentityProviderError.invalidResponse
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, body)
    }
}

final class GoogleOAuthHTTPIdentityProvider: GoogleOAuthIdentityProvider {
    private let endpoint: URL
    private let transport: any GoogleOAuthIdentityTransport

    init(
        endpoint: URL = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!,
        transport: any GoogleOAuthIdentityTransport = URLSessionGoogleOAuthIdentityTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func identity(accessToken: String) async throws -> GoogleOAuthIdentity {
        let response = try await transport.getJSON(from: endpoint, authorizationHeader: "Bearer \(accessToken)")
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleOAuthIdentityProviderError.httpStatus(response.statusCode)
        }
        guard let subject = response.body["sub"] as? String,
              let email = response.body["email"] as? String,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleOAuthIdentityProviderError.invalidResponse
        }
        return GoogleOAuthIdentity(
            subject: subject,
            email: email,
            displayName: response.body["name"] as? String ?? "",
            avatarURLString: response.body["picture"] as? String,
            hostedDomain: response.body["hd"] as? String
        )
    }
}

enum GoogleOAuthIdentityProviderError: LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "Google account identity request failed with HTTP \(status)."
        case .invalidResponse:
            return "Google account identity response was invalid."
        }
    }
}
