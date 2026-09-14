import Foundation

/// Parser for `agy --output-format stream-json`.
///
/// Antigravity's plain-text mode gives ASTRA nothing but prose: no turn
/// boundary, no usage, no session id, and tool calls only as scraped text.
/// The structured stream carries all four. Frames are `{"event": <kind>,
/// <kind>: {…}}`, captured live from agy 1.2.2:
///
///     {"event":"init","conversation_id":"…","init":{"cwd":"…","tools":[…]}}
///     {"event":"step_update","step_update":{"step_index":5,"state":"ACTIVE",
///       "step_type":"agent_response","text_delta":"DONE"}}
///     {"event":"step_update","step_update":{"step_index":4,"state":"DONE",
///       "step_type":"tool","tool_name":"run_command",
///       "tool_info":{"parameters":{…},"output":"hello\n"}}}
///     {"event":"result","result":{"status":"SUCCESS","response":"DONE\n",
///       "duration_seconds":9.8,"num_turns":1,"usage":{…}}}
///
/// Only the `result` frame ends the run. An `agent_response` step never does,
/// however finished it looks — that conflation is what let the process monitor
/// kill Codex and Copilot runs mid-work, and this parser is built to not
/// repeat it.
public enum AntigravityStreamEventParser {
    /// Returns nil when the line is not one of agy's structured frames, so the
    /// caller can fall back to the plain-text parser (which still owns
    /// permission prompts and auth notices).
    public static func parseStructuredAgentEvents(line: String) -> [AgentEvent]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = string(in: object, keys: ["event"]) else {
            return nil
        }

