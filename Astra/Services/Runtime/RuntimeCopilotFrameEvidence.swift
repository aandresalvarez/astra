import Foundation

enum RuntimeCopilotFrameEvidence {
    typealias Kind = RuntimeProviderFrameEvidence.Kind
    static func classify(_ frame: [String: Any]) -> Kind {
        guard let type = frame["type"] as? String else { return .uncertain }
        if type == "result" {
            return frame["exitCode"] is Int && !(frame["sessionId"] as? String ?? "").isEmpty ? .terminal : .uncertain
        }
        if type == "usage" || type == "stats" { return .bookkeeping }
        guard let data = frame["data"] as? [String: Any] else { return .uncertain }
        if let requests = data["toolRequests"], (requests as? [Any])?.isEmpty != true { return .uncertain }
        switch type {
        case "assistant.message", "assistant.message_delta", "assistant.reasoning", "assistant.reasoning_delta", "user.message":
            return data["content"] is String || data["deltaContent"] is String ? .activity : .uncertain
        case "assistant.turn_start", "assistant.message_start":
            return data["turnId"] is String || data["messageId"] is String ? .activity : .uncertain
        case "assistant.turn_end": return data["turnId"] is String ? .bookkeeping : .uncertain
        case "assistant.idle": return data.isEmpty ? .bookkeeping : .uncertain
        case "model.call_start": return data["model"] is String ? .activity : .uncertain
        case "model.call_finished": return data["turnId"] is String && data["outcome"] is String ? .bookkeeping : .uncertain
        case "model.call_failure": return data["errorMessage"] is String ? .activity : .uncertain
        case "model.call_final_result": return data["model"] is String && data["result"] is String ? .bookkeeping : .uncertain
        case "session.error": return data["message"] is String ? .activity : .uncertain
        case "session.shutdown": return data["modelMetrics"] is [String: Any] ? .bookkeeping : .uncertain
        case "session.mcp_server_status_changed": return data["serverName"] is String && data["status"] is String ? .bookkeeping : .uncertain
        case "session.mcp_server_tools_loaded": return data["serverName"] is String && data["toolCount"] is Int ? .bookkeeping : .uncertain
        case "session.mcp_servers_loaded": return data["servers"] is [Any] ? .bookkeeping : .uncertain
        case "session.tools_updated": return data["model"] is String ? .bookkeeping : .uncertain
        case "session.auto_mode_resolved": return data["chosenModel"] is String ? .bookkeeping : .uncertain
        default: return .uncertain
        }
    }
}
