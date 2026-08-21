import Foundation
import SwiftData
import ASTRAModels

/// The one definition of how the sidebar reads `AgentTask` rows.
///
/// Three properties of this fetch are load-bearing and easy to break by
/// accident, so they live here with their reasons rather than inline at each
/// call site.
///
/// **It is never sorted.** `queuePosition` holds 0 for every row in a real
/// store and carries no index, so ordering on it made SQLite build a temp
/// B-tree and spill the entire result set — 10+ MB of `goal` text included —
/// to a temp file on every fetch. That fetch runs on the main thread inside
/// the SwiftUI view transaction. Every consumer re-sorts in Swift anyway.
/// Measured on a production-shaped store (726 tasks, 12.8 MB of payload):
/// 91.9 ms sorted against 64.4 ms unsorted, before counting the disk writes.
///
/// **It is never filtered by the search term.** `SidebarTaskIndex` needs the
/// whole set even while searching: its per-workspace running and waiting
/// counts deliberately ignore search so a collapsed drawer's live-work signal
/// cannot vanish because the query doesn't match. Filtering here would silence
/// those counts.
///
/// **It is never projected.** See `renderedProperties`.
enum SidebarTaskFetch {
    /// The columns the sidebar and its index actually read.
    ///
    /// Deliberately *not* passed as `propertiesToFetch`. Restricting the fetch
    /// to these is the obvious next optimisation and it does not work:
    /// measured at 74.8 ms against 64.4 ms for whole rows, because SwiftData
    /// still pays for the row and adds partial-fault bookkeeping on top. The
    /// same benchmark puts the floor from row width at 58.2 ms — moving `goal`
    /// into a side entity would buy about 6 ms for a custom migration across
    /// the whole schema history and 151 call sites, so that is not worth doing
    /// either.
    ///
    /// What the numbers do say: at ~64 ms a fetch, the cost that matters is
    /// how *often* the sidebar fetches, not how wide the rows are. That is
    /// `SidebarTaskStore`'s job.
    ///
    /// Kept here because `SidebarTaskFetchBenchmarkTests` measures against it,
    /// and because the list is the honest answer to "what does the sidebar
    /// need?" for anyone revisiting this.
    static let renderedProperties: [PartialKeyPath<AgentTask>] = [
        \AgentTask.id,
        \AgentTask.title,
        \AgentTask.status,
        \AgentTask.isPinned,
        \AgentTask.isDone,
        \AgentTask.unreadAt,
        \AgentTask.updatedAt,
        \AgentTask.originScheduleID,
        \AgentTask.workspace
    ]

    static func descriptor() -> FetchDescriptor<AgentTask> {
        FetchDescriptor<AgentTask>()
    }

    /// The query the sidebar view keeps purely to stay subscribed to
    /// `AgentTask` changes, while `SidebarTaskStore` owns the real fetch.
    ///
    /// SwiftData invalidates a `@Query` on any mutation to its model type, not
    /// just to rows in its result set — `SwiftDataQueryInvalidationBreadthTests`
    /// pins that. So a one-row fetch receives exactly the same signal as the
    /// unfiltered one it replaces, for a `LIMIT 1` instead of a 726-row read.
    ///
    /// Deliberately a limit rather than a never-matching predicate: a false
    /// predicate still makes SQLite scan every row, which is most of what we
    /// are trying to stop paying for.
    static func invalidationSignalDescriptor() -> FetchDescriptor<AgentTask> {
        var descriptor = FetchDescriptor<AgentTask>()
        descriptor.fetchLimit = 1
        return descriptor
    }
}
