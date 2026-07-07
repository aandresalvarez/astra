import Foundation

public protocol RemoteMCPHTTPTransport: AnyObject {
    func postJSON(to url: URL, headers: [String: String], body: [String: Any]) throws -> (statusCode: Int, body: [String: Any])
}

public struct RemoteMCPHTTPTimeouts: Equatable {
    public static let gatewayDefault = RemoteMCPHTTPTimeouts(request: 30)
    private static let minimumRequest: TimeInterval = 0.001

    public var request: TimeInterval

    public init(request: TimeInterval) {
        let finiteRequest = request.isFinite ? request : Self.minimumRequest
        self.request = max(Self.minimumRequest, finiteRequest)
    }
}

public final class URLSessionRemoteMCPHTTPTransport: RemoteMCPHTTPTransport {
    private let session: URLSession
    private let timeouts: RemoteMCPHTTPTimeouts

    public init(
        session: URLSession? = nil,
        timeouts: RemoteMCPHTTPTimeouts = .gatewayDefault
    ) {
        self.timeouts = timeouts
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeouts.request
            configuration.timeoutIntervalForResource = timeouts.request
            self.session = URLSession(configuration: configuration)
        }
    }

    public func postJSON(to url: URL, headers: [String: String], body: [String: Any]) throws -> (statusCode: Int, body: [String: Any]) {
        var request = URLRequest(url: url, timeoutInterval: timeouts.request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let semaphore = DispatchSemaphore(value: 0)
        let response = RemoteMCPHTTPResponseBox()
        let task = session.dataTask(with: request) { data, responseValue, error in
            defer { semaphore.signal() }
            if let error {
                if (error as? URLError)?.code == .timedOut {
                    response.store(.failure(RemoteMCPHTTPClient.Error.requestTimedOut))
                } else {
                    response.store(.failure(error))
                }
                return
            }
            guard let http = responseValue as? HTTPURLResponse else {
                response.store(.failure(RemoteMCPHTTPClient.Error.invalidResponse))
                return
            }
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            response.store(.success((http.statusCode, object)))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeouts.request) == .timedOut {
            task.cancel()
            throw RemoteMCPHTTPClient.Error.requestTimedOut
        }
        guard let result = response.load() else {
            throw RemoteMCPHTTPClient.Error.invalidResponse
        }
        return try result.get()
    }
}

private final class RemoteMCPHTTPResponseBox {
    private let lock = NSLock()
    private var result: Result<(Int, [String: Any]), Error>?

    func store(_ result: Result<(Int, [String: Any]), Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.result = result
    }

    func load() -> Result<(Int, [String: Any]), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

public final class RemoteMCPHTTPClient: RemoteMCPClient {
    public enum Error: LocalizedError, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case missingTools
        case missingResult
        case requestTimedOut

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
            case .requestTimedOut:
                return "Remote MCP request timed out."
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
