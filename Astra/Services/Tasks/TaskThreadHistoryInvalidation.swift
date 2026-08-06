import Foundation

/// Announces transcript mutations that an incremental tail read provably cannot
/// observe.
///
/// `TaskThreadViewModel.applyTailPage` decides whether a tail read saw every
/// change by comparing the authoritative event count against
/// `historyTotalEventCount + appended`. That detects any *net* change, but a
/// mutation that deletes rows and inserts the same number of backdated rows
/// leaves the count untouched and lands entirely before the tail cursor.
/// `AgentEventCompactor` does exactly that when its preserve rules reduce
/// `toCompact` to one row: one delete plus one backdated `activity.compacted`
/// summary, net zero. No count-based invariant can see it, and the tail path
/// removed the periodic full read that used to self-heal it, so the deleted row
/// would keep rendering for the rest of the session.
///
/// The mutating service therefore says so. Tokens are globally monotonic, so a
/// reader that observes a different token than the one its last full read was
/// built from must re-read the whole page and replace what it accumulated.
@MainActor
enum TaskThreadHistoryInvalidation {
    /// Bounded so a long session cannot accumulate one entry per task ever
    /// compacted. Dropping an entry is safe in the conservative direction: the
    /// reader sees a token it does not recognize and pays one extra full read.
    private static let maxTrackedTasks = 256

    private static var sequence = 0
    private static var tokens: [UUID: Int] = [:]

    /// Call after mutating a task's durable events in a way a tail read cannot
    /// reconstruct from counts alone (deletions paired with backdated inserts).
    static func invalidate(taskID: UUID) {
        sequence += 1
        tokens[taskID] = sequence
        pruneIfNeeded()
    }

    /// The generation of the newest announced mutation for this task. `0` means
    /// none has been announced since launch.
    static func token(for taskID: UUID) -> Int {
        tokens[taskID] ?? 0
    }

    static func resetForTesting() {
        sequence = 0
        tokens.removeAll()
    }

    private static func pruneIfNeeded() {
        guard tokens.count > maxTrackedTasks else { return }
        let cutoff = tokens.values.sorted()[tokens.count / 2]
        tokens = tokens.filter { $0.value >= cutoff }
    }
}
