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
            case .control:
                continue
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

    public static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        parsePlainTextAgentEvents(line: line, appendingNewline: appendingNewline)
            .compactMap(parsedEvent(from:))
    }

    public static func parsePlainTextAgentEvents(line: String, appendingNewline: Bool = false) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let prompt = plainTextPermissionPrompt(line: trimmed) {
            return [.permissionRequested(tool: prompt.tool, reason: prompt.reason)]
        }
        return [.text(text: appendingNewline ? line + "\n" : trimmed)]
    }

    public static func isBlockingPlainTextPermissionPrompt(line: String) -> Bool {
        plainTextPermissionPrompt(line: line.trimmingCharacters(in: .whitespacesAndNewlines))?.isBlocking == true
    }

    public static func parseAgentEvents(line: String) -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return parsePlainTextAgentEvents(line: trimmed)
        }

        return events(from: object, raw: trimmed)
    }

    private static func events(from object: [String: Any], raw: String) -> [AgentEvent] {
        let type = firstStringIncludingPayload(in: object, keys: ["type", "event", "kind", "sessionUpdate", "name"]) ?? "unknown"
        let normalized = type.lowercased()

        if ["event", "message", "data", "payload"].contains(normalized),
           let payload = payloadObject(in: object),
           firstString(in: payload, keys: ["type", "event", "kind", "sessionUpdate", "name"]) != nil {
            return events(from: payload, raw: raw)
        }

        if normalized == "session.shutdown",
           let events = sessionShutdownEvents(from: object) {
            return events
        }

        if normalized.hasPrefix("session.") {
            return sessionEvent(from: object, type: type, raw: raw)
        }

        if normalized == "user.message" || normalized == "assistant.turn_start" || normalized == "assistant.turn_end" {
            return []
        }

        if normalized == "assistant.message_start" || normalized == "abort" {
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
           let text = textValue(in: object) {
            return [.text(text: text)]
        }

        if normalized == "agent_thought_chunk" || normalized == "thinking" || normalized.contains("reasoning") {
            if let text = textValue(in: object) {
                return [.thinking(text: text)]
            }
        }

        if normalized.contains("permission") || normalized.contains("approval") {
            let tool = toolName(in: object)
            let reason = textValue(in: object) ?? raw
            return [.permissionRequested(tool: tool, reason: reason)]
        }

        if normalized.contains("error") || normalized == "failed" {
            return [.failed(message: textValue(in: object) ?? raw)]
        }

        if isToolUse(normalized, object: object) {
            let name = toolName(in: object)
            let id = toolID(in: object)
            return [.toolUse(name: name, id: id, inputSummary: inputSummary(in: object, toolName: name))]
        }

        if isToolResult(normalized, object: object) {
            let id = toolID(in: object)
            return [.toolResult(id: id, content: textValue(in: object) ?? raw)]
        }

        if normalized.contains("usage") || normalized.contains("stats") || normalized == "result" {
            let input = intValueIncludingPayload(in: object, keys: ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"])
                ?? nestedIntIncludingPayload(object, path: ["usage", "input_tokens"])
                ?? nestedIntIncludingPayload(object, path: ["usage", "inputTokens"])
                ?? nestedIntIncludingPayload(object, path: ["usage", "prompt_tokens"])
                ?? 0
            let output = intValueIncludingPayload(in: object, keys: ["output_tokens", "outputTokens", "completion_tokens", "completionTokens"])
                ?? nestedIntIncludingPayload(object, path: ["usage", "output_tokens"])
                ?? nestedIntIncludingPayload(object, path: ["usage", "outputTokens"])
                ?? nestedIntIncludingPayload(object, path: ["usage", "completion_tokens"])
                ?? 0
            let cost = doubleValueIncludingPayload(in: object, keys: ["costUSD", "cost_usd", "total_cost_usd"])
                ?? nestedDoubleIncludingPayload(object, path: ["usage", "costUSD"])
                ?? nestedDoubleIncludingPayload(object, path: ["usage", "cost_usd"])
            let duration = intValueIncludingPayload(in: object, keys: ["duration_ms", "durationMs"])
            let turns = intValueIncludingPayload(in: object, keys: ["turns", "num_turns", "numTurns"])

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
        case .fileChange(let path, let kind, let summary, let oldString, let newString):
            let toolName = kind.lowercased().contains("write") ? "Write" : "Edit"
            var input: [String: Any] = ["file_path": path]
            if let summary, !summary.isEmpty {
                input["summary"] = summary
            }
            if let oldString {
                input["old_string"] = oldString
            }
            if let newString {
                input["new_string"] = newString
            }
            return .toolUse(name: toolName, id: "", input: input)
        case .teamEvent:
            return nil
        case .unknown:
            return nil
        }
    }

    private static func isToolUse(_ type: String, object: [String: Any]) -> Bool {
        if type.contains("tool") && (type.contains("use") || type.contains("call") || type.contains("start")) {
            return true
        }
        if hasAnyKey(in: object, keys: ["tool", "toolName", "tool_call_id", "toolUseId", "callId"]) {
            return !isToolResult(type, object: object)
        }
        return false
    }

    private static func isToolResult(_ type: String, object: [String: Any]) -> Bool {
        type.contains("tool") && (type.contains("result") || type.contains("output") || type.contains("complete"))
            || hasAnyKey(in: object, keys: ["toolResult"])
    }

    private static func inputSummary(in object: [String: Any], toolName: String?) -> String? {
        if shouldPreferActionSummary(for: toolName) {
            if let command = firstStringIncludingPayload(in: object, keys: ["command", "cmd"]) {
                return command
            }
            if let command = argumentStringIncludingPayload(in: object, keys: ["command", "cmd"]) {
                return command
            }
            if let path = argumentStringIncludingPayload(in: object, keys: ["file_path", "path", "target_path"]) {
                return path
            }
            if let url = argumentStringIncludingPayload(in: object, keys: ["url", "uri"]) {
                return url
            }
        }
        if let input = object["input"] ?? object["arguments"] ?? object["args"] {
            return stableInputSummary(input)
        }
        if let payload = payloadObject(in: object),
           let input = payload["input"] ?? payload["arguments"] ?? payload["args"] {
            return stableInputSummary(input)
        }
        return nil
    }

    private static func shouldPreferActionSummary(for toolName: String?) -> Bool {
        let normalized = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return [
            "bash", "shell",
            "read", "view", "grep", "glob",
            "write", "create", "edit", "multiedit", "multi_edit", "apply_patch",
            "webfetch", "websearch"
        ].contains(normalized)
    }

    private static func textValue(in object: [String: Any]) -> String? {
        if let text = firstStringIncludingPayload(in: object, keys: ["text", "message", "content", "delta", "deltaContent", "delta_content", "chunk", "output", "result", "summary"]) {
            return text
        }
        if let text = nestedStringIncludingPayload(object, path: ["result", "content"])
            ?? nestedStringIncludingPayload(object, path: ["result", "detailedContent"])
            ?? nestedStringIncludingPayload(object, path: ["error", "message"]) {
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
        if let text = nestedStringIncludingPayload(object, path: ["content", "text"])
            ?? nestedStringIncludingPayload(object, path: ["message", "content"])
            ?? nestedStringIncludingPayload(object, path: ["message", "text"])
            ?? nestedStringIncludingPayload(object, path: ["delta", "text"])
            ?? nestedStringIncludingPayload(object, path: ["delta", "content"]) {
            return text
        }
        if let text = nestedContentText(object["content"]) {
            return text
        }
        if let message = object["message"] as? [String: Any],
           let text = nestedContentText(message["content"]) {
            return text
        }
        if let payload = payloadObject(in: object),
           let text = nestedContentText(payload) {
            return text
        }
        if let delta = object["delta"] as? [String: Any],
           let text = nestedContentText(delta["content"]) ?? nestedContentText(delta["message"]) {
            return text
        }
        return nil
    }

    private static func sessionEvent(from object: [String: Any], type: String, raw: String) -> [AgentEvent] {
        let sessionID = firstStringIncludingPayload(in: object, keys: ["session_id", "sessionId"])
            ?? payloadObject(in: object).flatMap { firstString(in: $0, keys: ["id"]) }
            ?? nestedStringIncludingPayload(object, path: ["session", "id"])
            ?? nestedStringIncludingPayload(object, path: ["session", "sessionId"])
        let model = firstStringIncludingPayload(in: object, keys: ["model"])
            ?? nestedStringIncludingPayload(object, path: ["session", "model"])
        if sessionID != nil || model != nil {
            return [.started(sessionID: sessionID, model: model)]
        }
        return []
    }

    private static func sessionShutdownEvents(from object: [String: Any]) -> [AgentEvent]? {
        guard let payload = payloadObject(in: object),
              let modelMetrics = payload["modelMetrics"] as? [String: Any] else {
            return nil
        }

        var input = 0
        var output = 0
        var turns = 0
        var cost: Double?
        for value in modelMetrics.values {
            guard let entry = value as? [String: Any] else { continue }
            let usage = entry["usage"] as? [String: Any]
            input += tokenCount(
                in: usage,
                fallback: entry,
                keys: ["inputTokens", "input_tokens", "promptTokens", "prompt_tokens"]
            )
            input += tokenCount(
                in: usage,
                fallback: entry,
                keys: ["cacheReadTokens", "cacheReadInputTokens", "cache_read_input_tokens"]
            )
            input += tokenCount(
                in: usage,
                fallback: entry,
                keys: ["cacheWriteTokens", "cacheCreationInputTokens", "cache_creation_input_tokens"]
            )
            output += tokenCount(
                in: usage,
                fallback: entry,
                keys: ["outputTokens", "output_tokens", "completionTokens", "completion_tokens"]
            )
            if cost == nil {
                cost = usage.flatMap { doubleValue(in: $0, keys: ["costUSD", "cost_usd", "total_cost_usd"]) }
                    ?? doubleValue(in: entry, keys: ["costUSD", "cost_usd", "total_cost_usd"])
            }
            if let requests = entry["requests"] as? [String: Any] {
                turns += intValue(in: requests, keys: ["count"]) ?? 0
            }
        }

        let duration = intValue(in: payload, keys: ["totalApiDurationMs", "durationMs", "duration_ms"])
        guard input > 0 || output > 0 || cost != nil || duration != nil || turns > 0 else {
            return nil
        }
        return [.stats(
            inputTokens: input,
            outputTokens: output,
            costUSD: cost,
            durationMs: duration,
            turns: turns > 0 ? turns : nil
        )]
    }

    private static func tokenCount(in primary: [String: Any]?, fallback: [String: Any], keys: [String]) -> Int {
        primary.flatMap { intValue(in: $0, keys: keys) } ?? intValue(in: fallback, keys: keys) ?? 0
    }

    private static func nestedContentText(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }
        if let dictionary = value as? [String: Any] {
            if let text = firstString(in: dictionary, keys: ["text", "content", "delta", "deltaContent", "delta_content", "message", "summary", "chunk", "output", "result"]) {
                return text
            }
            if let text = nestedContentText(dictionary["data"]) {
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

    private static func toolName(in object: [String: Any]) -> String {
        firstStringIncludingPayload(in: object, keys: ["tool", "toolName", "name"])
            ?? nestedString(object, path: ["tool", "name"])
            ?? nestedString(object, path: ["data", "tool", "name"])
            ?? nestedStringIncludingPayload(object, path: ["tool", "name"])
            ?? textValue(in: object).flatMap(inferredToolName)
            ?? firstStringIncludingPayload(in: object, keys: ["toolUseId", "tool_call_id", "callId", "id"])
            ?? firstStringIncludingPayload(in: object, keys: ["command", "cmd"])
            ?? "unknown"
    }

    private static func inferredToolName(from text: String) -> String? {
        let patterns = [
            #"(?i)permission denied:\s*tool\s+([A-Za-z0-9_()./\-]+)"#,
            #"(?i)tool\s+([A-Za-z0-9_()./\-]+)\s+is\s+not\s+allowed"#,
            #"(?i)user denied\s+(?:the\s+)?([A-Za-z0-9_()./\-]+)\s+tool"#,
            #"(?i)approval (?:needed|required).*?\bfor\s+([A-Za-z0-9_()./\-]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func plainTextPermissionPrompt(line: String) -> (tool: String, reason: String, isBlocking: Bool)? {
        let lower = line.lowercased()
        if lower.contains("permission denied and could not request permission from user") {
            return (
                tool: inferredToolName(from: line) ?? "ToolApproval",
                reason: line,
                isBlocking: true
            )
        }
        if lower.contains("allow access to these paths") && lower.contains("(y/n)") {
            return (
                tool: "WorkspaceAccess",
                reason: line,
                isBlocking: true
            )
        }
        if lower.contains("outside the allowed directories") {
            return (
                tool: "WorkspaceAccess",
                reason: line,
                isBlocking: false
            )
        }
        if lower.contains("permission denied") {
            return (
                tool: inferredToolName(from: line) ?? "ToolApproval",
                reason: line,
                isBlocking: false
            )
        }
        return nil
    }

    private static func toolID(in object: [String: Any]) -> String {
        firstString(in: object, keys: ["toolUseId", "tool_call_id", "toolCallId", "callId"])
            ?? payloadObject(in: object).flatMap { firstString(in: $0, keys: ["toolUseId", "tool_call_id", "toolCallId", "callId", "id"]) }
            ?? firstString(in: object, keys: ["id"])
            ?? ""
    }

    private static func firstStringIncludingPayload(in object: [String: Any], keys: [String]) -> String? {
        firstString(in: object, keys: keys)
            ?? payloadObject(in: object).flatMap { firstString(in: $0, keys: keys) }
    }

    private static func intValueIncludingPayload(in object: [String: Any], keys: [String]) -> Int? {
        intValue(in: object, keys: keys)
            ?? payloadObject(in: object).flatMap { intValue(in: $0, keys: keys) }
    }

    private static func doubleValueIncludingPayload(in object: [String: Any], keys: [String]) -> Double? {
        doubleValue(in: object, keys: keys)
            ?? payloadObject(in: object).flatMap { doubleValue(in: $0, keys: keys) }
    }

    private static func argumentStringIncludingPayload(in object: [String: Any], keys: [String]) -> String? {
        argumentString(in: object, keys: keys)
            ?? payloadObject(in: object).flatMap { argumentString(in: $0, keys: keys) }
    }

    private static func argumentString(in object: [String: Any], keys: [String]) -> String? {
        for containerKey in ["input", "arguments", "args"] {
            if let dictionary = object[containerKey] as? [String: Any],
               let value = firstString(in: dictionary, keys: keys) {
                return value
            }
            if let text = object[containerKey] as? String,
               let dictionary = jsonDictionary(from: text),
               let value = firstString(in: dictionary, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func nestedIntIncludingPayload(_ object: [String: Any], path: [String]) -> Int? {
        nestedInt(object, path: path)
            ?? payloadObject(in: object).flatMap { nestedInt($0, path: path) }
    }

    private static func nestedDoubleIncludingPayload(_ object: [String: Any], path: [String]) -> Double? {
        nestedDouble(object, path: path)
            ?? payloadObject(in: object).flatMap { nestedDouble($0, path: path) }
    }

    private static func hasAnyKey(in object: [String: Any], keys: [String]) -> Bool {
        if keys.contains(where: { object[$0] != nil }) {
            return true
        }
        guard let payload = payloadObject(in: object) else {
            return false
        }
        return keys.contains { payload[$0] != nil }
    }

    private static func payloadObject(in object: [String: Any]) -> [String: Any]? {
        if let data = object["data"] as? [String: Any] {
            return data
        }
        if let payload = object["payload"] as? [String: Any] {
            return payload
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

    private static func nestedStringIncludingPayload(_ object: [String: Any], path: [String]) -> String? {
        nestedString(object, path: path)
            ?? payloadObject(in: object).flatMap { nestedString($0, path: path) }
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

    private static func stableInputSummary(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return stableJSONString(value)
    }

    private static func jsonDictionary(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
