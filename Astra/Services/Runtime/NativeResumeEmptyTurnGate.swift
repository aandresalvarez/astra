import Foundation
import ASTRACore

/// Holds back the output of a natively resumed turn until it shows something
/// real, so a turn that comes back empty can be discarded and re-run without
/// the resume.
///
/// Some resumed turns end cleanly (exit 0) having emitted nothing but reasoning
/// events and no assistant message; Cursor does this on a minority of resumes
/// (3 of 8 with ASTRA's own prompts, 0 of 10 without `--resume`). Recording that
/// as the run would leave the user a "no usable result" failure for a turn the
/// same CLI answers fine from a fresh session.
///
/// Reasoning and bookkeeping events are held, and the first substantive event
/// (text, a tool call, a file change, a failure, an unfamiliar event type)
/// releases everything in order and turns the gate into a pass-through. A turn
/// that streams real work therefore sees no delay beyond its first reasoning
/// tokens.
final class NativeResumeEmptyTurnGate: @unchecked Sendable {
    typealias Line = (text: String, parsesJSONLines: Bool)

    private let lock = NSLock()
    private let isSubstantiveLine: (String, Bool) -> Bool
    private var held: [Line] = []
    private var released = false

    init(isSubstantiveLine: @escaping (String, Bool) -> Bool) {
        self.isSubstantiveLine = isSubstantiveLine
    }

    func accept(_ line: String, _ parsesJSONLines: Bool, forward: (String, Bool) -> Void) {
        lock.lock()
        if released {
            lock.unlock()
            forward(line, parsesJSONLines)
            return
        }
        guard isSubstantiveLine(line, parsesJSONLines) else {
            held.append((line, parsesJSONLines))
            lock.unlock()
            return
        }
        released = true
        let pending = held
        held = []
        lock.unlock()
        for item in pending { forward(item.text, item.parsesJSONLines) }
        forward(line, parsesJSONLines)
    }

    /// True when nothing substantive ever arrived.
    var producedNothing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !released
    }

    /// Forwards whatever is still held, for a turn that is not being retried
    /// (it failed, was cancelled, or ended without output for a reason the
    /// normal recording already explains).
    func flush(forward: (String, Bool) -> Void) {
        lock.lock()
        let pending = held
        held = []
        released = true
        lock.unlock()
        for item in pending { forward(item.text, item.parsesJSONLines) }
    }

    /// Drops the held output of an attempt that is about to be re-run.
    func discard() {
        lock.lock()
        held = []
        lock.unlock()
    }

    /// Whether an event is real output rather than reasoning or bookkeeping.
    /// An event type this code does not recognise counts as real: a turn must
    /// never be thrown away because it showed something unfamiliar.
    static func isSubstantive(_ event: AgentEvent) -> Bool {
        switch event {
        case .text, .assistantMessage, .toolUse, .toolResult, .fileChange, .permissionRequested,
             .astraProtocol, .failed, .notice, .teamEvent:
            return true
        case .completed(let summary):
            return !(summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .unknown(_, let type, _):
            return type.lowercased() != "thinking"
        case .control, .started, .thinking, .stats:
            return false
        }
    }
}
