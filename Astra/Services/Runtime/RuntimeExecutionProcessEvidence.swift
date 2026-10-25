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
        for event in events { observe(event) }
    }
    var toolsStopped: Bool { lock.withLock { terminalFrameSeen && !toolsOrUnknownExecution } }
}
