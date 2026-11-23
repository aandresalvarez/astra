import Foundation
import ASTRACore

/// What a running run's stream last showed. Held in memory only: it is a view
/// of the live stream, never evidence, and nothing here is persisted.
struct RunLiveActivity: Equatable, Sendable {
    /// The last provider event of any kind, transient control frames included.
    var lastTrafficAt: Date
    /// The last event about an operation: a call, a result, partial output,
    /// or a background job ending.
    var lastOperationSignalAt: Date?
    /// The operation the newest partial activity named, while it is running.
    var activeOperationID: String?
}

/// The live activity of the runs streaming right now, keyed by run.
///
/// Source: every event the recorder is handed, before it decides what is
/// durable — so partial output that is never stored still refreshes it.
/// Cleared when the run's stream ends; a run it has no entry for (after a
/// relaunch, or once it has ended) is described from its stored events only.
/// Reading it changes nothing, and nothing reads it to decide task state.
final class RunLiveActivityStore: @unchecked Sendable {
    static let shared = RunLiveActivityStore()
    /// Entries a missed `finish` could leave behind are dropped at this age.
    static let staleInterval: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private var activityByRunID: [UUID: RunLiveActivity] = [:]

    func observe(_ event: AgentEvent, runID: UUID, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var activity = activityByRunID[runID] ?? RunLiveActivity(lastTrafficAt: now)
        activity.lastTrafficAt = now
        switch event {
        case .toolUse(_, let id, _):
            activity.lastOperationSignalAt = now
            activity.activeOperationID = id.isEmpty ? nil : id
        case .toolResult(let id, _, _):
            activity.lastOperationSignalAt = now
            if activity.activeOperationID == id { activity.activeOperationID = nil }
        case .operation(.progress(let operationID)):
            activity.lastOperationSignalAt = now
            activity.activeOperationID = operationID
        case .operation(.backgroundJobFinished), .fileChange:
            activity.lastOperationSignalAt = now
        default:
            break
        }
        if activityByRunID[runID] == nil, activityByRunID.count >= 32 {
            activityByRunID = activityByRunID.filter { now.timeIntervalSince($0.value.lastTrafficAt) < Self.staleInterval }
        }
        activityByRunID[runID] = activity
    }

    func activity(for runID: UUID) -> RunLiveActivity? {
        lock.lock()
        defer { lock.unlock() }
        return activityByRunID[runID]
    }

    /// The run's stream ended: nothing about it is live any more.
    func finish(runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activityByRunID[runID] = nil
    }
}
