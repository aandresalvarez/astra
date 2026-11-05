import Foundation
import CoreFoundation

/// Metadata accepted as non-executing evidence, not a presentation schema.
/// Unknown native extensions remain uncertain even if the parser renders text.
/// The helper and ordinary frame classifier share the same message contract.
enum RuntimeCopilotFrameMetadata {
    static func accepts(_ frame: [String: Any]) -> Bool {
        guard envelope(frame), let type = frame["type"] as? String,
              let data = frame["data"] as? [String: Any] else { return false }
        switch type {
        case "assistant.message": return message(data)
        case "assistant.message_delta":
            return fields(data, strings: ["deltaContent", "messageId"], special: ["parentToolCallId": emptyParent])
        case "assistant.reasoning":
            return fields(data, strings: ["content", "reasoningId", "apiCallId", "model", "turnId"], booleans: ["rte", "isByok"])
        case "assistant.reasoning_delta":
            return fields(data, strings: ["deltaContent", "reasoningId"])
        case "user.message":
            return fields(data, strings: ["content", "messageId", "delivery", "interactionId", "parentAgentTaskId",
                "transformedContent", "turnId", "source", "agentMode"], booleans: ["isAutopilotContinuation"],
                special: ["supportedNativeDocumentMimeTypes": stringArray, "nativeDocumentPathFallbackPaths": stringArray,
                          "causalDependencies": stringArray])
        case "assistant.turn_start":
            return fields(data, strings: ["turnId", "interactionId", "model", "agentMode"], special: ["parentToolCallId": emptyParent])
        case "assistant.message_start": return fields(data, strings: ["messageId", "phase"])
        case "assistant.turn_end":
            return fields(data, strings: ["turnId", "model"], special: ["parentToolCallId": emptyParent])
        case "assistant.idle": return data.isEmpty
        case "model.call_start": return fields(data, strings: ["model", "turnId", "previousResponseId"])
        case "model.call_finished":
            return fields(data, strings: ["turnId", "outcome", "interactionId"],
                numbers: ["dispatchDurationMs", "editClassifierVersion"], booleans: ["containsBuiltInFileEditRequest"])
        case "model.call_failure":
            return fields(data, strings: ["errorMessage", "errorCode", "errorType", "message", "model", "apiCallId"],
                numbers: ["statusCode", "durationMs"], special: ["parentToolCallId": emptyParent])
        case "model.call_final_result": return fields(data, strings: ["model", "result"])
        case "session.error":
            return fields(data, strings: ["message", "errorCode", "errorType"], numbers: ["statusCode"])
        case "session.shutdown": return shutdown(data)
        case "session.mcp_server_status_changed": return fields(data, strings: ["serverName", "status"])
        case "session.mcp_server_tools_loaded": return fields(data, strings: ["serverName"], numbers: ["toolCount"])
        case "session.mcp_servers_loaded": return fields(data, special: ["servers": servers])
        case "session.tools_updated": return fields(data, strings: ["model"])
        case "session.auto_mode_resolved": return fields(data, strings: ["chosenModel"])
        default: return false
        }
    }

    private static func envelope(_ frame: [String: Any]) -> Bool {
        guard Set(frame.keys).isSubset(of: ["type", "data", "id", "timestamp", "parentId", "ephemeral"]),
              ["id", "timestamp"].allSatisfy({ frame[$0] == nil || frame[$0] is String }) else { return false }
        if let parent = frame["parentId"], !(parent is NSNull), !(parent is String) { return false }
        if let ephemeral = frame["ephemeral"] {
            guard boolean(ephemeral) else { return false }
            if let type = frame["type"] as? String,
               ["assistant.message_delta", "assistant.reasoning_delta"].contains(type),
               (ephemeral as? NSNumber)?.boolValue != true { return false }
        }
        // agentId identifies subagent-originated events. Neither an unknown
        // attribution shape nor a replay/checkpoint extension grants cleanup.
        return true
    }

    private static func message(_ data: [String: Any]) -> Bool {
        guard data["content"] is String else { return false }
        return fields(data, strings: ["apiCallId", "clientRequestId", "content", "encryptedContent", "interactionId",
            "messageId", "model", "originatingMessageId", "phase", "providerId", "reasoningOpaque", "reasoningText",
            "reasoningWireField", "requestId", "serviceRequestId", "turnId"],
            numbers: ["outputTokens", "chunkCount", "chunkIndex"], booleans: ["rte"],
            special: ["toolRequests": { $0 is [[String: Any]] }, "reasoningBlocks": reasoning,
                      "parentToolCallId": emptyParent,
                      "serverTools": { !RuntimeStreamExecutionHints.containsWork(["serverTools": $0]) }])
    }

