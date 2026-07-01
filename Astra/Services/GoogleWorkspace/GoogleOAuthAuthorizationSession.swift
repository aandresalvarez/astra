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
    case invalidRedirectURI(String)
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .stateMismatch:
            return "Google OAuth state validation failed."
        case .invalidRedirectURI(let redirectURI):
            return "Google OAuth redirect URI is not a safe loopback callback: \(redirectURI)"
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
        let redirectURI = Self.redirectURI(from: authorizationURL)
        guard let redirectURI,
              let bindings = GoogleOAuthLoopbackListenerPolicy.bindings(for: redirectURI) else {
            throw GoogleOAuthAuthorizationSessionError.invalidRedirectURI(
                redirectURI?.absoluteString ?? ""
            )
        }
        let listeners = try bindings.map { binding in
            try NWListener(using: binding.parameters, on: binding.port)
        }
        let queue = DispatchQueue(label: "com.coral.astra.google-oauth-callback")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = CallbackState(continuation: continuation, listeners: listeners)
                for (listenerID, listener) in listeners.enumerated() {
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
                            state.listenerFailed(listenerID, error: error)
                        }
                    }
                    listener.start(queue: queue)
                }
                NSWorkspace.shared.open(authorizationURL)
            }
        } onCancel: {
            for listener in listeners {
                listener.cancel()
            }
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
    struct Binding {
        var parameters: NWParameters
        var port: NWEndpoint.Port
    }

    static func parameters(for redirectURI: URL) -> NWParameters? {
        bindings(for: redirectURI)?.first?.parameters
    }

    static func bindings(for redirectURI: URL) -> [Binding]? {
        guard let hosts = loopbackHosts(from: redirectURI),
              let port = port(for: redirectURI) else {
            return nil
        }

        return hosts.map { host in
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
            return Binding(parameters: parameters, port: port)
        }
    }

    static func port(for redirectURI: URL) -> NWEndpoint.Port? {
        guard let portValue = redirectURI.port,
              let rawPort = UInt16(exactly: portValue) else {
            return nil
        }
        return NWEndpoint.Port(rawValue: rawPort)
    }

    private static func loopbackHosts(from redirectURI: URL) -> [String]? {
        guard let host = redirectURI.host?.lowercased() else {
            return nil
        }
        switch host {
        case "localhost":
            return ["127.0.0.1", "::1"]
        case "127.0.0.1", "::1":
            return [host]
        default:
            return nil
        }
    }
}

struct GoogleOAuthLoopbackListenerFailurePolicy: Sendable, Equatable {
    private let listenerCount: Int
    private var failedListenerIDs: Set<Int> = []

    init(listenerCount: Int) {
        self.listenerCount = max(0, listenerCount)
    }

    mutating func recordFailure(listenerID: Int) -> Bool {
        guard listenerID >= 0, listenerID < listenerCount else {
            return false
        }
        failedListenerIDs.insert(listenerID)
        return listenerCount > 0 && failedListenerIDs.count == listenerCount
    }
}

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var listenerFailurePolicy: GoogleOAuthLoopbackListenerFailurePolicy
    private let continuation: CheckedContinuation<GoogleOAuthCallback, Error>
    private let listeners: [NWListener]

    init(continuation: CheckedContinuation<GoogleOAuthCallback, Error>, listeners: [NWListener]) {
        self.continuation = continuation
        self.listeners = listeners
        self.listenerFailurePolicy = GoogleOAuthLoopbackListenerFailurePolicy(listenerCount: listeners.count)
    }

    func resume(_ result: Result<GoogleOAuthCallback, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        for listener in listeners {
            listener.cancel()
        }
        continuation.resume(with: result)
    }

    func listenerFailed(_ listenerID: Int, error: Error) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        guard listenerFailurePolicy.recordFailure(listenerID: listenerID) else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        for listener in listeners {
            listener.cancel()
        }
        continuation.resume(throwing: error)
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
        guard let components = callbackTargetComponents(from: target, redirectURI: redirectURI) else {
            return nil
        }
        let query = components.queryItems ?? []
        guard let code = query.first(where: { $0.name == "code" })?.value,
              let state = query.first(where: { $0.name == "state" })?.value else {
            return nil
        }
        return GoogleOAuthCallback(code: code, state: state)
    }

    private static func callbackTargetComponents(from target: String, redirectURI: URL) -> URLComponents? {
        guard let components = URLComponents(string: target),
              requestPath(components.percentEncodedPath) == redirectPath(for: redirectURI) else {
            return nil
        }

        guard components.scheme != nil || components.host != nil || components.port != nil else {
            return components
        }

        guard components.scheme?.lowercased() == redirectURI.scheme?.lowercased(),
              normalizedHost(components.host) == normalizedHost(redirectURI.host),
              components.port == redirectURI.port else {
            return nil
        }
        return components
    }

    private static func redirectPath(for redirectURI: URL) -> String {
        let path = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return requestPath(path)
    }

    private static func requestPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        return host
    }
}
