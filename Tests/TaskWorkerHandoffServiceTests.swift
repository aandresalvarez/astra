import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskWorkerHandoffContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task worker handoff service")
@MainActor
struct TaskWorkerHandoffServiceTests {
    @Test("run finalization records structured handoff in task events and context capsule")
    func runFinalizationRecordsStructuredHandoff() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskWorkerHandoffContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Handoff", primaryPath: root)
        let task = AgentTask(title: "Handoff task", goal: "Create a report", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Report plan",
            goal: "Create a report",
            steps: [
                TaskPlanPayloadStep(id: "report", title: "Write report", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "review", title: "Review report", likelyTools: ["Read"])
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Wrote the initial report."
        run.completedAt = Date()
        run.appendFileChange(StoredFileChange(from: FileChange(
            path: "\(root)/report.md",
            changeType: .write,
            content: "report",
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )))
        context.insert(run)
        task.status = .completed
        TaskPlanService.recordStepProgress(
            type: TaskPlanEventTypes.stepCompleted,
            planID: plan.planID,
            stepID: "report",
            status: .done,
            task: task,
            modelContext: context,
            run: run,
            summary: "Report draft created"
        )

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        let event = try #require(task.events.first { $0.type == TaskHandoffEventTypes.created })
        let payload = try #require(TaskWorkerHandoffService.decode(event.payload))
        #expect(payload.runID == run.id)
        #expect(payload.completedWork.contains("Report draft created"))
        #expect(payload.filesChanged.contains { $0.hasSuffix("report.md") })
        #expect(payload.unfinishedWork.contains { $0.contains("Review report") })

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let handoff = try #require(state.latestHandoff)
        #expect(handoff.runID == run.id.uuidString)
        #expect(handoff.completedWork.contains("Report draft created"))

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Latest handoff:"))
        #expect(prompt.contains("Report draft created"))
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
