import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Bounds how long a cancelled task can keep its resource lease.
///
/// Cancel stops the provider, and the queue releases a lease when the worker
/// call that owns it returns. If that call never returns — a descendant that
/// escaped the process group still holds stdout, a settlement hangs — the
/// lease stays held until relaunch and every task that needs the workspace
/// waits on it. Cancel therefore schedules one deadline per task: any lease
/// the task held when it was cancelled and still holds after `grace` is
/// released through `TaskQueue.releaseWedgedLeases`, which records a durable
/// `resource.lock.released` event with reason `cancelled_wedged_worker`.
///
/// Leases are identified by id, and `TaskQueue.releaseResourceLocks` removes
/// only claims still held, so a worker that does return later releases
/// nothing and cannot free a hold another admission has taken since.
@MainActor
final class TaskWedgedWorkerLeaseReclaimer {
    nonisolated static let releaseReason = "cancelled_wedged_worker"
    /// Well past the provider's SIGTERM→SIGKILL ladder (3 s) plus settlement,
    /// so a worker that honors the cancel always releases its own lease.
    nonisolated static let defaultGrace: Duration = .seconds(30)

    let grace: Duration
    private var deadlines: [UUID: (leaseIDs: Set<UUID>, timer: Task<Void, Never>)] = [:]

    init(grace: Duration = defaultGrace) {
        self.grace = grace
    }

    var pendingCount: Int { deadlines.count }

    /// Runs `reclaim` once after `grace` unless cancelled first. A repeated
    /// cancel of the same task restarts the deadline over the union of both
    /// lease sets.
    func schedule(
        taskID: UUID,
        leaseIDs: Set<UUID>,
        reclaim: @escaping @MainActor (Set<UUID>) -> Void
    ) {
        guard !leaseIDs.isEmpty else { return }
        let previous = deadlines.removeValue(forKey: taskID)
        previous?.timer.cancel()
        let grace = grace
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self,
                  let deadline = self.deadlines.removeValue(forKey: taskID) else { return }
            reclaim(deadline.leaseIDs)
        }
        deadlines[taskID] = (leaseIDs.union(previous?.leaseIDs ?? []), timer)
    }

    func cancelAll() {
        deadlines.values.forEach { $0.timer.cancel() }
        deadlines.removeAll()
    }
}

extension TaskQueue {
    /// Captures the leases `taskID` holds at cancel time. Only those ids can be
    /// reclaimed, so a later admission of the same task is never touched.
    @MainActor
    func scheduleWedgedLeaseRelease(for taskID: UUID, modelContext: ModelContext?) {
        let leaseIDs = Set(activeResourceLocks.filter { $0.taskID == taskID }.compactMap(\.leaseID))
        wedgedLeaseReclaimer.schedule(taskID: taskID, leaseIDs: leaseIDs) { [weak self] leases in
            self?.releaseWedgedLeases(leases, taskID: taskID, modelContext: modelContext)
        }
    }

    /// Releases whatever part of `leaseIDs` is still held. A no-op when the
    /// worker returned and released its own lease within the grace period.
    @MainActor
    func releaseWedgedLeases(_ leaseIDs: Set<UUID>, taskID: UUID, modelContext: ModelContext?) {
        let stranded = activeResourceLocks.filter { claim in claim.leaseID.map(leaseIDs.contains) ?? false }
        guard !stranded.isEmpty else { return }
        let task = modelContext.flatMap { context in
            try? context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first
        }.flatMap { $0.isDeleted ? nil : $0 }
        AppLogger.audit(.resourceLockReleased, category: "Queue", taskID: taskID, fields: [
            "reason": TaskWedgedWorkerLeaseReclaimer.releaseReason,
            "claim_count": String(stranded.count),
            "lease_count": String(Set(stranded.compactMap(\.leaseID)).count),
            "durable_event": String(task != nil)
        ], level: .warning)
        releaseResourceLocks(
            stranded,
            task: task,
            modelContext: modelContext,
            reason: TaskWedgedWorkerLeaseReclaimer.releaseReason
        )
    }
}
