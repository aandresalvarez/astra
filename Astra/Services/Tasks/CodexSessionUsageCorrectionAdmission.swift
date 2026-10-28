import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// History repair borrows the execution fence; it never creates an execution
/// receipt, releases resources, or changes a recovery allowance.
@MainActor
enum CodexSessionUsageCorrectionAdmission {
    static func acquire(task: AgentTask, context: ModelContext) throws -> RuntimeExecutionOwnerStore.Lease {
        let lease = try RuntimeTaskOwnerJournal.acquire(task: task, context: context)
        guard task.status != .running, task.status != .queued,
              !task.runs.contains(where: { $0.status == .running }),
              !(try TaskTurnRequestRepository.requests(for: task, in: context)).contains(where: { $0.state.isActive }) else {
            throw RuntimeExecutionOwnerStore.Failure.busy
        }
        if let owner = try lease.read() {
            guard owner.taskID == task.id, owner.canReplace,
                  owner.runID == nil || task.runs.contains(where: { $0.id == owner.runID }) else {
                throw RuntimeExecutionOwnerStore.Failure.unreadable
            }
        } else {
            // Old closed history predates execution receipts. An interrupted
            // run or any ownership audit is different: absence is not proof.
            guard !task.events.contains(where: {
                $0.type == "runtime.execution_ownership" || $0.type == "imported.runtime.execution_ownership"
                    || $0.type == "runtime.result.captured" || $0.type == "imported.runtime.result.captured"
            }), task.runs.allSatisfy({ run in
                run.status == .completed || (run.status == .failed && run.tokensUsed == 0
                    && run.inputTokens == 0 && run.outputTokens == 0
                    && run.typedStopReason == .workspaceNotFound)
            }) else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        }
        return lease
    }
}
