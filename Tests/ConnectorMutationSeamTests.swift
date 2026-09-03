import Foundation
import Network
import os
import Testing
import ASTRACore
@testable import ASTRA
@testable import HostControlToolSupport

/// Cross-checks the three tables that together decide whether a connector write
/// can happen: what the broker will stage, what ASTRA will send, and what the
/// permission ledger will accept an approval for.
///
/// Each is edited on its own, in a different file, usually by someone adding a
/// single operation. The failure mode is not that one of them is wrong — it is
/// that two of them disagree, and the disagreement shows up as a proposal the
/// user approves and ASTRA then cannot send, or a send route with nothing
/// upstream to review it.
@Suite("Connector mutation seam")
struct ConnectorMutationSeamTests {
    /// A commit route for an unbrokered service is unreachable by construction:
    /// `isSafeConnectorMutationAuthorization` refuses the approval, because
    /// unbrokered means the credential is projected into the agent and there was
    /// never anything to protect. Better to fail here than to ship a POST route
    /// nobody can ever authorize.
    @Test("Every operation ASTRA can commit belongs to a brokered service")
    func everyCommitRouteIsBrokered() {
        let unbrokered = ConnectorMutationOperations.all
            .filter { !HostControlBrokeredServices.ownsConfiguration(ofServiceType: $0.serviceType) }
            .map(\.serviceType)

        #expect(
            unbrokered.isEmpty,
            """
            ASTRA can commit a mutation for a service the broker does not own: \
            \(unbrokered.sorted()). Register the service in \
            HostControlBrokeredServices, or remove the route.
            """
        )
    }

    /// The direction that hurts. The broker stages `create_issue`; if the send
    /// table ever loses that entry, the agent keeps composing proposals, the
    /// dock keeps raising them, and every approval ends in
    /// `unsupportedOperation` — a review surface that cannot do the one thing it
    /// asks the user to authorize.
    @Test("Everything the broker stages is something ASTRA can send")
    func everyStagedOperationHasACommitRoute() {
        let staged = JiraIssueProposalPolicy.stagedOperation

        #expect(
            ConnectorMutationOperations.definition(serviceType: "jira", operation: staged) != nil,
            """
            The Jira broker stages '\(staged)' but ConnectorMutationOperations has \
            no route for it, so an approved proposal cannot be sent.
            """
        )
    }

    /// Not a style rule. Every entry here is a URL the app will POST to with a
    /// Keychain credential attached, chosen by the app rather than by the staged
    /// envelope — which is the only reason a rewritten envelope cannot redirect
    /// the credential. An entry that took its path from elsewhere, or reached a
    /// different host, would give that back.
    @Test("Commit routes are absolute paths on the connector's own host")
    func commitRoutesAreWellFormed() {
        for definition in ConnectorMutationOperations.all {
            #expect(definition.path.hasPrefix("/"), "\(definition.operation): path is not absolute")
            #expect(!definition.path.contains(".."), "\(definition.operation): path contains traversal")
            #expect(!definition.path.contains("://"), "\(definition.operation): path names a host")
            #expect(
                definition.serviceType == definition.serviceType.lowercased(),
                "\(definition.serviceType): lookups lowercase the service type, so the table must too"
            )
            #expect(
                definition.operation == definition.operation.lowercased(),
                "\(definition.operation): lookups lowercase the operation, so the table must too"
            )
        }
    }

    /// The prompt tells the agent to propose only where ASTRA can actually
    /// commit. If this drifts, the guidance either goes silent on a service that
    /// works or advertises one that does not.
    @Test("Mutation support is reported from the commit table")
    func mutationSupportTracksTheCommitTable() {
        #expect(ConnectorMutationOperations.supportsMutation(serviceType: "jira"))
        #expect(ConnectorMutationOperations.supportsMutation(serviceType: " JIRA "))
        #expect(!ConnectorMutationOperations.supportsMutation(serviceType: "github"))
        #expect(!ConnectorMutationOperations.supportsMutation(serviceType: ""))
    }

    /// The ceiling has to bind on what is allocated, not on what is kept.
    /// `URLSession.data(for:)` returns only once the whole body is in memory, so
    /// trimming afterwards left a connector answering a write with a gigabyte —
    /// a misconfigured proxy, an error page from something that is not the
    /// service — free to pull all of it in first.
    @Test("A response larger than the ceiling stops at the ceiling")
    func oversizedResponsesStopAtTheCeiling() async throws {
        let limit = 4 * 1024
        let source = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-oversized-\(UUID().uuidString).json")
        try Data(repeating: UInt8(ascii: "x"), count: limit * 8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (stream, _) = try await session.bytes(from: source)
        let body = try await URLSessionConnectorMutationSender.read(stream, limit: limit)

        #expect(body.count == limit)
    }

    /// The ordinary case, and the one the cap must not damage: a receipt is an
    /// issue key and a URL, and it has to come back whole.
    @Test("A response under the ceiling is returned intact")
    func ordinaryResponsesAreReturnedWhole() async throws {
        let receipt = #"{"id":"10042","key":"STAR-1","self":"https://jira.test/rest/api/2/issue/10042"}"#
        let source = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-receipt-\(UUID().uuidString).json")
        try Data(receipt.utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (stream, _) = try await session.bytes(from: source)
        let body = try await URLSessionConnectorMutationSender.read(
            stream, limit: URLSessionConnectorMutationSender.responseByteLimit)

        #expect(String(data: body, encoding: .utf8) == receipt)
    }

    /// The review sheet shows one URL, and that has to be the only URL the write
    /// reaches. `307`/`308` preserve the method and the body, so a redirect on an
    /// approved `POST` re-delivers the reviewed request somewhere the user never
    /// saw and never authorized — a second ticket, on a host chosen by whatever
    /// answered the first one.
    ///
    /// Answered against a real socket rather than a stubbed session, because what
    /// is being tested is `URLSession`'s behaviour and not ASTRA's arithmetic.
    @Test("An approved write is not re-sent to a redirect target")
    func redirectsAreRefused() async throws {
        let server = try await RedirectingHTTPServer.start()
        defer { server.stop() }

        let response = try await URLSessionConnectorMutationSender().send(
            ConnectorMutationHTTPRequest(
                url: server.url(path: RedirectingHTTPServer.writePath),
                method: "POST",
                body: Data(#"{"fields":{"summary":"Reviewed"}}"#.utf8),
                authorizationHeader: "Basic \(Data("user:secret-token".utf8).base64EncodedString())"
            )
        )

        // The redirect itself comes back, which the coordinator reads as neither
        // a receipt nor a refusal and quarantines. That is the honest answer: a
        // server that redirects a POST may already have applied it.
        #expect(response.statusCode == 307)
        #expect(server.requests.map(\.path) == [RedirectingHTTPServer.writePath])
        #expect(server.requests.first?.carriedCredential == true)
    }

    /// The control, and the reason the delegate is not decoration: the same
    /// fixture, sent by an ordinary session, is delivered a second time — same
    /// method, same body — to a path nobody reviewed.
    @Test("A default session follows the same redirect and re-sends the write")
    func aDefaultSessionFollowsTheRedirect() async throws {
        let server = try await RedirectingHTTPServer.start()
        defer { server.stop() }

        let body = Data(#"{"fields":{"summary":"Reviewed"}}"#.utf8)
        var request = URLRequest(url: server.url(path: RedirectingHTTPServer.writePath))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "Basic \(Data("user:secret-token".utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(server.requests.map(\.path) == [
            RedirectingHTTPServer.writePath, RedirectingHTTPServer.followedPath
        ])
        // The write arrives whole at the unreviewed path. Whether the loading
        // system also re-attaches the credential is its business and varies; the
        // ticket being filed twice is the harm either way.
        let followed = try #require(server.requests.last)
        #expect(followed.method == "POST")
        #expect(followed.contentLength == body.count)
    }
}

/// Answers the write path with a `307` pointing at a second path on the same
/// host, and records what arrived at each.
private final class RedirectingHTTPServer: @unchecked Sendable {
    static let writePath = "/rest/api/2/issue"
    static let followedPath = "/somewhere-else"

    struct Request: Equatable {
        let method: String
        let path: String
        let carriedCredential: Bool
        let contentLength: Int
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.coral.astra.tests.redirecting-http")
    private var port: UInt16 = 0
    private var received: [Request] = []

    var requests: [Request] { queue.sync { received } }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(queue.sync { port })\(path)")!
    }

    static func start() async throws -> RedirectingHTTPServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = RedirectingHTTPServer(listener: try NWListener(using: parameters, on: .any))
        try await server.listen()
        return server
    }

    private init(listener: NWListener) {
        self.listener = listener
    }

    func stop() {
        listener.cancel()
    }

    private func listen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: (Result<Void, Error>) -> Void = { result in
                let alreadyResumed = resumed.withLock { state -> Bool in
                    defer { state = true }
                    return state
                }
                if !alreadyResumed { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                connection.stateUpdateHandler = { state in
                    if case .ready = state { self.read(connection, buffer: Data()) }
                }
                connection.start(queue: self.queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port else { return }
                    self?.port = port.rawValue
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Reads headers and then the declared body, so the response is not sent
    /// while the client is still writing — a close with unread bytes pending
    /// draws a reset rather than a status code.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            guard error == nil else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            guard let terminator = next.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.read(connection, buffer: next) }
                return
            }
            let header = String(decoding: next[..<terminator.lowerBound], as: UTF8.self)
            let declared = Self.contentLength(header)
            if next.count - terminator.upperBound < declared, !isComplete {
                self.read(connection, buffer: next)
                return
            }
            self.respond(to: header, on: connection)
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        let path = requestLine.count > 1 ? requestLine[1] : ""
        received.append(Request(
            method: requestLine.first ?? "",
            path: path,
            carriedCredential: lines.contains { $0.lowercased().hasPrefix("authorization:") },
            contentLength: Self.contentLength(header)
        ))

        let response: String
        if path == Self.writePath {
            response = "HTTP/1.1 307 Temporary Redirect\r\n"
                + "Location: \(Self.followedPath)\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: close\r\n\r\n"
        } else {
            let body = #"{"key":"STAR-9"}"#
            response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
        }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func contentLength(_ header: String) -> Int {
        for line in header.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}
