import Foundation
import SwiftData
import Testing
@testable import ASTRA

private func makeAgentTaskForkContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Agent task fork checkpoints")
@MainActor
struct AgentTaskForkServiceTests {
    @Test("fork preserves run-scoped events and records a checkpoint")
    func forkPreservesRunScopedEventsAndRecordsCheckpoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeAgentTaskForkContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Fork Checkpoint", primaryPath: root)
        let source = AgentTask(
            title: "Source",
            goal: "Try two implementation branches",
            workspace: workspace,
            validationStrategy: .runTests
        )
        source.testCommand = "swift test --filter ForkCheckpointTests"
        context.insert(workspace)
        context.insert(source)

        let firstRun = TaskRun(task: source)
        firstRun.startedAt = Date(timeIntervalSince1970: 100)
        firstRun.completedAt = Date(timeIntervalSince1970: 110)
        firstRun.status = RunStatus.completed
        firstRun.output = "First branch result"
        firstRun.stopReason = "completed"
        context.insert(firstRun)

        let firstEvent = TaskEvent(
            task: source,
            type: "tool.use",
            payload: "Using tool: Bash: swift test --filter FirstBranchTests",
            run: firstRun
        )
        firstEvent.timestamp = Date(timeIntervalSince1970: 105)
        context.insert(firstEvent)

        let secondRun = TaskRun(task: source)
        secondRun.startedAt = Date(timeIntervalSince1970: 200)
        secondRun.completedAt = Date(timeIntervalSince1970: 210)
        secondRun.status = RunStatus.completed
        secondRun.output = "Second branch result"
        secondRun.stopReason = "completed"
        context.insert(secondRun)

        let secondEvent = TaskEvent(
            task: source,
            type: "tool.use",
            payload: "Using tool: Bash: swift test --filter SecondBranchTests",
            run: secondRun
        )
        secondEvent.timestamp = Date(timeIntervalSince1970: 205)
        context.insert(secondEvent)

        let forked = AgentTask.fork(from: source, upToRun: firstRun, in: context)
        try context.save()

        #expect(forked.forkedFromID == source.id)
        #expect(forked.forkedAtRunIndex == 0)
        #expect(forked.runs.count == 1)
        let forkedRun = try #require(forked.runs.first)
        let copiedFirstEvent = try #require(forked.events.first { $0.payload.contains("FirstBranchTests") })
        #expect(copiedFirstEvent.run?.id == forkedRun.id)
        #expect(!forked.events.contains { $0.payload.contains("SecondBranchTests") })

        let checkpointEvent = try #require(forked.events.first { $0.type == "task.checkpoint" })
        #expect(checkpointEvent.run?.id == forkedRun.id)
        #expect(checkpointEvent.payload.contains(source.id.uuidString))
        #expect(checkpointEvent.payload.contains("Later source runs are not authoritative"))

        TaskContextStateManager.refresh(task: forked)
        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: forked).taskFolder))
        #expect(state.decisionFacts.contains { $0.text.contains("Forked checkpoint from task \(source.id.uuidString)") })
        #expect(state.sourcePointers.contains { $0.kind == "checkpoint" && $0.id == source.id.uuidString })

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue from checkpoint", task: forked)
        #expect(prompt.contains("Checkpoint:"))
        #expect(prompt.contains("source runs after the checkpoint are not authoritative"))
        #expect(prompt.contains("after source run 1"))
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-fork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
