import Foundation
import Observation
import SwiftData

/// Observes the snapshot's source, independently of SwiftUI query result sets.
/// Saves cover membership; model observation covers unsaved index-field writes.
@MainActor
final class SidebarTaskChangeObservation {
    private var saveObserver: NSObjectProtocol?
    private var generation = UUID()
    typealias ChangeHandler = @MainActor (_ membershipChanged: Bool, _ externallyUpdated: [PersistentIdentifier],
                                         _ deleted: Set<PersistentIdentifier>) -> Void
    private let onChange: ChangeHandler

    init(context: ModelContext, onChange: @escaping ChangeHandler) {
        self.onChange = onChange
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak context] notification in
            MainActor.assumeIsolated {
                guard let context, let source = notification.object as? ModelContext,
                      source.container === context.container else { return }
                let deleted = Set(Self.taskIdentifiers(for: .deletedIdentifiers, in: notification))
                let membershipChanged = !deleted.isEmpty || !Self.taskIdentifiers(for: .insertedIdentifiers, in: notification).isEmpty
                let taskUpdates = Self.taskIdentifiers(for: .updatedIdentifiers, in: notification)
                guard membershipChanged || !taskUpdates.isEmpty else { return }
                // Own-context task saves also release any foreign refreshes
                // deferred while the local task was dirty.
                let externalUpdates = source === context ? [] : taskUpdates
                onChange(membershipChanged, externalUpdates, deleted)
            }
        }
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
    }

    /// Re-armed after each reconcile. Several writes before the reconcile need
    /// only one signal, and an obsolete snapshot must not keep notifying it.
    func track<T>(_ read: () -> T) -> T {
        generation = UUID()
        let observedGeneration = generation
        return withObservationTracking(read) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == observedGeneration else { return }
                self.onChange(false, [], [])
            }
        }
    }

    private static func taskIdentifiers(for key: ModelContext.NotificationKey, in notification: Notification) -> [PersistentIdentifier] {
        let value = notification.userInfo?[key.rawValue]
        let identifiers = value as? [PersistentIdentifier] ?? Array(value as? Set<PersistentIdentifier> ?? [])
        return identifiers.filter { $0.entityName == "AgentTask" }
    }
}
