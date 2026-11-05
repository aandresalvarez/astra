import Foundation
import CoreFoundation
import ASTRACore
import WorkspaceToolSupport

/// Broker observations are local, execution-scoped acknowledgements of exact
/// parsed commands. Provider text alone cannot account for a helper attempt.
final class RuntimeManagedSSHBrokerEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [RemoteWorkspaceJobCLI.Command] = []
    private var activity = false
    func beginCommand() { lock.withLock { activity = true } }
    var hasActivity: Bool { lock.withLock { activity } }
    func acknowledge(_ command: RemoteWorkspaceJobCLI.Command) { lock.withLock { activity = true; commands.append(command) } }
    func accounts(for observed: [RemoteWorkspaceJobCLI.Command]) -> Bool {
        lock.withLock {
            var remaining = commands
            for command in observed {
                guard let index = remaining.firstIndex(of: command) else { return false }
                remaining.remove(at: index)
            }
            // The helper also asks the broker for status itself. Extra starts,
            // unlike those read requests, indicate omitted provider tool frames.
            return !remaining.contains { if case .start = $0 { true } else { false } }
        }
    }
}

/// Narrow exception for known helper frames, not general shell tool cleanup.
/// The caller keeps unrelated/unknown work sticky and retains remote uncertainty
/// until the exact protected job inventory proves local permission was withdrawn.
struct RuntimeManagedSSHHelperEvidence {
    private let broker: RuntimeManagedSSHBrokerEvidence
    private var calls: [String: RemoteWorkspaceJobCLI.Command] = [:]
    private var completed = Set<String>()
    private var starts = Set<String>()
    private var streamed: [Int: String] = [:]
    private var fragments: [String: String] = [:]
    private var streamedNames: [String: String] = [:]
    init(broker: RuntimeManagedSSHBrokerEvidence) { self.broker = broker }

    var hasBrokerActivity: Bool { broker.hasActivity }
    var fullyAccounted: Bool {
        !calls.isEmpty && starts == Set(calls.keys) && completed == Set(calls.keys)
            && streamed.isEmpty && fragments.isEmpty && broker.accounts(for: Array(calls.values))
    }

    private mutating func call(id: String?, name: String?, input: Any?, started: Bool) -> Bool {
        guard let id, !id.isEmpty, let name, ["Bash", "bash"].contains(name),
              let input = input as? [String: Any], let command = input["command"] as? String,
              Set(input.keys).isSubset(of: ["command", "description", "timeout", "timeout_ms"]),
              let tokens = HostControlCLIRelayPolicy.shellTokens(command), tokens.first == RemoteWorkspaceJobCLI.commandName,
              let parsed = try? RemoteWorkspaceJobCLI.parse(Array(tokens.dropFirst())), parsed != .help else { return false }
        if let previous = calls[id], previous != parsed { return false }
        guard !completed.contains(id) else { return false }
        calls[id] = parsed
        if started { starts.insert(id) }
        return true
    }

    private mutating func result(_ id: String?) -> Bool {
        guard let id, calls[id] != nil, starts.contains(id), completed.insert(id).inserted else { return false }
        return true
    }

    mutating func observe(_ frame: [String: Any], runtime: AgentRuntimeID) -> Bool {
        guard frame["parent_tool_use_id"] == nil || frame["parent_tool_use_id"] is NSNull else { return false }
        // Strip only the expected native tool marker. Redundant counters or
        // extra requests on any intermediate frame still disprove cleanup.
        var hints = frame
        if runtime == .copilotCLI, frame["type"] as? String == "assistant.message", var data = frame["data"] as? [String: Any] {
            data["toolRequests"] = []; hints["data"] = data
        }
        if let type = frame["type"] as? String, ["assistant", "user"].contains(type), var message = frame["message"] as? [String: Any] {
            if message["stop_reason"] as? String == "tool_use" { message.removeValue(forKey: "stop_reason") }
            hints["message"] = message
        }
        if frame["type"] as? String == "stream_event", var event = frame["event"] as? [String: Any],
           event["type"] as? String == "message_delta", var delta = event["delta"] as? [String: Any] {
            if delta["stop_reason"] as? String == "tool_use" { delta.removeValue(forKey: "stop_reason") }
            event["delta"] = delta; hints["event"] = event
        }
        guard !RuntimeStreamExecutionHints.containsWork(hints) else { return false }
        switch runtime {
        case .claudeCode, .cursorCLI: return claude(frame)
        case .copilotCLI: return copilot(frame)
        default: return false
        }
    }

