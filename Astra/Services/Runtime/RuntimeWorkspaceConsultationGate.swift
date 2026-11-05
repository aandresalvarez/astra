import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Checks ASTRA-owned work before hooks, isolation, artifact preparation, or
/// final-only plan validation can write outside the provider sandbox.
@MainActor
enum RuntimeWorkspaceConsultationGate {
    @discardableResult
    static func validate(
        task: AgentTask,
        launchTask: AgentTask,
        request: TaskTurnRequest?,
        workspaceAccess: TaskExecutionResourceAccess,
        approvedPlan: TaskPlanPayload? = nil,
        modelContext: ModelContext
    ) -> Bool {
        guard TaskWorkspaceConsultationPolicy.isRequired(by: request, task: launchTask) else { return true }
        let commandAssertions = TaskWorkspaceConsultationPolicy.hasCommandAssertions(in: approvedPlan)
            || TaskWorkspaceConsultationPolicy.hasCommandAssertions(
                in: TaskWorkspaceConsultationPolicy.acceptedPlan(for: request, task: task))
        guard workspaceAccess != .shared || commandAssertions
                || TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: request, task: launchTask)
                || TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: nil, task: launchTask)
        else { return true }

        let reason = commandAssertions ? "consultation_plan_commands" : "consultation_requires_read_only_workspace"
        let message = commandAssertions
            ? "Consult cannot execute a plan with command assertions. Switch to Work to execute and validate this plan."
            : "Consult cannot start with writable workspace access. Enable sandbox enforcement and disable branch changes, automatic tests, and template hooks, or switch to Work."
        TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: message))
        if let request {
            _ = TaskTurnRequestStateMachine.transition(request, to: .failed, terminalReason: reason)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext,
            taskID: task.id, auditFields: ["operation": reason])
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: ["reason": reason], level: .warning)
        return false
    }
}
