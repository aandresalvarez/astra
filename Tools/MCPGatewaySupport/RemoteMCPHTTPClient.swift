import Foundation

public protocol RemoteMCPHTTPTransport: AnyObject {
    func postJSON(to url: URL, headers: [String: String], body: [String: Any]) throws -> (statusCode: Int, body: [String: Any])
}

public final class URLSessionRemoteMCPHTTPTransport: RemoteMCPHTTPTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    public func postJSON(to url: URL, headers: [String: String], body: [String: Any]) throws -> (statusCode: Int, body: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let semaphore = DispatchSemaphore(value: 0)
        let state = RemoteMCPHTTPTransportState()
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                state.store(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                state.store(.failure(RemoteMCPHTTPClient.Error.invalidResponse))
                return
            }
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            state.store(.success((http.statusCode, object)))
        }
        task.resume()
        if semaphore.wait(timeout: Self.deadline(for: timeout)) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        return try state.load().get()
    }

    private static func deadline(for timeout: TimeInterval) -> DispatchTime {
        let milliseconds = max(1, Int((timeout * 1_000).rounded(.up)))
        return DispatchTime.now() + .milliseconds(milliseconds)
    }
}

private final class RemoteMCPHTTPTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<(Int, [String: Any]), Error> = .failure(URLError(.unknown))

    func store(_ result: Result<(Int, [String: Any]), Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<(Int, [String: Any]), Error> {
        lock.lock()
        let current = result
        lock.unlock()
        return current
    }
}

public final class RemoteMCPHTTPClient: RemoteMCPClient {
    public enum Error: LocalizedError, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case missingTools
        case missingResult

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Remote MCP response was invalid."
            case .httpStatus(let status):
                return "Remote MCP request failed with HTTP \(status)."
            case .missingTools:
                return "Remote MCP tools/list response did not include tools."
            case .missingResult:
                return "Remote MCP tools/call response did not include a result."
            }
        }
    }

    private let transport: any RemoteMCPHTTPTransport

    public init(transport: any RemoteMCPHTTPTransport = URLSessionRemoteMCPHTTPTransport()) {
        self.transport = transport
    }

    public func listTools(
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> [[String: Any]] {
        let body = try rpc(method: "tools/list", params: nil, server: server, auth: auth)
        guard let result = body["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw Error.missingTools
        }
        return tools
    }

    public func callTool(
        _ name: String,
        arguments: [String: Any],
        for server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> RemoteMCPToolResult {
        let body = try rpc(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            server: server,
            auth: auth
        )
        guard let result = body["result"] as? [String: Any] else {
            throw Error.missingResult
        }
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return RemoteMCPToolResult(text: text, isError: result["isError"] as? Bool ?? false)
    }

    private func rpc(
        method: String,
        params: [String: Any]?,
        server: RemoteMCPServerDescriptor,
        auth: MCPGatewayAuthContext
    ) throws -> [String: Any] {
        var headers = ["Accept": "application/json"]
        if let authorizationHeader = auth.authorizationHeader {
            headers["Authorization"] = authorizationHeader
        }
        var body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params {
            body["params"] = params
        }
        let response = try transport.postJSON(to: server.endpoint, headers: headers, body: body)
        guard (200..<300).contains(response.statusCode) else {
            throw Error.httpStatus(response.statusCode)
        }
        if response.body["error"] != nil {
            throw Error.invalidResponse
        }
        return response.body
    }
}
