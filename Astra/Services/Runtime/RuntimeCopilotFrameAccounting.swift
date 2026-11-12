import Foundation

/// Session bookkeeping that Copilot CLI 1.0.105 writes to stdout around a turn:
/// the user's reasoning settings, model routing, a configuration notice and
/// the usage checkpoint. Shapes come from isolated stdout captures
/// (Tests/Fixtures/ProviderStreams/copilot/*-1.0.105*.jsonl). None of them can
/// request or run a tool; every field outside the captured shape stays
/// uncertain, as does accounting that contradicts a tool-free turn.
extension RuntimeCopilotFrameMetadata {
    static func responsesReasoning(_ value: Any) -> Bool {
        guard let reasoning = value as? [String: Any] else { return false }
        return fields(reasoning, strings: ["effort", "initialEffort", "model"])
    }

    /// `categoryScores.tool_use` is the router's estimate of the prompt, made
    /// before any model call. It is not a count of tool calls.
    static func autoModeResolved(_ data: [String: Any]) -> Bool {
        fields(data, strings: ["chosenModel", "routingMethod", "selectionReason"], numbers: ["endToEndLatencyMs"],
            booleans: ["fallback", "hasImage"],
            special: ["availableModels": stringArray, "candidateModels": stringArray, "categoryScores": { value in
                guard let scores = value as? [String: Any] else { return false }
                return fields(scores, numbers: ["code_gen", "debugging", "reasoning", "tool_use"])
            }])
    }

    /// Only the captured notice kind: a statement about how the session is
    /// configured (for example which tools are disabled). Other kinds are unknown.
    static func configurationNotice(_ data: [String: Any]) -> Bool {
        data["infoType"] as? String == "configuration" && fields(data, strings: ["infoType", "message"])
    }

    static func usageCheckpoint(_ data: [String: Any]) -> Bool {
        guard data["accountingSnapshot"] != nil else { return false }
        return fields(data, numbers: ["totalNanoAiu", "totalPremiumRequests"], special: [
            "accountingSnapshot": accountingSnapshot, "providerModelMetrics": providerModelMetrics,
            "modelCacheState": objects { fields($0, strings: ["cacheExpiresAt", "modelId"], numbers: ["cacheTtlSeconds"]) },
            "promptCacheBreakState": objects(promptCacheConversation),
            "usageAccountingWatermarks": { ($0 as? [String: Any])?.values.allSatisfy(number) == true }])
    }

    private static func accountingSnapshot(_ value: Any) -> Bool {
        // Copilot accounts a session, not a turn: after `--resume` these totals
        // still include earlier turns. Recorded changes or a second agent
        // therefore keep the frame uncertain, like the result frame's own usage.
        guard let snapshot = value as? [String: Any], snapshot["codeChanges"] != nil,
              let agents = snapshot["agentMetrics"] as? [String: Any], Set(agents.keys) == ["main"] else { return false }
        return fields(snapshot, strings: ["aiCreditsStatus", "currentModel", "sessionStartTime"],
            numbers: ["lastCallInputTokens", "lastCallOutputTokens", "totalApiDurationMs", "totalNanoAiu",
                      "totalPremiumRequestCost", "totalUserRequests"],
            special: ["agentMetrics": { _ in
                guard let main = agents["main"] as? [String: Any] else { return false }
                return fields(main, numbers: ["totalApiDurationMs", "totalNanoAiu"], special: ["modelMetrics": modelMetrics])
            }, "codeChanges": noAccountedCodeChanges, "modelMetrics": { value in
                guard let models = value as? [String: Any] else { return false }
                return models.values.allSatisfy { metric($0, strings: ["aiCreditsStatus", "cacheExpiresAt"]) }
            }, "providerModelMetrics": providerModelMetrics, "tokenDetails": tokenDetails])
    }

    private static func noAccountedCodeChanges(_ value: Any) -> Bool {
        guard let changes = value as? [String: Any],
              Set(changes.keys) == ["linesAdded", "linesRemoved", "filesModifiedCount", "filesModified"],
              fields(changes, numbers: ["linesAdded", "linesRemoved", "filesModifiedCount"],
                     special: ["filesModified": stringArray]) else { return false }
        return ["linesAdded", "linesRemoved", "filesModifiedCount"].allSatisfy { (changes[$0] as? NSNumber)?.doubleValue == 0 }
            && (changes["filesModified"] as? [Any])?.isEmpty == true
    }

    private static func providerModelMetrics(_ value: Any) -> Bool {
        let entry: ([String: Any]) -> Bool = { entry in
            fields(entry, strings: ["modelDisplayName", "modelId"], special: [
                "metrics": { metric($0, strings: ["aiCreditsStatus"]) },
                "provider": { value in
                    guard let provider = value as? [String: Any] else { return false }
                    return fields(provider, strings: ["id", "kind", "label"])
                }])
        }
        return objects(entry)(value)
    }

    /// Prompt-cache diagnostics for the last model call of each conversation.
    /// `tools` lists the tool definitions offered to the model, not calls.
    /// `initiator` is `user` when the call answered the user's message and
    /// `agent` when it followed a tool result, so only `user` is tool-free.
    private static func promptCacheConversation(_ entry: [String: Any]) -> Bool {
        guard (entry["pendingRewriteSources"] as? [Any])?.isEmpty != false else { return false }
        return fields(entry, strings: ["conversation", "lastActiveModel"], special: [
            "pendingRewriteSources": { $0 is [Any] },
            "models": { value in
                guard let models = value as? [String: Any] else { return false }
                return models.values.allSatisfy { ($0 as? [String: Any]).map(promptCacheModel) == true }
            }])
    }

    private static func promptCacheModel(_ model: [String: Any]) -> Bool {
        guard model["initiator"] as? String == "user" else { return false }
        return fields(model, strings: ["api_endpoint", "cache_expires_at", "completed_at", "frontier_source",
                "github_request_id", "initiator", "model", "model_call_id", "reasoning_effort", "request_id",
                "session_mode", "transport", "vendor"],
            numbers: ["cache_read", "cache_write", "frontier_tokens", "prompt_tokens", "tool_count", "tool_tokens",
                      "tools_truncated", "ttl_seconds"],
            booleans: ["cache_details_reported"],
            special: ["cache_config": { value in
                guard let config = value as? [String: Any] else { return false }
                return fields(config, strings: ["arm", "system_prompt_layout"],
                    booleans: ["advisor_tool", "incremental_input", "marks_conversation", "marks_system_prompt"])
            }, "conversation": { value in
                guard let conversation = value as? [String: Any] else { return false }
                return fields(conversation, numbers: ["message_count"],
                    special: ["points": objects { fields($0, strings: ["hash"], numbers: ["index"]) }])
            }, "system_segments": objects { fields($0, strings: ["hash", "segment"], numbers: ["tokens"]) },
               "tools": objects { fields($0, strings: ["name", "schema_hash"], booleans: ["safe"]) }])
    }

    private static func objects(_ accepts: @escaping ([String: Any]) -> Bool) -> (Any) -> Bool {
        { ($0 as? [[String: Any]])?.allSatisfy(accepts) == true }
    }
}
