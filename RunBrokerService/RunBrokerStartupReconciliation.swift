import Foundation

public enum RunBrokerStartupRollout: Equatable, Sendable {
    case dormant
    case enabled
}

/// Coalesces window/app bootstrap races into one broker reconciliation. It has
/// no installer dependency and cannot create or reload a LaunchAgent.
public actor RunBrokerStartupReconciler {
    private var inFlight: Task<Void, Error>?

    public init() {}

    public func reconcileOnce(
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }
}

/// Testable ordering seam for app startup. When rollout is enabled, broker
/// reconciliation must finish before legacy orphan repair or task-queue drain.
/// PR7 leaves the app composition at `.dormant`.
public struct RunBrokerStartupOrdering: Sendable {
    private let reconciler: RunBrokerStartupReconciler

    public init(reconciler: RunBrokerStartupReconciler = .init()) {
        self.reconciler = reconciler
    }

    public func perform(
        rollout: RunBrokerStartupRollout,
        reconcileBroker: @escaping @Sendable () async throws -> Void,
        recoverLegacyOrphans: @escaping @Sendable () async throws -> Void,
        drainTaskQueue: @escaping @Sendable () async throws -> Void
    ) async throws {
        if rollout == .enabled {
            try await reconciler.reconcileOnce(operation: reconcileBroker)
        }
        try await recoverLegacyOrphans()
        try await drainTaskQueue()
    }
}
