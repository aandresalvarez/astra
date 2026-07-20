import Foundation

public struct MCPToolCall {
    public var name: String
    public var arguments: [String: Any]
    /// The exact JSON-RPC request id rendered as a stable string. Tool
    /// handlers use it to bind durable side effects to the invocation that
    /// requested them instead of trusting provider-authored result text.
    public var invocationID: String

    public init(name: String, arguments: [String: Any], invocationID: String = "") {
        self.name = name
        self.arguments = arguments
        self.invocationID = invocationID
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
    private let tools: () throws -> [[String: Any]]
    private let diagnostics: (MCPServerDiagnostic) -> Void
    private let handleToolCall: (MCPToolCall) -> MCPServerReply
    /// A JSON-RPC request ID only correlates one request with its response —
    /// clients may reuse it after completion, and a numeric counter resets
    /// when the helper process restarts. Durable consumers (e.g. the
    /// workspace_job_start idempotency check) need an invocation identity that
    /// is unique ACROSS helper processes, so every invocation id is scoped by
    /// this per-process nonce.
    private let sessionNonce = UUID().uuidString

    public init(
        name: String,
        version: String = "1.0.0",
        protocolVersion: String = "2025-03-26",
        tools: @escaping () throws -> [[String: Any]],
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
            do {
                return encodeResult(id: id, result: ["tools": try tools()])
            } catch {
                return encodeError(id: id, code: -32000, message: "Tool discovery failed: \(error.localizedDescription)")
            }
        case "tools/call":
            return handleToolRequest(id: id, object: object)
        default:
            diagnostics(.unsupportedMethod(method))
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    private func handleToolRequest(id: Any?, object: [String: Any]) -> String? {
        guard let invocationID = stableInvocationID(id) else {
            diagnostics(.invalidRequest)
            return encodeError(
                id: id,
                code: -32600,
                message: "tools/call requires a non-empty string or numeric request id"
            )
        }
        guard let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        diagnostics(.toolCall(toolName))
        switch handleToolCall(MCPToolCall(
            name: toolName,
            arguments: arguments,
            invocationID: "\(sessionNonce):\(invocationID)"
        )) {
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
        case let value as NSNumber:
            return isJSONBoolean(value) ? NSNull() : value
        case .none: return NSNull()
        default: return NSNull()
        }
    }

    /// Raw request-id length is capped at 200 (not 256) so the composed
    /// "\(sessionNonce):\(id)" invocation identity stays within downstream
    /// consumers' 256-character validation limit.
    private func stableInvocationID(_ id: Any?) -> String? {
        switch id {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed.count <= 200 ? value : nil
        case let value as NSNumber:
            guard !isJSONBoolean(value) else { return nil }
            let rendered = value.stringValue
            return rendered.count <= 200 ? rendered : nil
        default:
            return nil
        }
    }

    /// JSONSerialization bridges both numbers and booleans through NSNumber.
    /// Core Foundation type identity keeps numeric 0/1 valid JSON-RPC IDs
    /// without accidentally admitting JSON true/false as request IDs.
    private func isJSONBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
