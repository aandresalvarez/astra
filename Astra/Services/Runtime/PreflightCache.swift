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

    /// First-attempt liveness budget. Most CLIs answer in well under a second.
    public static let defaultProbeTimeout: TimeInterval = 3

    /// Budget for the single retry after a first attempt timed out. A
    /// Python-based CLI such as gcloud can take several seconds to start on a
    /// loaded machine (endpoint security scanning every import, a backup
    /// running), and a slow answer must not fail a task launch.
    public static let defaultSlowProbeRetryTimeout: TimeInterval = 15

    private struct Entry {
        let status: HealthStatus
        let checkedAt: Date
    }

    private struct InFlightProbe {
        let id: UUID
        let task: Task<HealthStatus, Never>
    }

    private let checker: EnvironmentHealthChecker
    private let contextualProbe: ContextualHealthProbe
    private let ttl: TimeInterval
    private let probeTimeout: TimeInterval
    private let slowProbeRetryTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlightProbe] = [:]

    public init(
        checker: EnvironmentHealthChecker = EnvironmentHealthChecker(),
        ttl: TimeInterval = PreflightCache.defaultTTL,
        probeTimeout: TimeInterval = PreflightCache.defaultProbeTimeout,
        slowProbeRetryTimeout: TimeInterval = PreflightCache.defaultSlowProbeRetryTimeout,
        now: @escaping @Sendable () -> Date = { Date() },
        contextualProbe: ContextualHealthProbe? = nil
    ) {
        self.checker = checker
        self.ttl = ttl
        self.probeTimeout = probeTimeout
        self.slowProbeRetryTimeout = slowProbeRetryTimeout
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
    /// stores the result. Concurrent callers for the same key share one
    /// probe, so a launch and a catalog refresh never spawn the same CLI
    /// twice at once on an already busy machine.
    public func status(
        for prereq: CLIPrerequisite,
        workingDirectory: String? = nil
    ) async -> HealthStatus {
        let key = cacheKey(for: prereq, workingDirectory: workingDirectory)
        if let cached = entries[key],
           now().timeIntervalSince(cached.checkedAt) < ttl {
            return cached.status
        }
        if let running = inFlight[key] {
            return await running.task.value
        }
        // The probe runs unstructured so one caller's cancellation cannot
        // cut it short for the others; its result is always a real answer
        // and is safe to cache.
        let probe = InFlightProbe(id: UUID(), task: Task {
            await self.probe(prereq, workingDirectory: workingDirectory)
        })
        inFlight[key] = probe
        let fresh = await probe.task.value
        // An invalidation while the probe ran drops it from `inFlight`; its
        // answer predates the invalidation and must not be cached.
        if inFlight[key]?.id == probe.id {
            inFlight[key] = nil
            entries[key] = Entry(status: fresh, checkedAt: now())
        }
        return fresh
    }

    private func probe(
        _ prereq: CLIPrerequisite,
        workingDirectory: String?
    ) async -> HealthStatus {
        var checked = await checker.check(
            binary: prereq.binary,
            livenessArgs: prereq.livenessArgs,
            semantic: prereq.semantic,
            timeout: probeTimeout
        )
        if checked.isLivenessTimeout, slowProbeRetryTimeout > probeTimeout {
            let retried = await checker.check(
                binary: prereq.binary,
                livenessArgs: prereq.livenessArgs,
                semantic: prereq.semantic,
                timeout: slowProbeRetryTimeout
            )
            AppLogger.info(
                "capability.prerequisite_probe_retried prerequisite=\(prereq.id) first_timeout_s=\(Int(probeTimeout)) retry_timeout_s=\(Int(slowProbeRetryTimeout)) result=\(retried.isUsable ? "usable" : retried.isLivenessTimeout ? "timed_out" : "failed")",
                category: "Capabilities"
            )
            checked = retried
        }
        var fresh = normalizedStatus(checked, for: prereq)
        if case .healthy(let executablePath, _) = fresh,
           let contextualCheck = prereq.contextualCheck,
           let workingDirectory = normalizedWorkingDirectory(workingDirectory) {
            fresh = await contextualProbe(contextualCheck, executablePath, workingDirectory)
        }
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
        // A timeout is a slow machine, not a signed-out CLI: telling the
        // user to log in again would send them to re-run a login that can
        // drop scopes they rely on (gcloud's `--enable-gdrive-access`).
        guard case .unresponsive(let detail) = status,
              !status.isLivenessTimeout,
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
        inFlight.removeAll()
    }

    /// Drop cached entries for a specific binary, across all probe
    /// variants. Used by the "Re-check" button and when a user runs an
    /// install action we know should change the status.
    public func invalidate(binary: String) {
        // A prereq's id embeds the binary + args, so prefix-match the key.
        let matching = entries.keys.filter { $0.hasPrefix("\(binary):") }
        for key in matching { entries.removeValue(forKey: key) }
        for key in inFlight.keys where key.hasPrefix("\(binary):") {
            inFlight.removeValue(forKey: key)
        }
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
