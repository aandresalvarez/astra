import SwiftData
import ASTRAModels
@testable import ASTRA

extension TaskDeliverableVerificationService {
    @MainActor
    static func evaluate(task: AgentTask, run: TaskRun?, modelContext: ModelContext? = nil,
        workspacePath: String? = nil, environment: TaskDeliverableVerificationEnvironment = .live) async -> TaskDeliverableVerificationResult {
        await evaluate(task: task, run: run, modelContext: modelContext,
            executionContext: .legacy(task: task, workingDirectory: workspacePath), environment: environment)
    }
}

extension ValidationService {
    @MainActor
    static func aiCheck(task: AgentTask, claudePath: String, model: String = "claude-haiku-4-5-20251001",
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil, workspacePath: String? = nil) async -> ValidationResult {
        await aiCheck(task: task, claudePath: claudePath, model: model, utilityRuntime: utilityRuntime,
            executionContext: .legacy(task: task, workingDirectory: workspacePath))
    }
}
