import Foundation
import SwiftData

/// Coalesces committed job invalidations within one main-actor turn. The queue
/// registry owns and drains the coroutine; this is only its pending identity.
@MainActor
final class TaskQueueRemoteAdmissionRefresh {
    private var pendingID: UUID?
    var isPending: Bool { pendingID != nil }
    #if DEBUG
    private(set) var completedRefreshCount = 0
    #endif

    func schedule(session: TaskQueueStoreSession, registry: ExecutionRequestTaskRegistry,
                  isCurrent: @escaping @MainActor (TaskQueueStoreSession) -> Bool,
                  refresh: @escaping @MainActor (ModelContext) -> Void) {
        guard pendingID == nil else { return }
        let id = UUID()
        pendingID = id
        let task = Task { @MainActor [weak self, session] in
            defer { registry.finishLifecycle(id: id) }
            guard let self else { return }
            defer { if self.pendingID == id { self.pendingID = nil } }
            guard !Task.isCancelled, self.pendingID == id, isCurrent(session) else { return }
            // A notification emitted by refresh itself must schedule another
            // pass, rather than disappear into this already-consumed batch.
            self.pendingID = nil
            refresh(session.modelContext)
            #if DEBUG
            self.completedRefreshCount += 1
            #endif
        }
        registry.registerLifecycle(task, id: id)
    }
}
