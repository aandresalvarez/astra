import Foundation

public enum CodexStreamEventParser {
    public static func parse(line: String) -> ParsedEvent? {
        parseAll(line: line).first
    }

    public static func parseAll(line: String) -> [ParsedEvent] {
        CopilotStreamEventParser.parseAll(line: line)
    }

    public static func parsePlainText(line: String, appendingNewline: Bool = false) -> [ParsedEvent] {
        CopilotStreamEventParser.parsePlainText(line: line, appendingNewline: appendingNewline)
    }

    public static func parseAgentEvents(line: String) -> [AgentEvent] {
        CopilotStreamEventParser.parseAgentEvents(line: line).map(relabelUnknownAgentEvent)
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
}
