import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// The settlement protocol and plan replay read their events by predicate
/// fetch instead of scanning `task.events`. These pin that the fetch answers
/// exactly what the scans did, including for the state a settlement is in
/// mid-transaction: rows inserted or deleted but not yet saved.
@MainActor
@Suite("Task event type lookup")
struct TaskEventTypeLookupTests {
    private let settled = TaskEventTypes.System.runtimeTurnSettled.rawValue

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return (container, container.mainContext)
    }

    @Test("Unsaved inserts are found and unsaved deletions are not")
    func pendingChangesMatchTheRelationshipScan() throws {
        let (container, context) = try makeContext()
        defer { _ = container }
        let task = AgentTask(title: "Lookup", goal: "Pending changes")
        context.insert(task)
        let saved = TaskEvent(task: task, type: settled, payload: "saved")
        let doomed = TaskEvent(task: task, type: settled, payload: "doomed")
        context.insert(saved)
        context.insert(doomed)
        context.insert(TaskEvent(task: task, type: "agent.response", payload: "other type"))
        try context.save()

        let pending = TaskEvent(task: task, type: settled, payload: "pending")
        context.insert(pending)
        context.delete(doomed)

        let payloads = Set(TaskEventTypeLookup.events(ofType: settled, task: task).map(\.payload))
        #expect(payloads == ["saved", "pending"])
        let scanned = Set(task.events.filter { !$0.isDeleted && $0.type == settled }.map(\.payload))
        #expect(payloads == scanned)
    }

    @Test("Run-scoped lookups return only that run's events, saved or not")
    func runScopedLookup() throws {
        let (container, context) = try makeContext()
        defer { _ = container }
        let task = AgentTask(title: "Lookup", goal: "Runs")
        context.insert(task)
        let earlier = TaskRun(task: task)
        context.insert(earlier)
        context.insert(TaskEvent(task: task, type: settled, payload: "earlier", run: earlier))
        context.insert(TaskEvent(task: task, type: settled, payload: "no run"))
        try context.save()
        // The current run is inserted in the same transaction as its event,
        // as the worker does, and never saved before the lookup.
        let current = TaskRun(task: task)
        context.insert(current)
        context.insert(TaskEvent(task: task, type: settled, payload: "current", run: current))

        #expect(TaskEventTypeLookup.first(ofType: settled, task: task, run: current)?.payload == "current")
        #expect(TaskEventTypeLookup.events(ofType: settled, task: task, run: earlier).map(\.payload) == ["earlier"])
        #expect(TaskEventTypeLookup.events(ofType: settled, task: task).count == 3)
    }

    @Test("Another task's events of the same type are never returned")
    func lookupIsScopedToTheTask() throws {
        let (container, context) = try makeContext()
        defer { _ = container }
        let task = AgentTask(title: "Mine", goal: "Scope")
        let other = AgentTask(title: "Theirs", goal: "Scope")
        context.insert(task)
        context.insert(other)
        context.insert(TaskEvent(task: other, type: settled, payload: "theirs"))
        try context.save()

        #expect(TaskEventTypeLookup.events(ofType: settled, task: task).isEmpty)
    }

    @Test("An unmanaged task is scanned, since no store can answer for it")
    func unmanagedTaskFallsBackToTheRelationship() {
        let task = AgentTask(title: "Detached", goal: "No store")
        let run = TaskRun(task: task)
        let event = TaskEvent(task: task, type: settled, payload: "detached", run: run)
        task.runs = [run]
        task.events = [event, TaskEvent(task: task, type: "agent.response")]

        #expect(task.modelContext == nil)
        #expect(TaskEventTypeLookup.first(ofType: settled, task: task, run: run)?.payload == "detached")
    }

    @Test("Plan replay from plan rows matches the full relationship replay")
    func storeBackedPlanReconstructionMatchesTheRelationshipReplay() throws {
        let (container, context) = try makeContext()
        defer { _ = container }
        let task = AgentTask(title: "Plan", goal: "Ship the plan")
        context.insert(task)
        let plan = TaskPlanPayload(
            title: "Plan", goal: "Ship the plan",
            steps: [TaskPlanPayloadStep(id: "one", title: "Inspect"), TaskPlanPayloadStep(id: "two", title: "Fix")]
        )
        _ = TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        for index in 0..<50 {
            context.insert(TaskEvent(task: task, type: "agent.response", payload: "message \(index)"))
        }
        _ = TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        _ = TaskPlanService.recordExecutionStarted(planID: plan.planID, task: task, modelContext: context)
        try context.save()
        // The newest event is a conversation event, unsaved: the replay's
        // `latestEventAt` must still come from it, not from the plan rows.
        let newest = TaskEvent(task: task, type: "agent.response", payload: "newest")
        newest.timestamp = Date().addingTimeInterval(60)
        context.insert(newest)

        let fromStore = TaskPlanService.reconstruct(for: task)
        let fromRelationship = TaskPlanService.reconstruct(from: task.events, recoveryRuns: task.runs)
        #expect(fromStore == fromRelationship)
        #expect(fromStore.lifecycleStatus == .executing)
        #expect(fromStore.latestEventAt == newest.timestamp)
    }
}
