import Foundation

public enum OpenCodeStreamEventParser {
    public static func parse(line: String) -> ParsedEvent? {
        parseAll(line: line).first
    }

    public static func parseAll(line: String) -> [ParsedEvent] {
        let events = openCodeParsedEvents(line: line)
        return events.isEmpty ? parsePlainText(line: line) : events
    }

    public static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        CopilotStreamEventParser.parsePlainText(line: line, appendingNewline: appendingNewline)
    }

    public static func parseAgentEvents(line: String) -> [AgentEvent] {
        parseAll(line: line).flatMap { agentEvents(from: $0, rawLine: line) }
    }

    public static func parsePlainTextAgentEvents(line: String, appendingNewline: Bool = false) -> [AgentEvent] {
        CopilotStreamEventParser.parsePlainTextAgentEvents(
            line: line,
            appendingNewline: appendingNewline
        ).map(relabelUnknownAgentEvent)
    }

    private static func agentEvents(from event: ParsedEvent, rawLine: String) -> [AgentEvent] {
        switch event {
        case .systemInit(let model, let sessionID):
            return [.started(sessionID: sessionID, model: model)]
        case .thinking(let text):
            return [.thinking(text: text)]
        case .text(let text):
            return [.text(text: text)]
        case .toolUse(let name, let id, let input):
            return [.toolUse(name: name, id: id, inputSummary: inputSummary(input))]
        case .toolResult(let toolID, let content, let isError):
            return [.toolResult(id: toolID, content: content, isError: isError)]
        case .usage(let input, let output):
            return [.stats(inputTokens: input, outputTokens: output, costUSD: nil, durationMs: nil, turns: nil)]
        case .result(let text, let cost, let input, let output, let duration, let turns, let isError):
            if isError {
                return [.failed(message: text ?? "OpenCode CLI run failed.")]
            }
            var events: [AgentEvent] = []
            if let text, !text.isEmpty {
                events.append(.completed(summary: text))
            }
            if input > 0 || output > 0 || cost != nil || duration != nil || turns != nil {
                events.append(.stats(
                    inputTokens: input,
                    outputTokens: output,
                    costUSD: cost,
                    durationMs: duration,
                    turns: turns
                ))
            }
            return events
        case .permissionDenied(let tool, let reason):
            return [.permissionRequested(tool: tool, reason: reason)]
        case .astraProtocol(let event):
            return [.astraProtocol(event)]
        case .teammateStarted, .teammateCompleted, .teamCreated, .teamDeleted, .teamMessage:
            return []
        case .unknown(let type):
            return [.unknown(
                provider: "opencode",
                type: type,
                raw: rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        }
    }

    private static func relabelUnknownAgentEvent(_ event: AgentEvent) -> AgentEvent {
        guard case .unknown(_, let type, let raw) = event else { return event }
        return .unknown(provider: "opencode", type: type, raw: raw)
    }

    private static func openCodeParsedEvents(line: String) -> [ParsedEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }

        switch type {
        case "session", "session.created", "session.updated":
            return systemInit(from: object)
        case "text":
            return textEvent(from: object)
        case "reasoning":
            return reasoningEvent(from: object)
        case "tool_use":
            return toolEvents(from: object)
        case "error", "session.error":
            return errorEvent(from: object)
        case "permission.asked":
            return permissionEvent(from: object)
        case "session.status":
            return []
        default:
            return [.unknown(type: type)]
        }
    }

    private static func systemInit(from object: [String: Any]) -> [ParsedEvent] {
        let sessionID = object["sessionID"] as? String
        let model = object["model"] as? String
            ?? nestedString(object, path: ["properties", "info", "modelID"])
            ?? nestedString(object, path: ["properties", "model", "id"])
        guard sessionID != nil || model != nil else { return [] }
        return [.systemInit(model: model, sessionId: sessionID)]
    }

    private static func textEvent(from object: [String: Any]) -> [ParsedEvent] {
        guard let text = textFromPart(object), !text.isEmpty else { return [] }
        return [.text(text: text)]
    }

    private static func reasoningEvent(from object: [String: Any]) -> [ParsedEvent] {
        guard let text = textFromPart(object), !text.isEmpty else { return [] }
        return [.thinking(text: text)]
    }

    private static func toolEvents(from object: [String: Any]) -> [ParsedEvent] {
        guard let part = object["part"] as? [String: Any] else { return [] }
        let name = part["tool"] as? String ?? part["name"] as? String ?? "tool"
        let id = part["id"] as? String ?? part["toolID"] as? String ?? name
        let state = part["state"] as? [String: Any]
        let input = state?["input"] as? [String: Any] ?? part["input"] as? [String: Any]
        var events: [ParsedEvent] = [.toolUse(name: name, id: id, input: input)]
        if let output = state?["output"] as? String, !output.isEmpty {
            events.append(.toolResult(toolId: id, content: output))
        } else if let error = state?["error"] as? String, !error.isEmpty {
            events.append(.toolResult(toolId: id, content: error))
        }
        return events
    }

    private static func errorEvent(from object: [String: Any]) -> [ParsedEvent] {
        let message = object["message"] as? String
            ?? nestedString(object, path: ["error", "message"])
            ?? nestedString(object, path: ["error", "data", "message"])
            ?? "OpenCode CLI run failed."
        return [.result(
            text: message,
            costUSD: nil,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            durationMs: nil,
            numTurns: nil,
            isError: true
        )]
    }

    private static func permissionEvent(from object: [String: Any]) -> [ParsedEvent] {
        let permission = object["permission"] as? String
            ?? nestedString(object, path: ["properties", "permission"])
            ?? "Permission"
        let patterns = object["patterns"] as? [String]
            ?? nestedStrings(object, path: ["properties", "patterns"])
            ?? []
        let reason = patterns.isEmpty ? permission : "\(permission) (\(patterns.joined(separator: ", ")))"
        return [.permissionDenied(tool: permission, reason: reason)]
    }

    private static func textFromPart(_ object: [String: Any]) -> String? {
        if let text = object["text"] as? String {
            return text
        }
        if let part = object["part"] as? [String: Any] {
            return part["text"] as? String
        }
        return nestedString(object, path: ["properties", "part", "text"])
    }

    private static func nestedString(_ object: [String: Any], path: [String]) -> String? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current as? String
    }

    private static func nestedStrings(_ object: [String: Any], path: [String]) -> [String]? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current as? [String]
    }

    private static func inputSummary(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
