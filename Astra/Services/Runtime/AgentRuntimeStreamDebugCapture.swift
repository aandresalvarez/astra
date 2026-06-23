import Foundation
import ASTRACore

struct AgentRuntimeStreamDebugSnapshot: Sendable {
    let rawLineCount: Int
    let jsonLineCount: Int
    let plainTextLineCount: Int
    let parsedEventCount: Int
    let emittedEventCount: Int
    let stdoutBytes: Int
    let stderrBytes: Int
    let durationMs: Int
    let firstLineLatencyMs: Int?
    let lastLineOffsetMs: Int?
    let eventTypeCounts: [String: Int]
    let rawSamples: [String]
    let unknownJSONShapes: [String]
    let stderrTail: String?

    var fields: [String: String] {
        var fields: [String: String] = [
            "raw_lines": String(rawLineCount),
            "json_lines": String(jsonLineCount),
            "plain_text_lines": String(plainTextLineCount),
            "parsed_events": String(parsedEventCount),
            "emitted_events": String(emittedEventCount),
            "stdout_bytes": String(stdoutBytes),
            "stderr_bytes": String(stderrBytes),
            "duration_ms": String(durationMs),
            "raw_samples": String(rawSamples.count),
            "unknown_json_shapes": String(unknownJSONShapes.count),
            "stderr_tail_chars": String(stderrTail?.count ?? 0),
            "event_types": eventTypeCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        ]
        if let firstLineLatencyMs {
            fields["first_line_latency_ms"] = String(firstLineLatencyMs)
        }
        if let lastLineOffsetMs {
            fields["last_line_offset_ms"] = String(lastLineOffsetMs)
        }
        return fields
    }
}

final class AgentRuntimeStreamDebugCapture: @unchecked Sendable {
    static let environmentKey = "ASTRA_STREAM_DEBUG"

    private let lock = NSLock()
    private let startedAt = Date()
    private let maxRawSamples: Int
    private let maxUnknownJSONShapes: Int
    private let maxSampleLength: Int
    private let maxStderrTailLength: Int

    private var rawLineCount = 0
    private var jsonLineCount = 0
    private var plainTextLineCount = 0
    private var parsedEventCount = 0
    private var emittedEventCount = 0
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var firstLineAt: Date?
    private var lastLineAt: Date?
    private var eventTypeCounts: [String: Int] = [:]
    private var rawSamples: [String] = []
    private var unknownJSONShapes: [String] = []
    private var stderrTail = ""

