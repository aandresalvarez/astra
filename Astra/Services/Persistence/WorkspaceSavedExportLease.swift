import Foundation
import SwiftData
import ASTRAModels

/// One observer per source context computes a save's scope once, regardless
/// of how many workspaces have projections queued. Only didSave retires the
/// affected tickets; failed saves cannot discard the last committed mirror.
final class WorkspaceSavedExportLease {
    private let observation: SavedExportContextObservation
    private let id: UUID

    @MainActor
    init(context: ModelContext, workspace: Workspace, ticket: WorkspaceAutoExportGate.Ticket) {
        observation = SavedExportContextObservation.shared(for: context)
        id = observation.insert(workspace: workspace, ticket: ticket)
    }

    deinit { observation.remove(id) }
}

private final class SavedExportContextObservation: @unchecked Sendable {
    private struct Entry {
        weak var workspace: Workspace?
        let ticket: WorkspaceAutoExportGate.Ticket
    }
    private final class WeakObservation {
        weak var value: SavedExportContextObservation?
        init(_ value: SavedExportContextObservation) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var registry: [ObjectIdentifier: WeakObservation] = [:]
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var affected: Set<UUID>?
    private var observers: [NSObjectProtocol] = []
    @MainActor private weak var context: ModelContext?

    @MainActor
    static func shared(for context: ModelContext) -> SavedExportContextObservation {
        registryLock.withLock {
            registry = registry.filter { $0.value.value != nil }
            let key = ObjectIdentifier(context)
            if let existing = registry[key]?.value { return existing }
            let observation = SavedExportContextObservation(context)
            registry[key] = WeakObservation(observation)
            return observation
        }
    }

    @MainActor
    private init(_ context: ModelContext) {
        self.context = context
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.willSave,
            object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let context = self.context else { return }
                let pending = self.lock.withLock {
                    self.entries.filter { WorkspaceAutoExportGate.shared.isCurrent($0.value.ticket) }
                }
                guard !pending.isEmpty else {
                    self.lock.withLock { self.affected = [] }
                    return
                }
                let scope = WorkspaceExportChangeScope.capture(context)
                let affected = Set(pending.compactMap { id, entry -> UUID? in
                    guard let workspaceID = UUID(uuidString: entry.ticket.workspaceID),
                          scope.affects(entry.workspace, id: workspaceID) else { return nil }
                    return id
                })
                self.lock.withLock { self.affected = affected }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave,
            object: context, queue: nil) { [weak self] _ in
            guard let self else { return }
            let tickets = self.lock.withLock {
                let tickets = self.entries.compactMap { id, entry in
                    (self.affected?.contains(id) ?? true) ? entry.ticket : nil
                }
                self.affected = nil
                return tickets
            }
            for ticket in tickets { WorkspaceAutoExportGate.shared.invalidateIfCurrent(ticket) }
        })
    }

    func insert(workspace: Workspace, ticket: WorkspaceAutoExportGate.Ticket) -> UUID {
        let id = UUID()
        lock.withLock { entries[id] = Entry(workspace: workspace, ticket: ticket) }
        return id
    }

    func remove(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
