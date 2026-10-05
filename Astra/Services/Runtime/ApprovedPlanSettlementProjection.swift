import ASTRAModels

extension ApprovedPlanRuntimeSettlement {
    @MainActor
    static func settledPlan(_ accepted: TaskPlanPayload, task: AgentTask) -> TaskPlanPayload {
        guard let current = TaskPlanService.reconstruct(for: task).plan,
              current.planID == accepted.planID else { return accepted }
        var result = accepted
        for index in result.steps.indices {
            guard let progress = current.steps.first(where: { $0.id == result.steps[index].id }) else { continue }
            result.steps[index].status = progress.status
            if progress.status == .blocked { result.steps[index].detail = progress.detail }
        }
        return result
    }
}