    init(
        maxRawSamples: Int = 4,
        maxUnknownJSONShapes: Int = 4,
        maxSampleLength: Int = 500,
        maxStderrTailLength: Int = 2_000
    ) {
        self.maxRawSamples = maxRawSamples
        self.maxUnknownJSONShapes = maxUnknownJSONShapes
        self.maxSampleLength = maxSampleLength
        self.maxStderrTailLength = maxStderrTailLength
    }

    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String], defaults: UserDefaults = .standard) -> Bool {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return LoggingPreferences.runtimeStreamDebugCaptureEnabled(in: defaults)
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    static func makeIfEnabled() -> AgentRuntimeStreamDebugCapture? {
        isEnabled ? AgentRuntimeStreamDebugCapture() : nil
    }

    func recordLine(_ line: String, parsesJSONLines: Bool) {
        let now = Date()
        lock.lock()
        rawLineCount += 1
        if parsesJSONLines {
            jsonLineCount += 1
        } else {
            plainTextLineCount += 1
        }
        stdoutBytes += line.utf8.count
        if firstLineAt == nil {
            firstLineAt = now
        }
        lastLineAt = now
        if rawSamples.count < maxRawSamples {
            rawSamples.append(Self.sanitizedSample(line, limit: maxSampleLength))
        }
        lock.unlock()
    }

    func recordParsed(_ events: [ParsedEvent], rawLine: String) {
        lock.lock()
        parsedEventCount += events.count
        for event in events {
            let type = Self.eventType(event)
            eventTypeCounts[type, default: 0] += 1
            if case .unknown(let unknownType) = event {
                appendUnknownJSONShape(raw: rawLine, eventType: unknownType)
            }
        }
        if events.isEmpty {
            appendUnknownJSONShape(raw: rawLine, eventType: nil)
        }
        lock.unlock()
    }

    func recordParsed(_ events: [AgentEvent], rawLine: String) {
        lock.lock()
        parsedEventCount += events.count
        for event in events {
            let type = Self.eventType(event)
            eventTypeCounts[type, default: 0] += 1
            if case .unknown(_, let unknownType, let raw) = event {
                appendUnknownJSONShape(raw: raw.isEmpty ? rawLine : raw, eventType: unknownType)
            }
        }
        if events.isEmpty {
            appendUnknownJSONShape(raw: rawLine, eventType: nil)
        }
        lock.unlock()
    }

    func recordEmitted(_ events: [ParsedEvent]) {
        lock.lock()
        emittedEventCount += events.count
        lock.unlock()
    }

    func recordEmitted(_ events: [AgentEvent]) {
        lock.lock()
        emittedEventCount += events.count
        lock.unlock()
    }

    func recordStderr(_ stderr: String?) {
        guard let stderr, !stderr.isEmpty else { return }
        lock.lock()
        stderrBytes += stderr.utf8.count
        stderrTail += stderr
        if stderrTail.count > maxStderrTailLength {
            stderrTail = String(stderrTail.suffix(maxStderrTailLength))
        }
        stderrTail = LogSanitizer.sanitize(stderrTail, maxLength: maxStderrTailLength)
        lock.unlock()
    }

    func snapshot() -> AgentRuntimeStreamDebugSnapshot {
        let finishedAt = Date()
        lock.lock()
        defer { lock.unlock() }
        return AgentRuntimeStreamDebugSnapshot(
            rawLineCount: rawLineCount,
            jsonLineCount: jsonLineCount,
            plainTextLineCount: plainTextLineCount,
            parsedEventCount: parsedEventCount,
            emittedEventCount: emittedEventCount,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            durationMs: Self.milliseconds(from: startedAt, to: finishedAt),
            firstLineLatencyMs: firstLineAt.map { Self.milliseconds(from: startedAt, to: $0) },
            lastLineOffsetMs: lastLineAt.map { Self.milliseconds(from: startedAt, to: $0) },
            eventTypeCounts: eventTypeCounts,
            rawSamples: rawSamples,
            unknownJSONShapes: unknownJSONShapes,
            stderrTail: stderrTail.isEmpty ? nil : stderrTail
        )
    }

    private func appendUnknownJSONShape(raw: String, eventType: String?) {
        guard unknownJSONShapes.count < maxUnknownJSONShapes,
              let shape = Self.jsonShape(raw: raw, eventType: eventType),
              !unknownJSONShapes.contains(shape) else {
            return
        }
        unknownJSONShapes.append(shape)
    }

    private static func sanitizedSample(_ value: String, limit: Int) -> String {
        LogSanitizer.sanitize(truncated(value, limit: limit), maxLength: limit)
    }

    private static func jsonShape(raw: String, eventType: String?) -> String? {
        let trimmed = sanitizedSample(raw, limit: 500).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = eventType
            ?? firstString(in: object, keys: ["type", "event", "kind", "sessionUpdate", "name"])
            ?? "unknown"
        var parts = [
            "type=\(type)",
            "keys=\(object.keys.sorted().joined(separator: ","))"
        ]
        for key in ["data", "payload", "message", "content", "delta"] {
            if let nested = object[key] as? [String: Any] {
                parts.append("\(key)_keys=\(nested.keys.sorted().joined(separator: ","))")
            }
        }
        return truncated(parts.joined(separator: " "), limit: 500)
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        for key in ["data", "payload", "message"] {
            if let nested = object[key] as? [String: Any],
               let value = firstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func eventType(_ event: ParsedEvent) -> String {
        switch event {
        case .systemInit: "system_init"
        case .thinking: "thinking"
        case .text: "text"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        case .usage: "usage"
        case .result: "result"
        case .teammateStarted: "teammate_started"
        case .teammateCompleted: "teammate_completed"
        case .teamCreated: "team_created"
        case .teamDeleted: "team_deleted"
        case .teamMessage: "team_message"
        case .permissionDenied: "permission_denied"
        case .astraProtocol: "astra_protocol"
        case .unknown(let type): "unknown:\(type)"
        }
    }

    private static func eventType(_ event: AgentEvent) -> String {
        switch event {
        case .control(let type): "control:\(type)"
        case .started: "started"
        case .thinking: "thinking"
        case .text: "text"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        case .fileChange: "file_change"
        case .permissionRequested: "permission_requested"
        case .stats: "stats"
        case .astraProtocol: "astra_protocol"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown(_, let type, _): "unknown:\(type)"
        }
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " [truncated]"
    }
}
