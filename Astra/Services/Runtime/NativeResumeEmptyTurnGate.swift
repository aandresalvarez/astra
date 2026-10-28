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

    /// Drops the held output of an attempt that is about to be re-run, handing it back so its
    /// usage can still be accounted for.
    @discardableResult
    func discard() -> [Line] {
        lock.lock()
        let dropped = held
        held = []
        lock.unlock()
        return dropped
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
        case .control, .started, .thinking, .stats, .usageMetadata:
            return false
        }
    }
}

/// The provider usage an attempt spent before it was discarded.
///
/// The re-run is a second process of the same run, so its token and cost
/// totals start at zero while the run's budget and spend do not. The discarded
/// attempt's final usage is added to every usage event the re-run reports, which
/// the recorder takes as that run's cumulative totals; if the re-run reports
/// none, it is recorded on its own once the re-run ends.
final class DiscardedAttemptUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: (input: Int, output: Int)?
    private var cost: Double?
    private var tokensApplied = false
    private var costApplied = false

    /// Tokens (input plus output) the discarded attempt spent.
    var totalTokens: Int {
        lock.lock()
        defer { lock.unlock() }
        return RuntimeUsageArithmetic.adding(tokens?.input ?? 0, tokens?.output ?? 0)
    }

    /// Takes the attempt's final usage, which is cumulative within its process.
    func record(from events: [AgentEvent]) {
        lock.lock()
        defer { lock.unlock() }
        for event in events {
            switch event {
            case .stats(let input, let output, let cost, _, _):
                tokens = (input, output)
                if let cost { self.cost = cost }
            case .usageMetadata(let cost, _, _):
                if let cost { self.cost = cost }
            default:
                break
            }
        }
    }

    func apply(to events: [AgentRuntimeRecordedEvent]) -> [AgentRuntimeRecordedEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard tokens != nil || cost != nil else { return events }
        return events.map { recorded in
            switch recorded {
            case .agent(.stats(let eventInput, let eventOutput, let eventCost, let duration, let turns)):
                tokensApplied = true
                costApplied = cost != nil
                return .agent(.stats(
                    inputTokens: RuntimeUsageArithmetic.adding(eventInput, tokens?.input ?? 0),
                    outputTokens: RuntimeUsageArithmetic.adding(eventOutput, tokens?.output ?? 0),
                    costUSD: addingCost(to: eventCost),
                    durationMs: duration,
                    turns: turns
                ))
            case .agent(.usageMetadata(let eventCost, let duration, let turns)):
                costApplied = cost != nil
                return .agent(.usageMetadata(costUSD: addingCost(to: eventCost), durationMs: duration, turns: turns))
            default:
                return recorded
            }
        }
    }

    private func addingCost(to current: Double?) -> Double? {
        current.map { min(Double.greatestFiniteMagnitude, $0 + (cost ?? 0)) } ?? cost
    }

    /// The discarded attempt's usage as an event of its own, when the re-run never reported any.
    func unappliedEvents() -> [AgentRuntimeRecordedEvent] {
        lock.lock()
        defer { lock.unlock() }
        let remainingCost = costApplied ? nil : cost
        if let tokens, !tokensApplied {
            tokensApplied = true
            costApplied = true
            return [.agent(.stats(inputTokens: tokens.input, outputTokens: tokens.output,
                costUSD: remainingCost, durationMs: nil, turns: nil))]
        }
        guard let remainingCost else { return [] }
        costApplied = true
        return [.agent(.usageMetadata(costUSD: remainingCost, durationMs: nil, turns: nil))]
    }
}
