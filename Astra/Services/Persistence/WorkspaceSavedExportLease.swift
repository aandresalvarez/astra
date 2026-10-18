import Foundation
import SwiftData
import ASTRAModels

/// One observer per source context computes a save's scope once, regardless
/// of how many workspaces have projections queued. Only didSave retires the
/// affected tickets; failed saves cannot discard the last committed mirror.
final class WorkspaceSavedExportLease: @unchecked Sendable {
    private let observation: SavedExportContextObservation
    private let id: UUID
    let readTicket: WorkspaceAutoExportGate.ReadTicket
    @MainActor private(set) var writeTicket: WorkspaceAutoExportGate.Ticket?
    private let stateLock = NSLock()
    private var sealed = false
    var isSealed: Bool { stateLock.withLock { sealed } }
    var isCurrent: Bool {
        isSealed ? WorkspaceAutoExportGate.shared.isSealedCurrent(readTicket)
            : WorkspaceAutoExportGate.shared.isCurrent(readTicket)
    }

    @MainActor
    init(context: ModelContext, workspace: Workspace, ticket: WorkspaceAutoExportGate.ReadTicket) {
        readTicket = ticket
        observation = SavedExportContextObservation.shared(for: context)
        id = observation.insert(workspace: workspace, ticket: ticket)
    }

    @MainActor
    func seal() -> Bool {
        guard !Task.isCancelled, WorkspaceAutoExportGate.shared.isCurrent(readTicket) else { return false }
        stateLock.withLock { sealed = true }
        observation.seal(id)
        return true
    }

    @MainActor
    func promote() -> WorkspaceAutoExportGate.Ticket? {
        guard let ticket = WorkspaceAutoExportGate.shared.promote(readTicket, sealed: isSealed) else { return nil }
        writeTicket = ticket
        observation.publish(id, ticket: ticket)
        return ticket
    }

    deinit { observation.remove(id) }
}

private final class SavedExportContextObservation: @unchecked Sendable {
    private struct Entry {
        weak var workspace: Workspace?
        let ticket: WorkspaceAutoExportGate.ReadTicket
        let sourcePath: String
        var writeTicket: WorkspaceAutoExportGate.Ticket?
        var sealed = false
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
    private var withdrawn: Set<UUID>?
    private var observers: [NSObjectProtocol] = []
    @MainActor private weak var context: ModelContext?

    @MainActor
    static func shared(for context: ModelContext) -> SavedExportContextObservation {
        registryLock.withLock {
            registry = registry.filter { $0.value.value != nil }
            let key = ObjectIdentifier(context)
            if let existing = registry[key]?.value, existing.context === context { return existing }
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
                    self.entries.filter { WorkspaceAutoExportGate.shared.isCurrent($0.value.ticket)
                        || ($0.value.sealed && WorkspaceAutoExportGate.shared.isSealedCurrent($0.value.ticket))
                        || $0.value.writeTicket.map { WorkspaceAutoExportGate.shared.isCurrent($0) } == true }
                }
                guard !pending.isEmpty else {
                    self.lock.withLock { self.affected = []; self.withdrawn = [] }
                    return
                }
                let scope = WorkspaceExportChangeScope.capture(context)
                let affected = Set(pending.compactMap { id, entry -> UUID? in
                    guard let workspaceID = UUID(uuidString: entry.ticket.workspaceID),
                          scope.affects(entry.workspace, id: workspaceID) else { return nil }
                    return id
                })
                let withdrawn = Set(pending.compactMap { id, entry -> UUID? in
                    guard affected.contains(id), let workspace = entry.workspace,
                          workspace.isDeleted || workspace.primaryPath != entry.sourcePath else { return nil }
                    return id
                })
                self.lock.withLock { self.affected = affected; self.withdrawn = withdrawn }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave,
            object: context, queue: nil) { [weak self] _ in
            guard let self else { return }
            let tickets = self.lock.withLock {
                let reads = self.entries.compactMap { id, entry in
                    (self.affected?.contains(id) ?? true) ? entry.ticket : nil
                }
                let writes = self.entries.compactMap { id, entry in
                    (self.withdrawn?.contains(id) ?? true) ? entry.writeTicket : nil
                }
                let sealed = self.entries.compactMap { id, entry in
                    entry.sealed && (self.withdrawn?.contains(id) ?? true) ? entry.ticket : nil
                }
                self.affected = nil
                self.withdrawn = nil
                return (reads, writes, sealed)
            }
            for ticket in tickets.0 { WorkspaceAutoExportGate.shared.invalidateIfCurrent(ticket) }
            for ticket in tickets.1 { WorkspaceAutoExportGate.shared.invalidateIfCurrent(ticket) }
            for ticket in tickets.2 { WorkspaceAutoExportGate.shared.retireIfCurrentEpoch(ticket) }
        })
    }

    @MainActor
    func insert(workspace: Workspace, ticket: WorkspaceAutoExportGate.ReadTicket) -> UUID {
        let id = UUID()
        lock.withLock { entries[id] = Entry(workspace: workspace, ticket: ticket, sourcePath: workspace.primaryPath) }
        return id
    }

    func publish(_ id: UUID, ticket: WorkspaceAutoExportGate.Ticket) {
        lock.withLock { entries[id]?.writeTicket = ticket }
    }

    func seal(_ id: UUID) { lock.withLock { entries[id]?.sealed = true } }

    func remove(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
