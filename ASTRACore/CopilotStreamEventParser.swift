import Foundation

public enum CopilotStreamEventParser {
    public static func parse(line: String) -> ParsedEvent? {
        parseAll(line: line).first
    }

    public static func parseAll(line: String) -> [ParsedEvent] {
        let events = parseAgentEvents(line: line)
        let stats = events.compactMap { event -> (Int, Int, Double?, Int?, Int?)? in
            if case .stats(let input, let output, let cost, let duration, let turns) = event {
                return (input, output, cost, duration, turns)
            }
            return nil
        }.first
        var hasCompletion = false
        var completionSummary: String?
        for event in events {
            if case .completed(let summary) = event {
                hasCompletion = true
                completionSummary = summary
                break
            }
        }

        var parsed: [ParsedEvent] = []
        var emittedMergedResult = false
        for event in events {
            switch event {
            case .stats where hasCompletion:
                if let stats, !emittedMergedResult {
                    parsed.append(.result(
                        text: completionSummary,
                        costUSD: stats.2,
                        totalInputTokens: stats.0,
                        totalOutputTokens: stats.1,
                        durationMs: stats.3,
                        numTurns: stats.4,
                        isError: false
                    ))
                    emittedMergedResult = true
                }
            case .completed where stats != nil:
                continue
            default:
                if let parsedEvent = parsedEvent(from: event) {
                    parsed.append(parsedEvent)
                }
            }
        }
        return parsed
    }

    public static func parseAgentEvents(line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [.text(text: trimmed)]
        }

