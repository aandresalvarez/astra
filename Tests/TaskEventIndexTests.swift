import Foundation
import SwiftData
import Testing
import ASTRACore
@testable import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// `TaskEventIndex` is a derived owner: everything it answers must be what
/// reading `task.events` answers, at every point a caller can ask. These pin
/// the ways it learns about changes — the off-main build, the fold from
/// `TaskEvent.init`, deletions, relinks, staleness — and that every rule moved
/// onto it answers exactly as it did before.
@Suite("Task event index")
@MainActor
struct TaskEventIndexTests {
    @Test("A prepared task's facts match its event log")
    func preparedFactsMatchTheEventLog() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()

        await TaskEventIndex.shared.prepare(fixture.task)

        let facts = try #require(TaskEventIndex.shared.facts(for: fixture.task))
        #expect(facts.eventCount == fixture.task.events.count)
        #expect(facts.latestEventAt == fixture.task.events.map(\.timestamp).max())
        for type in Set(fixture.task.events.map(\.type)) where TaskEventFacts.isIndexed(type) {
            #expect(facts.records(ofType: type).map(\.id) == fixture.legacyRecords(ofType: type).map(\.id), "\(type)")
        }
        #expect(Set(facts.runs.map(\.id)) == Set(fixture.task.runs.map(\.id)))
        #expect(facts.contains(eventID: try #require(fixture.task.events.first).id))
    }

    @Test("An event created after preparing is readable at once, without another build")
    func createdEventsFoldSynchronously() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()
        await TaskEventIndex.shared.prepare(fixture.task)
        let before = try #require(TaskEventIndex.shared.facts(for: fixture.task))

        let event = TaskEvent(task: fixture.task, type: TaskPolicyStore.selectedPolicyEventType, payload: #"{"level":"autonomous","source":"t","selectedAt":0}"#)
        fixture.context.insert(event)

        let after = try #require(TaskEventIndex.shared.facts(for: fixture.task))
        #expect(after.eventCount == before.eventCount + 1)
        #expect(after.revision > before.revision)
        #expect(after.records(ofType: TaskPolicyStore.selectedPolicyEventType).last?.id == event.id)
        #expect(TaskPolicyStore.latestSelectedLevel(for: fixture.task) == .autonomous)
    }

    @Test("Unsaved inserts made before the build are part of what it publishes")
    func unsavedInsertsAreMergedIntoTheBuild() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()
        let unsaved = TaskEvent(task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "not saved yet")
        fixture.context.insert(unsaved)

        await TaskEventIndex.shared.prepare(fixture.task)

        let facts = try #require(TaskEventIndex.shared.facts(for: fixture.task))
        #expect(facts.contains(eventID: unsaved.id))
        #expect(facts.eventCount == fixture.task.events.count)
    }

    @Test("A deletion leaves the index, saved or rolled back")
    func deletionsLeaveTheIndex() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()
        await TaskEventIndex.shared.prepare(fixture.task)
        let staged = TaskEvent(task: fixture.task, type: ConnectorMutationEventTypes.staged, payload: "{}")
        fixture.context.insert(staged)
        #expect(TaskEventIndex.shared.facts(for: fixture.task)?.contains(eventID: staged.id) == true)

        // The shape of every failed-save rollback: unlink, then delete.
        fixture.task.events.removeAll { $0.id == staged.id }
        TaskEventIndex.delete(staged, from: fixture.context)

        let facts = try #require(TaskEventIndex.shared.facts(for: fixture.task))
        #expect(!facts.contains(eventID: staged.id))
        #expect(!facts.records(ofType: ConnectorMutationEventTypes.staged).contains { $0.id == staged.id })
    }

    @Test("A source event linked to its run after the fact carries the run")
    func relinkedEventsCarryTheirRun() async throws {
        let fixture = try Fixture()
        try fixture.context.save()
        await TaskEventIndex.shared.prepare(fixture.task)
        let message = TaskEvent(task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "go")
        fixture.context.insert(message)
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)

        message.run = run
        TaskEventIndex.shared.noteChanged(message)

        let facts = try #require(TaskEventIndex.shared.facts(for: fixture.task))
        #expect(facts.record(id: message.id)?.runID == run.id)
        #expect(facts.records(ofType: TaskEventTypes.Conversation.userMessage.rawValue).count == 1)
        #expect(facts.runs.contains { $0.id == run.id && $0.runStatus == .running })
    }

    @Test("A stale index keeps answering and rebuilds on the next read")
    func staleIndexRebuildsOnRead() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()
        await TaskEventIndex.shared.prepare(fixture.task)
        let before = try #require(TaskEventIndex.shared.facts(for: fixture.task))

        TaskEventIndex.shared.markStale(taskID: fixture.task.id)
        #expect(TaskEventIndex.shared.facts(for: fixture.task)?.revision == before.revision)

        var rebuilt = false
        for _ in 0..<500 where !rebuilt {
            await Task.yield()
            rebuilt = (TaskEventIndex.shared.facts(for: fixture.task)?.revision ?? 0) > before.revision
        }
        #expect(rebuilt, "the stale entry must be rebuilt by the read that found it stale")
        #expect(TaskEventIndex.shared.facts(for: fixture.task)?.eventCount == fixture.task.events.count)
    }

    @Test("A task nobody prepared has no facts and keeps none")
    func unpreparedTasksAreNotIndexed() throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        #expect(TaskEventIndex.shared.facts(for: fixture.task) == nil)
        #expect(!TaskEventIndex.shared.isPrepared(fixture.task.id))
        // Readers still answer, from the events.
        #expect(TaskPolicyStore.latestSelectedLevel(for: fixture.task) == .review)
    }

    @Test("Preparing past capacity evicts the least recently used task")
    func capacityEvictsLeastRecentlyUsed() async throws {
        let index = TaskEventIndex(capacity: 2)
        let fixture = try Fixture()
        let tasks = (0..<3).map { index in
            let task = AgentTask(title: "T\(index)", goal: "g", workspace: fixture.workspace)
            fixture.context.insert(task)
            return task
        }
        try fixture.context.save()
        await index.prepare(tasks[0])
        await index.prepare(tasks[1])
        _ = index.facts(for: tasks[0])
        await index.prepare(tasks[2])

        #expect(index.isPrepared(tasks[0].id))
        #expect(!index.isPrepared(tasks[1].id))
        #expect(index.isPrepared(tasks[2].id))
    }

    @Test("Every rule moved onto the index answers as reading the events does")
    func consumersAnswerTheSameWithAndWithoutTheIndex() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()

        TaskEventIndex.shared.forget(taskID: fixture.task.id)
        let legacy = Answers(fixture)
        await TaskEventIndex.shared.prepare(fixture.task)
        #expect(TaskEventIndex.shared.isPrepared(fixture.task.id))
        let indexed = Answers(fixture)

        #expect(indexed == legacy)
        #expect(legacy.policyLevel == .review)
        #expect(legacy.planStatus == .approved)
        #expect(legacy.firstRequest == "Write the cohort report")
        #expect(legacy.pendingMutationPaths == ["/tmp/staged/one.json"])
        #expect(legacy.reviewCandidates.first == "/tmp/review.json")
    }

    // MARK: - Fixture

    struct Answers: Equatable {
        let policyLevel: AgentPolicyLevel?
        let planStatus: TaskPlanLifecycleStatus
        let planStepCount: Int
        let firstRequest: String?
        let pendingMutationPaths: [String]
        let recordedStagedPaths: Set<String>
        let reviewCandidates: [String]
        let followsUp: Bool
        let worktreeState: String
        let containsFirstEvent: Bool

        @MainActor
        init(_ fixture: Fixture) {
            let task = fixture.task
            policyLevel = TaskPolicyStore.latestSelectedLevel(for: task)
            let plan = TaskPlanService.reconstruct(for: task)
            planStatus = plan.lifecycleStatus
            planStepCount = plan.plan?.steps.count ?? 0
            firstRequest = TaskContextStateManager.firstConversationRequestValue(for: task)
            pendingMutationPaths = ConnectorMutationRequirementResolver.pendingMutations(task: task).map(\.stagedPayloadPath)
            recordedStagedPaths = ConnectorMutationRequirementResolver.recordedStagedPaths(task: task)
            reviewCandidates = GitHubReviewPublicationService.candidatePaths(task: task, filePaths: ["/tmp/other.json"])
            followsUp = fixture.latestRun.map { TaskDeliverableExpectation.followsUpDeliveredRequest($0, in: task) } ?? false
            worktreeState = String(describing: TaskWorktreeBinding.state(of: task))
            containsFirstEvent = TaskEventIndex.contains(eventID: fixture.firstEventID ?? UUID(), in: task)
        }
    }

    @MainActor
    final class Fixture {
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let task: AgentTask
        var latestRun: TaskRun?
        var firstEventID: UUID?

        init() throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            retainedIndexTestContainers.append(container)
            context = container.mainContext
            workspace = Workspace(name: "Index", primaryPath: "/tmp/astra-index-\(UUID().uuidString)")
            task = AgentTask(title: "Indexed", goal: "Write the cohort report", workspace: workspace)
            task.status = .completed
            context.insert(workspace)
            context.insert(task)
        }

        /// Two conversation turns with tool traffic, a policy choice, an
        /// approved plan, a staged connector write (one resolved, one not), a
        /// review request, and a prepared worktree that no longer verifies.
        func seedHistory() {
            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            func record(_ type: String, _ payload: String, run: TaskRun? = nil) {
                clock = clock.addingTimeInterval(1)
                let event = TaskEvent(task: task, type: type, payload: payload, run: run)
                event.timestamp = clock
                context.insert(event)
                if firstEventID == nil { firstEventID = event.id }
            }
            record(TaskPolicyStore.selectedPolicyEventType, #"{"level":"review","source":"seed","selectedAt":0}"#)
            for (turn, message) in ["Write the cohort report", "Now add the counts"].enumerated() {
                let run = TaskRun(task: task)
                clock = clock.addingTimeInterval(1)
                run.startedAt = clock
                context.insert(run)
                record(TaskEventTypes.Conversation.userMessage.rawValue, message, run: run)
                for call in 0..<4 {
                    record(TaskEventTypes.Tool.use.rawValue, "call \(turn).\(call)", run: run)
                    record(TaskEventTypes.Tool.result.rawValue, "result \(turn).\(call)", run: run)
                }
                record(TaskEventTypes.Conversation.agentResponse.rawValue, "done \(turn)", run: run)
                run.status = .completed
                run.stopReason = TaskRunStopReason.completed.rawValue
                latestRun = run
            }
            func stamp(_ event: TaskEvent) {
                clock = clock.addingTimeInterval(1)
                event.timestamp = clock
            }
            let plan = TaskPlanPayload(title: "Report", goal: "Write the cohort report",
                                       steps: [.init(id: "s1", title: "Draft", likelyTools: [])])
            stamp(TaskPlanService.recordCreated(plan, task: task, modelContext: context))
            stamp(TaskPlanService.recordApproved(plan, task: task, modelContext: context))
            for path in ["/tmp/staged/one.json", "/tmp/staged/two.json"] {
                let staged = TaskStagedConnectorMutation(
                    runID: latestRun?.id ?? UUID(), serviceType: "jira", operation: "create_issue",
                    connectorID: "c", connectorAlias: "jira", target: "STAR / Bug", summary: "s",
                    stagedPayloadPath: path, requestDigest: "d", authorization: nil
                )
                let event = TaskEvent.structuredPayloadEvent(
                    task: task, type: ConnectorMutationEventTypes.staged, payload: staged, run: latestRun
                )
                stamp(event)
                context.insert(event)
            }
            record(ConnectorMutationEventTypes.declined, #"{"stagedPayloadPath":"/tmp/staged/two.json"}"#)
            record(GitHubReviewPublicationEventTypes.requested, #"{"filePath":"/tmp/review.json","contentDigest":"ab"}"#)
            let prepared = TaskWorktreePayload(repositoryPath: "/tmp/no-repo", worktreePath: "/tmp/no-worktree", branch: "b")
            record(TaskEventTypes.Task.worktreePrepared.rawValue, String(decoding: (try? JSONEncoder().encode(prepared)) ?? Data(), as: UTF8.self))
            task.executionRootPath = "/tmp/no-worktree"
        }

        func legacyRecords(ofType type: String) -> [TaskEventRecord] {
            task.events.filter { $0.type == type }
                .map(TaskEventRecord.init(event:))
                .sorted(by: TaskEventRecord.isChronologicallyOrdered)
        }
    }
}

@MainActor private var retainedIndexTestContainers: [ModelContainer] = []
