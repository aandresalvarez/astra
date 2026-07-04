import Foundation

/// App-scoped, sliding-window rate limiter for connector reads (`astra.read`). The bridge's per-WebView
/// throttle + one-in-flight serialization bound a SINGLE surface; this bounds reads across ALL surfaces of
/// an app over TIME, so a long-lived multi-surface poller can't accrue unbounded audit runs or hammer a
/// connector. Shared in-process: durable across a session's surfaces (it resets on relaunch — but the run
/// log resets then too, so that's the right granularity for "bound audit-run growth").
///
/// Owned by `WorkspaceAppReadPolicy` / `WorkspaceAppCapabilityReadPipeline`. Async bridge reads are
/// admitted before a run record is created, so a rejected read leaves no audit row. Sync pipeline reads
/// share the same app-scoped budget once a run is already open, which prevents `astra.runAction` from
/// bypassing the connector-read cap.
final class WorkspaceAppConnectorReadRateLimiter: @unchecked Sendable {
    /// The shared limiter the executor consults. It MUST be process-wide (each read constructs a fresh
    /// `WorkspaceAppActionExecutor`, so a per-executor limiter would never accumulate and never limit).
    static let shared = WorkspaceAppConnectorReadRateLimiter()

    /// Max reads admitted per app within `window`. ~1/sec sustained — generous for legitimate refresh +
    /// state-toggle UX, tight enough to bound run growth + connector load from a runaway poller.
    let maxPerWindow: Int
    let window: TimeInterval

    private let lock = NSLock()
    private var history: [UUID: [Date]] = [:]

    init(maxPerWindow: Int = 60, window: TimeInterval = 60) {
        self.maxPerWindow = maxPerWindow
        self.window = window
    }

    /// Admit a read for `appID` at `now`, recording it. Returns false when the app is over budget for the
    /// trailing `window` (the caller then fails closed without creating a run record). Old entries are
    /// pruned on every call so memory stays bounded by active apps × maxPerWindow.
    func admit(appID: UUID, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        var recent = (history[appID] ?? []).filter { $0 > cutoff }
        guard recent.count < maxPerWindow else {
            history[appID] = recent
            return false
        }
        recent.append(now)
        history[appID] = recent
        return true
    }
}
