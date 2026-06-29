import Foundation
import AppKit
import Network

struct GoogleOAuthAuthorizationSessionRequest: Equatable, Sendable {
    var configuration: GoogleOAuthConfiguration
    var scopes: [String]
    var pkce: GoogleOAuthPKCE.Material

    var authorizationURL: URL {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthScopeNormalizer.normalized(scopes).joined(separator: " ")),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!
    }
}

struct GoogleOAuthAuthorizationGrant: Equatable, Sendable {
    var code: String
    var redirectURI: URL
    var codeVerifier: String
}

protocol GoogleOAuthAuthorizationSession {
    mutating func authorize(_ request: GoogleOAuthAuthorizationSessionRequest) async throws -> GoogleOAuthAuthorizationGrant
}

enum GoogleOAuthAuthorizationSessionError: LocalizedError, Equatable {
    case missingAuthorizationCode
    case stateMismatch
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .stateMismatch:
            return "Google OAuth state validation failed."
        case .unsupportedPlatform:
            return "Google OAuth browser authorization is unavailable on this platform."
        }
    }
}

struct LoopbackGoogleOAuthAuthorizationSession: GoogleOAuthAuthorizationSession {
    private let callbackReceiver: any GoogleOAuthCallbackReceiving

    init(callbackReceiver: any GoogleOAuthCallbackReceiving = LoopbackGoogleOAuthCallbackReceiver()) {
        self.callbackReceiver = callbackReceiver
    }

    func authorize(_ request: GoogleOAuthAuthorizationSessionRequest) async throws -> GoogleOAuthAuthorizationGrant {
        let callback = try await callbackReceiver.receiveCallback(authorizationURL: request.authorizationURL)
        guard GoogleOAuthPKCE.validate(returnedState: callback.state, expectedState: request.pkce.state) else {
            throw GoogleOAuthAuthorizationSessionError.stateMismatch
        }
        guard !callback.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleOAuthAuthorizationSessionError.missingAuthorizationCode
        }
        return GoogleOAuthAuthorizationGrant(
            code: callback.code,
            redirectURI: request.configuration.redirectURI,
            codeVerifier: request.pkce.codeVerifier
        )
    }
}

struct GoogleOAuthCallback: Equatable, Sendable {
    var code: String
    var state: String
}

protocol GoogleOAuthCallbackReceiving {
    func receiveCallback(authorizationURL: URL) async throws -> GoogleOAuthCallback
}

struct LoopbackGoogleOAuthCallbackReceiver: GoogleOAuthCallbackReceiving {
    func receiveCallback(authorizationURL: URL) async throws -> GoogleOAuthCallback {
        guard let redirectURI = Self.redirectURI(from: authorizationURL),
              let port = GoogleOAuthLoopbackListenerPolicy.port(for: redirectURI),
              let parameters = GoogleOAuthLoopbackListenerPolicy.parameters(for: redirectURI) else {
            throw GoogleOAuthAuthorizationSessionError.unsupportedPlatform
        }
        let listener = try NWListener(using: parameters, on: port)
        let queue = DispatchQueue(label: "com.coral.astra.google-oauth-callback")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = CallbackState(continuation: continuation, listener: listener)
                listener.newConnectionHandler = { connection in
                    connection.start(queue: queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                        if let error {
                            state.resume(.failure(error))
                            connection.cancel()
                            return
                        }
                        guard let data,
                              let request = String(data: data, encoding: .utf8),
                              let callback = GoogleOAuthCallbackParser.callback(fromHTTPRequest: request, redirectURI: redirectURI) else {
                            state.resume(.failure(GoogleOAuthAuthorizationSessionError.missingAuthorizationCode))
                            connection.cancel()
                            return
                        }
                        let response = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/plain; charset=utf-8\r
                        Connection: close\r
                        \r
                        Google sign-in is complete. You can return to ASTRA.
                        """
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        state.resume(.success(callback))
                    }
                }
                listener.stateUpdateHandler = { stateUpdate in
                    if case .failed(let error) = stateUpdate {
                        state.resume(.failure(error))
                    }
                }
                listener.start(queue: queue)
                NSWorkspace.shared.open(authorizationURL)
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private static func redirectURI(from authorizationURL: URL) -> URL? {
        URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "redirect_uri" }?
            .value
            .flatMap(URL.init(string:))
    }
}

enum GoogleOAuthLoopbackListenerPolicy {
    static func parameters(for redirectURI: URL) -> NWParameters? {
        guard let host = normalizedLoopbackHost(from: redirectURI),
              let port = port(for: redirectURI) else {
            return nil
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        return parameters
    }

    static func port(for redirectURI: URL) -> NWEndpoint.Port? {
        guard let portValue = redirectURI.port,
              let rawPort = UInt16(exactly: portValue) else {
            return nil
        }
        return NWEndpoint.Port(rawValue: rawPort)
    }

    private static func normalizedLoopbackHost(from redirectURI: URL) -> String? {
        guard let host = redirectURI.host?.lowercased() else {
            return nil
        }
        switch host {
        case "localhost":
            return "127.0.0.1"
        case "127.0.0.1", "::1":
            return host
        default:
            return nil
        }
    }
}

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<GoogleOAuthCallback, Error>
    private let listener: NWListener

    init(continuation: CheckedContinuation<GoogleOAuthCallback, Error>, listener: NWListener) {
        self.continuation = continuation
        self.listener = listener
    }

    func resume(_ result: Result<GoogleOAuthCallback, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        listener.cancel()
        continuation.resume(with: result)
    }
}

enum GoogleOAuthCallbackParser {
    static func callback(fromHTTPRequest request: String, redirectURI: URL) -> GoogleOAuthCallback? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: "\(redirectURI.scheme ?? "http")://\(redirectURI.host ?? "127.0.0.1")\(target)") else {
            return nil
        }
        let query = components.queryItems ?? []
        guard let code = query.first(where: { $0.name == "code" })?.value,
              let state = query.first(where: { $0.name == "state" })?.value else {
            return nil
        }
        return GoogleOAuthCallback(code: code, state: state)
    }
}
