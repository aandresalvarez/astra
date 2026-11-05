import Foundation
import CoreFoundation

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
            if let parent = object["parentToolCallId"], !(parent is NSNull), (parent as? String)?.isEmpty != true { return true }
            if let serverTools = object["serverTools"], serverToolsContainWork(serverTools) { return true }
            if let edits = object["containsBuiltInFileEditRequest"] {
                guard let flag = edits as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue else { return true }
            }
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

    private static func serverToolsContainWork(_ value: Any) -> Bool {
        if value is NSNull { return false }
        guard let fields = value as? [String: Any],
              Set(fields.keys).isSubset(of: ["provider", "items", "rawContentBlocks", "functionCallNamespaces", "advisorModel"]),
              let provider = fields["provider"] as? String, !provider.isEmpty else { return true }
        // Native provider-only envelopes and explicitly empty collections carry
        // no server work. Arbitrary zero/false values cannot establish that.
        for key in ["items", "rawContentBlocks"] {
            if let items = fields[key], (items as? [Any])?.isEmpty != true { return true }
        }
        if let namespaces = fields["functionCallNamespaces"], (namespaces as? [String: Any])?.isEmpty != true { return true }
        if let advisor = fields["advisorModel"], (advisor as? String)?.isEmpty != true { return true }
        return false
    }

    private static func zeroCounters(_ value: Any) -> Bool {
        if let fields = value as? [String: Any] { return fields.values.allSatisfy(zeroCounters) }
        if let items = value as? [Any] { return items.isEmpty }
        return (value as? NSNumber)?.doubleValue == 0
    }
}
