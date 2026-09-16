import Foundation

/// Trailing window on the sidebar's index rebuilds, for the changes that arrive
/// at stream rate.
///
/// `SidebarTaskStore` already coalesces the *fetch*, but the view's rebuild
/// trigger is `tasksVersion ^ taskActivitySignature`, and the activity half
/// moves on every turn-request write — a status landing, a blocker summary
/// changing, a request completing. Each move ran a full `SidebarTaskIndex`
/// build inside `withAnimation`, which re-lays out the whole rail. Production
/// logged 5,611 builds, 47% of them landing under a second after the previous
/// one.
///
/// Trailing only while changes keep arriving: the first one after a quiet
/// stretch still runs on the next main-actor turn, so a run starting or a
/// result landing animates in immediately rather than waiting out a window it
/// did not need. That is the same shape as `SidebarTaskStore.noteChanged`, for
/// the same reason — the deferral is what keeps the rebuild out of the view
/// update that asked for it.
///
/// A stable reference held in `@State`, so the pending work survives the view
/// struct being recreated underneath it.
@MainActor
final class SidebarTaskIndexRebuildScheduler {
    /// Matches `SidebarTaskStoreDefaults.coalesceInterval`. The two windows sit
    /// in series on the same signal, so a shorter one here would only add a
    /// second rebuild inside the store's window.
    /// `nonisolated` so it can be a default argument: the initializer is not
    /// main-actor-isolated at the point its defaults are evaluated.
    nonisolated static let defaultInterval: TimeInterval = 0.25

    private let interval: TimeInterval
    private var pending: Task<Void, Never>?
    private var lastRebuildAt = Date.distantPast

    init(interval: TimeInterval = SidebarTaskIndexRebuildScheduler.defaultInterval) {
        self.interval = interval
    }

    /// Runs `rebuild` on a trailing window, collapsing everything that arrives
    /// while one is already scheduled.
    func schedule(_ rebuild: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        let sinceLast = Date().timeIntervalSince(lastRebuildAt)
        pending = Task { [weak self] in
            guard let self else { return }
            if sinceLast < self.interval {
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            self.pending = nil
            rebuild()
        }
    }

    /// Stamps the window. Called by every rebuild, including the ones that
    /// bypass this scheduler — first appear, a search keystroke, a selection
    /// change — so a burst arriving straight after one of those is coalesced
    /// rather than treated as the first change in a quiet stretch.
    func noteRebuilt() {
        lastRebuildAt = Date()
    }

    /// Tears down with the view. A rebuild firing into a sidebar that has left
    /// the hierarchy is wasted work at best.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Whether a rebuild is waiting out the window. Nothing in the app reads
    /// it; a test that could not see the difference between "coalesced" and
    /// "never scheduled" would pass on the regression this exists to prevent.
    var hasPendingRebuildForTesting: Bool { pending != nil }
}
