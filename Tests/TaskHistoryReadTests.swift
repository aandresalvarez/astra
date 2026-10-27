import Foundation
import SwiftData
import Testing
import ASTRACore
@testable import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Task history reads")
@MainActor
struct TaskHistoryReadTests {
    @Test("Rolling back a policy change immediately restores the durable policy")
    func rolledBackPolicyIsNotUsed() async throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()
        let event = TaskEvent(task: fixture.task, type: TaskPolicyStore.selectedPolicyEventType,
                              payload: #"{"level":"autonomous","source":"t","selectedAt":0}"#)
        fixture.context.insert(event)
        #expect(TaskPolicyStore.latestSelectedLevel(for: fixture.task) == .autonomous)
        fixture.context.rollback()
        #expect(TaskPolicyStore.latestSelectedLevel(for: fixture.task) == .review)
    }

    @Test("Run completion is visible before another event or rebuild")
    func completedRunIsCurrent() async throws {
        let fixture = try Fixture()
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        try fixture.context.save()
        run.status = .completed
        run.stopReason = TaskRunStopReason.completed.rawValue
        run.completedAt = Date()
        #expect(TaskHistoryRead.runs(for: fixture.task).first?.runStatus == .completed)
        #expect(TaskHistoryRead.runs(for: fixture.task).first?.stopReason == TaskRunStopReason.completed.rawValue)
    }

    @Test("An event edited after initialization is read with its final payload")
    func editedEventIsCurrent() async throws {
        let fixture = try Fixture()
        try fixture.context.save()
        let event = TaskEvent(task: fixture.task, eventType: TaskEventTypes.Conversation.userMessage, payload: "draft")
        fixture.context.insert(event)
        event.payload = "final"
        #expect(TaskHistoryRead.record(id: event.id, in: fixture.task)?.payload == "final")
    }

    @Test("Queries preserve the rules that previously replayed the relationship")
    func consumersReadCurrentHistory() throws {
        let fixture = try Fixture()
        fixture.seedHistory()
        try fixture.context.save()
        let answers = Answers(fixture)
        #expect(answers.policyLevel == .review)
        #expect(answers.planStatus == .approved)
        #expect(answers.firstRequest == "Write the cohort report")
        #expect(answers.pendingMutationPaths == ["/tmp/staged/one.json"])
        #expect(answers.reviewCandidates.first == "/tmp/review.json")
        #expect(answers.containsFirstEvent)
        for type in Set(fixture.task.events.map(\.type)) {
            #expect(TaskHistoryRead.records(for: fixture.task, ofTypes: [type]) == fixture.legacyRecords(ofType: type))
        }
    }

    @Test("Pending insert, relink, deletion and rollback are visible immediately")
    func pendingChangesStayCurrent() throws {
        let f = try Fixture()
        let event = TaskEvent(task: f.task, type: "user.message", payload: "saved")
        f.context.insert(event)
        try f.context.save()
        let run = TaskRun(task: f.task)
        f.context.insert(run)
        event.run = run
        #expect(TaskHistoryRead.record(id: event.id, in: f.task)?.runID == run.id)
        f.context.delete(event)
        #expect(!TaskHistoryRead.contains(eventID: event.id, in: f.task))
        f.context.rollback()
        #expect(TaskHistoryRead.record(id: event.id, in: f.task)?.payload == "saved")
        #expect(TaskHistoryRead.record(id: event.id, in: f.task)?.runID == nil)
    }

