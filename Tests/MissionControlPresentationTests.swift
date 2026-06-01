import Foundation
import SwiftData
import Testing
@testable import ASTRA

private func makeMissionControlContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Mission Control presentation")
@MainActor
struct MissionControlPresentationTests {
    @Test("mission control summarizes source-backed validation and correction state")
    func missionControlSummarizesValidationAndCorrectionState() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Mission", primaryPath: root)
        let task = AgentTask(title: "Mission task", goal: "Ship evidence-gated work", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Mission plan",
            goal: "Ship evidence-gated work",
            steps: [TaskPlanPayloadStep(id: "fix", title: "Fix implementation")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "tests",
                    description: "Focused tests pass",
                    method: .command,
                    command: "false"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let presentation = try #require(MissionControlPresentation.build(
            task: task,
            planState: TaskPlanService.reconstruct(for: task),
            state: state
        ))

        #expect(presentation.statusTitle == "Needs correction")
        #expect(presentation.tone == .failed)
        #expect(presentation.objective == "Ship evidence-gated work")
        #expect(presentation.validationSummary.contains("failed"))
        #expect(presentation.assertionRows.map(\.id) == ["tests"])
        #expect(presentation.correction?.failedAssertionID == "tests")
        #expect(presentation.isSourceBacked)
        #expect(presentation.nextAction?.contains("failed assertion tests") == true)
    }

    @Test("mission control actions are durable task events")
    func missionControlActionsAreDurableTaskEvents() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeMissionControlContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Mission Actions", primaryPath: root)
        let task = AgentTask(title: "Mission task", goal: "Audit mission actions", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        MissionControlPresentation.recordAction(
            TaskMissionActionEventTypes.dismissed,
            task: task,
            correctiveStepID: "corrective-tests",
            reason: "Not needed",
            modelContext: context
        )

        let event = try #require(task.events.first { $0.type == TaskMissionActionEventTypes.dismissed })
        #expect(event.category == "lifecycle")
        #expect(event.payload.contains("corrective-tests"))
        #expect(event.payload.contains("Not needed"))
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-mission-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
