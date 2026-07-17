import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeObjectiveAssessmentEventContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [configuration]
    )
}

@Suite("Objective assessment durable projection", .serialized)
@MainActor
struct TaskObjectiveAssessmentEventStoreTests {
    @Test("A task outside durable storage rejects assessment writes")
    func missingModelContextFailsClosed() {
        let workspace = Workspace(name: "Detached", primaryPath: "/tmp/detached")
        let task = AgentTask(title: "Detached", goal: "Do not fake durability", workspace: workspace)

        #expect(TaskObjectiveAssessmentEventStore.record(
            Self.assessment(objective: "Do not fake durability"),
            task: task,
            source: "test"
        ) == .persistenceFailed)
        #expect(objectiveEvents(task).isEmpty)
    }

    @Test("Recorded assessment rebuilds a missing capsule")
    func recordedAssessmentRebuildsMissingCapsule() throws {
        let fixture = try makeFixture("rebuild")
        defer { fixture.cleanup() }
        let assessment = Self.assessment(objective: "Ship the durable objective")

        #expect(TaskObjectiveAssessmentEventStore.record(
            assessment,
            task: fixture.task,
            source: "test"
        ) == .persisted)
        removeCapsule(fixture.folder)

        TaskContextStateManager.refresh(task: fixture.task)

        let rebuilt = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(rebuilt.objectiveAssessment == assessment)
        #expect(rebuilt.objective.currentObjective == "Ship the durable objective")
    }

    @Test("Existing capsule assessment backfills exactly one durable event")
    func existingCapsuleBackfillsOnce() throws {
        let fixture = try makeFixture("backfill")
        defer { fixture.cleanup() }
        var state = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        state.objectiveAssessment = Self.assessment(objective: "Preserve the imported pivot")
        #expect(TaskContextStateManager.saveState(state, taskFolder: fixture.folder).didSave)
        #expect(objectiveEvents(fixture.task).isEmpty)

        TaskContextStateManager.refresh(task: fixture.task)
        TaskContextStateManager.refresh(task: fixture.task)

        #expect(objectiveEvents(fixture.task).count == 1)
        let reloaded = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(reloaded.objectiveAssessment?.currentObjective == "Preserve the imported pivot")
    }

    @Test("Clear tombstone prevents assessment resurrection after capsule loss")
    func clearTombstonePreventsResurrection() throws {
        let fixture = try makeFixture("clear")
        defer { fixture.cleanup() }
        let assessment = Self.assessment(objective: "Temporary pivot")
        #expect(TaskObjectiveAssessmentEventStore.record(
            assessment,
            task: fixture.task,
            source: "test"
        ).didPersist)
        TaskContextStateManager.refresh(task: fixture.task)
        #expect(TaskObjectiveAssessmentEventStore.clear(
            task: fixture.task,
            reason: "test_clear"
        ) == .persisted)
        removeCapsule(fixture.folder)

        TaskContextStateManager.refresh(task: fixture.task)

        let rebuilt = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(rebuilt.objectiveAssessment == nil)
        #expect(objectiveEvents(fixture.task).count == 2)
    }

    @Test("Event compaction preserves objective assessment source events")
    func compactionPreservesObjectiveAssessmentEvents() throws {
        let fixture = try makeFixture("compaction")
        defer { fixture.cleanup() }
        let assessment = Self.assessment(objective: "Keep the compacted pivot")
        #expect(TaskObjectiveAssessmentEventStore.record(
            assessment,
            task: fixture.task,
            source: "test"
        ).didPersist)
        for index in 0..<(AgentEventCompactor.threshold + 30) {
            fixture.context.insert(TaskEvent(
                task: fixture.task,
                eventType: TaskEventTypes.Conversation.agentThinking,
                payload: "transient thought \(index)"
            ))
        }

        AgentEventCompactor.compactEvents(for: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        removeCapsule(fixture.folder)
        TaskContextStateManager.refresh(task: fixture.task)

        #expect(objectiveEvents(fixture.task).count == 1)
        let rebuilt = try #require(TaskContextStateManager.load(taskFolder: fixture.folder))
        #expect(rebuilt.objectiveAssessment == assessment)
    }

    private static func assessment(objective: String) -> TaskContextState.ObjectiveAssessment {
        TaskContextState.ObjectiveAssessment(
            verdict: "superseded",
            currentObjective: objective,
            assessedAtTurn: 7,
            inputHash: "input-hash"
        )
    }

    private func makeFixture(_ suffix: String) throws -> Fixture {
        let defaults = UserDefaults.standard
        let driftDetectionKey = AppStorageKeys.objectiveDriftDetectionEnabled
        let originalDriftDetectionSetting = defaults.object(forKey: driftDetectionKey) as? Bool
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-objective-events-\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try makeObjectiveAssessmentEventContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Objective Events", primaryPath: root.path)
        let task = AgentTask(title: "Objective Events", goal: "Original goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        try context.save()
        defaults.set(true, forKey: driftDetectionKey)
        TaskContextStateManager.refresh(task: task)
        return Fixture(
            root: root,
            container: container,
            context: context,
            task: task,
            restoreDriftDetectionSetting: {
                if let originalDriftDetectionSetting {
                    defaults.set(originalDriftDetectionSetting, forKey: driftDetectionKey)
                } else {
                    defaults.removeObject(forKey: driftDetectionKey)
                }
            }
        )
    }

    private func objectiveEvents(_ task: AgentTask) -> [TaskEvent] {
        task.events.filter { $0.type == TaskEventTypes.Objective.assessmentChanged.rawValue }
    }

    private func removeCapsule(_ folder: String) {
        let manager = FileManager.default
        for name in [TaskContextStateManager.jsonFileName, TaskContextStateManager.markdownFileName] {
            try? manager.removeItem(at: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
    }

    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let restoreDriftDetectionSetting: () -> Void

        var folder: String {
            TaskWorkspaceAccess(task: task).taskFolder
        }

        func cleanup() {
            restoreDriftDetectionSetting()
            try? FileManager.default.removeItem(at: root)
            _ = container
        }
    }
}
