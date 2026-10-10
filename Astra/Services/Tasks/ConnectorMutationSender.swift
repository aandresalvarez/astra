import Foundation
import HostControlToolSupport

/// The mutations ASTRA knows how to commit, and the exact route each one takes.
///
/// The staged envelope declares a method and a path, but this is the authority
/// and the envelope is checked against it. That ordering matters: the staging
/// directory is agent-writable, so a trusted `requestPath` would let a rewritten
/// envelope aim an authenticated request anywhere on the connector's host.
/// Deriving the route here means the worst a rewritten envelope can do is
/// disagree, and disagreement is refused.
///
/// It is also the allowlist. An operation absent from this table cannot be
/// committed at all, which is what keeps "ASTRA can mutate" from meaning "ASTRA
/// can perform whatever the broker wrote down".
///
/// A route may name one ticket. `{issue}` marks the single path segment the
/// envelope is allowed to fill, and it can fill it only with a well-formed issue
/// key — so the ticket is data the envelope supplies, and everything around it is
/// ASTRA's. There is deliberately no other placeholder: a second one would be a
/// second place for an envelope to write into the URL.
enum ConnectorMutationOperations {
    struct Definition: Equatable, Sendable {
        let serviceType: String
        let operation: String
        let method: String
        let pathTemplate: String

        static let issuePlaceholder = "{issue}"

        /// The path ASTRA will send to for a staged request, or `nil` when the
        /// staged path is not this operation's route.
        ///
        /// Built from `pathTemplate` and the validated key, never copied from the
        /// envelope: the two are equal when this returns a value, and taking the
        /// template's own segments is what keeps that a property of the code and
        /// not of a comparison somebody could later loosen.
        func resolvedPath(forStagedPath stagedPath: String) -> String? {
            let template = pathTemplate.split(separator: "/", omittingEmptySubsequences: false)
            let staged = stagedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard template.count == staged.count else { return nil }
            var resolved: [String] = []
            for (expected, actual) in zip(template, staged) {
                if expected == Self.issuePlaceholder {
                    // The one definition of a well-formed key lives with the
                    // broker that composes them, so the two cannot drift.
                    guard JiraHostControlOperations.isValidIssueKey(String(actual)) else { return nil }
                } else if expected != actual {
                    return nil
                }
                resolved.append(String(actual))
            }
            return resolved.joined(separator: "/")
        }

        /// The ticket a resolved path addresses, when the route is ticket-scoped.
        func issueKey(inResolvedPath path: String) -> String? {
            let template = pathTemplate.split(separator: "/", omittingEmptySubsequences: false)
            let resolved = path.split(separator: "/", omittingEmptySubsequences: false)
            guard template.count == resolved.count,
                  let index = template.firstIndex(of: Substring(Self.issuePlaceholder)) else {
                return nil
            }
            return String(resolved[index])
        }

        /// Whether the staged `target` names the ticket the route goes to.
        ///
        /// The target is what the dock row and the sheet print as the
        /// destination, and it is written by the same party that could rewrite
        /// the path. Without this check a proposal could read "STAR-1 · comment"
        /// above a request to STAR-2. Routes that name no ticket have nothing to
        /// disagree with.
        func target(_ target: String, namesTheTicketIn resolvedPath: String) -> Bool {
            guard let key = issueKey(inResolvedPath: resolvedPath) else { return true }
            return target == key || target.hasPrefix(key + " ")
        }
    }

    static let all: [Definition] = [
        Definition(serviceType: "jira", operation: "create_issue", method: "POST", pathTemplate: "/rest/api/2/issue"),
        Definition(
            serviceType: "jira", operation: "add_comment", method: "POST",
            pathTemplate: "/rest/api/2/issue/\(Definition.issuePlaceholder)/comment"
        ),
        Definition(
            serviceType: "jira", operation: "update_issue", method: "PUT",
            pathTemplate: "/rest/api/2/issue/\(Definition.issuePlaceholder)"
        ),
        Definition(
            serviceType: "jira", operation: "transition_issue", method: "POST",
            pathTemplate: "/rest/api/2/issue/\(Definition.issuePlaceholder)/transitions"
        )
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
    /// Per stall and for the whole exchange, as `URLSessionConnectorMutationSender`
    /// applies it.
    var timeoutSeconds: TimeInterval = URLSessionConnectorMutationSender.timeoutSeconds
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
    /// The default; a request may carry its own (`ConnectorMutationHTTPRequest`).
    static let timeoutSeconds: TimeInterval = 30

    func send(_ request: ConnectorMutationHTTPRequest) async throws -> ConnectorMutationHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeoutSeconds)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.authorizationHeader, forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutSeconds
        configuration.timeoutIntervalForResource = request.timeoutSeconds
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
