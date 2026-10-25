import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Task deliverable intent memo")
@MainActor
struct TaskDeliverableIntentMemoTests {
    @Test("Streaming and runtime changes reuse the pure request classification")
    func streamingReusesClassification() {
        let task = AgentTask(title: "Review", goal: "Explain the result in chat")
        let memo = TaskDeliverableIntentMemo()
        var calls = 0
        let compute: (AgentTask) -> Bool = { _ in calls += 1; return false }
        #expect(!memo.requiresArtifact(for: task, compute: compute))
        for runtime in [AgentRuntimeID.claudeCode, .codexCLI, .copilotCLI, .cursorCLI, .openCodeCLI, .antigravityCLI] {
            task.runtimeID = runtime.rawValue
            task.updatedAt = Date()
            task.status = .running
            #expect(!memo.requiresArtifact(for: task, compute: compute))
        }
        task.status = .completed
        #expect(!memo.requiresArtifact(for: task, compute: compute))
        #expect(calls == 1)
    }

    @Test("Every classification input invalidates the memo")
    func requestChangesInvalidate() {
        let task = AgentTask(title: "Review", goal: "Explain the result in chat")
        let memo = TaskDeliverableIntentMemo()
        var calls = 0
        let compute: (AgentTask) -> Bool = { _ in calls += 1; return calls.isMultiple(of: 2) }
        #expect(!memo.requiresArtifact(for: task, compute: compute))
        task.title = "New title"
        #expect(memo.requiresArtifact(for: task, compute: compute))
        task.goal = "Create a report"
        #expect(!memo.requiresArtifact(for: task, compute: compute))
        task.inputs = ["Source material"]
        #expect(memo.requiresArtifact(for: task, compute: compute))
        task.acceptanceCriteria = ["Deliver report.pdf"]
        #expect(!memo.requiresArtifact(for: task, compute: compute))
        #expect(calls == 5)
    }

    @Test("A request edited from text to a file updates its real classification")
    func changedRequestUsesActualClassifier() {
        let task = AgentTask(title: "Review", goal: "Explain the result in chat")
        let memo = TaskDeliverableIntentMemo()
        #expect(!memo.requiresArtifact(for: task))
        task.goal = "Create a CSV file"
        #expect(memo.requiresArtifact(for: task))
        task.goal = "Explain the result in chat"
        #expect(!memo.requiresArtifact(for: task))
    }
}
