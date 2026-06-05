import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Mission hardening service")
@MainActor
struct MissionHardeningServiceTests {
    @Test("checkpoint records run-backed mission state")
    func checkpointRecordsRunBackedMissionState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Checkpoint", primaryPath: root)
        let task = AgentTask(title: "Checkpoint task", goal: "Create checkpoint", workspace: workspace)
        let run = TaskRun(task: task)
        run.status = .completed
        task.status = .completed
        task.tokensUsed = 42
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let payload = MissionHardeningService.recordCheckpoint(task: task, run: run, modelContext: context)

        #expect(payload.runID == run.id)
        #expect(payload.taskStatus == TaskStatus.completed.rawValue)
        #expect(payload.tokensUsed == 42)
        let event = try #require(task.events.first { $0.type == TaskMissionEventTypes.checkpointCreated })
        #expect(event.run?.id == run.id)
        let decoded = try #require(MissionHardeningService.decodeCheckpoint(event.payload))
        #expect(decoded.checkpointID == payload.checkpointID)
    }

    @Test("audit bundle exports plan events context and validation evidence")
    func auditBundleExportsPlanEventsContextAndValidationEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Audit Bundle", primaryPath: root)
        let task = AgentTask(title: "Audit task", goal: "Export bundle", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body>Bundle Ready</body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Audit plan",
            goal: "Export bundle",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "bundle-visible",
                    description: "Bundle Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Bundle Ready"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)
        MissionHardeningService.recordCheckpoint(task: task, run: run, modelContext: context)

        let payload = try MissionHardeningService.exportAuditBundle(task: task, modelContext: context)

        #expect(FileManager.default.fileExists(atPath: payload.path))
        let content = try String(contentsOfFile: payload.path, encoding: .utf8)
        #expect(content.contains("Audit plan"))
        #expect(content.contains("bundle-visible"))
        #expect(content.contains("validation-evidence"))
        #expect(content.contains("mission.checkpoint.created"))
        #expect(task.events.contains { $0.type == TaskMissionEventTypes.auditBundleCreated })
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-mission-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
