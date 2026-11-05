import Foundation
import CoreFoundation
import ASTRACore

/// A pure, bounded contract for the helper exception. Validate structural
/// evidence before mutating call/fragment bookkeeping; text remains opaque.
enum RuntimeManagedSSHFrameMetadata {
    static func accepts(_ frame: [String: Any], runtime: AgentRuntimeID) -> Bool {
        switch runtime {
        case .copilotCLI: return copilot(frame)
        case .claudeCode, .cursorCLI: return acceptsClaudeFrame(frame)
        default: return false
        }
    }

    static func input(_ value: Any, allowEmpty: Bool = false) -> Bool {
        guard let input = value as? [String: Any], allowEmpty && input.isEmpty || input["command"] is String else { return false }
        return fields(input, strings: ["command", "description"], special: ["timeout": nonnegativeNumber, "timeout_ms": nonnegativeNumber])
    }

    private static func copilot(_ frame: [String: Any]) -> Bool {
        guard RuntimeCopilotFrameMetadata.acceptsEnvelope(frame), let type = frame["type"] as? String,
              let data = frame["data"] as? [String: Any] else { return false }
        if ["assistant.tool_call_delta", "tool.execution_progress", "tool.execution_partial_result"].contains(type),
           let ephemeral = frame["ephemeral"] as? NSNumber, !ephemeral.boolValue { return false }
        switch type {
        case "assistant.message":
            guard RuntimeCopilotFrameMetadata.accepts(frame), let requests = data["toolRequests"] as? [[String: Any]],
                  !requests.isEmpty else { return false }
            return requests.allSatisfy {
                $0["toolCallId"] is String && $0["name"] is String && $0["arguments"].map { input($0) } == true
                    && fields($0, strings: ["toolCallId", "name"], special: [
                        "arguments": { input($0) }, "type": { $0 as? String == "function" }, "intentionSummary": nullableString])
            }
        case "assistant.tool_call_delta":
            return requiredStrings(data, ["toolCallId", "toolName", "inputDelta"])
                && fields(data, strings: ["toolCallId", "toolName", "inputDelta"], special: ["toolType": { $0 as? String == "function" }])
        case "tool.execution_start":
            return requiredStrings(data, ["toolCallId", "toolName"]) && data["arguments"].map { input($0) } == true
                && fields(data, strings: ["toolCallId", "toolName", "turnId", "model", "interactionId"],
                    booleans: ["rte"], special: ["arguments": { input($0) }])
        case "tool.execution_complete":
            return data["toolCallId"] is String && data["success"].map(boolean) == true
                && fields(data, strings: ["toolCallId", "turnId", "model", "interactionId"], booleans: ["success", "rte"],
                    special: ["result": copilotResult, "error": copilotError])
        case "tool.execution_progress", "tool.execution_partial_result":
            let output = type == "tool.execution_progress" ? "progressMessage" : "partialOutput"
            return requiredStrings(data, ["toolCallId", output]) && fields(data, strings: ["toolCallId", output])
        default: return false
        }
    }

    private static func copilotResult(_ value: Any) -> Bool {
        guard let result = value as? [String: Any], result["content"] is String else { return false }
        return fields(result, strings: ["content", "detailedContent"], special: ["contents": { value in
            guard let blocks = value as? [[String: Any]] else { return false }
            return blocks.allSatisfy { block in
                switch block["type"] as? String {
                case "text": return requiredStrings(block, ["text"]) && fields(block, strings: ["type", "text"])
                case "terminal":
                    // Native terminal output can precede the command's exit.
                    return block["text"] is String && block["exitCode"].map(exitCode) == true
                        && fields(block, strings: ["type", "text", "cwd"], special: ["exitCode": exitCode])
                case "shell_exit":
                    return (block["shellId"] as? String)?.isEmpty == false && block["exitCode"].map(exitCode) == true
                        && fields(block, strings: ["type", "shellId", "cwd", "outputFilePath", "outputPreview"],
                            booleans: ["outputTruncated"], special: ["exitCode": exitCode])
                default: return false
                }
            }
        }])
    }

    private static func copilotError(_ value: Any) -> Bool {
        guard let error = value as? [String: Any], error["message"] is String else { return false }
        return fields(error, strings: ["message", "code"])
    }

