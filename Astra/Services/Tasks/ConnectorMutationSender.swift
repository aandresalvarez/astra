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

/// The one place in the app that performs a connector write.
struct URLSessionConnectorMutationSender: ConnectorMutationSending {
    /// Ceiling on the response ASTRA reads back. A receipt is an issue key and a
    /// URL; anything larger is a body no one benefits from holding.
    static let responseByteLimit = 64 * 1024
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
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // A write must not be replayed by the loading system on ASTRA's behalf.
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let capped = data.prefix(Self.responseByteLimit)
        return ConnectorMutationHTTPResponse(
            statusCode: statusCode,
            body: String(data: capped, encoding: .utf8) ?? ""
        )
    }
}
