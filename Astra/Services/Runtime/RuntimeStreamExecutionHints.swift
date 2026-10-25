import Foundation

/// Redundant provider signals catch omitted tool-start frames. These counters
/// can disprove cleanup, but zero counters never establish cleanup on their own.
enum RuntimeStreamExecutionHints {
    static func containsWork(_ frame: [String: Any]) -> Bool {
        var containers = [frame]
        // Only structural envelopes, never JSON-looking text supplied by a user.
        for key in ["data", "item", "message", "event"] {
            if let object = frame[key] as? [String: Any] { containers.append(object) }
        }
        if let event = frame["event"] as? [String: Any] {
            for key in ["message", "delta"] {
                if let object = event[key] as? [String: Any] { containers.append(object) }
            }
        }
        for object in containers {
            for key in ["toolRequests", "tool_requests", "permission_denials"] {
                if let value = object[key], (value as? [Any])?.isEmpty != true { return true }
            }
            if let parent = object["parent_tool_use_id"], !(parent is NSNull) { return true }
            if object["stop_reason"] as? String == "tool_use" { return true }
            if let count = object["queued_turn_count"], (count as? Int) != 0 { return true }
            if let stats = object["subagent_stats"], !zeroCounters(stats) { return true }
            if let usage = object["usage"] as? [String: Any] {
                for key in ["server_tool_use", "codeChanges"] {
                    if let counters = usage[key], !zeroCounters(counters) { return true }
                }
            }
        }
        return false
    }

    private static func zeroCounters(_ value: Any) -> Bool {
        if let fields = value as? [String: Any] { return fields.values.allSatisfy(zeroCounters) }
        if let items = value as? [Any] { return items.isEmpty }
        return (value as? NSNumber)?.doubleValue == 0
    }
}
