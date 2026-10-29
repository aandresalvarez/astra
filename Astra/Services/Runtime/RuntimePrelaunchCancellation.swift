import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Closes task-owned preparation before the durable provider launch boundary.
/// Shared read-only capability/policy queries have their own service lifetime;
/// task-owned probes must supply explicit process-group completion evidence.
@MainActor
enum RuntimePrelaunchCancellation {
    /// Persist the barrier before a task-owned probe can spawn. On an app
    /// crash, an unfinished barrier continues to fence the saved owner.
    static func prepareAntigravity(_ preparation: AntigravityLaunchPreparation,
                                   executablePath: String, homeDirectory: String,
                                   task: AgentTask, run: TaskRun, request: TaskTurnRequest?,
                                   owner: RuntimeExecutionOwner, context: ModelContext) async -> Bool {
        do {
            try owner.beginSettlement()
            let stopped = await preparation.prepare(executablePath: executablePath,
                homeDirectory: homeDirectory, taskID: task.id)
            try owner.completeSettlement(localWorkStopped: stopped, toolsStopped: stopped)
            guard !stopped else { return true }
            if owner.record.cancellationRequested == true || Task.isCancelled || task.status == .cancelled {
                settle(task: task, request: request, owner: owner, context: context, localWorkStopped: false)
            } else {
                run.status = .failed; run.completedAt = Date()
                run.typedStopReason = .custom("runtime_preparation_stop_unverified")
            }
            RuntimeExecutionOwner.report("The Antigravity preparation process has not been confirmed stopped. Your work is preserved; continuation must wait.",
                task: task, context: context, pause: task.status != .cancelled)
        } catch {
            RuntimeExecutionOwner.report("ASTRA could not persist the preparation state. The provider was not launched; this task keeps its reservations.",
                task: task, context: context)
        }
        return false
    }

    static func settle(task: AgentTask, request: TaskTurnRequest?, owner: RuntimeExecutionOwner,
                       context: ModelContext, localWorkStopped: Bool) {
        guard owner.isActive, owner.record.state == .preparing,
              owner.record.providerProcess == nil, owner.record.stopProof == nil else { return }
        owner.requestCancellation() // also covers cancellation of the Swift caller
        do {
            try owner.beginSettlement()
            TaskRunLifecycleService.cancelTask(task, modelContext: context, source: .userAction)
            if let request {
                guard (try TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID == task.persistentModelID,
                      request.runID == owner.record.runID else { return }
                let transition = TaskTurnRequestStateMachine.transition(request, to: .cancelled,
                    terminalReason: "cancelled_by_user")
                guard transition.rejection == nil else { return }
            }
            guard WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context) else { return }
            try owner.completeSettlement(localWorkStopped: localWorkStopped, toolsStopped: localWorkStopped)
        } catch {
            RuntimeExecutionOwner.report("ASTRA could not confirm that preparation stopped. This task keeps its reservations until its state can be verified.",
                task: task, context: context)
        }
    }
}
