import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence

@MainActor
@Suite("Saved export observer lifetimes", .serialized)
struct WorkspaceSavedExportObserverLifetimeTests {
    @Test("An already-delivered callback after observer removal never assumes the former executor")
    func lateDeliveryAfterRemoval() async throws {
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let workspace = Workspace(name: "Synthetic lease", primaryPath: "/tmp/synthetic-export-observer")
        let ticket = WorkspaceAutoExportGate.shared.beginRead(for: workspace.id.uuidString)
        defer { WorkspaceAutoExportGate.shared.retire(workspaceID: workspace.id.uuidString) }
        let notifications = DeferredNotifications()
        WorkspaceSavedExportLease.$notifications.withValue(notifications) {
            let lease = WorkspaceSavedExportLease(context: context, workspace: workspace, ticket: ticket)
            withExtendedLifetime(lease) {}
        }
        #expect(notifications.removals == 2)
        // NotificationCenter can have copied a callback before removal. Keep
        // that delivery alive, but never use the model on the worker: only the
        // expired observer's identity guard may inspect this notification.
        notifications.prepare(context)
        await Task.detached { notifications.deliver() }.value
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket))
    }

    @Test("A lease does not keep its context alive and ignores another context's notifications")
    func releasedContextAndForeignDelivery() async throws {
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let workspace = Workspace(name: "Synthetic expired context", primaryPath: "/tmp/synthetic-export-observer")
        let ticket = WorkspaceAutoExportGate.shared.beginRead(for: workspace.id.uuidString)
        defer { WorkspaceAutoExportGate.shared.retire(workspaceID: workspace.id.uuidString) }
        let notifications = DeferredNotifications()
        weak var released: ModelContext?
        let lease = WorkspaceSavedExportLease.$notifications.withValue(notifications) {
            autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                released = context
                return WorkspaceSavedExportLease(context: context, workspace: workspace, ticket: ticket)
            }
        }
        #expect(released == nil)
        try await Task.detached {
            let other = ModelContext(container)
            other.autosaveEnabled = false
            notifications.prepare(other)
            notifications.deliver()
            other.insert(Workspace(name: "Unrelated saved owner", primaryPath: "/tmp/synthetic-export-foreign"))
            try other.save()
        }.value
        #expect(WorkspaceAutoExportGate.shared.isCurrent(ticket))
        withExtendedLifetime(lease) {}
    }
}

/// Models a callback already copied by NotificationCenter before removal.
/// Model objects are carried only as notification identities, never accessed.
private final class DeferredNotifications: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [(Notification.Name?, @Sendable (Notification) -> Void)] = []
    private var deliveries: [Notification] = []
    private var removed = 0
    var removals: Int { lock.withLock { removed } }

    override func addObserver(forName name: Notification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        lock.withLock { callbacks.append((name, block)) }
        return NSObject()
    }

    override func removeObserver(_ observer: Any) { lock.withLock { removed += 1 } }

    func prepare(_ context: ModelContext) {
        lock.withLock {
            deliveries = callbacks.map { Notification(name: $0.0!, object: context) }
        }
    }

    func deliver() {
        let pending = lock.withLock { Array(zip(callbacks, deliveries)) }
        for (callback, notification) in pending { callback.1(notification) }
        lock.withLock { deliveries.removeAll() }
    }
}