        switch event.lowercased() {
        case "init":
            return [.started(sessionID: string(in: object, keys: ["conversation_id"]), model: nil)]
        case "step_update":
            return stepEvents(in: object["step_update"] as? [String: Any] ?? [:])
        case "result":
            return resultEvents(in: object["result"] as? [String: Any] ?? [:])
        default:
            return [.control(type: "agy.\(event.lowercased())")]
        }
    }

    /// `ParsedEvent` twin, for the process monitor.
    public static func parseStructured(line: String) -> [ParsedEvent]? {
        guard let events = parseStructuredAgentEvents(line: line) else { return nil }
        // The terminal frame is rebuilt as one `.result` rather than mapped
        // event by event, so the monitor sees a single unambiguous end of run
        // carrying the usage that rode with it.
        if let terminal = terminalParsedEvent(from: events) {
            return [terminal]
        }
        return events.compactMap(parsedEvent(from:))
    }

    // MARK: - Frames

    private static func stepEvents(in step: [String: Any]) -> [AgentEvent] {
        let stepType = string(in: step, keys: ["step_type"])?.lowercased() ?? "unknown"
        let state = string(in: step, keys: ["state"])?.uppercased() ?? ""

        switch stepType {
        case "agent_response":
            // Deltas arrive on both ACTIVE and DONE; the DONE frame also
            // carries this step's own usage, which is deliberately dropped —
            // the `result` frame reports the run total, and adding both would
            // double count.
            guard let delta = string(in: step, keys: ["text_delta"]), !delta.isEmpty else {
                return [.control(type: "agy.step.agent_response")]
            }
            return [.text(text: delta)]
        case "tool":
            return toolEvents(in: step, state: state)
        case "user_input":
            return [.control(type: "agy.step.user_input")]
        default:
            return [.control(type: "agy.step.\(stepType)")]
        }
    }

    private static func toolEvents(in step: [String: Any], state: String) -> [AgentEvent] {
        let info = step["tool_info"] as? [String: Any] ?? [:]
        let name = string(in: step, keys: ["tool_name"]) ?? string(in: info, keys: ["name"]) ?? "tool"
        // agy identifies a step by index rather than a call id, and the ACTIVE
        // and DONE frames for one tool share it, which is exactly what pairing
        // a result to its use needs.
        let id = int(in: step, keys: ["step_index"]).map { "step-\($0)" } ?? name

        switch state {
        case "ACTIVE":
            return [.toolUse(name: name, id: id, inputSummary: parameterSummary(in: info))]
        case "ERROR":
            let error = info["error"] as? [String: Any] ?? [:]
            let message = string(in: error, keys: ["message"])
                ?? string(in: info, keys: ["output"])
                ?? "\(name) failed."
            return [.toolResult(id: id, content: message, isError: true)]
        case "DONE":
            return [.toolResult(id: id, content: string(in: info, keys: ["output"]) ?? "", isError: false)]
        default:
            return [.control(type: "agy.step.tool.\(state.lowercased())")]
        }
    }

    private static func resultEvents(in result: [String: Any]) -> [AgentEvent] {
        let status = string(in: result, keys: ["status"])?.uppercased() ?? "SUCCESS"
        let response = string(in: result, keys: ["response"])
        var events: [AgentEvent] = []
        if let usage = usageEvent(in: result) {
            events.append(usage)
        }
        // A non-SUCCESS status is the provider saying the turn itself failed.
        // Note that a print timeout does *not* land here: agy reports SUCCESS
        // with an empty response and explains itself on stderr, which the
        // empty-result path already treats as no usable result.
        if status == "SUCCESS" {
            events.append(.completed(summary: response))
        } else {
            events.append(.failed(message: response ?? "Antigravity reported \(status)."))
        }
        return events
    }

    private static func usageEvent(in result: [String: Any]) -> AgentEvent? {
        let usage = result["usage"] as? [String: Any] ?? [:]
        // Cached reads still entered the context window, so they belong in the
        // input total the budget is measured against.
        let input = (int(in: usage, keys: ["input_tokens"]) ?? 0)
            + (int(in: usage, keys: ["cache_read_tokens"]) ?? 0)
        // `thinking_tokens` is a subset of `output_tokens`, not an addition.
        let output = int(in: usage, keys: ["output_tokens"]) ?? 0
        let duration = double(in: result, keys: ["duration_seconds"]).map { Int($0 * 1000) }
        let turns = int(in: result, keys: ["num_turns"])
        guard input > 0 || output > 0 || duration != nil || turns != nil else { return nil }
        // Antigravity bills through a subscription, so there is no per-run cost
        // to report.
        return .stats(inputTokens: input, outputTokens: output, costUSD: nil, durationMs: duration, turns: turns)
    }

    // MARK: - ParsedEvent mapping

    private static func terminalParsedEvent(from events: [AgentEvent]) -> ParsedEvent? {
        var summary: String?
        var isError = false
        var sawTerminal = false
        for event in events {
            switch event {
            case .completed(let text):
                summary = text
                sawTerminal = true
            case .failed(let message):
                summary = message
                isError = true
                sawTerminal = true
            default:
                continue
            }
        }
        guard sawTerminal else { return nil }

        var input = 0
        var output = 0
        var duration: Int?
        var turns: Int?
        for event in events {
            if case .stats(let statsInput, let statsOutput, _, let statsDuration, let statsTurns) = event {
                input = statsInput
                output = statsOutput
                duration = statsDuration
                turns = statsTurns
            }
        }

        return .result(
            text: summary,
            costUSD: nil,
            totalInputTokens: input,
            totalOutputTokens: output,
            durationMs: duration,
            numTurns: turns,
            isError: isError
        )
    }

    private static func parsedEvent(from event: AgentEvent) -> ParsedEvent? {
        switch event {
        case .control(let type):
            return .control(type: type)
        case .started(let sessionID, let model):
            return .systemInit(model: model, sessionId: sessionID)
        case .text(let text):
            return .text(text: text)
        case .thinking(let text):
            return .thinking(text: text)
        case .toolUse(let name, let id, let inputSummary):
            return .toolUse(name: name, id: id, input: inputSummary.map { ["summary": $0] })
        case .toolResult(let id, let content, let isError):
            return .toolResult(toolId: id, content: content, isError: isError)
        case .stats(let input, let output, _, _, _):
            return .usage(totalInputTokens: input, totalOutputTokens: output)
        case .completed(let summary):
            // Only reachable if a completion ever arrives outside the `result`
            // frame. It would be an assistant message, not the end of the run.
            guard let summary, !summary.isEmpty else { return nil }
            return .text(text: summary)
        default:
            return nil
        }
    }

    // MARK: - JSON helpers

    private static func parameterSummary(in info: [String: Any]) -> String? {
        guard let parameters = info["parameters"] else { return nil }
        if let text = parameters as? String { return text }
        guard JSONSerialization.isValidJSONObject(parameters),
              let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func int(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private static func double(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }
}
