import Foundation
import ASTRACore

/// TTL cache over `EnvironmentHealthChecker`. The catalog re-renders often
/// (every filter change, every tab switch) and every render would otherwise
/// re-probe every CLI — that hammers `which` for no benefit, and worse,
/// `--version` calls can be slow for some tools (java, gcloud first-run).
///
/// Keys are the `CLIPrerequisite.id` (binary + livenessArgs) so two
/// packages sharing the same probe share a single cache slot.
///
/// Thread-safe: the cache is a plain dictionary guarded by an NSLock.
/// Using a real `actor` would force every call site to `await`, which is
/// noisy in SwiftUI bodies. The lock holds for O(1) dictionary ops only.
public actor PreflightCache {
    /// How long a result is considered fresh. Conservative; users will
    /// trigger a re-check on demand when they care.
    public static let defaultTTL: TimeInterval = 30

    private struct Entry {
        let status: HealthStatus
        let checkedAt: Date
    }

    private let checker: EnvironmentHealthChecker
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    public init(
        checker: EnvironmentHealthChecker = EnvironmentHealthChecker(),
        ttl: TimeInterval = PreflightCache.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.checker = checker
        self.ttl = ttl
        self.now = now
    }

    /// Returns the status for `prereq`. If the cached entry is within TTL,
    /// returns it without running any subprocess. Otherwise, probes and
    /// stores the result.
    public func status(for prereq: CLIPrerequisite) async -> HealthStatus {
        if let cached = entries[prereq.id],
           now().timeIntervalSince(cached.checkedAt) < ttl {
            return cached.status
        }
        let checked = await checker.check(
            binary: prereq.binary,
            livenessArgs: prereq.livenessArgs,
            semantic: prereq.semantic
        )
        let fresh = normalizedStatus(checked, for: prereq)
        entries[prereq.id] = Entry(status: fresh, checkedAt: now())
        return fresh
    }

    private func normalizedStatus(_ status: HealthStatus, for prereq: CLIPrerequisite) -> HealthStatus {
        guard case .unresponsive(let detail) = status,
              prereq.authHint != nil,
              prereq.livenessArgs.contains(where: { $0.localizedCaseInsensitiveContains("auth") })
        else {
            return status
        }
        return .unauthenticated(detail: detail)
    }

    /// Drop all cached results. Use on app foreground / workspace switch.
    public func invalidateAll() {
        entries.removeAll()
    }

    /// Drop cached entries for a specific binary, across all probe
    /// variants. Used by the "Re-check" button and when a user runs an
    /// install action we know should change the status.
    public func invalidate(binary: String) {
        entries = entries.filter { _, entry in
            // A prereq's id embeds the binary + args, so we can't just
            // delete by prefix match without reconstructing the key.
            // Instead we keep a parallel index on insert.
            _ = entry
            return true
        }
        // Simpler: rebuild by walking and deleting matching keys.
        let matching = entries.keys.filter { $0.hasPrefix("\(binary):") }
        for key in matching { entries.removeValue(forKey: key) }
    }

    /// For tests / debugging. Not part of the public UI contract.
    public func cachedStatus(for prereq: CLIPrerequisite) -> HealthStatus? {
        entries[prereq.id]?.status
    }

    public func cachedCount() -> Int { entries.count }
}
