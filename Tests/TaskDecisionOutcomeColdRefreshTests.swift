import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Decision outcomes on cold thousand-run histories", .serialized)
@MainActor
struct TaskDecisionOutcomeColdRefreshTests {
    @Test("First projection and relevant save stay below a quarter of a full scan with 1,000 runs")
    func thousandRunColdRefresh() throws {
        let fixture = try Fixture()
        var cold: [Double] = [], invalidated: [Double] = [], control: [Double] = []
        // Every sample uses a fresh context. Neither the first projection nor
        // the control is warmed; alternate order to avoid favoring either.
        for repetition in 0..<3 {
            if repetition.isMultiple(of: 2) { control.append(try measureControl(fixture)) }
            let context = ModelContext(fixture.container)
            context.autosaveEnabled = false
            let task = try fixture.task(in: context)
            let probe = TaskDecisionOutcomeRefreshTests.Probe(task: task, context: context)
            defer { probe.stop() }
            cold.append(cpuMilliseconds { probe.refresh(fixture.snapshot) })
            #expect(probe.resolves == 1)
            #expect(probe.projection.outcomes.deliveredRequestFollowUpRunID == fixture.latestRunID)

            let approval = TaskEvent(task: task, eventType: TaskEventTypes.Task.approved,
                payload: TaskDeliverableExpectation.userApprovalPayloadPrefix)
            approval.timestamp = fixture.startedAt.addingTimeInterval(-1)
            context.insert(approval)
            try context.save()
            invalidated.append(cpuMilliseconds { probe.refresh(fixture.snapshot) })
            #expect(probe.resolves == 2, "The relevant save must really re-enter the resolver")
            #expect(probe.projection.outcomes.deliveredRequestFollowUpRunID == fixture.latestRunID)
            context.delete(approval)
            try context.save()
            if !repetition.isMultiple(of: 2) { control.append(try measureControl(fixture)) }
        }
        let full = median(control), first = median(cold), saved = median(invalidated)
        print("[decision-cold-refresh] runs=1000 samples=3 full_scan_cpu_ms=\(full) first_projection_cpu_ms=\(first) relevant_refresh_cpu_ms=\(saved)")
        #expect(first < full * 0.25, "Includes the first key construction and complete resolver; no warmup")
        #expect(saved < full * 0.25, "A semantic invalidation must not restore full-history work")
    }

