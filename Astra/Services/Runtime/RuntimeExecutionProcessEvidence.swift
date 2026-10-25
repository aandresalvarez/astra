import Foundation
import ASTRACore

/// A provider's terminal text or a model verdict never establishes cleanup.
/// Unattested native tools (including detached commands/remote work) conservatively
/// block recovery. A finished user turn can still be followed by a new user turn.
final class RuntimeExecutionProcessEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var toolsOrUnknownExecution = false
    private var terminalFrameSeen = false
    func observe(_ event: ParsedEvent) {
        switch event {
        case .toolUse, .toolResult, .teammateStarted, .teammateCompleted, .teamCreated, .teamMessage, .unknown:
            lock.withLock { toolsOrUnknownExecution = true }
        case .result: lock.withLock { terminalFrameSeen = true }
        case .control(let type):
            // Only known bookkeeping can attest a tool-free terminal stream.
            let bookkeeping: Set<String> = ["thinking.completed", "turn.started", "turn.completed",
                "stream_event.message_start", "stream_event.message_delta", "stream_event.message_stop",
                "stream_event.content_block_stop", "rate_limit_event.allowed", "rate_limit_event.allowed_warning",
                "rate_limit_event.rejected", "system.post_turn_summary", "system.status", "system.thinking_tokens"]
            if !bookkeeping.contains(type) { lock.withLock { toolsOrUnknownExecution = true } }
        default: break
        }
    }
    func observeFrame(_ line: String, parsesJSONLines: Bool, events: [ParsedEvent]) {
        if !parsesJSONLines || events.isEmpty || (try? JSONSerialization.jsonObject(with: Data(line.utf8))) == nil {
            lock.withLock { toolsOrUnknownExecution = true }
        }
        if let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           frame["type"] as? String == "stream_event", let partial = frame["event"] as? [String: Any],
           let type = partial["type"] as? String,
           type == "content_block_start" || type == "content_block_delta",
           !Self.isTypedTextBookkeeping("stream_event." + type, line: line) {
            // Presentation may project an unknown delta carrying text as .text.
            // That projection cannot establish a tool-free execution.
            lock.withLock { toolsOrUnknownExecution = true }
        }
        for event in events {
            if case .control(let type) = event, Self.isTypedTextBookkeeping(type, line: line) { continue }
            observe(event)
        }
    }

    /// The parser intentionally collapses block-start types for presentation.
    /// Cleanup evidence must inspect the original type before trusting that control.
    private static func isTypedTextBookkeeping(_ control: String, line: String) -> Bool {
        guard let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        if control == "assistant.block.text" || control == "assistant.final_copy", frame["type"] as? String == "assistant",
           let message = frame["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
            return blocks.allSatisfy { block in
                (block["type"] as? String == "text" && block["text"] is String)
                    || (block["type"] as? String == "thinking" && block["thinking"] is String)
            }
        }
        guard control == "stream_event.content_block_start" || control == "stream_event.content_block_delta",
              frame["type"] as? String == "stream_event",
              let event = frame["event"] as? [String: Any] else { return false }
        if control == "stream_event.content_block_start", event["type"] as? String == "content_block_start",
           let block = event["content_block"] as? [String: Any] {
            switch block["type"] as? String {
            case "text": return block["text"] is String
            case "thinking": return block["thinking"] is String
            default: return false
            }
        }
        if control == "stream_event.content_block_delta", event["type"] as? String == "content_block_delta",
           let delta = event["delta"] as? [String: Any] {
            switch delta["type"] as? String {
            case "text_delta": return delta["text"] is String
            case "thinking_delta": return delta["thinking"] is String
            case "signature_delta": return delta["signature"] is String
            default: return false
            }
        }
        return false
    }
    var toolsStopped: Bool { lock.withLock { terminalFrameSeen && !toolsOrUnknownExecution } }
}