        return events(from: object, raw: trimmed)
    }

    private static func events(from object: [String: Any], raw: String) -> [AgentEvent] {
        let type = firstString(in: object, keys: ["type", "event", "kind", "sessionUpdate", "name"]) ?? "unknown"
        let normalized = type.lowercased()

        if normalized.hasPrefix("session.") {
            return sessionEvent(from: object, type: type, raw: raw)
        }

        if normalized == "user.message" || normalized == "assistant.turn_start" || normalized == "assistant.turn_end" {
            return []
        }

        if normalized == "assistant.message_start" {
            return []
        }

        if normalized == "assistant.reasoning" || normalized == "assistant.reasoning_delta" {
            if let text = textValue(in: object), !text.isEmpty {
                return [.thinking(text: text)]
            }
            return []
        }

        if normalized == "assistant.message_delta" {
            if let text = textValue(in: object), !text.isEmpty {
                return [.text(text: text)]
            }
            return [.unknown(provider: "copilot", type: type, raw: raw)]
        }

        if normalized == "assistant.message" {
            if let text = textValue(in: object), !text.isEmpty {
                return [.completed(summary: text)]
            }
            return [.completed(summary: nil)]
        }

        if normalized == "agent_message_chunk",
           let text = nestedString(object, path: ["content", "text"]) {
            return [.text(text: text)]
        }

        if normalized == "agent_thought_chunk" || normalized == "thinking" || normalized.contains("reasoning") {
            if let text = textValue(in: object) {
                return [.thinking(text: text)]
            }
        }

        if normalized.contains("permission") || normalized.contains("approval") {
            let tool = firstString(in: object, keys: ["tool", "toolName", "name", "command"]) ?? "unknown"
            let reason = textValue(in: object) ?? raw
            return [.permissionRequested(tool: tool, reason: reason)]
        }

        if normalized.contains("error") || normalized == "failed" {
            return [.failed(message: textValue(in: object) ?? raw)]
        }

        if isToolUse(normalized, object: object) {
            let name = firstString(in: object, keys: ["tool", "toolName", "name", "command"])
                ?? nestedString(object, path: ["tool", "name"])
                ?? "tool"
            let id = firstString(in: object, keys: ["id", "toolUseId", "tool_call_id", "callId"]) ?? ""
            return [.toolUse(name: name, id: id, inputSummary: inputSummary(in: object))]
        }

        if isToolResult(normalized, object: object) {
            let id = firstString(in: object, keys: ["id", "toolUseId", "tool_call_id", "callId"]) ?? ""
            return [.toolResult(id: id, content: textValue(in: object) ?? raw)]
        }

        if normalized.contains("usage") || normalized.contains("stats") || normalized == "result" {
            let input = intValue(in: object, keys: ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"])
                ?? nestedInt(object, path: ["usage", "input_tokens"])
                ?? nestedInt(object, path: ["usage", "inputTokens"])
                ?? nestedInt(object, path: ["usage", "prompt_tokens"])
                ?? 0
            let output = intValue(in: object, keys: ["output_tokens", "outputTokens", "completion_tokens", "completionTokens"])
                ?? nestedInt(object, path: ["usage", "output_tokens"])
                ?? nestedInt(object, path: ["usage", "outputTokens"])
                ?? nestedInt(object, path: ["usage", "completion_tokens"])
                ?? 0
            let cost = doubleValue(in: object, keys: ["costUSD", "cost_usd", "total_cost_usd"])
                ?? nestedDouble(object, path: ["usage", "costUSD"])
                ?? nestedDouble(object, path: ["usage", "cost_usd"])
            let duration = intValue(in: object, keys: ["duration_ms", "durationMs"])
            let turns = intValue(in: object, keys: ["turns", "num_turns", "numTurns"])

            var events: [AgentEvent] = []
            if input > 0 || output > 0 || cost != nil || duration != nil || turns != nil {
                events.append(.stats(inputTokens: input, outputTokens: output, costUSD: cost, durationMs: duration, turns: turns))
            }
            if let text = textValue(in: object), !text.isEmpty {
                events.append(.completed(summary: text))
            } else if normalized == "result" || normalized.contains("completed") {
                events.append(.completed(summary: nil))
            }
            return events.isEmpty ? [.unknown(provider: "copilot", type: type, raw: raw)] : events
        }

        if let text = textValue(in: object), !text.isEmpty {
            return [.text(text: text)]
        }

        return [.unknown(provider: "copilot", type: type, raw: raw)]
    }

    private static func parsedEvent(from event: AgentEvent) -> ParsedEvent? {
        switch event {
        case .started(let sessionID, let model):
            return .systemInit(model: model, sessionId: sessionID)
        case .thinking(let text):
            return .thinking(text: text)
        case .text(let text):
            return .text(text: text)
        case .toolUse(let name, let id, _):
            return .toolUse(name: name, id: id, input: nil)
        case .toolResult(let id, let content):
            return .toolResult(toolId: id, content: content)
        case .permissionRequested(let tool, let reason):
            return .permissionDenied(tool: tool, reason: reason)
        case .stats(let input, let output, let cost, let duration, let turns):
            return .result(text: nil, costUSD: cost, totalInputTokens: input, totalOutputTokens: output, durationMs: duration, numTurns: turns, isError: false)
        case .astraProtocol(let event):
            return .astraProtocol(event)
        case .completed(let summary):
            return .result(text: summary, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: false)
        case .failed(let message):
            return .result(text: message, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: true)
        case .fileChange, .unknown:
            return nil
        }
    }

    private static func isToolUse(_ type: String, object: [String: Any]) -> Bool {
        if type.contains("tool") && (type.contains("use") || type.contains("call") || type.contains("start")) {
            return true
        }
        if object["tool"] != nil || object["toolName"] != nil || object["tool_call_id"] != nil {
            return !isToolResult(type, object: object)
        }
        return false
    }

    private static func isToolResult(_ type: String, object: [String: Any]) -> Bool {
        type.contains("tool") && (type.contains("result") || type.contains("output") || type.contains("complete"))
            || object["toolResult"] != nil
    }

    private static func inputSummary(in object: [String: Any]) -> String? {
        if let command = firstString(in: object, keys: ["command", "cmd"]) {
            return command
        }
        if let input = object["input"] ?? object["arguments"] ?? object["args"] {
            return stableJSONString(input)
        }
        return nil
    }

    private static func textValue(in object: [String: Any]) -> String? {
        if let text = firstString(in: object, keys: ["text", "message", "content", "delta", "chunk", "output", "result", "summary"]) {
            return text
        }
        if let text = nestedString(object, path: ["content", "text"]) {
            return text
        }
        if let text = nestedString(object, path: ["message", "content"]) {
            return text
        }
        if let text = nestedString(object, path: ["delta", "text"]) {
            return text
        }
        if let text = nestedString(object, path: ["delta", "content"]) {
            return text
        }
        if let text = nestedContentText(object["content"]) {
            return text
        }
        if let message = object["message"] as? [String: Any],
           let text = nestedContentText(message["content"]) {
            return text
        }
        if let delta = object["delta"] as? [String: Any],
           let text = nestedContentText(delta["content"]) ?? nestedContentText(delta["message"]) {
            return text
        }
        return nil
    }

    private static func sessionEvent(from object: [String: Any], type: String, raw: String) -> [AgentEvent] {
        let sessionID = firstString(in: object, keys: ["session_id", "sessionId", "id"])
            ?? nestedString(object, path: ["session", "id"])
            ?? nestedString(object, path: ["session", "sessionId"])
        let model = firstString(in: object, keys: ["model"])
            ?? nestedString(object, path: ["session", "model"])
        if sessionID != nil || model != nil {
            return [.started(sessionID: sessionID, model: model)]
        }
        return []
    }

    private static func nestedContentText(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }
        if let dictionary = value as? [String: Any] {
            if let text = firstString(in: dictionary, keys: ["text", "content", "delta", "message", "summary"]) {
                return text
            }
            if let text = nestedContentText(dictionary["content"]) {
                return text
            }
            if let text = nestedContentText(dictionary["delta"]) {
                return text
            }
            if let text = nestedContentText(dictionary["message"]) {
                return text
            }
            return nil
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { item -> String? in
                guard let dictionary = item as? [String: Any] else {
                    return item as? String
                }
                let blockType = firstString(in: dictionary, keys: ["type"])?.lowercased()
                if blockType == nil || blockType == "text" || blockType == "text_delta" || blockType == "output_text" {
                    return nestedContentText(dictionary)
                }
                return nil
            }
            let text = parts.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func intValue(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String, let int = Int(value) { return int }
        }
        return nil
    }

    private static func doubleValue(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
            if let value = object[key] as? String, let double = Double(value) { return double }
        }
        return nil
    }

    private static func nestedString(_ object: [String: Any], path: [String]) -> String? {
        nestedValue(object, path: path) as? String
    }

    private static func nestedInt(_ object: [String: Any], path: [String]) -> Int? {
        let value = nestedValue(object, path: path)
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func nestedDouble(_ object: [String: Any], path: [String]) -> Double? {
        let value = nestedValue(object, path: path)
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func nestedValue(_ object: [String: Any], path: [String]) -> Any? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func stableJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
