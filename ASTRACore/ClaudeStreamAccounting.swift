import Foundation
import CoreFoundation

/// Reconstructs per-process usage from message-scoped Claude snapshots and deltas.
/// This cache is derived solely from the current pipe and dies with that process.
public final class ClaudeStreamAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String: [String: Int]] = [:]
    private var activeMessages: [String: String] = [:]
    private var input: Int
    private var output: Int
    private let sessionInput: Int
    private let sessionOutput: Int
    private var invalid = false
    public var hasInvalidUsage: Bool { lock.withLock { invalid } }
    public init(sessionInput: Int = 0, sessionOutput: Int = 0) {
        self.sessionInput = max(0, sessionInput); self.sessionOutput = max(0, sessionOutput)
        input = self.sessionInput; output = self.sessionOutput
    }

    public func normalize(_ line: String) -> (line: String, invalidUsage: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var frame = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = frame["type"] as? String else { return (line, false) }
        if type == "result" { return normalizeResult(frame, fallback: line) }
        let scope = frame["parent_tool_use_id"] as? String ?? "main"
        var event = frame["event"] as? [String: Any] ?? [:]
        var message = (type == "assistant" ? frame["message"] : event["message"]) as? [String: Any] ?? [:]
        let eventType = event["type"] as? String
        guard type == "assistant" || (type == "stream_event" && ["message_start", "message_delta"].contains(eventType)) else {
            return (line, false)
        }
        let id = message["id"] as? String ?? (eventType == "message_delta" ? activeMessages[scope] : nil)
        if eventType == "message_start" {
            activeMessages[scope] = id?.isEmpty == false ? id : nil
        }
        let usage = (eventType == "message_delta" ? event["usage"] : message["usage"]) as? [String: Any]
        guard let usage else { return (line, false) }
        let fields = [
            "input": ["input_tokens", "inputTokens"], "output": ["output_tokens", "outputTokens"],
            "cached": ["cachedInputTokens"],
            "read": ["cache_read_input_tokens", "cacheReadInputTokens", "cacheReadTokens"],
            "write": ["cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteTokens"]
        ]
        guard fields.values.contains(where: { aliases in aliases.contains { usage[$0] != nil } }) else {
            return (line, false)
        }
        // An anonymous message cannot safely be deduplicated against its full snapshot.
        guard let id, !id.isEmpty else { return (removingUsage(frame, event: event, message: message, type: type, delta: eventType == "message_delta", fallback: line), false) }
        let key = scope + ":" + id
        guard messages[key] != nil || messages.count < 10_000 else { invalid = true; return (line, true) }
        let previous = messages[key] ?? [:]
        var next = previous
        for (name, aliases) in fields {
            guard let value = aliases.compactMap({ usage[$0] }).first else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let count = value as? Int, count >= 0, Double(count) == number.doubleValue else {
                invalid = true; return (line, true)
            }
            next[name] = max(previous[name] ?? 0, count)
        }
        func inputs(_ counts: [String: Int]) -> Int { ProviderUsageArithmetic.sum([counts["input"] ?? 0, counts["cached"] ?? 0, counts["read"] ?? 0, counts["write"] ?? 0]) }
        input = ProviderUsageArithmetic.adding(input, inputs(next) - inputs(previous))
        output = ProviderUsageArithmetic.adding(output, (next["output"] ?? 0) - (previous["output"] ?? 0))
        messages[key] = next
        let totals = ["input_tokens": input, "output_tokens": output]
        if type == "assistant" { message["usage"] = totals; frame["message"] = message }
        else {
            if eventType == "message_delta" { event["usage"] = totals }
            else { message["usage"] = totals; event["message"] = message }
            frame["event"] = event
        }
        return (encode(frame, fallback: line), false)
    }

    private func normalizeResult(_ value: [String: Any], fallback: String) -> (line: String, invalidUsage: Bool) {
        var frame = value
        if let models = frame["modelUsage"] as? [String: Any], !models.isEmpty {
            guard ClaudeSessionUsageSnapshot.modelTotals(models) != nil else { invalid = true; return (fallback, true) }
            return (fallback, false) // Native session totals already include all subagents.
        }
        guard let usage = frame["usage"] as? [String: Any] else { return (fallback, false) }
        let aliases = [["input_tokens", "inputTokens"], ["cachedInputTokens"],
                       ["cache_read_input_tokens", "cacheReadInputTokens", "cacheReadTokens"],
                       ["cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteTokens"],
                       ["output_tokens", "outputTokens"]]
        var counts = [Int?]()
        for names in aliases {
            guard let value = names.compactMap({ usage[$0] }).first else { counts.append(nil); continue }
            guard let count = ProviderUsageArithmetic.reportedCount(value) else { invalid = true; return (fallback, true) }
            counts.append(count)
        }
        guard counts.contains(where: { $0 != nil }) else { return (fallback, false) }
        frame.removeValue(forKey: "modelUsage")
        frame["usage"] = ["input_tokens": ProviderUsageArithmetic.sum([sessionInput] + counts.prefix(4).map { $0 ?? 0 }),
                          "output_tokens": ProviderUsageArithmetic.adding(sessionOutput, counts[4] ?? 0)]
        return (encode(frame, fallback: fallback), false)
    }

    private func removingUsage(_ frame: [String: Any], event: [String: Any], message: [String: Any], type: String, delta: Bool, fallback: String) -> String {
        var frame = frame; var event = event; var message = message
        message.removeValue(forKey: "usage")
        if type == "assistant" { frame["message"] = message }
        else { if delta { event.removeValue(forKey: "usage") } else { event["message"] = message }; frame["event"] = event }
        return encode(frame, fallback: fallback)
    }
    private func encode(_ frame: [String: Any], fallback: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }
}
