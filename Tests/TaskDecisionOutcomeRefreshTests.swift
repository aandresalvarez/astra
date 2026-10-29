import Darwin
import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Decision outcome semantic refresh", .serialized)
@MainActor
struct TaskDecisionOutcomeRefreshTests {
    @Test("Snapshot inputs select legacy failure evidence by timestamp and UUID, ignoring later successful traffic")
    func legacyFailureTies() throws {
        let task = AgentTask(title: "Synthetic evidence", goal: "Synthetic publication")
        let maximum = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "gh pr create")
        maximum.id = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let minimum = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Read README.md")
        minimum.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let failure = TaskEvent(task: task, eventType: TaskEventTypes.Tool.resultFailed, payload: "Synthetic failure")
        for event in [maximum, minimum, failure] { event.timestamp = Date(timeIntervalSince1970: 50) }
        func inputs(_ extra: [TaskEvent] = []) -> TaskDecisionOutcomeRefresh.SnapshotInputs {
            .init(events: ([maximum, failure, minimum] + extra).map(TaskEventSnapshot.init), runs: [])
        }
        let original = inputs()
        #expect(Set(original.events.map(\.id)) == [maximum.id, failure.id])
        let later = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Read another file")
        later.timestamp = Date(timeIntervalSince1970: 51)
        #expect(inputs([later]) == original)
        minimum.payload = "Other irrelevant tool text"
        #expect(inputs() == original)
        maximum.payload = "Changed publication evidence"
        #expect(inputs() != original)
    }

    @Test("Long failure histories use a linear cancellable snapshot projection")
    func longFailureProjection() throws {
        let task = AgentTask(title: "Synthetic failures", goal: "Synthetic projection")
        let use = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Synthetic use")
        use.timestamp = Date(timeIntervalSince1970: 0)
        let window = [TaskEventSnapshot(event: use)] + (1...5_000).map { index in
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.resultFailed, payload: "Synthetic failure")
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            return TaskEventSnapshot(event: event)
        }
        func measure(_ count: Int) -> Double {
            let events = Array(window.prefix(count))
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            for _ in 0..<4 {
                let inputs = TaskDecisionOutcomeRefresh.SnapshotInputs(events: events, runs: [])
                #expect(inputs.events.count == count)
            }
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        }
        let small = measure(1_000), large = measure(5_000)
        #expect(large < small * 12, "Five times the rows must not cause quadratic growth")
        var checkpoints = 0
        #expect(throws: CancellationError.self) {
            try TaskDecisionOutcomeRefresh.SnapshotInputs(events: window, runs: [], cancellationCheck: {
                checkpoints += 1
                if checkpoints == 3 { throw CancellationError() }
            })
        }
    }

    @Test("Saved streaming bursts avoid history queries, including the full main-thread write and refresh path")
    func streamingBurstCost() throws {
        let before = try measureBurst(legacy: true)
        let after = try measureBurst(legacy: false)
        print("[decision-refresh] history=5000 snapshots=60 events=120 before_resolves=\(before.resolves) after_resolves=\(after.resolves) before_main_cpu_ms=\(before.cpu) after_main_cpu_ms=\(after.cpu) before_refresh_cpu_ms=\(before.refreshCPU) after_refresh_cpu_ms=\(after.refreshCPU)")
        #expect(before.resolves == 60)
        #expect(after.resolves == 0, "An irrelevant burst must issue zero decision-history reads")
        // Persistence dominates the full path. Keep its raw cost visible and
        // guard against a total regression; the refresh budget separately
        // bounds key construction as well as the removed history reads.
        #expect(after.cpu < before.cpu * 1.1, "Includes insert/save, change classification, snapshot/key construction and resolution")
        #expect(after.refreshCPU < before.refreshCPU * 0.25)
    }

    @Test("Relevant writes outside the transcript window, edits, deletions and recovery refresh the durable answer")
    func historyAndRecovery() throws {
        let f = try Fixture()
        let probe = Probe(task: f.task, context: f.context)
        defer { probe.stop() }
        var snapshot = f.snapshot(events: []) // deliberately omit all history
        probe.refresh(snapshot)
        #expect(probe.projection.outcomes.deliveredRequestFollowUpRunID == nil)

        let approval = TaskEvent(task: f.task, eventType: TaskEventTypes.Task.approved,
                                payload: TaskDeliverableExpectation.userApprovalPayloadPrefix)
        approval.timestamp = f.run.startedAt.addingTimeInterval(-1)
        f.context.insert(approval) // atomic services need not publish an insertion notice
        try f.context.save()
        probe.refresh(snapshot)
        #expect(probe.projection.outcomes.deliveredRequestFollowUpRunID == f.run.id)

        let mutation = TaskStagedConnectorMutation(runID: f.run.id, serviceType: "synthetic",
            operation: "create_item", connectorID: UUID().uuidString, connectorAlias: "fixture",
            target: "Synthetic destination", summary: "Synthetic proposal",
            stagedPayloadPath: "/tmp/synthetic-staged.json", requestDigest: "synthetic-digest")
        let staged = TaskEvent.structuredPayloadEvent(task: f.task, type: ConnectorMutationEventTypes.staged, payload: mutation)
        staged.timestamp = approval.timestamp
        f.context.insert(staged)
        try f.context.save()
        probe.refresh(snapshot)
        #expect(probe.projection.outcomes.pendingConnectorMutationTargets == [mutation.target])
        let declined = TaskEvent(task: f.task, type: ConnectorMutationEventTypes.declined,
                                payload: #"{"stagedPayloadPath":"/tmp/synthetic-staged.json"}"#)
        declined.timestamp = staged.timestamp.addingTimeInterval(0.5)
        f.context.insert(declined)
        try f.context.save()
        probe.refresh(snapshot)
        #expect(probe.projection.outcomes.pendingConnectorMutationTargets.isEmpty)
        declined.payload = "{}"
        try f.context.save()
        probe.refresh(snapshot)
        #expect(probe.projection.outcomes.pendingConnectorMutationTargets == [mutation.target])
        f.context.delete(staged)
        try f.context.save()
        probe.refresh(snapshot)
        #expect(probe.projection.outcomes.pendingConnectorMutationTargets.isEmpty)

        for status in [RunStatus.completed, .cancelled] {
            f.run.status = status
            f.run.stopReason = status == .completed ? TaskRunStopReason.completed.rawValue : "cancelled"
            try f.context.save()
            snapshot = f.snapshot(events: [])
            let previous = probe.resolves
            probe.refresh(snapshot)
            #expect(probe.resolves == previous + 1)
        }
        let recovered = Probe(task: f.task, context: f.context)
        defer { recovered.stop() }
        recovered.refresh(snapshot)
        #expect(recovered.projection.outcomes == probe.projection.outcomes)
        #expect(recovered.resolves == 1)

        let freshContext = ModelContext(f.container)
        freshContext.autosaveEnabled = false
        let reloadedTask = try #require(freshContext.model(for: f.task.persistentModelID) as? AgentTask)
        let reloaded = Probe(task: reloadedTask, context: freshContext)
        defer { reloaded.stop() }
        reloaded.refresh(snapshot)
        #expect(reloaded.projection.outcomes == probe.projection.outcomes)
    }

    @Test("Publication, review retirement, legacy failure evidence and artifact changes affect the key")
    func publicationAndArtifacts() throws {
        let f = try Fixture()
        let probe = Probe(task: f.task, context: f.context)
        defer { probe.stop() }
        let request = TaskEvent.structuredPayloadEvent(task: f.task, type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: TaskRequiredExternalOutcomeRequest(kind: .githubPullRequest, runID: f.run.id, message: "Synthetic publication"), run: f.run)
        f.context.insert(request)
        try f.context.save()
        probe.refresh(f.snapshot(events: [request]))
        #expect(probe.projection.outcomes.hasGitPublishRequest)
        let receipt = TaskEvent(task: f.task, type: TaskExternalOutcomeEventTypes.publicationReceipt, run: f.run)
        receipt.timestamp = request.timestamp.addingTimeInterval(1)
        f.context.insert(receipt)
        try f.context.save()
        probe.refresh(f.snapshot(events: [request, receipt]))
        #expect(!probe.projection.outcomes.hasGitPublishRequest)

        let key = probe.key(f.snapshot(events: []))
        #expect(key != TaskDecisionOutcomeRefresh.Key(task: f.task, snapshot: f.snapshot(events: []),
            artifactPaths: ["/tmp/synthetic-review.json"], saveRevision: probe.revision))
        for type in [GitHubReviewPublicationEventTypes.requested, GitHubReviewPublicationEventTypes.dispatched,
                     GitHubReviewPublicationEventTypes.unusable, ConnectorMutationEventTypes.receipt,
                     ConnectorMutationEventTypes.failed, ConnectorMutationEventTypes.indeterminate,
                     ConnectorMutationEventTypes.quarantined, TaskEventTypes.Tool.resultFailed.rawValue] {
            #expect(TaskDecisionOutcomeRefresh.affectsOutcomes(type))
        }
        let use = TaskEvent(task: f.task, eventType: TaskEventTypes.Tool.use, payload: "gh pr create", run: f.run)
        let failure = TaskEvent(task: f.task, eventType: TaskEventTypes.Tool.resultFailed, payload: "failed", run: f.run)
        use.timestamp = failure.timestamp.addingTimeInterval(-1)
        let legacyKey = probe.key(f.snapshot(events: [use, failure]))
        use.payload = "Read README.md"
        #expect(legacyKey != probe.key(f.snapshot(events: [use, failure])))
    }

    @Test("Imported copies sharing task, run and event UUIDs never share delivery evidence or projection keys")
    func importedOwners() throws {
        let f = try Fixture()
        let copy = AgentTask(title: f.task.title, goal: f.task.goal)
        copy.id = f.task.id
        f.context.insert(copy)
        let otherRun = TaskRun(task: copy)
        otherRun.id = f.run.id
        otherRun.startedAt = f.run.startedAt
        f.context.insert(otherRun)
        let source = TaskEvent(task: copy, eventType: TaskEventTypes.Conversation.userMessage, payload: "Synthetic follow-up", run: otherRun)
        source.id = try #require(f.task.events.first { $0.type == TaskEventTypes.Conversation.userMessage.rawValue }?.id)
        f.context.insert(source)
        let approval = TaskEvent(task: copy, eventType: TaskEventTypes.Task.approved,
                                payload: TaskDeliverableExpectation.userApprovalPayloadPrefix)
        approval.timestamp = f.run.startedAt.addingTimeInterval(-1)
        f.context.insert(approval)
        try f.context.save()
        let own = TaskDecisionOutcomeResolver.outcomes(task: f.task,
            latestRun: .init(id: f.run.id, startedAt: f.run.startedAt), windowEvents: [], decisionArtifactPaths: [], modelContext: f.context)
        let other = TaskDecisionOutcomeResolver.outcomes(task: copy,
            latestRun: .init(id: otherRun.id, startedAt: otherRun.startedAt), windowEvents: [], decisionArtifactPaths: [], modelContext: f.context)
        #expect(own.deliveredRequestFollowUpRunID == nil)
        #expect(other.deliveredRequestFollowUpRunID == otherRun.id)
        var switched = TaskDecisionOutcomeRefresh.Projection()
        switched.refresh(key: .init(task: f.task, snapshot: nil, artifactPaths: [], saveRevision: 0)) { own }
        switched.refresh(key: .init(task: copy, snapshot: nil, artifactPaths: [], saveRevision: 0)) { other }
        #expect(switched.outcomes == other)
        #expect(TaskDecisionOutcomeRefresh.Key(task: f.task, snapshot: nil, artifactPaths: [], saveRevision: 0)
            != TaskDecisionOutcomeRefresh.Key(task: copy, snapshot: nil, artifactPaths: [], saveRevision: 0))
        var tracker = TaskDecisionOutcomeRefresh.SaveTracker()
        f.context.insert(TaskEvent(task: copy, type: ConnectorMutationEventTypes.declined))
        let invalidated = tracker.record(context: f.context, task: f.task)
        #expect(!invalidated)
    }

    @Test("Delivery evidence remains exact beyond fifty intermediate plan completions")
    func deliveryBeyondRunWindow() throws {
        let f = try Fixture()
        let delivered = TaskRun(task: f.task)
        delivered.startedAt = f.run.startedAt.addingTimeInterval(-1_000)
        delivered.status = .completed
        delivered.stopReason = TaskRunStopReason.completed.rawValue
        f.context.insert(delivered)
        for index in 0..<60 {
            let step = TaskRun(task: f.task)
            step.startedAt = f.run.startedAt.addingTimeInterval(Double(index - 100))
            step.status = .completed
            step.stopReason = TaskRunStopReason.completed.rawValue
            f.context.insert(step)
            f.context.insert(TaskEvent.structuredPayloadEvent(task: f.task,
                type: TaskEventTypes.ExecutionRequest.planStep.rawValue,
                payload: TaskExecutionSourcePayloadV1(launchMode: .approvedPlan), run: step))
        }
        try f.context.save()
        let probe = Probe(task: f.task, context: f.context)
        defer { probe.stop() }
        probe.refresh(f.snapshot(events: []))
        #expect(probe.projection.outcomes.deliveredRequestFollowUpRunID == f.run.id)
    }

    private func measureBurst(legacy: Bool) throws -> (cpu: Double, refreshCPU: Double, resolves: Int) {
        let fixture = try TaskMainActorScalingGateTests.Fixture(eventCount: 5_000)
        let context = fixture.container.mainContext
        context.autosaveEnabled = false
        let task = try #require(try fixture.task(in: context))
        task.status = .running
        let run = TaskRun(task: task)
        context.insert(run)
        let source = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Synthetic follow-up", run: run)
        context.insert(source)
        try context.save()
        let probe = Probe(task: task, context: context)
        defer { probe.stop() }
        let runValue = TaskRunSnapshot(input: .init(run: run))
        func snapshot(_ event: TaskEvent? = nil) -> TaskThreadSnapshot {
            .init(goal: task.goal, createdAt: task.createdAt,
                  events: ([source] + (event.map { [$0] } ?? [])).map(TaskEventSnapshot.init), runs: [runValue])
        }
        probe.refresh(snapshot())
        // Warm the lifecycle classifier, just as the first run save does.
        run.setOutput("Synthetic stream begins")
        try context.save()
        probe.refresh(snapshot())
        let initialResolves = probe.resolves
        var refreshCPU = 0.0
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for index in 0..<60 {
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Read synthetic-\(index).md", run: run)
            context.insert(event)
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.result, payload: "Synthetic result", run: run))
            run.setOutput("Synthetic streamed response \(index)")
            try context.save()
            let current = snapshot(event)
            let refreshStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            if legacy {
                // The previous view ran this on every updatedAt/snapshot
                // revision, with the bounded delivery query on main.
                _ = try TaskDeliverableExpectation.followsUpDeliveredRequest(taskID: task.id,
                    runID: run.id, startedAt: run.startedAt, in: context)
                _ = TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task,
                    targetRunID: run.id, events: current.sortedEvents.map {
                        .init(id: $0.id, runID: $0.runID, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
                    })
                _ = ConnectorMutationRequirementResolver.pendingMutations(task: task)
                probe.resolves += 1
            } else {
                probe.refresh(current)
            }
            refreshCPU += Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - refreshStart) / 1_000_000
        }
        return (Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000,
                refreshCPU, probe.resolves - initialResolves)
    }

    @MainActor
    final class Probe {
        let task: AgentTask
        let context: ModelContext
        var tracker = TaskDecisionOutcomeRefresh.SaveTracker()
        var revision = 0
        var resolves = 0
        var projection = TaskDecisionOutcomeRefresh.Projection()
        var observer: NSObjectProtocol?

        init(task: AgentTask, context: ModelContext) {
            self.task = task; self.context = context
            observer = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.tracker.record(context: self.context, task: self.task) { self.revision += 1 }
                }
            }
        }
        func stop() { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func key(_ snapshot: TaskThreadSnapshot) -> TaskDecisionOutcomeRefresh.Key {
            .init(task: task, snapshot: snapshot, artifactPaths: [], saveRevision: revision)
        }
        func refresh(_ snapshot: TaskThreadSnapshot) {
            projection.refresh(key: key(snapshot)) {
                resolves += 1
                return TaskDecisionOutcomeResolver.outcomes(task: task,
                    latestRun: snapshot.latestRun.map { .init(id: $0.id, startedAt: $0.startedAt) },
                    windowEvents: snapshot.sortedEvents.map {
                        .init(id: $0.id, runID: $0.runID, type: $0.type, payload: $0.payload, timestamp: $0.timestamp)
                    }, decisionArtifactPaths: [], modelContext: context)
            }
        }
    }

    @MainActor
    struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let run: TaskRun
        init() throws {
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            context = ModelContext(container)
            context.autosaveEnabled = false
            task = AgentTask(title: "Synthetic task", goal: "Synthetic follow-up")
            context.insert(task)
            run = TaskRun(task: task)
            context.insert(run)
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Synthetic message", run: run))
            try context.save()
        }
        func snapshot(events: [TaskEvent]) -> TaskThreadSnapshot {
            .init(goal: task.goal, createdAt: task.createdAt, events: events.map(TaskEventSnapshot.init),
                  runs: [TaskRunSnapshot(input: .init(run: run))])
        }
    }
}