    private static func reasoning(_ value: Any) -> Bool {
        // The provider schema explicitly declares these arrays opaque JSON.
        guard let object = value as? [String: Any], let provider = object["provider"] as? String,
              !provider.isEmpty else { return false }
        return fields(object, strings: ["provider"], special: ["blocks": { $0 is [Any] }, "orderedBlocks": { $0 is [Any] }])
    }

    private static func servers(_ value: Any) -> Bool {
        guard let servers = value as? [[String: Any]] else { return false }
        return servers.allSatisfy {
            $0["name"] is String && $0["status"] is String
                && fields($0, strings: ["name", "status", "source"])
        }
    }

    private static let tokenNumbers: [String] = ["inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
        "outputTokens", "output_tokens", "completionTokens", "completion_tokens", "cacheReadTokens", "cacheReadInputTokens",
        "cache_read_input_tokens", "cacheWriteTokens", "cacheCreationInputTokens", "cache_creation_input_tokens",
        "reasoningTokens", "costUSD", "cost_usd", "total_cost_usd"]

    private static func shutdown(_ data: [String: Any]) -> Bool {
        fields(data, strings: ["currentModel", "errorReason", "shutdownType"],
            numbers: ["conversationTokens", "currentTokens", "eventsFileSizeBytes", "sessionStartTime", "systemTokens",
                "toolDefinitionsTokens", "totalApiDurationMs", "durationMs", "duration_ms", "totalNanoAiu", "totalPremiumRequests"],
            special: ["modelMetrics": modelMetrics, "tokenDetails": tokenDetails, "codeChanges": noCodeChanges])
    }

    private static func modelMetrics(_ value: Any) -> Bool {
        guard let models = value as? [String: Any] else { return false }
        return models.values.allSatisfy { value in
            guard let metric = value as? [String: Any] else { return false }
            return fields(metric, numbers: tokenNumbers + ["totalNanoAiu"], special: [
                "usage": { value in
                    guard let usage = value as? [String: Any] else { return false }
                    return fields(usage, numbers: tokenNumbers)
                },
                "requests": { value in
                    guard let requests = value as? [String: Any] else { return false }
                    return fields(requests, numbers: ["count", "cost"])
                }, "tokenDetails": tokenDetails])
        }
    }

    private static func tokenDetails(_ value: Any) -> Bool {
        guard let details = value as? [String: Any] else { return false }
        return details.values.allSatisfy { value in
            guard let entry = value as? [String: Any], entry["tokenCount"] != nil else { return false }
            return fields(entry, numbers: ["tokenCount"])
        }
    }

    private static func noCodeChanges(_ value: Any) -> Bool {
        guard let changes = value as? [String: Any],
              Set(changes.keys) == ["linesAdded", "linesRemoved", "filesModified"],
              fields(changes, numbers: ["linesAdded", "linesRemoved"], special: ["filesModified": stringArray]) else { return false }
        return ["linesAdded", "linesRemoved"].allSatisfy { (changes[$0] as? NSNumber)?.doubleValue == 0 }
            && (changes["filesModified"] as? [String])?.isEmpty == true
    }

    private static func emptyParent(_ value: Any) -> Bool { value is NSNull || (value as? String)?.isEmpty == true }
    private static func stringArray(_ value: Any) -> Bool { value is [String] }
    private static func boolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    private static func number(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
    }

    private static func fields(_ object: [String: Any], strings: [String] = [], numbers: [String] = [],
                               booleans: [String] = [], special: [String: (Any) -> Bool] = [:]) -> Bool {
        let allowed = Set(strings).union(numbers).union(booleans).union(special.keys)
        guard Set(object.keys).isSubset(of: allowed) else { return false }
        for (key, value) in object {
            if strings.contains(key) { if !(value is String) { return false } }
            else if numbers.contains(key) { if !number(value) { return false } }
            else if booleans.contains(key) { if !boolean(value) { return false } }
            else if special[key]?(value) != true { return false }
        }
        return true
    }
}
