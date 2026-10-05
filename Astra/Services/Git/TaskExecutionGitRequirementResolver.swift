import Foundation
import ASTRAModels

enum TaskExecutionGitRequirementResolver {
    static func approvedPlanRequirement(_ plan: TaskPlanPayload, mode: TaskPlanExecutionMode) -> TaskExecutionResourceScope.GitAccess? {
        let steps = mode == .nextStep ? TaskPlanService.nextExecutableStep(in: plan).map { [$0] } ?? [] : plan.steps
        let requirements = steps.compactMap(\.gitAccessRequirement)
        if requirements.contains(.invalid) { return .invalid }
        return requirements.contains(.readWrite) ? .readWrite : requirements.first
    }

    static func resolve(task: AgentTask, requirement: TaskExecutionResourceScope.GitAccess?, writable: Bool) -> TaskExecutionResourceScope.GitAccess {
        let prefix = "ASTRA_GIT_ACCESS="
        let declarations = task.constraints.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        guard declarations.allSatisfy({ ["read_only", "read_write"].contains($0) }),
              Set(declarations).count <= 1, requirement != .invalid else { return .invalid }
        let workflowWrites = task.isolationStrategy == .gitBranch || task.validationStrategy == .runTests || requirement == .readWrite
        if declarations.first == "read_only" { return workflowWrites ? .invalid : .readOnly }
        if declarations.first == "read_write" { return writable ? .readWrite : .invalid }
        guard writable else { return workflowWrites ? .invalid : .readOnly }
        return workflowWrites ? .readWrite : .readOnly
    }
}
