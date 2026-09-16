import Foundation

/// The mutations ASTRA knows how to commit, and the exact route each one takes.
///
/// The staged envelope declares a method and a path, but this is the authority
/// and the envelope is checked against it. That ordering matters: the staging
/// directory is agent-writable, so a trusted `requestPath` would let a rewritten
/// envelope aim an authenticated POST anywhere on the connector's host. Deriving
/// the route here means the worst a rewritten envelope can do is disagree, and
/// disagreement is refused.
///
/// It is also the allowlist. An operation absent from this table cannot be
/// committed at all, which is what keeps "ASTRA can mutate" from meaning "ASTRA
/// can perform whatever the broker wrote down".
enum ConnectorMutationOperations {
    struct Definition: Equatable, Sendable {
        let serviceType: String
        let operation: String
        let method: String
        let path: String
    }

    static let all: [Definition] = [
        Definition(serviceType: "jira", operation: "create_issue", method: "POST", path: "/rest/api/2/issue")
    ]

    static func definition(serviceType: String, operation: String) -> Definition? {
        let service = serviceType.lowercased()
        let name = operation.lowercased()
        return all.first { $0.serviceType == service && $0.operation == name }
    }

    /// Whether ASTRA can commit anything at all for this service.
    ///
    /// Read by the prompt builder so the propose-and-review contract is stated
    /// only where it is true. Telling an agent to propose a change ASTRA has no
    /// route to send is worse than saying nothing: it turns a clean "this cannot
    /// be done" into a proposal that sits unsendable on the dock.
    static func supportsMutation(serviceType: String) -> Bool {
        let service = serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.contains { $0.serviceType == service }
    }
}

/// A fully resolved outbound request. Holds the credential, so it is
/// deliberately not `Codable`, not `Equatable`, and has no synthesised
/// description — nothing here should be able to reach a log or a transcript by
/// being printed.
struct ConnectorMutationHTTPRequest: @unchecked Sendable {
    let url: URL
    let method: String
    let body: Data
    let authorizationHeader: String
}

struct ConnectorMutationHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let body: String
}

protocol ConnectorMutationSending: Sendable {
    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse
}

/// Stops `URLSession` from re-sending an approved write somewhere the user
/// never saw.
///
/// Default redirect handling follows `3xx` transparently, and `307`/`308`
/// preserve the method and the body — so a reviewed `POST` to the endpoint on
/// the sheet is re-delivered whole to a different path, or a different host,
/// chosen by whatever answered first. Whether the loading system re-attaches
/// the `Authorization` header on the way is beside the point: the write itself
/// arrives somewhere nobody reviewed. `httpShouldSetCookies` and a `nil` cache
/// do not touch any of that; only a delegate does.
///
/// Returning `nil` completes the task with the redirect response itself, which
/// lands in the coordinator's "neither 2xx nor 4xx" branch and is quarantined as
/// indeterminate. That is the right reading: a server that redirects a `POST`
/// may well have applied it before answering, so this is not a refusal ASTRA can
/// report as a clean failure.
private final class ConnectorMutationRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The one place in the app that performs a connector write.
struct URLSessionConnectorMutationSender: ConnectorMutationSending {
    /// Ceiling on the response ASTRA reads back. A receipt is an issue key and a
    /// URL; anything larger is a body no one benefits from holding.
    ///
    /// Enforced while reading, not after. `URLSession.data(for:)` buffers the
    /// entire body before returning it, so trimming the result afterwards
    /// bounded what ASTRA *kept* and not what it *allocated*: a connector that
    /// answered a write with a gigabyte — a misconfigured proxy, an error page
    /// from something that is not the service, a host the base URL now resolves
    /// to — pulled all of it into memory first. Streaming and stopping at the
    /// limit makes the ceiling real.
    static let responseByteLimit = 64 * 1024

    /// Applied per stall *and* to the exchange as a whole. Without the second,
    /// a server dribbling bytes below the limit holds the send open for as long
    /// as it likes, and a write with no answer is the one outcome the commit
    /// path cannot resolve for the user.
    static let timeoutSeconds: TimeInterval = 30

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: Self.timeoutSeconds)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.authorizationHeader, forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = Self.timeoutSeconds
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // A write must not be replayed by the loading system on ASTRA's behalf.
        configuration.httpShouldSetCookies = false
        let session = URLSession(
            configuration: configuration,
            delegate: ConnectorMutationRedirectRefusal(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (stream, response) = try await session.bytes(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = try await Self.read(stream, limit: Self.responseByteLimit)
        return ConnectorMutationHTTPResponse(
            statusCode: statusCode,
            body: String(data: body, encoding: .utf8) ?? ""
        )
    }

    /// Reads at most `limit` bytes and hangs up.
    ///
    /// Cancelling the task is the part that matters. Leaving the stream to be
    /// torn down by deinit would let the transfer keep running — the ceiling
    /// would bound the string ASTRA holds while the download it was meant to
    /// stop continued in the background.
    static func read(_ stream: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var body = Data()
        body.reserveCapacity(min(limit, 8 * 1024))
        for try await byte in stream {
            body.append(byte)
            if body.count >= limit {
                stream.task.cancel()
                break
            }
        }
        return body
    }
}
