import Foundation
import Network
import os

final class RedirectingHTTPServer: @unchecked Sendable {
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
    private let responseBody: String
    private let declaredLength: Bool

    var requests: [Request] { queue.sync { received } }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(queue.sync { port })\(path)")!
    }

    static func start(body: String = #"{"key":"STAR-9"}"#, declaredLength: Bool = true) async throws -> RedirectingHTTPServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = RedirectingHTTPServer(listener: try NWListener(using: parameters, on: .any), body: body, declaredLength: declaredLength)
        try await server.listen()
        return server
    }

    private init(listener: NWListener, body: String, declaredLength: Bool) {
        self.listener = listener
        responseBody = body
        self.declaredLength = declaredLength
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
            let body = responseBody
            response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + (declaredLength ? "Content-Length: \(body.utf8.count)\r\n" : "")
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
