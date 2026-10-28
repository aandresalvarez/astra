import Foundation
import ASTRACore

/// A stricter contract than the presentation parsers: projecting unfamiliar JSON
/// as readable text must never turn it into proof that no tools were launched.
enum RuntimeProviderFrameEvidence {
    enum Kind { case activity, bookkeeping, terminal, openCodeStop, uncertain }

    static func classify(_ frame: [String: Any], runtime: AgentRuntimeID) -> Kind {
        if RuntimeStreamExecutionHints.containsWork(frame) { return .uncertain }
        switch runtime {
        case .claudeCode, .cursorCLI: return claude(frame, cursor: runtime == .cursorCLI)
        case .codexCLI: return codex(frame)
        case .copilotCLI: return RuntimeCopilotFrameEvidence.classify(frame)
        case .antigravityCLI: return antigravity(frame)
        case .openCodeCLI: return openCode(frame)
        default: return .uncertain
        }
    }

    private static func claude(_ frame: [String: Any], cursor: Bool) -> Kind {
        if let parent = frame["parent_tool_use_id"], !(parent is NSNull) { return .uncertain }
        switch frame["type"] as? String {
        case "system":
            switch frame["subtype"] as? String {
            case "init": return .activity
            case "status", "thinking_tokens", "post_turn_summary": return .bookkeeping
            case "commands_changed": return frame["commands"] is [Any] ? .bookkeeping : .uncertain
            default: return .uncertain
            }
        case "assistant", "user":
            guard let message = frame["message"] as? [String: Any], textBlocks(message["content"]) else { return .uncertain }
            if let role = message["role"] as? String, role != frame["type"] as? String { return .uncertain }
            return .activity
        case "thinking" where cursor:
            switch frame["subtype"] as? String {
            case "delta": return frame["text"] is String ? .activity : .uncertain
            case "completed": return frame["text"] == nil ? .bookkeeping : .uncertain
            default: return .uncertain
            }
        case "result": return frame["is_error"] is Bool ? .terminal : .uncertain
        case "rate_limit_event":
            let info = frame["rate_limit_info"] as? [String: Any]
            return ["allowed", "allowed_warning", "rejected"].contains(info?["status"] as? String ?? "") ? .bookkeeping : .uncertain
        case "stream_event" where !cursor:
            guard let event = frame["event"] as? [String: Any] else { return .uncertain }
            switch event["type"] as? String {
            case "message_start":
                guard let message = event["message"] as? [String: Any], textBlocks(message["content"]) else { return .uncertain }
                return .activity
            case "message_delta":
                guard let delta = event["delta"] as? [String: Any],
                      !RuntimeStreamExecutionHints.containsWork(delta) else { return .uncertain }
                return .bookkeeping
            case "message_stop", "content_block_stop": return .bookkeeping
            case "content_block_start": return textBlocks([event["content_block"] as Any]) ? .activity : .uncertain
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { return .uncertain }
                let keys = ["text_delta": "text", "thinking_delta": "thinking", "signature_delta": "signature"]
                guard let key = keys[delta["type"] as? String ?? ""], delta[key] is String else { return .uncertain }
                return .activity
            default: return .uncertain
            }
        default: return .uncertain
        }
    }

    private static func textBlocks(_ value: Any?) -> Bool {
        guard let blocks = value as? [[String: Any]] else { return false }
        return blocks.allSatisfy { block in
            (block["type"] as? String == "text" && block["text"] is String)
                || (block["type"] as? String == "thinking" && block["thinking"] is String)
        }
    }

    private static func codex(_ frame: [String: Any]) -> Kind {
        switch frame["type"] as? String {
        case "thread.started": return frame["thread_id"] is String ? .activity : .uncertain
        case "turn.started": return .activity
        case "turn.completed": return .terminal
        case "item.started", "item.completed":
            guard let item = frame["item"] as? [String: Any], item["id"] is String,
                  ["agent_message", "reasoning"].contains(item["type"] as? String ?? ""),
                  item["tool"] == nil, item["name"] == nil, item["toolRequests"] == nil else { return .uncertain }
            return frame["type"] as? String == "item.started" || item["text"] is String ? .activity : .uncertain
        default: return .uncertain
        }
    }

    private static func antigravity(_ frame: [String: Any]) -> Kind {
        switch frame["event"] as? String {
        case "init": return frame["init"] is [String: Any] ? .activity : .uncertain
        case "result":
            let result = frame["result"] as? [String: Any]
            return ["SUCCESS", "ERROR", "FAILED"].contains(result?["status"] as? String ?? "") ? .terminal : .uncertain
        case "step_update":
            guard let step = frame["step_update"] as? [String: Any],
                  let index = step["step_index"] as? Int, index >= 0,
                  step["tool_name"] == nil, step["tool_info"] == nil,
                  step["text_delta"] == nil || step["text_delta"] is String else { return .uncertain }
            let state = step["state"] as? String
            switch step["step_type"] as? String {
            case "user_input": return state == "DONE" ? .activity : .uncertain
            case "system_message":
                // Native continuation can insert a completed context update.
                // Only the captured metadata shape is harmless; unfamiliar
                // fields or unfinished steps still preserve uncertainty.
                let keys: Set<String> = ["conversation_id", "step_index", "state", "step_type", "duration_seconds"]
                return state == "DONE" && Set(step.keys).isSubset(of: keys) ? .bookkeeping : .uncertain
            case "agent_response": return state == "ACTIVE" || state == "DONE" ? .activity : .uncertain
            default: return .uncertain
            }
        default: return .uncertain
        }
    }

    private static func openCode(_ frame: [String: Any]) -> Kind {
        guard let session = frame["sessionID"] as? String, !session.isEmpty,
              let part = frame["part"] as? [String: Any],
              part["sessionID"] as? String == session, part["id"] is String,
              part["messageID"] is String else { return .uncertain }
        switch (frame["type"] as? String, part["type"] as? String) {
        case ("step_start", "step-start"): return .activity
        case ("text", "text"), ("reasoning", "reasoning"):
            return part["text"] is String ? .activity : .uncertain
        case ("step_finish", "step-finish"):
            // OpenCode CLI does not emit session-idle. Only the last stop step
            // plus an owned, natural zero exit and full stdout EOF can substitute.
            return part["reason"] as? String == "stop" ? .openCodeStop : .uncertain
        default: return .uncertain
        }
    }
}
