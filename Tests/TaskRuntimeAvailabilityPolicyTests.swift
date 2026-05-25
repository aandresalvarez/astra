import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Task Runtime Availability Policy")
@MainActor
struct TaskRuntimeAvailabilityPolicyTests {
    @Test("Readiness refresh preserves an existing task provider")
    func readinessRefreshPreservesExistingTaskProvider() {
        let task = AgentTask(
            title: "Keep Claude",
            goal: "Continue with the original provider",
            model: AgentRuntimeID.claudeCode.defaultModel
        )
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        let originalUpdatedAt = Date(timeIntervalSince1970: 100)
        task.updatedAt = originalUpdatedAt

        TaskRuntimeAvailabilityPolicy.alignAfterReadinessRefresh(
            task: task,
            runtimeReadinessStates: [
                .claudeCode: .blocked,
                .copilotCLI: .ready
            ],
            cachedClaudeModelsJSON: "",
            cachedCopilotModelsJSON: "",
            now: { Date(timeIntervalSince1970: 200) }
        )

        #expect(task.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(task.model == AgentRuntimeID.claudeCode.defaultModel)
        #expect(task.updatedAt == originalUpdatedAt)
    }

    @Test("Readiness refresh normalizes model without switching provider")
    func readinessRefreshNormalizesModelWithoutSwitchingProvider() {
        let task = AgentTask(
            title: "Keep Claude",
            goal: "Normalize model for the original provider",
            model: AgentRuntimeID.copilotCLI.defaultModel
        )
        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        let updatedAt = Date(timeIntervalSince1970: 300)

        TaskRuntimeAvailabilityPolicy.alignAfterReadinessRefresh(
            task: task,
            runtimeReadinessStates: [
                .claudeCode: .blocked,
                .copilotCLI: .ready
            ],
            cachedClaudeModelsJSON: "",
            cachedCopilotModelsJSON: "",
            now: { updatedAt }
        )

        #expect(task.runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(task.model == AgentRuntimeID.claudeCode.defaultModel)
        #expect(task.updatedAt == updatedAt)
    }
}