    private mutating func claude(_ frame: [String: Any]) -> Bool {
        switch frame["type"] as? String {
        case "assistant", "user":
            guard let message = frame["message"] as? [String: Any],
                  message["role"] == nil || message["role"] as? String == frame["type"] as? String,
                  let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty else { return false }
            var found = false
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    guard block["text"] is String, Set(block.keys).isSubset(of: ["type", "text", "citations"]) else { return false }
                case "thinking":
                    guard block["thinking"] is String, Set(block.keys).isSubset(of: ["type", "thinking", "signature"]) else { return false }
                case "tool_use":
                    guard Set(block.keys).isSubset(of: ["type", "id", "name", "input", "caller"]),
                          Self.directCaller(block["caller"]),
                          frame["type"] as? String == "assistant",
                          call(id: block["id"] as? String, name: block["name"] as? String,
                               input: block["input"], started: true) else { return false }
                    found = true
                case "tool_result":
                    guard Set(block.keys).isSubset(of: ["type", "tool_use_id", "content", "is_error"]),
                          frame["type"] as? String == "user", result(block["tool_use_id"] as? String) else { return false }
                    found = true
                default: return false
                }
            }
            // Redundant usage/subagent counters remain independent evidence.
            var stripped = frame
            var cleaned = message; cleaned["content"] = []
            if cleaned["stop_reason"] as? String == "tool_use" { cleaned.removeValue(forKey: "stop_reason") }
            stripped["message"] = cleaned
            return found && !RuntimeStreamExecutionHints.containsWork(stripped)
        case "stream_event":
            guard let event = frame["event"] as? [String: Any] else { return false }
            switch event["type"] as? String {
            case "content_block_start":
                guard let index = event["index"] as? Int, streamed[index] == nil,
                      let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
                      Set(block.keys).isSubset(of: ["type", "id", "name", "input", "caller"]),
                      Self.directCaller(block["caller"]),
                      let id = block["id"] as? String, !id.isEmpty,
                      let name = block["name"] as? String, ["Bash", "bash"].contains(name),
                      let input = block["input"] as? [String: Any], input.isEmpty else { return false }
                streamed[index] = id; fragments[id] = ""; streamedNames[id] = name
                return true
            case "content_block_delta":
                guard let index = event["index"] as? Int, let id = streamed[index],
                      let delta = event["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
                      Set(delta.keys).isSubset(of: ["type", "partial_json"]),
                      let fragment = delta["partial_json"] as? String,
                      (fragments[id]?.utf8.count ?? 0) + fragment.utf8.count <= 131_072 else { return false }
                fragments[id, default: ""] += fragment
                return true
            case "content_block_stop":
                guard let index = event["index"] as? Int, let id = streamed.removeValue(forKey: index),
                      let text = fragments.removeValue(forKey: id), let name = streamedNames.removeValue(forKey: id),
                      let input = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                      call(id: id, name: name, input: input, started: true) else { return false }
                return true
            case "message_delta":
                guard let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "tool_use",
                      !calls.isEmpty else { return false }
                var stripped = frame; var cleaned = event; var stop = delta
                stop.removeValue(forKey: "stop_reason"); cleaned["delta"] = stop; stripped["event"] = cleaned
                return !RuntimeStreamExecutionHints.containsWork(stripped)
            default: return false
            }
        default: return false
        }
    }

    private mutating func copilot(_ frame: [String: Any]) -> Bool {
        guard let data = frame["data"] as? [String: Any],
              Set(frame.keys).isSubset(of: ["type", "data", "id", "timestamp", "parentId", "ephemeral"]),
              Self.ephemeralMetadata(frame["ephemeral"]) else { return false }
        switch frame["type"] as? String {
        case "assistant.message":
            guard Self.copilotMessageMetadata(data),
                  let requests = data["toolRequests"] as? [[String: Any]], !requests.isEmpty else { return false }
            for request in requests {
                guard Set(request.keys).isSubset(of: ["toolCallId", "name", "arguments", "type", "intentionSummary"]),
                      request["type"] == nil || request["type"] as? String == "function",
                      request["intentionSummary"] == nil || request["intentionSummary"] is NSNull || request["intentionSummary"] is String,
                      call(id: request["toolCallId"] as? String, name: request["name"] as? String,
                    input: request["arguments"], started: false) else { return false }
            }
            var stripped = frame; var cleaned = data; cleaned["toolRequests"] = []; stripped["data"] = cleaned
            return !RuntimeStreamExecutionHints.containsWork(stripped)
        case "assistant.tool_call_delta":
            guard Set(data.keys).isSubset(of: ["toolCallId", "toolName", "inputDelta", "toolType"]),
                  data["toolType"] == nil || data["toolType"] as? String == "function",
                  let id = data["toolCallId"] as? String, !id.isEmpty, !starts.contains(id),
                  let name = data["toolName"] as? String, ["Bash", "bash"].contains(name),
                  let fragment = data["inputDelta"] as? String,
                  (fragments[id]?.utf8.count ?? 0) + fragment.utf8.count <= 131_072 else { return false }
            if let existing = streamedNames[id], existing != name { return false }
            fragments[id, default: ""] += fragment; streamedNames[id] = name
            return true
        case "tool.execution_start":
            guard Set(data.keys).isSubset(of: ["toolCallId", "toolName", "arguments", "turnId", "model", "interactionId", "rte"]) else { return false }
            if let id = data["toolCallId"] as? String, let text = fragments.removeValue(forKey: id) {
                guard let name = streamedNames.removeValue(forKey: id),
                      let input = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                      call(id: id, name: name, input: input, started: false) else { return false }
            }
            return !RuntimeStreamExecutionHints.containsWork(frame)
                && call(id: data["toolCallId"] as? String, name: data["toolName"] as? String,
                    input: data["arguments"], started: true)
        case "tool.execution_complete":
            guard Set(data.keys).isSubset(of: ["toolCallId", "success", "result", "error", "turnId", "model", "interactionId", "rte"]) else { return false }
            return !RuntimeStreamExecutionHints.containsWork(frame) && result(data["toolCallId"] as? String)
        case "tool.execution_partial_result", "tool.execution_progress":
            // Account only for native textual output from the already-bound call.
            // Extra payload fields retain native-tool uncertainty.
            let outputKey = frame["type"] as? String == "tool.execution_partial_result" ? "partialOutput" : "progressMessage"
            guard Set(data.keys).isSubset(of: ["toolCallId", outputKey]),
                  data[outputKey] is String, let id = data["toolCallId"] as? String else { return false }
            return calls[id] != nil && starts.contains(id) && !completed.contains(id)
        default: return false
        }
    }

    private static func copilotMessageMetadata(_ data: [String: Any]) -> Bool {
        let strings: Set<String> = ["apiCallId", "clientRequestId", "content", "encryptedContent", "interactionId",
            "messageId", "model", "originatingMessageId", "phase", "providerId", "reasoningOpaque", "reasoningText",
            "reasoningWireField", "requestId", "serviceRequestId", "turnId"]
        let numbers: Set<String> = ["outputTokens", "chunkCount", "chunkIndex"]
        let allowed = strings.union(numbers).union(["toolRequests", "reasoningBlocks", "rte", "parentToolCallId", "serverTools"])
        guard Set(data.keys).isSubset(of: allowed), data["content"] is String,
              strings.allSatisfy({ data[$0] == nil || data[$0] is String }) else { return false }
        for key in numbers {
            guard let value = data[key] else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return false }
        }
        if let value = data["rte"] {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        }
        if let value = data["reasoningBlocks"] {
            // The native schema preserves provider reasoning as opaque JSON.
            // Only its descriptive envelope is accepted here; it grants no work.
            guard let reasoning = value as? [String: Any],
                  Set(reasoning.keys).isSubset(of: ["provider", "blocks", "orderedBlocks"]),
                  let provider = reasoning["provider"] as? String, !provider.isEmpty,
                  ["blocks", "orderedBlocks"].allSatisfy({ reasoning[$0] == nil || reasoning[$0] is [Any] }) else { return false }
        }
        // The shared work-hint guard validates parentToolCallId/serverTools,
        // including text-only messages which do not enter this helper branch.
        return true
    }

    // Captured native metadata is descriptive only in these exact shapes.
    // Indirect callers, malformed flags and added work fields stay uncertain.
    private static func directCaller(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let caller = value as? [String: Any] else { return false }
        return Set(caller.keys) == ["type"] && caller["type"] as? String == "direct"
    }

    private static func ephemeralMetadata(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return flag.boolValue
    }
}
