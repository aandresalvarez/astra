import Foundation
import Observation
import SwiftData

/// An event-driven presentation snapshot. Saves refresh it; streaming model
/// writes never make SwiftUI fetch or diff the entire task/run tables.
@MainActor @Observable
final class UsageDashboardStore {
    typealias Read = @Sendable (ModelContainer, TimeFilter) async throws -> UsageDashboardSummary

    private(set) var summary: UsageDashboardSummary?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var timeFilter: TimeFilter = .allTime
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let read: Read

    init(read: @escaping Read = { container, filter in
        try await UsageDashboardReader(container: container).read(timeFilter: filter)
    }) {
        self.read = read
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func start(container: ModelContainer, timeFilter: TimeFilter) {
        if self.container !== container {
            stop()
            summary = nil
            self.container = container
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self, weak container] notification in
                MainActor.assumeIsolated {
                    guard let self, let container, let source = notification.object as? ModelContext,
                          source.container === container, Self.affectsUsage(notification) else { return }
                    self.refresh()
                }
            }
        }
        self.timeFilter = timeFilter
        refresh()
    }

    func stop() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        pending = false
        isRefreshing = false
        container = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() {
        guard let container else { return }
        pending = true
        guard worker == nil else { return }
        let generation = generation
        isRefreshing = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.worker = nil
                    self.isRefreshing = false
                }
            }
            while self.pending, !Task.isCancelled, self.generation == generation {
                self.pending = false
                let filter = self.timeFilter
                do {
                    let result = try await self.read(container, filter)
                    guard !Task.isCancelled, self.generation == generation else { return }
                    if filter == self.timeFilter {
                        if result != self.summary { self.summary = result }
                        if self.errorMessage != nil { self.errorMessage = nil }
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    if filter == self.timeFilter {
                        self.errorMessage = "Usage could not be refreshed. Try again."
                        PerformanceTelemetry.log("usage_summary_failed", level: .error)
                    }
                }
                // Coalesce saves arriving during a read without cancelling or
                // starving that read. A quiet user action refreshes immediately.
                if self.pending { try? await Task.sleep(for: .milliseconds(250)) }
            }
        }
    }

    private static func affectsUsage(_ notification: Notification) -> Bool {
        [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers].contains { key in
            let value = notification.userInfo?[key.rawValue]
            let ids = value as? [PersistentIdentifier] ?? Array(value as? Set<PersistentIdentifier> ?? [])
            return ids.contains { $0.entityName == "AgentTask" || $0.entityName == "TaskRun" }
        }
    }
}
