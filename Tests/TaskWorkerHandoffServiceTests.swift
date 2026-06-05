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

    @Test("blocked plan steps are surfaced as handoff blockers")
    func blockedPlanStepsSurfaceAsHandoffBlockers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskWorkerHandoffContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Handoff", primaryPath: root)
        let task = AgentTask(title: "Blocked task", goal: "Create a report", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Report plan",
            goal: "Create a report",
            steps: [
                TaskPlanPayloadStep(id: "requirements", title: "Gather requirements", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "write", title: "Write report", likelyTools: ["Write"])
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Blocked waiting for directory preparation."
        run.completedAt = Date()
        context.insert(run)
        task.status = .pendingUser
        TaskPlanService.recordStepProgress(
            type: TaskPlanEventTypes.stepBlocked,
            planID: plan.planID,
            stepID: "requirements",
            status: .blocked,
            task: task,
            modelContext: context,
            run: run,
            reason: "Cannot create docs/requirements.md because docs is missing"
        )

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        let event = try #require(task.events.first { $0.type == TaskHandoffEventTypes.created })
        let payload = try #require(TaskWorkerHandoffService.decode(event.payload))
        #expect(payload.blockers.contains { $0.contains("Plan step blocked: requirements") })
        #expect(payload.risks.contains { $0.contains("Open blockers remain") })

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.blockers.contains { $0.contains("Cannot create docs/requirements.md") })
        #expect(state.latestHandoff?.blockers.contains { $0.contains("Plan step blocked: requirements") } == true)
    }

    @Test("handoff discovers task output files when provider metadata is missing")
    func handoffDiscoversTaskOutputFilesWhenProviderMetadataIsMissing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskWorkerHandoffContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Handoff Discovered Files", primaryPath: root)
        let task = AgentTask(title: "Handoff task", goal: "Create a standalone page", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.startedAt = Date().addingTimeInterval(-30)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Created the standalone page."
        run.completedAt = Date().addingTimeInterval(30)
        task.status = .completed
        context.insert(run)

        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (folder as NSString).appendingPathComponent("index.html")
        try "<!doctype html><html><body>Artifact</body></html>".write(
            toFile: indexPath,
            atomically: true,
            encoding: .utf8
        )

        AgentRuntimeRunPersistence.finalizeAndPersist(
            task: task,
            run: run,
            modelContext: context,
            phase: "run"
        )

        let event = try #require(task.events.first { $0.type == TaskHandoffEventTypes.created })
        let payload = try #require(TaskWorkerHandoffService.decode(event.payload))
        #expect(payload.filesChanged.contains(indexPath))
        #expect(payload.artifactsCreated.contains(indexPath))

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.latestHandoff?.sourcePointers.contains { $0.summary.contains("Structured worker handoff") } == true)
        #expect(state.artifacts.contains { $0.path == indexPath })
        #expect(state.changedFiles.contains { $0.path == indexPath })
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
