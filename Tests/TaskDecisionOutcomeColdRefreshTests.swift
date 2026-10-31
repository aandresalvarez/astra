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

    @Test("Pending source inserts and deletes cannot omit plan evidence across run batches")
    func pendingSourcePages() throws {
        let fixture = try Fixture(runCount: 71, planRuns: true)
        for boundary in [0, 115, 146, 147, 148, 178, 179, 210, 211, 1_000] {
            let context = ModelContext(fixture.container)
            context.autosaveEnabled = false
            let task = try fixture.task(in: context)
            let runs = try context.fetch(FetchDescriptor<TaskRun>())
            let events = try context.fetch(FetchDescriptor<TaskEvent>())
            let run = try #require(runs.first { $0.id == Fixture.uuid("00000000", 169) })
            // Match production reversible edits without warming the cold-read benchmark.
            SwiftDataTaskRollbackPreparation.prepare(task)
            let noise = TaskEvent.structuredPayloadEvent(task: task,
                type: TaskEventTypes.ExecutionRequest.retry.rawValue,
                payload: TaskExecutionSourcePayloadV1(launchMode: .continuation), run: run)
            noise.id = Fixture.uuid("10000000", boundary * 10 + 5)
            noise.timestamp = Date(timeIntervalSince1970: 200)
            context.insert(noise)
            try expectParity(fixture, task: task, context: context, expected: false)
            context.rollback()
            try expectParity(fixture, task: task, context: context, expected: false)

            if let initial = events.first(where: { $0.id == Fixture.uuid("10000000", boundary * 10) }),
               TaskDeliverableExpectation.requestSource(type: initial.type, payload: initial.payload) == .other {
                SwiftDataTaskRollbackPreparation.prepare(task)
                context.delete(initial)
                try expectParity(fixture, task: task, context: context, expected: false)
                context.rollback()
                try expectParity(fixture, task: task, context: context, expected: false)
            }
        }
    }

    @Test("Pending run deletion and lifecycle edits preserve delivery beyond the first batch")
    func pendingRunPages() throws {
        let fixture = try Fixture(runCount: 71, planRuns: true)
        let seedContext = ModelContext(fixture.container)
        seedContext.autosaveEnabled = false
        let task = try fixture.task(in: seedContext)
        let delivered = TaskRun(task: task)
        delivered.startedAt = Date(timeIntervalSince1970: 10)
        delivered.status = .completed
        delivered.stopReason = TaskRunStopReason.completed.rawValue
        seedContext.insert(delivered)
        try seedContext.save()
        let deliveredID = delivered.id
        for index in [100, 105, 106, 137, 138, 169] {
            let context = ModelContext(fixture.container)
            context.autosaveEnabled = false
            let current = try fixture.task(in: context)
            let runs = try context.fetch(FetchDescriptor<TaskRun>())
            SwiftDataTaskRollbackPreparation.prepare(current)
            context.delete(try #require(runs.first { $0.id == Fixture.uuid("00000000", index) }))
            try expectParity(fixture, task: current, context: context, expected: true)
            context.rollback()
            let ordinary = try #require(runs.first { $0.id == deliveredID })
            SwiftDataTaskRollbackPreparation.prepare(current)
            ordinary.status = .failed
            try expectParity(fixture, task: current, context: context, expected: false)
            context.rollback()
            try expectParity(fixture, task: current, context: context, expected: true)
            SwiftDataTaskRollbackPreparation.prepare(current)
            context.delete(ordinary)
            try expectParity(fixture, task: current, context: context, expected: false)
        }
    }

    private func expectParity(_ fixture: Fixture, task: AgentTask, context: ModelContext, expected: Bool) throws {
        #expect(try TaskDeliverableHistoryReader.followsUpDeliveredRequest(ownerID: task.persistentModelID,
            runID: fixture.latestRunID, startedAt: fixture.startedAt, in: context) == expected)
        #expect(TaskDeliverableExpectation.followsUpDeliveredRequest(runID: fixture.latestRunID,
            startedAt: fixture.startedAt, in: task) == expected)
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

        init(runCount: Int = 1_000, planRuns: Bool = false) throws {
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
            for index in 0..<runCount {
                let run = TaskRun(task: task)
                if planRuns { run.id = Self.uuid("00000000", index + 100) }
                run.startedAt = Date(timeIntervalSince1970: planRuns
                    ? (index == runCount - 1 ? 1_000 : 100) : 1_700_000_000 + Double(index))
                run.status = .completed
                run.stopReason = TaskRunStopReason.completed.rawValue
                run.setOutput(String(repeating: "Synthetic response data. ", count: 128))
                context.insert(run)
                if planRuns, index < runCount - 1 {
                    for sourceIndex in 0..<3 {
                        let event = TaskEvent.structuredPayloadEvent(task: task,
                            type: TaskEventTypes.ExecutionRequest.retry.rawValue,
                            payload: TaskExecutionSourcePayloadV1(launchMode: sourceIndex == 2 ? .approvedPlan : .initial), run: run)
                        event.id = Self.uuid("10000000", (index * 3 + sourceIndex + 1) * 10)
                        event.timestamp = Date(timeIntervalSince1970: 200)
                        context.insert(event)
                    }
                    continue
                }
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

        static func uuid(_ family: String, _ number: Int) -> UUID {
            UUID(uuidString: family + "-0000-0000-0000-" + String(format: "%012X", number))!
        }
    }
}

@MainActor private var retainedDecisionColdContainers: [ModelContainer] = []
