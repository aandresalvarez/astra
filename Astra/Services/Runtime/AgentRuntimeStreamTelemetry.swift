import Foundation
import ASTRACore

struct AgentRuntimeStreamTelemetrySnapshot: Sendable {
    let rawLineCount: Int
    let jsonLineCount: Int
    let plainTextLineCount: Int
    let parsedEventCount: Int
    let emittedEventCount: Int
    let textEventCount: Int
    let thinkingEventCount: Int
    let toolUseEventCount: Int
    let toolResultEventCount: Int
    let statsEventCount: Int
    let completedEventCount: Int
    let failedEventCount: Int
    let unknownEventCount: Int
    let unknownTypeCounts: [String: Int]
    let unknownSamples: [(type: String, sample: String)]

    var fields: [String: String] {
        [
            "raw_lines": String(rawLineCount),
            "json_lines": String(jsonLineCount),
            "plain_text_lines": String(plainTextLineCount),
            "parsed_events": String(parsedEventCount),
            "emitted_events": String(emittedEventCount),
            "text_events": String(textEventCount),
            "thinking_events": String(thinkingEventCount),
            "tool_use_events": String(toolUseEventCount),
            "tool_result_events": String(toolResultEventCount),
            "stats_events": String(statsEventCount),
            "completed_events": String(completedEventCount),
            "failed_events": String(failedEventCount),
            "unknown_events": String(unknownEventCount),
            "unknown_types": unknownTypeCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        ]
    }
}

final class AgentRuntimeStreamTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private let maxUnknownSamples: Int

    private var rawLineCount = 0
    private var jsonLineCount = 0
    private var plainTextLineCount = 0
    private var parsedEventCount = 0
    private var emittedEventCount = 0
    private var textEventCount = 0
    private var thinkingEventCount = 0
    private var toolUseEventCount = 0
    private var toolResultEventCount = 0
    private var statsEventCount = 0
    private var completedEventCount = 0
    private var failedEventCount = 0
    private var unknownEventCount = 0
    private var unknownTypeCounts: [String: Int] = [:]
    private var unknownSamples: [(type: String, sample: String)] = []

    init(maxUnknownSamples: Int = 3) {
        self.maxUnknownSamples = maxUnknownSamples
    }

    func recordRawLine(parsesJSONLines: Bool) {
        lock.lock()
        rawLineCount += 1
        if parsesJSONLines {
            jsonLineCount += 1
        } else {
            plainTextLineCount += 1
        }
        lock.unlock()
    }

    func recordParsed(_ events: [AgentEvent]) {
        lock.lock()
        parsedEventCount += events.count
        for event in events {
            record(event)
        }
        lock.unlock()
    }

    func recordEmitted(_ events: [AgentEvent]) {
        lock.lock()
        emittedEventCount += events.count
        lock.unlock()
    }

    func snapshot() -> AgentRuntimeStreamTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AgentRuntimeStreamTelemetrySnapshot(
            rawLineCount: rawLineCount,
            jsonLineCount: jsonLineCount,
            plainTextLineCount: plainTextLineCount,
            parsedEventCount: parsedEventCount,
            emittedEventCount: emittedEventCount,
            textEventCount: textEventCount,
            thinkingEventCount: thinkingEventCount,
            toolUseEventCount: toolUseEventCount,
            toolResultEventCount: toolResultEventCount,
            statsEventCount: statsEventCount,
            completedEventCount: completedEventCount,
            failedEventCount: failedEventCount,
            unknownEventCount: unknownEventCount,
            unknownTypeCounts: unknownTypeCounts,
            unknownSamples: unknownSamples
        )
    }

    private func record(_ event: AgentEvent) {
        switch event {
        case .control:
            break
        case .started:
            break
        case .thinking:
            thinkingEventCount += 1
        case .text:
            textEventCount += 1
        case .toolUse:
            toolUseEventCount += 1
        case .toolResult:
            toolResultEventCount += 1
        case .fileChange:
            break
        case .permissionRequested:
            break
        case .stats:
            statsEventCount += 1
        case .astraProtocol:
            break
        case .completed:
            completedEventCount += 1
        case .failed:
            failedEventCount += 1
        case .teamEvent:
            break
        case .unknown(_, let type, let raw):
            unknownEventCount += 1
            unknownTypeCounts[type, default: 0] += 1
            if unknownSamples.count < maxUnknownSamples,
               !unknownSamples.contains(where: { $0.type == type }) {
                unknownSamples.append((type: type, sample: raw))
            }
        }
    }
}
