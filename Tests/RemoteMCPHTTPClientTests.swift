import Foundation
import Testing
@testable import MCPGatewaySupport

@Suite("Remote MCP HTTP Client")
struct RemoteMCPHTTPClientTests {
    @Test("lists tools using JSON RPC and bearer auth")
    func listsTools() throws {
        let transport = RecordingRemoteMCPHTTPTransport(response: .success([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "tools": [[
                    "name": "search_threads",
                    "description": "Search Gmail threads"
                ]]
            ]
        ]))
        let client = RemoteMCPHTTPClient(transport: transport)
        let server = descriptor()

        let tools = try client.listTools(for: server, auth: .init(authorizationHeader: "Bearer access-secret"))

        #expect(tools.first?["name"] as? String == "search_threads")
        #expect(transport.requests.first?.url == server.endpoint)
        #expect(transport.requests.first?.headers["Authorization"] == "Bearer access-secret")
        #expect(transport.requests.first?.body["method"] as? String == "tools/list")
        #expect(!String(describing: tools).contains("access-secret"))
    }

    @Test("calls tools using JSON RPC arguments")
    func callsTools() throws {
        let transport = RecordingRemoteMCPHTTPTransport(response: .success([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "content": [["type": "text", "text": "done"]],
                "isError": false
            ]
        ]))
        let client = RemoteMCPHTTPClient(transport: transport)

        let result = try client.callTool(
            "search_threads",
            arguments: ["query": "budget"],
            for: descriptor(),
            auth: .init()
        )

        #expect(result.text == "done")
        #expect(result.isError == false)
        let params = try #require(transport.requests.first?.body["params"] as? [String: Any])
        #expect(params["name"] as? String == "search_threads")
        #expect((params["arguments"] as? [String: Any])?["query"] as? String == "budget")
    }

    @Test("remote errors are stable and redact auth material")
    func errorsAreRedacted() {
        let transport = RecordingRemoteMCPHTTPTransport(response: .failure(statusCode: 401, body: [
            "error": ["code": -32000, "message": "invalid token access-secret"]
        ]))
        let client = RemoteMCPHTTPClient(transport: transport)

        do {
            _ = try client.listTools(for: descriptor(), auth: .init(authorizationHeader: "Bearer access-secret"))
            Issue.record("Expected remote MCP failure")
        } catch {
            #expect(error.localizedDescription.contains("401"))
            #expect(!error.localizedDescription.contains("access-secret"))
        }
    }

    @Test("URLSession transport fails closed when upstream never completes")
    func urlSessionTransportTimesOut() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionRemoteMCPHTTPTransport(session: session, timeout: 0.01)

        do {
            _ = try transport.postJSON(
                to: URL(string: "https://mcp.example.test/hang")!,
                headers: [:],
                body: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
            )
            Issue.record("Expected remote MCP transport timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Expected URLError.timedOut, got \(error)")
        }
    }
}

private func descriptor() -> RemoteMCPServerDescriptor {
    RemoteMCPServerDescriptor(
        id: "google_workspace_gmail",
        displayName: "Gmail",
        transport: .http,
        endpoint: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!,
        connectorBindings: ["google-workspace"]
    )
}

private final class RecordingRemoteMCPHTTPTransport: RemoteMCPHTTPTransport {
    enum Response {
        case success([String: Any])
        case failure(statusCode: Int, body: [String: Any])
    }

    struct Request {
        var url: URL
        var headers: [String: String]
        var body: [String: Any]
    }

    var response: Response
    private(set) var requests: [Request] = []

    init(response: Response) {
        self.response = response
    }

    func postJSON(to url: URL, headers: [String: String], body: [String: Any]) throws -> (statusCode: Int, body: [String: Any]) {
        requests.append(Request(url: url, headers: headers, body: body))
        switch response {
        case .success(let body):
            return (200, body)
        case .failure(let statusCode, let body):
            return (statusCode, body)
        }
    }
}

private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}
