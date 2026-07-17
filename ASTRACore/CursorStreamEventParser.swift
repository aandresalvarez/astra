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
        case "thinking":
            guard let text = object["text"] as? String, !text.isEmpty else {
                return .recognized([.unknown(type: type)])
            }
            return .recognized([.thinking(text: text)])
        default:
            return .unrecognized
        }
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
