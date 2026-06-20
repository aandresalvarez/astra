import Foundation

public protocol BrowserMCPCommandExecutor: AnyObject {
    func runBrowserCommand(arguments: [String]) async throws -> String
}

public final class BrowserMCPServer {
    private let executor: BrowserMCPCommandExecutor

    public init(executor: BrowserMCPCommandExecutor) {
        self.executor = executor
    }

    public func handleLine(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = object["method"] as? String else {
            return encodeError(id: nil, code: -32700, message: "Invalid JSON-RPC request")
        }

        let id = object["id"]
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        switch method {
        case "initialize":
            return encodeResult(id: id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "astra-browser", "version": "1.0.0"]
            ])
        case "tools/list":
            return encodeResult(id: id, result: [
                "tools": [[
                    "name": "browser",
                    "description": "Run an ASTRA browser bridge command. Use the same command names and arguments as the astra-browser CLI, for example command=analyze or command=read-page.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "Browser command to run, such as health, actions, analyze, read-page, click, fill, navigate, or google-drive-open."
                            ],
                            "arguments": [
                                "type": "array",
                                "items": ["type": "string"],
                                "description": "Optional CLI-style arguments for the command, excluding the command name."
                            ]
                        ],
                        "required": ["command"],
                        "additionalProperties": false
                    ]
                ]]
            ])
        case "tools/call":
            return await handleToolCall(id: id, object: object)
        default:
            return encodeError(id: id, code: -32601, message: "Unsupported method \(method)")
        }
    }

    private func handleToolCall(id: Any?, object: [String: Any]) async -> String? {
        guard let params = object["params"] as? [String: Any],
              params["name"] as? String == "browser" else {
            return encodeError(id: id, code: -32602, message: "Unsupported tool")
        }

        let toolArguments = params["arguments"] as? [String: Any] ?? [:]
        guard let command = toolArguments["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return encodeError(id: id, code: -32602, message: "browser requires command")
        }
        let rawArguments: [Any]
        if let value = toolArguments["arguments"] {
            guard let parsed = value as? [Any] else {
                return encodeError(id: id, code: -32602, message: "browser arguments must be an array of strings")
            }
            rawArguments = parsed
        } else {
            rawArguments = []
        }

        var arguments = [command]
        for raw in rawArguments {
            guard let value = raw as? String else {
                return encodeError(id: id, code: -32602, message: "browser arguments must be an array of strings")
            }
            arguments.append(value)
        }

        do {
            let output = try await executor.runBrowserCommand(arguments: arguments)
            return encodeToolResult(id: id, text: output, isError: false)
        } catch {
            return encodeToolResult(id: id, text: error.localizedDescription, isError: true)
        }
    }

    private func encodeToolResult(id: Any?, text: String, isError: Bool) -> String? {
        encodeResult(id: id, result: [
            "content": [[
                "type": "text",
                "text": text
            ]],
            "isError": isError
        ])
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
