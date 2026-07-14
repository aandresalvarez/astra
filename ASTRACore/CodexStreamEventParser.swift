import Foundation

public enum CodexStreamEventParser {
    public static func parse(line: String) -> ParsedEvent? {
        parseAll(line: line).first
    }

    public static func parseAll(line: String) -> [ParsedEvent] {
        parseAgentEvents(line: line).compactMap { parsedEvent(from: $0) }
    }

    public static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        CopilotStreamEventParser.parsePlainText(line: line, appendingNewline: appendingNewline)
    }

    public static func parseAgentEvents(line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return parsePlainTextAgentEvents(line: trimmed)
        }

        let codexEvents = events(from: object, raw: trimmed)
        if !codexEvents.isEmpty {
            return codexEvents
        }

        return CopilotStreamEventParser.parseAgentEvents(line: line).map(relabelUnknownAgentEvent)
    }

    public static func parsePlainTextAgentEvents(line: String, appendingNewline: Bool = false) -> [AgentEvent] {
        CopilotStreamEventParser.parsePlainTextAgentEvents(
            line: line,
            appendingNewline: appendingNewline
        ).map(relabelUnknownAgentEvent)
    }

    private static func relabelUnknownAgentEvent(_ event: AgentEvent) -> AgentEvent {
        guard case .unknown(_, let type, let raw) = event else { return event }
        return .unknown(provider: "codex", type: type, raw: raw)
    }

    private static func events(from object: [String: Any], raw: String) -> [AgentEvent] {
        let type = string(in: object, keys: ["type", "event", "kind"]) ?? "unknown"
        let normalized = type.lowercased()

        switch normalized {
        case "thread.started":
            return [.started(sessionID: string(in: object, keys: ["thread_id", "threadId", "id"]), model: nil)]
        case "turn.started":
            return [.control(type: "turn.started")]
        case "turn.completed":
            return usageEvent(from: object).map { [$0] } ?? []
        case "turn.failed", "error", "failed":
            return [.failed(message: textValue(in: object) ?? raw)]
        case "item.started":
            return startedItemEvents(from: object, raw: raw)
        case "item.completed":
            return completedItemEvents(from: object, raw: raw)
        case "assistant.message_delta", "assistant.message", "assistant.reasoning_delta", "assistant.reasoning":
            return CopilotStreamEventParser.parseAgentEvents(line: raw).map(relabelUnknownAgentEvent)
        default:
            return []
        }
    }

    private static func startedItemEvents(from object: [String: Any], raw: String) -> [AgentEvent] {
        guard let item = object["item"] as? [String: Any] else {
            return [.unknown(provider: "codex", type: "item.started", raw: raw)]
        }
        let itemType = string(in: item, keys: ["type", "kind"])?.lowercased() ?? "unknown"
        if itemType == "command_execution" {
            return [commandToolUseEvent(from: item)]
        }
        if itemType == "file_change" {
            return [fileChangeEvent(from: item) ?? .control(type: "item.started.file_change")]
        }
        if itemType == "agent_message" || itemType == "message" || itemType == "assistant_message" {
            return [.control(type: "item.started.\(itemType)")]
        }
        if itemType.contains("reasoning") {
            return [.control(type: "item.started.\(itemType)")]
        }
        if itemType.contains("tool") || item["tool"] != nil || item["name"] != nil {
            let name = string(in: item, keys: ["name", "tool", "tool_name", "toolName"]) ?? "tool"
            let id = string(in: item, keys: ["id", "call_id", "callId"]) ?? ""
            return [.toolUse(name: name, id: id, inputSummary: inputSummary(in: item))]
        }
        return [.unknown(provider: "codex", type: "item.started.\(itemType)", raw: raw)]
    }

    private static func completedItemEvents(from object: [String: Any], raw: String) -> [AgentEvent] {
        guard let item = object["item"] as? [String: Any] else {
            return [.unknown(provider: "codex", type: "item.completed", raw: raw)]
        }
        let itemType = string(in: item, keys: ["type", "kind"])?.lowercased() ?? "unknown"
        if itemType == "command_execution" {
            return [.toolResult(id: string(in: item, keys: ["id", "call_id", "callId"]) ?? "", content: commandResultSummary(in: item))]
        }
        if itemType == "file_change" {
            return [fileChangeEvent(from: item) ?? .control(type: "item.completed.file_change")]
        }
        if itemType == "agent_message" || itemType == "message" || itemType == "assistant_message" {
            return [.completed(summary: textValue(in: item))]
        }
        if itemType.contains("reasoning") {
            guard let text = textValue(in: item), !text.isEmpty else { return [] }
            return [.thinking(text: text)]
        }
        if itemType.contains("tool") || item["tool"] != nil || item["name"] != nil {
            let name = string(in: item, keys: ["name", "tool", "tool_name", "toolName"]) ?? "tool"
            let id = string(in: item, keys: ["id", "call_id", "callId"]) ?? ""
            return [.toolUse(name: name, id: id, inputSummary: inputSummary(in: item))]
        }
        if itemType.contains("error") || itemType == "failed" {
            return [.failed(message: textValue(in: item) ?? raw)]
        }
        return [.unknown(provider: "codex", type: "item.completed.\(itemType)", raw: raw)]
    }

    private static func commandToolUseEvent(from item: [String: Any]) -> AgentEvent {
        let id = string(in: item, keys: ["id", "call_id", "callId"]) ?? ""
        return .toolUse(name: "command_execution", id: id, inputSummary: inputSummary(in: item))
    }

    private static func commandResultSummary(in item: [String: Any]) -> String {
        var pieces: [String] = []
        for key in ["aggregated_output", "output", "stdout", "stderr", "text", "message"] {
            if let value = string(in: item, keys: [key]) {
                pieces.append(value)
            }
        }
        if let exitCode = int(in: item, keys: ["exit_code", "exitCode"]) {
            pieces.append("exit_code=\(exitCode)")
        }
        if let status = string(in: item, keys: ["status"]) {
            pieces.append("status=\(status)")
        }
        let summary = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return summary.isEmpty ? "command_execution completed" : summary
    }

    private static func fileChangeEvent(from item: [String: Any]) -> AgentEvent? {
        guard let path = string(in: item, keys: ["path", "file_path", "filePath", "filename", "name"]) else {
            return nil
        }
        let kind = string(in: item, keys: ["kind", "change_type", "changeType", "status"]) ?? "modified"
        return .fileChange(path: path, kind: kind, summary: textValue(in: item))
    }

    private static func usageEvent(from object: [String: Any]) -> AgentEvent? {
        let usage = object["usage"] as? [String: Any] ?? object
        let input = (int(in: usage, keys: ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"]) ?? 0)
            + (int(in: usage, keys: ["cached_input_tokens", "cachedInputTokens"]) ?? 0)
            + (int(in: usage, keys: ["cache_read_input_tokens", "cacheReadInputTokens", "cacheReadTokens"]) ?? 0)
            + (int(in: usage, keys: ["cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteTokens"]) ?? 0)
        let output = int(in: usage, keys: ["output_tokens", "outputTokens", "completion_tokens", "completionTokens"]) ?? 0
        guard input > 0 || output > 0 else { return nil }
        return .stats(inputTokens: input, outputTokens: output, costUSD: nil, durationMs: nil, turns: nil)
    }

    private static func parsedEvent(from event: AgentEvent) -> ParsedEvent? {
        switch event {
        case .control:
            return nil
        case .started(let sessionID, let model):
            return .systemInit(model: model, sessionId: sessionID)
        case .thinking(let text):
            return .thinking(text: text)
        case .text(let text):
            return .text(text: text)
        case .toolUse(let name, let id, let inputSummary):
            let input: [String: Any]? = inputSummary.map { ["summary": $0] }
            return .toolUse(name: name, id: id, input: input)
        case .toolResult(let id, let content, let isError):
            return .toolResult(toolId: id, content: content, isError: isError)
        case .permissionRequested(let tool, let reason):
            return .permissionDenied(tool: tool, reason: reason)
        case .stats(let input, let output, let cost, let duration, let turns):
            if cost == nil, duration == nil, turns == nil {
                return .usage(totalInputTokens: input, totalOutputTokens: output)
            }
            return .result(
                text: nil,
                costUSD: cost,
                totalInputTokens: input,
                totalOutputTokens: output,
                durationMs: duration,
                numTurns: turns,
                isError: false
            )
        case .astraProtocol(let event):
            return .astraProtocol(event)
        case .completed(let summary):
            return .result(
                text: summary,
                costUSD: nil,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                durationMs: nil,
                numTurns: nil,
                isError: false
            )
        case .failed(let message):
            return .result(
                text: message,
                costUSD: nil,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                durationMs: nil,
                numTurns: nil,
                isError: true
            )
        case .fileChange:
            return nil
        case .teamEvent:
            return nil
        case .unknown:
            return nil
        }
    }

    private static func textValue(in object: [String: Any]) -> String? {
        if let text = string(in: object, keys: ["text", "delta", "message", "content", "output", "error", "summary", "aggregated_output"]),
           !text.isEmpty {
            return text
        }
        for key in ["item", "data", "message", "delta", "content"] {
            if let nested = object[key] as? [String: Any],
               let text = textValue(in: nested) {
                return text
            }
        }
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap(textValue).joined()
            if !text.isEmpty {
                return text
            }
        }
        if let summary = object["summary"] as? [[String: Any]] {
            let text = summary.compactMap(textValue).joined()
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func inputSummary(in object: [String: Any]) -> String? {
        for key in ["command", "cmd", "input", "arguments", "args"] {
            guard let value = object[key] else { continue }
            if let text = value as? String {
                return text
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func int(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
            if let value = object[key] as? String, let int = Int(value) {
                return int
            }
        }
        return nil
    }
}
