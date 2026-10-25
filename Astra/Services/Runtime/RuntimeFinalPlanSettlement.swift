import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

@MainActor
enum RuntimeFinalPlanSettlement {
    static func validate(task: AgentTask, plan: TaskPlanPayload, owner: RuntimeExecutionOwner,
                         modelContext: ModelContext, verifierRuntime: AgentUtilityRuntimeConfiguration) async {
        do { try owner.beginSettlement() } catch { return }
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        owner.settlementScope = scope
        scope.executionOwner = owner
        if owner.record.cancellationRequested == true { scope.cancel() }
        let valid = await RuntimeSettlementExecutionScope.$current.withValue(scope) {
            await ApprovedPlanRuntimeSettlement.validateApprovedPlanContractForFinalCompletion(
                task: task, plan: plan, modelContext: modelContext, verifierRuntime: verifierRuntime)
        }
        scope.seal()
        do { try owner.completeSettlement(localWorkStopped: scope.localWorkStopped, toolsStopped: scope.toolsStopped) }
        catch { return }
        guard !scope.isCancelled, owner.isActive, !Task.isCancelled else { return }
        if valid {
            TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
            TaskStateMachine.completeFromRuntime(task, modelContext: modelContext)
        }
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
    }
}
