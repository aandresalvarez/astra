import Foundation

public enum CursorStreamEventParser {
    public static func parse(line: String) -> ParsedEvent? {
        parseAll(line: line).first
    }

    public static func parseAll(line: String) -> [ParsedEvent] {
        switch cursorSpecificParsedEvents(line: line) {
        case .recognized(let events):
            return events
        case .unrecognized:
            return StreamEventParser.parseStructured(line: line).resolvingUnrecognized(with: {
                parsePlainText(line: line)
            })
        }
    }

    public static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        CopilotStreamEventParser.parsePlainText(line: line, appendingNewline: appendingNewline)
    }

    public static func parseAgentEvents(line: String) -> [AgentEvent] {
        parseAll(line: line).flatMap { agentEvents(from: $0, rawLine: line) } + fileChangeEvents(line: line)
    }

    /// The events the worker records, with each assistant message keyed by
    /// the provider's own identity (docs/specs/2026-09-23-provider-message-
    /// identity-plan.md). `parseAgentEvents` keeps the unkeyed shapes that
    /// utility-prompt collectors aggregate, until those paths move over too.
    public static func parseIdentifiedAgentEvents(line: String) -> [AgentEvent] {
        CursorMessageIdentity.annotate(parseAgentEvents(line: line), line: line)
    }

    public static func parsePlainTextAgentEvents(line: String, appendingNewline: Bool = false) -> [AgentEvent] {
        CopilotStreamEventParser.parsePlainTextAgentEvents(
            line: line,
            appendingNewline: appendingNewline
        ).map(relabelUnknownAgentEvent)
    }

    private static func agentEvents(from event: ParsedEvent, rawLine: String) -> [AgentEvent] {
        switch event {
        case .control(let type):
            return [.control(type: type)]
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
                return [.failed(message: text ?? "Cursor CLI run failed.")]
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
                provider: "cursor",
                type: type,
                raw: rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        }
    }

    private static func relabelUnknownAgentEvent(_ event: AgentEvent) -> AgentEvent {
        guard case .unknown(_, let type, let raw) = event else { return event }
        return .unknown(provider: "cursor", type: type, raw: raw)
    }

    private static func cursorSpecificParsedEvents(line: String) -> StructuredStreamParseOutcome<ParsedEvent> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .unrecognized
        }
        guard let object = json as? [String: Any] else {
            return .recognized([.unknown(type: "unknown")])
        }
        guard let type = object["type"] as? String else {
            return .recognized([.unknown(type: "unknown")])
        }
        switch type {
        case "tool_call":
            return .recognized(toolCallEvents(object))
        case "thinking":
            guard let text = object["text"] as? String, !text.isEmpty else {
                return .recognized([.unknown(type: type)])
            }
            return .recognized([.thinking(text: text)])
        default:
            return .unrecognized
        }
    }

    /// A `tool_call` frame names its tool by key (`readToolCall`,
    /// `editToolCall`, `shellToolCall`, …) with `args`, and on completion a
    /// `result` holding `success` or an error.
    private static func toolCallEvents(_ object: [String: Any]) -> [ParsedEvent] {
        guard let (name, call) = toolCall(in: object) else { return [.unknown(type: "tool_call")] }
        let id = object["call_id"] as? String ?? name
        switch (object["subtype"] as? String)?.lowercased() {
        case "started":
            // The file body a write streams is not a summary of the call.
            let args = (call["args"] as? [String: Any] ?? [:]).filter { !bulkyArgumentKeys.contains($0.key) }
            return [.toolUse(name: name, id: id, input: args)]
        case "completed":
            let result = call["result"] as? [String: Any] ?? [:]
            let succeeded = result["success"] != nil
            let text = result.values.first.map(resultText) ?? ""
            // The recorder keeps only results with content; an edit can
            // succeed without any.
            let content = text.isEmpty ? (succeeded ? "Completed \(name)" : "\(name) failed") : text
            return [.toolResult(toolId: id, content: content, isError: !succeeded)]
        default:
            return [.control(type: "tool_call")]
        }
    }

    /// A completed, successful edit or write is a file change.
    private static func fileChangeEvents(line: String) -> [AgentEvent] {
        guard line.contains("\"tool_call\""),
              let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "tool_call",
              (object["subtype"] as? String)?.lowercased() == "completed",
              let (name, call) = toolCall(in: object),
              let kind = fileChangeKinds[name],
              (call["result"] as? [String: Any])?["success"] != nil,
              let path = (call["args"] as? [String: Any])?["path"] as? String else {
            return []
        }
        return [.fileChange(path: path, kind: kind, summary: nil)]
    }

    private static func toolCall(in object: [String: Any]) -> (String, [String: Any])? {
        guard let calls = object["tool_call"] as? [String: Any] else { return nil }
        let name = calls.keys.sorted().first { $0.hasSuffix("ToolCall") } ?? calls.keys.sorted().first
        guard let name, let call = calls[name] as? [String: Any] else { return nil }
        return (name, call)
    }

    private static func resultText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            for key in ["content", "output", "message", "error", "stdout"] {
                if let text = object[key] as? String { return text }
            }
        }
        return ""
    }

    private static let bulkyArgumentKeys: Set<String> = ["streamContent", "content", "contents", "fileText", "newText"]
    private static let fileChangeKinds = ["editToolCall": "update", "writeToolCall": "add", "deleteToolCall": "delete"]

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
