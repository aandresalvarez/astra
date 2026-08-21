import Foundation
import ASTRAModels

/// The fingerprint that decides when `SidebarTaskIndex` has to be rebuilt.
///
/// It touches every task in the sidebar's snapshot, so what it *doesn't* read
/// matters as much as what it does. Production telemetry caught it at 283 calls
/// totalling 1,011 ms inside one 30 s window — 3.4% of wall clock — in 3.5 ms
/// slices that each stayed under the 8 ms log threshold and so never surfaced
/// as an event. Four terms were removed on that evidence:
///
/// - **`title` and `goal`, hashed whenever a search was active.** A real store
///   holds 10.85 MB of `goal` text across 726 rows, so an active search meant
///   hashing 10.85 MB per call. Redundant as well as ruinous: every writer of
///   either field bumps `updatedAt`, which is hashed unconditionally, and
///   `searchText` itself already drives its own `onChange` in the sidebar.
/// - **`shouldShowUnread`**, which is defined as `unreadAt != nil` and so can
///   never move without the `unreadAt` term moving too.
/// - **A `Set<UUID>` of workspace IDs**, allocated and grown on every call to
///   populate a `workspace_count` telemetry field that is discarded on every
///   call that comes in under threshold — which is nearly all of them.
///
/// The two date terms now hash the `Date` rather than truncating it to whole
/// seconds. That is the same cost, cannot trap on an out-of-range interval, and
/// closes a real blind spot: two writes inside one second used to be
/// indistinguishable.
///
/// **Do not call this from a SwiftUI `body`.** Reading a field off every task
/// registers an observation dependency on all of them, so a view that
/// fingerprints the snapshot inline re-runs on any field write to any task —
/// and `AgentEventRecorder` writes `updatedAt` for every streamed event. That
/// made the fingerprint both the cost and its own trigger. `SidebarTaskStore`
/// owns the call and publishes the result as `tasksVersion`.
enum SidebarTaskIndexInvalidation {
    static func signature(for tasks: [AgentTask]) -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        let signature = tasks.reduce(into: 0) { acc, task in
            acc ^= task.id.hashValue
            if let workspaceID = task.workspace?.id {
                acc ^= workspaceID.hashValue
            }
            acc ^= task.status.rawValue.hashValue
            acc ^= task.isPinned ? 1 : 0
            acc ^= task.isDone ? 2 : 0
            acc &+= task.updatedAt.hashValue
            acc &+= task.unreadAt?.hashValue ?? 0
        }
        PerformanceTelemetry.logIfNeeded(
            "sidebar_index_signature",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: ["task_count": PerformanceTelemetryFields.count(tasks.count)]
        )
        return signature
    }
}
