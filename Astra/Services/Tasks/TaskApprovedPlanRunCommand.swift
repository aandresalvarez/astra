import Foundation
import SwiftData
import ASTRAModels

/// The existing-task plan action. The view presents and signals its result;
/// ExecutionRequestSubmissionService remains the durable submission owner.
@MainActor
enum TaskApprovedPlanRunCommand {
    static func isEnabled(for task: AgentTask, hasQueue: Bool) -> Bool {
        hasQueue && !TaskWorkspaceConsultationPolicy.isEnabled(for: task)
    }

    static func submit(
        plan: TaskPlanPayload,
        mode: TaskPlanExecutionMode,
        task: AgentTask,
        modelContext: ModelContext,
        hasQueue: Bool,
        recordReadOnlyBlock: (String) -> Void,
        recordAdditionalPolicy: () -> Void = {}
    ) -> Result<ExecutionRequestSubmissionService.Submission, ExecutionRequestSubmissionService.SubmissionError>? {
        guard isEnabled(for: task, hasQueue: hasQueue),
              task.status != .queued,
              task.status != .running else { return nil }

        // Check before recording approval or enqueueing. A read-only fork must
        // preserve its completed/pending state so the general queue cannot
        // later reinterpret an approved-plan launch as a normal task run.
        if let readOnlyReason = TaskForkPolicyService.readOnlyReason(for: task) {
            recordReadOnlyBlock(readOnlyReason)
            return nil
        }

        return ExecutionRequestSubmissionService.submitPlan(
            plan: plan,
            mode: mode,
            mutation: .existingTask,
            for: task,
            into: modelContext,
            recordAdditionalPolicy: recordAdditionalPolicy
        )
    }
}
