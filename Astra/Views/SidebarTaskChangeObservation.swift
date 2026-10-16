import Foundation
import Observation
import SwiftData

/// Observes the snapshot's source, independently of SwiftUI query result sets.
/// Saves cover membership; model observation covers unsaved index-field writes.
@MainActor
final class SidebarTaskChangeObservation {
    private var saveObserver: NSObjectProtocol?
    private var generation = UUID()
    private let onChange: @MainActor (Bool, [PersistentIdentifier]) -> Void

    init(context: ModelContext, onChange: @escaping @MainActor (Bool, [PersistentIdentifier]) -> Void) {
        self.onChange = onChange
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak context] notification in
            MainActor.assumeIsolated {
                guard let context, let source = notification.object as? ModelContext,
                      source.container === context.container else { return }
                let membershipChanged = [ModelContext.NotificationKey.insertedIdentifiers, .deletedIdentifiers].contains { key in
                    Self.taskIdentifiers(for: key, in: notification).isEmpty == false
                }
                let externalUpdates = source === context ? [] : Self.taskIdentifiers(for: .updatedIdentifiers, in: notification)
                onChange(membershipChanged, externalUpdates)
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
                self.onChange(false, [])
            }
        }
    }

    private static func taskIdentifiers(for key: ModelContext.NotificationKey, in notification: Notification) -> [PersistentIdentifier] {
        let value = notification.userInfo?[key.rawValue]
        let identifiers = value as? [PersistentIdentifier] ?? Array(value as? Set<PersistentIdentifier> ?? [])
        return identifiers.filter { $0.entityName == "AgentTask" }
    }
}
