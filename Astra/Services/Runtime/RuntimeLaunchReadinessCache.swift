import Foundation
import ASTRACore

/// The last ready verdict from the launch-time readiness preflight, per
/// runtime, so a follow-up turn does not re-prove what the previous one just
/// proved.
///
/// The source of truth is still the readiness probe: this only remembers its
/// answer, keyed by the exact `RuntimeReadinessConfiguration` it was computed
/// from, and forgets it after `maxAge` or the moment the settings change.
///
/// Only a fully `.ready` report is remembered. A warning means a probe gave no
/// answer, and a block means it found a problem; neither is proof, and a retry
/// after the user fixes something must always re-probe rather than replay a
/// stale failure.
///
/// Caching is opt-in at the call site: `AgentRuntimeWorker` holds one only
/// when production composition hands it `.shared`. A default would let a test
/// inherit another test's verdict for an identical configuration.
actor RuntimeLaunchReadinessCache {
    static let shared = RuntimeLaunchReadinessCache()

    /// Five minutes: long enough to cover a run of quick follow-up turns, short
    /// enough that a sign-in changed in a terminal is noticed on the next probe.
    static let defaultMaxAge: TimeInterval = 300

    struct Hit: Sendable, Equatable {
        let report: RuntimeReadinessReport
        let age: TimeInterval
    }

    private struct Entry {
        let configuration: RuntimeReadinessConfiguration
        let report: RuntimeReadinessReport
        let checkedAt: Date
    }

    private var entries: [AgentRuntimeID: Entry] = [:]

    func hit(
        for configuration: RuntimeReadinessConfiguration,
        maxAge: TimeInterval = RuntimeLaunchReadinessCache.defaultMaxAge,
        now: Date = Date()
    ) -> Hit? {
        guard let entry = entries[configuration.runtime],
              entry.configuration == configuration else {
            return nil
        }
        let age = now.timeIntervalSince(entry.checkedAt)
        guard age >= 0, age <= maxAge else { return nil }
        return Hit(report: entry.report, age: age)
    }

    /// Remembers a ready report and forgets anything else, so the entry for a
    /// runtime is never older than its most recent fully-ready probe.
    func record(
        _ report: RuntimeReadinessReport,
        for configuration: RuntimeReadinessConfiguration,
        now: Date = Date()
    ) {
        guard report.state == .ready else {
            entries[configuration.runtime] = nil
            return
        }
        entries[configuration.runtime] = Entry(configuration: configuration, report: report, checkedAt: now)
    }

    func removeAll() {
        entries = [:]
    }
}
