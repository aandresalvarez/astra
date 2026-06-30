import Foundation
import Network
import Testing
@testable import ASTRA

@Suite("Local Agent network fetch")
struct LocalAgentNetworkFetchTests {
    @Test("Bounded loader stops reading at response cap")
    func boundedLoaderStopsReadingAtResponseCap() async throws {
        let body = String(repeating: "a", count: 4_096)
        let server = RawHTTPTestServer { _ in
            RawHTTPTestServer.response(statusCode: 200, body: body)
        }
        let port = try server.start()
        defer { server.stop() }

        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/large")))
        let result = try await LocalAgentCancellableDataLoader.boundedData(
            for: request,
            maxBytes: 128,
            cancellationToken: nil
        )

        #expect(result.data.count == 128)
        #expect(result.truncated)
        #expect(String(decoding: result.data, as: UTF8.self) == String(repeating: "a", count: 128))
    }

    @Test("Bounded loader rejects redirects before following them")
    func boundedLoaderRejectsRedirectsBeforeFollowingThem() async throws {
        let server = RawHTTPTestServer { _ in
            RawHTTPTestServer.response(
                statusCode: 302,
                headers: ["Location": "/redirect-target"],
                body: ""
            )
        }
        let port = try server.start()
        defer { server.stop() }

        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/redirect")))
        await #expect(throws: LocalAgentNetworkFetchError.self) {
            _ = try await LocalAgentCancellableDataLoader.boundedData(
                for: request,
                maxBytes: 128,
                cancellationToken: nil
            )
        }
    }
}

private final class RawHTTPTestServer {
    typealias Handler = @Sendable (String) -> String

    enum ServerError: Error {
        case startupTimedOut
        case missingPort
    }

    private let handler: Handler
    private let queue = DispatchQueue(label: "astra.tests.local-agent-network-fetch")
    private var listener: NWListener?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [handler, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let response = handler(request)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw ServerError.startupTimedOut
        }
        if let startupError {
            throw startupError
        }
        guard let port = listener.port?.rawValue else {
            throw ServerError.missingPort
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func response(
        statusCode: Int,
        headers: [String: String] = [:],
        body: String
    ) -> String {
        var lines = [
            "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(Data(body.utf8).count)",
            "Connection: close"
        ]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 302:
            return "Found"
        default:
            return "Status"
        }
    }
}