    /// Also guards the existing ordinary Claude text/event classifier, so a
    /// rejected helper envelope cannot regain clean evidence as rendered text.
    static func acceptsClaudeFrame(_ frame: [String: Any]) -> Bool {
        guard let type = frame["type"] as? String,
              fields(frame, strings: ["type", "session_id", "uuid", "timestamp", "request_id", "user_message_uuid", "resume_reason"],
                special: ["parent_tool_use_id": { $0 is NSNull }, "user_message_uuids": { $0 is [String] },
                    "message": { $0 is [String: Any] }, "event": { $0 is [String: Any] },
                    "wire_tool_inputs": { $0 is [String: Any] }, "tool_use_result": claudeShellResult,
                    "ttft_ms": nonnegativeNumber]) else { return false }
        if frame["ttft_ms"] != nil,
           type != "stream_event" || (frame["event"] as? [String: Any])?["type"] as? String != "message_start" { return false }
        switch type {
        case "assistant", "user":
            guard frame["event"] == nil, let message = frame["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]], claudeMessage(message, role: type) else { return false }
            if type == "assistant" {
                return frame["tool_use_result"] == nil && wireInputs(frame["wire_tool_inputs"], blocks: blocks)
            }
            return frame["wire_tool_inputs"] == nil
                && (frame["tool_use_result"] == nil || blocks.count == 1 && blocks[0]["type"] as? String == "tool_result")
        case "stream_event":
            guard frame["message"] == nil, frame["wire_tool_inputs"] == nil, frame["tool_use_result"] == nil,
                  let event = frame["event"] as? [String: Any] else { return false }
            switch event["type"] as? String {
            case "message_start":
                guard let message = event["message"] as? [String: Any], claudeMessage(message, role: "assistant") else { return false }
                return fields(event, strings: ["type"], special: ["message": { _ in true }])
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any] else { return false }
                let valid = block["type"] as? String == "tool_use"
                    ? claudeToolUse(block, allowEmpty: true) : claudeBlock(block, role: "assistant")
                return event["index"].map(integer) == true && valid
                    && fields(event, strings: ["type"], special: ["index": integer, "content_block": { _ in true }])
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], let type = delta["type"] as? String,
                      let key = ["input_json_delta": "partial_json", "text_delta": "text", "thinking_delta": "thinking",
                        "signature_delta": "signature"][type], delta[key] is String else { return false }
                let optional: [String: (Any) -> Bool] = type == "thinking_delta"
                    ? ["estimated_tokens": { $0 is NSNull || integer($0) }] : [:]
                return event["index"].map(integer) == true && fields(delta, strings: ["type", key], special: optional)
                    && fields(event, strings: ["type"], special: ["index": integer, "delta": { _ in true }])
            case "content_block_stop":
                return event["index"].map(integer) == true && fields(event, strings: ["type"], special: ["index": integer])
            case "message_delta":
                guard let delta = event["delta"] as? [String: Any] else { return false }
                return fields(delta, special: ["stop_reason": stopReason, "stop_sequence": nullableString,
                    "stop_details": { $0 is NSNull }, "container": { $0 is NSNull }])
                    && fields(event, strings: ["type"], special: ["delta": { _ in true }, "usage": claudeUsage,
                        "context_management": contextManagement])
            case "message_stop": return fields(event, strings: ["type"])
            default: return false
            }
        default: return false
        }
    }

    private static func claudeMessage(_ message: [String: Any], role: String) -> Bool {
        guard message["role"] == nil || message["role"] as? String == role,
              let blocks = message["content"] as? [[String: Any]], blocks.allSatisfy({ claudeBlock($0, role: role) }) else { return false }
        return fields(message, strings: ["id", "model", "role"], special: [
            "type": { $0 as? String == "message" }, "content": { _ in true },
            "stop_reason": stopReason, "stop_sequence": nullableString, "container": { $0 is NSNull },
            "stop_details": { $0 is NSNull }, "diagnostics": { $0 is NSNull }, "usage": claudeUsage,
            "context_management": contextManagement, "input_transformations": emptyArray])
    }

    private static func claudeBlock(_ block: [String: Any], role: String) -> Bool {
        switch block["type"] as? String {
        case "tool_use": return role == "assistant" && claudeToolUse(block)
        case "tool_result":
            return role == "user" && block["tool_use_id"] is String && block["content"].map(claudeResultContent) == true
                && fields(block, strings: ["type", "tool_use_id"], booleans: ["is_error"], special: ["content": claudeResultContent])
        case "text": return block["text"] is String && fields(block, strings: ["type", "text"], special: ["citations": { $0 is NSNull || emptyArray($0) }])
        case "thinking": return block["thinking"] is String && fields(block, strings: ["type", "thinking", "signature"])
        default: return false
        }
    }

    private static func claudeToolUse(_ block: [String: Any], allowEmpty: Bool = false) -> Bool {
        requiredStrings(block, ["id", "name"]) && block["input"].map { input($0, allowEmpty: allowEmpty) } == true
            && fields(block, strings: ["type", "id", "name"], special: ["input": { input($0, allowEmpty: allowEmpty) },
                "caller": { value in
                    guard let caller = value as? [String: Any] else { return false }
                    return Set(caller.keys) == ["type"] && caller["type"] as? String == "direct"
                }])
    }

    private static func claudeResultContent(_ value: Any) -> Bool {
        if value is String { return true }
        guard let blocks = value as? [[String: Any]] else { return false }
        return blocks.allSatisfy { $0["type"] as? String == "text" && $0["text"] is String && fields($0, strings: ["type", "text"]) }
    }

    private static func wireInputs(_ value: Any?, blocks: [[String: Any]]) -> Bool {
        guard let value else { return true }
        guard let wire = value as? [String: Any] else { return false }
        let uses = blocks.filter { $0["type"] as? String == "tool_use" }
        let ids = uses.compactMap { $0["id"] as? String }
        guard ids.count == uses.count, Set(ids).count == ids.count, Set(wire.keys) == Set(ids) else { return false }
        return uses.allSatisfy { block in
            guard let id = block["id"] as? String, let observed = block["input"], let original = wire[id],
                  input(original), let lhs = try? JSONSerialization.data(withJSONObject: original, options: .sortedKeys),
                  let rhs = try? JSONSerialization.data(withJSONObject: observed, options: .sortedKeys) else { return false }
            return lhs == rhs
        }
    }

    private static func claudeShellResult(_ value: Any) -> Bool {
        guard let result = value as? [String: Any], requiredStrings(result, ["stdout", "stderr"]),
              result["interrupted"].map(boolean) == true, (result["interrupted"] as? NSNumber)?.boolValue == false else { return false }
        return fields(result, strings: ["stdout", "stderr"], booleans: ["interrupted", "noOutputExpected"],
            special: ["isImage": { boolean($0) && ($0 as? NSNumber)?.boolValue == false }, "exitCode": exitCode])
    }

    private static let usageCounts = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
    private static func claudeUsage(_ value: Any) -> Bool {
        guard let usage = value as? [String: Any] else { return false }
        return fields(usage, strings: ["service_tier", "inference_geo", "speed"], numbers: usageCounts, special: [
            "cache_creation": cacheCreation, "output_tokens_details": { object($0, numbers: ["thinking_tokens"]) },
            "server_tool_use": { value in
                guard let counters = value as? [String: Any], fields(counters, numbers: ["web_search_requests", "web_fetch_requests"]) else { return false }
                return counters.values.allSatisfy { ($0 as? NSNumber)?.doubleValue == 0 }
            }, "iterations": { value in
                guard let iterations = value as? [[String: Any]] else { return false }
                return iterations.allSatisfy { fields($0, numbers: usageCounts, special: [
                    "type": { $0 as? String == "message" }, "cache_creation": cacheCreation]) }
            }])
    }

    private static func cacheCreation(_ value: Any) -> Bool { object(value, numbers: ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]) }
    private static func object(_ value: Any, numbers: [String]) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return fields(object, numbers: numbers)
    }
    private static func contextManagement(_ value: Any) -> Bool {
        if value is NSNull { return true }
        guard let object = value as? [String: Any], Set(object.keys) == ["applied_edits"] else { return false }
        return object["applied_edits"].map(emptyArray) == true
    }
    private static func stopReason(_ value: Any) -> Bool {
        value is NSNull || ["tool_use", "end_turn", "stop_sequence", "max_tokens", "pause_turn", "refusal"].contains(value as? String ?? "")
    }
    private static func nullableString(_ value: Any) -> Bool { value is NSNull || value is String }
    private static func emptyArray(_ value: Any) -> Bool { (value as? [Any])?.isEmpty == true }
    private static func requiredStrings(_ object: [String: Any], _ keys: [String]) -> Bool { keys.allSatisfy { object[$0] is String } }
    private static func boolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    private static func exitCode(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    }
    private static func nonnegativeNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
    }
    private static func integer(_ value: Any) -> Bool { exitCode(value) && ((value as? NSNumber)?.doubleValue ?? -1) >= 0 }
    private static func fields(_ object: [String: Any], strings: [String] = [], numbers: [String] = [],
                               booleans: [String] = [], special: [String: (Any) -> Bool] = [:]) -> Bool {
        guard Set(object.keys).isSubset(of: Set(strings).union(numbers).union(booleans).union(special.keys)) else { return false }
        return object.allSatisfy { key, value in
            if strings.contains(key) { return value is String }
            if numbers.contains(key) { return integer(value) }
            if booleans.contains(key) { return boolean(value) }
            return special[key]?(value) == true
        }
    }
}
