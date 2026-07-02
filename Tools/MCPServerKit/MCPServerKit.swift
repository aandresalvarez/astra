import Foundation

public struct MCPToolCall {
    public var name: String
    public var arguments: [String: Any]

    public init(name: String, arguments: [String: Any]) {
        self.name = name
        self.arguments = arguments
    }
}

public enum MCPServerReply {
    case result([String: Any])
    case error(code: Int, message: String)
}

public enum MCPServerDiagnostic: Equatable {
    case invalidRequest
    case notification(String)
    case unsupportedMethod(String)
    case toolCall(String)
}

public final class MCPServer {
    private let name: String
    private let version: String
    private let protocolVersion: String
    private let tools: () -> [[String: Any]]
    private let diagnostics: (MCPServerDiagnostic) -> Void
    private let handleToolCall: (MCPToolCall) -> MCPServerReply

    public init(
        name: String,
        version: String = "1.0.0",
        protocolVersion: String = "2025-03-26",
        tools: @escaping () -> [[String: Any]],
        diagnostics: @escaping (MCPServerDiagnostic) -> Void = { _ in },
        handleToolCall: @escaping (MCPToolCall) -> MCPServerReply
    ) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.tools = tools
        self.diagnostics = diagnostics
        self.handleToolCall = handleToolCall
    }

    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = object["method"] as? String else {
            diagnostics(.invalidRequest)
            return encodeError(id: nil, code: -32700, message: "Invalid JSON-RPC request")
        }

        let id = object["id"]
        if id == nil, method.hasPrefix("notifications/") {
            diagnostics(.notification(method))
            return nil
        }

        switch method {
        case "initialize":
            return encodeResult(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": name, "version": version]
            ])
        case "tools/list":
            return encodeResult(id: id, result: ["tools": tools()])
        case "tools/call":
            return handleToolRequest(id: id, object: object)
        default:
            diagnostics(.unsupportedMethod(method))
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    private func handleToolRequest(id: Any?, object: [String: Any]) -> String? {
        guard let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        diagnostics(.toolCall(toolName))
        switch handleToolCall(MCPToolCall(name: toolName, arguments: arguments)) {
        case .result(let result):
            return encodeResult(id: id, result: result)
        case .error(let code, let message):
            return encodeError(id: id, code: code, message: message)
        }
    }

    private func encodeResult(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": normalizedID(id), "result": result])
    }

    private func encodeError(id: Any?, code: Int, message: String) -> String? {
        encode([
            "jsonrpc": "2.0",
            "id": normalizedID(id),
            "error": ["code": code, "message": message]
        ])
    }

    private func normalizedID(_ id: Any?) -> Any {
        switch id {
        case let value as String: return value
        case let value as NSNumber: return value
        case .none: return NSNull()
        default: return NSNull()
        }
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