    @Test("Imported copies with identical task, event and run UUIDs stay independent")
    func duplicateIdentifiersDoNotMixOwners() throws {
        let f = try Fixture()
        let duplicate = AgentTask(title: "Copy", goal: "g", workspace: f.workspace)
        duplicate.id = f.task.id
        f.context.insert(duplicate)
        let first = TaskEvent(task: f.task, type: "user.message", payload: "original")
        let second = TaskEvent(task: duplicate, type: "user.message", payload: "copy")
        second.id = first.id
        f.context.insert(first)
        f.context.insert(second)
        let run = TaskRun(task: f.task)
        let otherRun = TaskRun(task: duplicate)
        otherRun.id = run.id
        run.status = .completed
        f.context.insert(run)
        f.context.insert(otherRun)
        try f.context.save()
        #expect(TaskHistoryRead.record(id: first.id, in: f.task)?.payload == "original")
        #expect(TaskHistoryRead.record(id: second.id, in: duplicate)?.payload == "copy")
        #expect(TaskHistoryRead.runs(for: f.task).map(\.runStatus) == [.completed])
        #expect(TaskHistoryRead.runs(for: duplicate).map(\.runStatus) == [.running])
        #expect(TaskHistoryRead.records(for: duplicate, ofTypes: ["user.message"]).count == 1)
        #expect(TaskHistoryRead.events(for: duplicate).map(\.payload) == ["copy"])
    }

    @Test("Uncommitted events in another context cannot change this context's policy")
    func contextsDoNotSharePendingPolicy() throws {
        let f = try Fixture()
        f.seedHistory()
        try f.context.save()
        let other = ModelContext(f.container)
        other.autosaveEnabled = false
        let id = f.task.id
        let task = try #require(other.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        let event = TaskEvent(task: task, type: TaskPolicyStore.selectedPolicyEventType,
                              payload: #"{"level":"autonomous","source":"t","selectedAt":0}"#)
        other.insert(event)
        #expect(TaskPolicyStore.latestSelectedLevel(for: task) == .autonomous)
        #expect(TaskPolicyStore.latestSelectedLevel(for: f.task) == .review)
        other.rollback()
        #expect(TaskPolicyStore.latestSelectedLevel(for: f.task) == .review)
    }

    @Test("Legacy permission reads track pending approvals and rollback without crossing task owners")
    func legacyPermissionsStayCurrent() throws {
        let f = try Fixture()
        f.context.autosaveEnabled = false
        f.task.runtimePermissionOpenRequestsJSON = nil
        let duplicate = AgentTask(title: "Imported copy", goal: "g", workspace: f.workspace)
        duplicate.id = f.task.id
        f.context.insert(duplicate)
        let request = TaskEvent(task: f.task, type: "permission.approval.requested",
                                payload: "Runtime grant: Bash(gh pr list *)")
        request.timestamp = Date(timeIntervalSince1970: 1_000)
        f.context.insert(request)
        let otherApproval = TaskEvent(task: duplicate, type: "task.approved", payload: "approved")
        otherApproval.timestamp = request.timestamp.addingTimeInterval(1)
        f.context.insert(otherApproval)
        try f.context.save()
        #expect(TaskRuntimePermissionState.build(task: f.task).hasOpenApprovalRequest)
        // Match production reversible edits: materialize the task relationships
        // before SwiftData captures a rollback snapshot. The reader itself stays pure.
        SwiftDataTaskRollbackPreparation.prepare(f.task)
        let approval = TaskEvent(task: f.task, type: "task.approved", payload: "approved")
        approval.timestamp = request.timestamp.addingTimeInterval(2)
        f.context.insert(approval)
        #expect(!TaskRuntimePermissionState.build(task: f.task).hasOpenApprovalRequest)
        f.context.rollback()
        #expect(TaskRuntimePermissionState.build(task: f.task).hasOpenApprovalRequest)
        SwiftDataTaskRollbackPreparation.prepare(f.task)
        f.context.delete(request)
        #expect(!TaskRuntimePermissionState.build(task: f.task).hasOpenApprovalRequest)
        f.context.rollback()
    }

