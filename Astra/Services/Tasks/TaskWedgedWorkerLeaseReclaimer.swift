import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Schedules one observable cancellation investigation. Time alone never
/// releases resources; the protected execution owner supplies stop evidence.
@MainActor
final class TaskWedgedWorkerLeaseReclaimer {
    /// Inspection delay, never termination or release evidence.
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

    func cancel(taskID: UUID) { deadlines.removeValue(forKey: taskID)?.timer.cancel() }

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

    /// A timer may wake a verified, cancelled provider wait. The worker then
    /// unwinds normally, restores hooks, and publishes release before the queue
    /// admits any competitor. Unknown local/remote work retains the fence.
    @MainActor
    func releaseWedgedLeases(_ leaseIDs: Set<UUID>, taskID: UUID, modelContext: ModelContext?) {
        guard let modelContext else { return }
        refreshResourceOwnership(in: modelContext)
        let stranded = activeResourceLocks.filter { $0.taskID == taskID && $0.leaseID.map(leaseIDs.contains) == true }
        guard !stranded.isEmpty else { return }
        if let worker = worker(forTaskID: taskID), let generation = worker.cancellationGeneration,
           worker.retireCancelledExecution(generation: generation) { return }
        guard let task = try? modelContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first else { return }
        let message = "Cancellation is still being checked. ASTRA cannot confirm that the previous execution and its tools stopped; shared resources remain reserved. Other tasks using those resources will wait."
        if !task.events.contains(where: { $0.type == "system.info" && $0.payload == message }) {
            RuntimeExecutionOwner.report(message, task: task, context: modelContext)
        }
    }
}
