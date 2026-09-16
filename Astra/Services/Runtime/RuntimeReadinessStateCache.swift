import Foundation
import ASTRACore

/// The last provider-readiness answer, keyed by the settings it was computed
/// from.
///
/// Readiness depends on provider settings, not on which task is open — yet
/// every `TaskMainView` starts with empty states, so each task open re-probed
/// every CLI and showed "Checking provider" until the slowest one answered.
/// Serving the previous answer for the same settings makes a task open show
/// its provider immediately; the probe still runs once the answer is older
/// than `maxAge` or the settings change.
actor RuntimeReadinessStateCache {
    static let shared = RuntimeReadinessStateCache()

    struct Entry: Sendable {
        let configuration: RuntimeProviderAvailabilityConfiguration
        let states: [AgentRuntimeID: RuntimeReadinessState]
        let checkedAt: Date
    }

    private var entry: Entry?

    func states(
        for configuration: RuntimeProviderAvailabilityConfiguration,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> [AgentRuntimeID: RuntimeReadinessState]? {
        guard let entry,
              entry.configuration == configuration,
              now.timeIntervalSince(entry.checkedAt) <= maxAge else {
            return nil
        }
        return entry.states
    }

    func store(
        _ states: [AgentRuntimeID: RuntimeReadinessState],
        for configuration: RuntimeProviderAvailabilityConfiguration,
        now: Date = Date()
    ) {
        entry = Entry(configuration: configuration, states: states, checkedAt: now)
    }

    func removeAll() {
        entry = nil
    }
}
