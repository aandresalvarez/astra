import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Context event index preserves durable history", .serialized)
@MainActor
struct TaskContextEventIndexTests {
    @Test("Only the selected persisted owner and necessary event types enter the index")
    func importedCopiesAndNoise() throws {
        let f = try Fixture()
        let copy = AgentTask(title: "Imported copy", goal: "copy")
        copy.id = f.task.id
        f.context.insert(copy)
        let original = f.add("user.message", "original")
        let other = TaskEvent(task: copy, type: "user.message", payload: "foreign")
        other.id = original.id
        f.context.insert(other)
        for _ in 0..<250 { f.add("tool.result", "unrelated tool output") }
        try f.context.save()
        let index = TaskContextEventIndex(task: f.task)
        #expect(index.userMessages.map(\.payload) == ["original"])
        #expect(TaskContextEventIndex(task: copy).userMessages.map(\.payload) == ["foreign"])
        #expect(index.assistantReplies.isEmpty && index.blocking.isEmpty)
        #expect(TaskHistoryRead.events(for: f.task).count == 251)
    }

    @Test("A new derive sees pending edits, relinks and deletion, then rollback", arguments: ["edit", "relink", "delete"])
    func currentContextIsAuthoritative(change: String) throws {
        let f = try Fixture()
        let event = f.add("user.message", "saved")
        let other = AgentTask(title: "Other", goal: "other")
        f.context.insert(other)
        try f.context.save()
        #expect(TaskContextEventIndex(task: f.task).userMessages.map(\.payload) == ["saved"])
        SwiftDataTaskRollbackPreparation.prepare(f.task)
        SwiftDataTaskRollbackPreparation.prepare(other)
        switch change {
        case "edit": event.type = "agent.response"; event.payload = "edited"
        case "relink": event.task = other
        default: f.context.delete(event)
        }
        let changed = TaskContextEventIndex(task: f.task)
        #expect(changed.userMessages.isEmpty)
        if change == "edit" { #expect(changed.assistantReplies.map(\.payload) == ["edited"]) }
        f.context.rollback()
        #expect(TaskContextEventIndex(task: f.task).userMessages.map(\.payload) == ["saved"])
        let separate = ModelContext(f.container)
        separate.autosaveEnabled = false
        let taskID = f.task.id
        let separateTask = try #require(separate.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first)
        separate.insert(TaskEvent(task: separateTask, type: "user.message", payload: "other context pending"))
        #expect(TaskContextEventIndex(task: separateTask).userMessages.count == 2)
        #expect(TaskContextEventIndex(task: f.task).userMessages.count == 1)
        separate.rollback()
    }

    @Test("Equal timestamps preserve the existing UUID order for the first request and objective")
    func equalTimestampOrdering() throws {
        let f = try Fixture()
        let later = f.add("user.message", "Actually, the new goal is to ship the CSV export")
        later.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let first = f.add("user.message", "Build the quarterly report")
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        first.timestamp = later.timestamp
        try f.context.save()
        let index = TaskContextEventIndex(task: f.task)
        #expect(index.orderedUserMessages.map(\.id) == [first.id, later.id])
        #expect(index.orderedUserMessages.first?.payload == TaskContextStateManager.firstConversationRequestValue(for: f.task))
        let plan = TaskPlanReconstructionSeam.required.reconstruct(for: f.task)
        let indexed = TaskContextStateManager.activeObjectiveResolution(for: f.task, events: index,
            planState: plan, startingRequest: first.payload, approvedGoal: nil)
        let existing = TaskContextStateManager.activeObjectiveResolution(for: f.task,
            planState: plan, startingRequest: first.payload, approvedGoal: nil)
        #expect(indexed == existing)
        #expect(indexed.objective == "ship the CSV export")
    }

    @Test("Waiting and cancelled instructions stay hidden; admission is visible without another event")
    func pendingAdmissionIsNotCached() throws {
        let f = try Fixture()
        let first = f.add("user.message", "Original request")
        first.timestamp = Date(timeIntervalSince1970: 1)
        let later = f.add("user.message", "Actually, the new goal is to ship the CSV export")
        let request = TaskTurnRequest(task: f.task, messageEventID: later.id, sequence: 1)
        f.context.insert(request)
        try f.context.save()
        func objective() -> String {
            TaskContextStateManager.activeObjectiveResolution(for: f.task, events: TaskContextEventIndex(task: f.task),
                planState: TaskPlanReconstructionSeam.required.reconstruct(for: f.task),
                startingRequest: first.payload, approvedGoal: nil).objective
        }
        #expect(objective() == f.task.goal)
        request.state = .admitted
        #expect(objective() == "ship the CSV export")
        request.state = .cancelled
        request.startedAt = nil
        #expect(objective() == f.task.goal)
    }

    @Test("Refreshing context preserves execution proof, request limits and the complete launch history", arguments: [true, false])
    func executionAndAccountingAreNotProjectedAway(toolsStopped: Bool) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        h.context.autosaveEnabled = false
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Preserve the original request", model: "test", tokenBudget: 1_000)
        task.status = .failed
        task.tokensUsed = 900
        let run = TaskRun(task: task)
        run.status = .failed; run.tokensUsed = 200
        h.context.insert(run)
        let types = ["tool.result", "astra.claude_session_usage", "astra.claude_session_usage_unconfirmed", "task.stats"]
        for type in types { h.context.insert(TaskEvent(task: task, type: type, payload: "retained native evidence", run: run)) }
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeResultCaptured,
            payload: #"{"requestTokensUsed":900,"effectiveTokenBudget":1000}"#, run: run))
        let owner = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: toolsStopped)
        try h.context.save()
        let before = TaskHistoryRead.events(for: task).map(TaskEventRecord.init(event:)).sorted(by: TaskEventRecord.isChronologicallyOrdered)
        let budget = TaskRequestBudget(run: run, task: task)
        _ = TaskContextStateManager.refresh(task: task)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == owner)
        #expect(TaskRequestBudget(run: run, task: task) == budget)
        #expect(budget.tokensUsed == 900 && budget.tokenCeiling == 1_000)
        #expect(TaskHistoryRead.events(for: task).map(TaskEventRecord.init(event:)).sorted(by: TaskEventRecord.isChronologicallyOrdered) == before)
        let copy = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: task), from: task)
        #expect(Set(copy.events.map(\.type)).isSuperset(of: types))
    }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let task: AgentTask
        var context: ModelContext { container.mainContext }
        init() throws {
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            container.mainContext.autosaveEnabled = false
            task = AgentTask(title: "Context", goal: "Original request")
            container.mainContext.insert(task)
        }
        @discardableResult func add(_ type: String, _ payload: String) -> TaskEvent {
            let event = TaskEvent(task: task, type: type, payload: payload)
            context.insert(event)
            return event
        }
    }
}
