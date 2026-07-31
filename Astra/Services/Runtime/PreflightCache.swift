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
    public typealias ContextualHealthProbe = @Sendable (
        _ check: CLIContextualCheck,
        _ executablePath: String,
        _ workingDirectory: String
    ) async -> HealthStatus

    /// How long a result is considered fresh. Conservative; users will
    /// trigger a re-check on demand when they care.
    public static let defaultTTL: TimeInterval = 30

    private struct Entry {
        let status: HealthStatus
        let checkedAt: Date
    }

    private let checker: EnvironmentHealthChecker
    private let contextualProbe: ContextualHealthProbe
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    public init(
        checker: EnvironmentHealthChecker = EnvironmentHealthChecker(),
        ttl: TimeInterval = PreflightCache.defaultTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        contextualProbe: ContextualHealthProbe? = nil
    ) {
        self.checker = checker
        self.ttl = ttl
        self.now = now
        self.contextualProbe = contextualProbe ?? { check, executablePath, workingDirectory in
            switch check {
            case .githubRepositoryAccess:
                return await GitHubRepositoryAccessProbe().check(
                    ghPath: executablePath,
                    workingDirectory: workingDirectory
                ).healthStatus(executablePath: executablePath)
            }
        }
    }

    /// Returns the status for `prereq`. If the cached entry is within TTL,
    /// returns it without running any subprocess. Otherwise, probes and
    /// stores the result.
    public func status(
        for prereq: CLIPrerequisite,
        workingDirectory: String? = nil
    ) async -> HealthStatus {
        let key = cacheKey(for: prereq, workingDirectory: workingDirectory)
        if let cached = entries[key],
           now().timeIntervalSince(cached.checkedAt) < ttl {
            return cached.status
        }
        let checked = await checker.check(
            binary: prereq.binary,
            livenessArgs: prereq.livenessArgs,
            semantic: prereq.semantic
        )
        var fresh = normalizedStatus(checked, for: prereq)
        if case .healthy(let executablePath, _) = fresh,
           let contextualCheck = prereq.contextualCheck,
           let workingDirectory = normalizedWorkingDirectory(workingDirectory) {
            fresh = await contextualProbe(contextualCheck, executablePath, workingDirectory)
        }
        // A probe interrupted by caller cancellation is not a real result —
        // caching it would publish "unresponsive: cancelled" for 30s and
        // make an installed runtime look broken to every other consumer.
        guard !Task.isCancelled else {
            return entries[key]?.status ?? fresh
        }
        entries[key] = Entry(status: fresh, checkedAt: now())
        return fresh
    }

    private func cacheKey(
        for prereq: CLIPrerequisite,
        workingDirectory: String?
    ) -> String {
        guard prereq.contextualCheck != nil else { return prereq.id }
        return "\(prereq.id):workspace=\(normalizedWorkingDirectory(workingDirectory) ?? "host")"
    }

    private func normalizedWorkingDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).standardizingPath
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
        // A prereq's id embeds the binary + args, so prefix-match the key.
        let matching = entries.keys.filter { $0.hasPrefix("\(binary):") }
        for key in matching { entries.removeValue(forKey: key) }
    }

    /// For tests / debugging. Not part of the public UI contract.
    public func cachedStatus(
        for prereq: CLIPrerequisite,
        workingDirectory: String? = nil
    ) -> HealthStatus? {
        entries[cacheKey(for: prereq, workingDirectory: workingDirectory)]?.status
    }

    public func cachedCount() -> Int { entries.count }
}