    @Test("Paged reads preserve mixed sources, timestamp ties, pending changes and rollback")
    func pagedEvidenceParity() throws {
        let f = try TaskDecisionOutcomeRefreshTests.Fixture()
        // More than two pages, all tied on time, plus >one page of source
        // events per run. A later approved-plan source must exclude the run.
        for _ in 0..<70 {
            let step = TaskRun(task: f.task)
            step.startedAt = f.run.startedAt.addingTimeInterval(-10)
            step.status = .completed
            step.stopReason = TaskRunStopReason.completed.rawValue
            f.context.insert(step)
            for _ in 0..<35 {
                f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task,
                    type: TaskEventTypes.ExecutionRequest.retry.rawValue,
                    payload: TaskExecutionSourcePayloadV1(launchMode: .continuation), run: step))
            }
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task,
                type: TaskEventTypes.ExecutionRequest.planStep.rawValue,
                payload: TaskExecutionSourcePayloadV1(launchMode: .approvedPlan), run: step))
        }
        let delivered = TaskRun(task: f.task)
        delivered.startedAt = f.run.startedAt.addingTimeInterval(-100)
        delivered.status = .failed
        delivered.stopReason = TaskRunStopReason.failed.rawValue
        f.context.insert(delivered)
        try f.context.save()
        func answer() throws -> Bool {
            try TaskDeliverableHistoryReader.followsUpDeliveredRequest(ownerID: f.task.persistentModelID,
                runID: f.run.id, startedAt: f.run.startedAt, in: f.context)
        }
        func expectParity(_ expected: Bool) throws {
            #expect(try answer() == expected)
            #expect(TaskDeliverableExpectation.followsUpDeliveredRequest(runID: f.run.id,
                startedAt: f.run.startedAt, in: f.task) == expected)
        }
        try expectParity(false)
        delivered.status = .completed
        delivered.stopReason = TaskRunStopReason.completed.rawValue
        try expectParity(true) // unsaved completion, beyond every plan page
        f.context.rollback()
        try expectParity(false)

        let approval = TaskEvent(task: f.task, eventType: TaskEventTypes.Task.approved,
            payload: TaskDeliverableExpectation.userApprovalPayloadPrefix)
        approval.timestamp = f.run.startedAt.addingTimeInterval(-1)
        f.context.insert(approval)
        try expectParity(true)
        try f.context.save()
        approval.payload = "Synthetic runtime permission approval"
        try expectParity(false)
        f.context.rollback()
        try expectParity(true)
        f.context.delete(approval)
        try expectParity(false)
        f.context.rollback()
        try expectParity(true)
    }

    @Test("Conversation continuations beyond the first source page still qualify")
    func lateContinuationSource() throws {
        let f = try TaskDecisionOutcomeRefreshTests.Fixture()
        for event in f.task.events { f.context.delete(event) }
        for _ in 0..<40 {
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task,
                type: TaskEventTypes.ExecutionRequest.retry.rawValue,
                payload: TaskExecutionSourcePayloadV1(launchMode: .initial), run: f.run))
        }
        f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task,
            type: TaskEventTypes.ExecutionRequest.resume.rawValue,
            payload: TaskExecutionSourcePayloadV1(launchMode: .continuation), run: f.run))
        let finished = TaskEvent(task: f.task, eventType: TaskEventTypes.Plan.executionCompleted)
        finished.timestamp = f.run.startedAt.addingTimeInterval(-1)
        f.context.insert(finished)
        try f.context.save()
        #expect(try TaskDeliverableHistoryReader.followsUpDeliveredRequest(ownerID: f.task.persistentModelID,
            runID: f.run.id, startedAt: f.run.startedAt, in: f.context))
    }

    private func measureControl(_ fixture: Fixture) throws -> Double {
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let task = try fixture.task(in: context)
        var answer = false
        let cpu = cpuMilliseconds {
            answer = TaskDeliverableExpectation.followsUpDeliveredRequest(
                runID: fixture.latestRunID, startedAt: fixture.startedAt, in: task)
        }
        #expect(answer)
        return cpu
    }

    private func cpuMilliseconds(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @MainActor
    struct Fixture {
        let container: ModelContainer
        let taskID: UUID
        let latestRunID: UUID
        let startedAt: Date
        let snapshot: TaskThreadSnapshot

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("decision-cold-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = root.appendingPathComponent("synthetic.store")
            let seed = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: store)])
            let context = ModelContext(seed)
            context.autosaveEnabled = false
            let task = AgentTask(title: "Synthetic cold history", goal: "Synthetic conversation")
            task.status = .completed
            context.insert(task)
            var lastRun: TaskRun?, lastSource: TaskEvent?
            for index in 0..<1_000 {
                let run = TaskRun(task: task)
                run.startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                run.status = .completed
                run.stopReason = TaskRunStopReason.completed.rawValue
                run.setOutput(String(repeating: "Synthetic response data. ", count: 128))
                context.insert(run)
                let source = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage,
                    payload: "Synthetic follow-up \(index)", run: run)
                source.timestamp = run.startedAt
                context.insert(source)
                lastRun = run; lastSource = source
            }
            try context.save()
            let run = try #require(lastRun), source = try #require(lastSource)
            taskID = task.id; latestRunID = run.id; startedAt = run.startedAt
            snapshot = .init(goal: task.goal, createdAt: task.createdAt,
                events: [TaskEventSnapshot(event: source)], runs: [TaskRunSnapshot(input: .init(run: run))])
            // Match the disk scaling fixtures: keep stores/containers alive
            // until process exit to avoid SwiftData teardown races.
            retainedDecisionColdContainers.append(seed)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: store)])
            retainedDecisionColdContainers.append(container)
        }

        func task(in context: ModelContext) throws -> AgentTask {
            let target = taskID
            var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == target })
            descriptor.fetchLimit = 1
            return try #require(try context.fetch(descriptor).first)
        }
    }
}

@MainActor private var retainedDecisionColdContainers: [ModelContainer] = []
