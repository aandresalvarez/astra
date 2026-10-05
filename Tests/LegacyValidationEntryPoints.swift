import SwiftData
import ASTRAModels
@testable import ASTRA

// Historical unit fixtures have no durable request. Production APIs require context.
extension ValidationService {
    @MainActor
    static func runTests(task: AgentTask,
        commandRunner: ValidationCommandRunning = ShellValidationCommandRunner()) async -> ValidationResult {
        await runTests(task: task, executionContext: .legacy(task: task), commandRunner: commandRunner)
    }

    @MainActor
    static func runContract(
        task: AgentTask, plan: TaskPlanPayload, run: TaskRun?, modelContext: ModelContext,
        workspacePath: String? = nil, verifierRuntime: AgentUtilityRuntimeConfiguration? = nil,
        commandRunner: ValidationCommandRunning = ShellValidationCommandRunner(),
        resourceScope: TaskExecutionResourceScope? = nil
    ) async -> TaskValidationContractEvaluation {
        let context = (resourceScope ?? task.acceptedResourceScope).map {
            TaskExecutionContext(taskID: task.id, acceptedScope: $0, workingDirectory: workspacePath)
        } ?? .legacy(task: task, workingDirectory: workspacePath)
        return await runContract(task: task, plan: plan, run: run, modelContext: modelContext,
            executionContext: context, verifierRuntime: verifierRuntime, commandRunner: commandRunner)
    }
}

extension TaskInferredValidationService {
    @MainActor
    static func suggestion(for task: AgentTask, workspacePath: String? = nil) -> TaskInferredValidationSuggestion? {
        suggestion(for: task, executionContext: .legacy(task: task, workingDirectory: workspacePath))
    }

    @MainActor
    static func shouldRunAutomaticBaseline(for task: AgentTask, workspacePath: String? = nil) -> Bool {
        shouldRunAutomaticBaseline(for: task, executionContext: .legacy(task: task, workingDirectory: workspacePath))
    }

    @MainActor
    static func run(task: AgentTask, modelContext: ModelContext, workspacePath: String? = nil,
        commandRunner: ValidationCommandRunning = ShellValidationCommandRunner(),
        resourceScope: TaskExecutionResourceScope? = nil) async -> TaskValidationContractEvaluation {
        let context = resourceScope.map { TaskExecutionContext(taskID: task.id, acceptedScope: $0, workingDirectory: workspacePath) }
            ?? .legacy(task: task, workingDirectory: workspacePath)
        return await run(task: task, modelContext: modelContext, executionContext: context, commandRunner: commandRunner)
    }

    @MainActor
    static func runAutomaticBaselineIfNeeded(task: AgentTask, modelContext: ModelContext, workspacePath: String? = nil,
        commandRunner: ValidationCommandRunning = ShellValidationCommandRunner(),
        resourceScope: TaskExecutionResourceScope? = nil) async -> TaskValidationContractEvaluation {
        let context = resourceScope.map { TaskExecutionContext(taskID: task.id, acceptedScope: $0, workingDirectory: workspacePath) }
            ?? .legacy(task: task, workingDirectory: workspacePath)
        return await runAutomaticBaselineIfNeeded(task: task, modelContext: modelContext,
            executionContext: context, commandRunner: commandRunner)
    }
}
