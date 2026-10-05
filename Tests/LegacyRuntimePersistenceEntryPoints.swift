import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

// Historical unit fixtures have no durable request; production must supply context.
extension AgentRuntimeRunPersistence {
    @MainActor @discardableResult
    static func recordSessionTurn(task: AgentTask, run: TaskRun, message: String) -> Bool {
        recordSessionTurn(task: task, run: run, message: message, executionContext: .legacy(task: task))
    }

    @MainActor @discardableResult
    static func finalizeAndPersist(task: AgentTask, run: TaskRun, modelContext: ModelContext, phase: RunPhase,
        handoffDiscoveredFiles: [TaskOutputDiscoveredFile]? = nil, autoExport: Bool = true,
        persist: (() -> Bool)? = nil) async -> Bool {
        await finalizeAndPersist(task: task, run: run, modelContext: modelContext, phase: phase,
            executionContext: .legacy(task: task), handoffDiscoveredFiles: handoffDiscoveredFiles,
            autoExport: autoExport, persist: persist)
    }
}