    @Test("Legacy grants respect pending changes, rollback, runtime and persistent task ownership")
    func legacyGrantsStayCurrent() throws {
        let f = try Fixture()
        f.context.autosaveEnabled = false
        let duplicate = AgentTask(title: "Imported copy", goal: "g", workspace: f.workspace)
        duplicate.id = f.task.id
        f.context.insert(duplicate)
        func grantEvent(_ task: AgentTask, runtime: AgentRuntimeID, label: String) throws -> TaskEvent {
            let payload = TaskRuntimePermissionGrants.Payload(
                brokerVersion: PermissionBroker.brokerVersion, providerID: runtime,
                grants: [.credential(label: label)], approvedAt: Date(), source: "legacy-test"
            )
            let event = TaskEvent(task: task, type: TaskRuntimePermissionGrants.eventType,
                                  payload: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self))
            f.context.insert(event)
            return event
        }
        let own = try grantEvent(f.task, runtime: .codexCLI, label: "own")
        _ = try grantEvent(duplicate, runtime: .codexCLI, label: "other-owner")
        _ = try grantEvent(f.task, runtime: .claudeCode, label: "other-runtime")
        try f.context.save()
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: f.task, runtime: .codexCLI) == ["own"])
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: f.task).isEmpty)
        SwiftDataTaskRollbackPreparation.prepare(f.task)
        _ = try grantEvent(f.task, runtime: .codexCLI, label: "pending")
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: f.task, runtime: .codexCLI) == ["own", "pending"])
        f.context.rollback()
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: f.task, runtime: .codexCLI) == ["own"])
        SwiftDataTaskRollbackPreparation.prepare(f.task)
        f.context.delete(own)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: f.task, runtime: .codexCLI).isEmpty)
        f.context.rollback()
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: f.task, runtime: .codexCLI) == ["own"])
    }

    @Test("Prefix and payload queries preserve ownership with duplicate UUIDs and pending edits")
    func narrowedRecoveryQueriesStayOwned() throws {
        let f = try Fixture()
        f.context.autosaveEnabled = false
        let duplicate = AgentTask(title: "Copy", goal: "g", workspace: f.workspace)
        duplicate.id = f.task.id
        f.context.insert(duplicate)
        let own = TaskEvent(task: f.task, type: "execution.request.future_kind", payload: "same")
        let other = TaskEvent(task: duplicate, type: own.type, payload: own.payload)
        other.id = own.id
        f.context.insert(own); f.context.insert(other)
        try f.context.save()
        #expect(TaskHistoryRead.events(for: f.task, ofTypes: ["user.message"], orTypePrefix: "execution.request.").map(\.persistentModelID) == [own.persistentModelID])
        #expect(TaskHistoryRead.events(for: f.task, matchingPayload: "same").map(\.persistentModelID) == [own.persistentModelID])
        SwiftDataTaskRollbackPreparation.prepare(f.task)
        own.payload = "edited"
        #expect(TaskHistoryRead.events(for: f.task, matchingPayload: "same").isEmpty)
        #expect(TaskHistoryRead.events(for: f.task, matchingPayload: "edited").map(\.id) == [own.id])
        f.context.rollback()
        #expect(TaskHistoryRead.events(for: f.task, matchingPayload: "same").map(\.persistentModelID) == [own.persistentModelID])
    }

    @Test("Detached task recovery queries keep their relationship fallback")
    func detachedRecoveryQueries() {
        let task = AgentTask(title: "Detached", goal: "g")
        let request = TaskEvent(task: task, type: "execution.request.future_kind", payload: "same")
        let unrelated = TaskEvent(task: task, type: "tool.result", payload: "unrelated")
        task.events = [request, unrelated]
        #expect(TaskHistoryRead.events(for: task, ofTypes: ["user.message"], orTypePrefix: "execution.request.").map(\.id) == [request.id])
        #expect(TaskHistoryRead.events(for: task, matchingPayload: "same").map(\.id) == [request.id])
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
            containsFirstEvent = TaskHistoryRead.contains(eventID: fixture.firstEventID ?? UUID(), in: task)
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
            retainedHistoryTestContainers.append(container)
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

@MainActor private var retainedHistoryTestContainers: [ModelContainer] = []
