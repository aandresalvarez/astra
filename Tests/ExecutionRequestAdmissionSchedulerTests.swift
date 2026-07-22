import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Execution request admission scheduler")
@MainActor
struct ExecutionRequestAdmissionSchedulerTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("Projection is global FIFO while exposing only one request per task")
    func globalFIFOWithTaskLocalFIFO() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspaceA = Workspace(name: "A", primaryPath: "/tmp/astra-scheduler-a")
        let workspaceB = Workspace(name: "B", primaryPath: "/tmp/astra-scheduler-b")
        let taskA = AgentTask(title: "A", goal: "A", workspace: workspaceA)
        let taskB = AgentTask(title: "B", goal: "B", workspace: workspaceB)
        context.insert(workspaceA)
        context.insert(workspaceB)
        context.insert(taskA)
        context.insert(taskB)

        let firstA = TaskTurnRequest(
            task: taskA,
            messageEventID: UUID(),
            sequence: 1,
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        let secondA = TaskTurnRequest(
            task: taskA,
            messageEventID: UUID(),
            sequence: 2,
            submittedAt: Date(timeIntervalSince1970: 11)
        )
        let firstB = TaskTurnRequest(
            task: taskB,
            messageEventID: UUID(),
            sequence: 1,
            submittedAt: Date(timeIntervalSince1970: 12)
        )
        context.insert(firstA)
        context.insert(secondA)
        context.insert(firstB)
        try context.save()

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)

        #expect(projection.ordered.map(\.request.id) == [firstA.id, firstB.id])
        #expect(!projection.ordered.contains { $0.request.id == secondA.id })
    }

    @Test("Blocked oldest project does not prevent unrelated project admission")
    func skipsOnlyUnavailableCandidate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspaceA = Workspace(name: "A", primaryPath: "/tmp/astra-scheduler-blocked")
        let workspaceB = Workspace(name: "B", primaryPath: "/tmp/astra-scheduler-free")
        let taskA = AgentTask(title: "Blocked", goal: "A", workspace: workspaceA)
        let taskB = AgentTask(title: "Free", goal: "B", workspace: workspaceB)
        context.insert(workspaceA)
        context.insert(workspaceB)
        context.insert(taskA)
        context.insert(taskB)
        let requestA = TaskTurnRequest(
            task: taskA,
            messageEventID: UUID(),
            sequence: 1,
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        let requestB = TaskTurnRequest(
            task: taskB,
            messageEventID: UUID(),
            sequence: 1,
            submittedAt: Date(timeIntervalSince1970: 11)
        )
        context.insert(requestA)
        context.insert(requestB)
        try context.save()

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let selected = ExecutionRequestAdmissionScheduler.nextCandidate(
            from: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: [],
            resourceIsAvailable: { $0.task.id != taskA.id }
        )

        #expect(selected?.request.id == requestB.id)
    }

    @Test("Active task cannot consume a second worker while another project can run")
    func oneWorkerPerTask() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspaceA = Workspace(name: "A", primaryPath: "/tmp/astra-scheduler-active")
        let workspaceB = Workspace(name: "B", primaryPath: "/tmp/astra-scheduler-other")
        let taskA = AgentTask(title: "Active", goal: "A", workspace: workspaceA)
        let taskB = AgentTask(title: "Other", goal: "B", workspace: workspaceB)
        context.insert(workspaceA)
        context.insert(workspaceB)
        context.insert(taskA)
        context.insert(taskB)
        let requestA = TaskTurnRequest(task: taskA, messageEventID: UUID(), sequence: 1)
        let requestB = TaskTurnRequest(task: taskB, messageEventID: UUID(), sequence: 1)
        context.insert(requestA)
        context.insert(requestB)
        try context.save()

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let selected = ExecutionRequestAdmissionScheduler.nextCandidate(
            from: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: [taskA.id],
            resourceIsAvailable: { _ in true }
        )

        #expect(selected?.task.id == taskB.id)
    }

    @Test("Candidate resource predicate admits a shared request beside a shared holder")
    func sharedRequestAdmitsBesideSharedHolder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let resourceKey = "/tmp/astra-scheduler-shared"
        let workspace = Workspace(name: "Shared", primaryPath: resourceKey)
        let holder = AgentTask(title: "Holder", goal: "Read current state", workspace: workspace)
        let candidateTask = AgentTask(title: "Candidate", goal: "Summarize current state", workspace: workspace)
        context.insert(workspace)
        context.insert(holder)
        context.insert(candidateTask)

        let sharedClaim = TaskExecutionResourceClaim(
            kind: .workspace,
            key: resourceKey,
            access: .shared
        )
        let request = TaskTurnRequest(
            task: candidateTask,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [sharedClaim]
        )
        context.insert(request)
        try context.save()

        let queue = TaskQueue(poolSize: 1)
        let held = try #require(queue.acquireResourceLockIfAvailable(
            task: holder,
            resourceKey: resourceKey,
            accessMode: .readOnly,
            runMode: "test"
        ))
        defer { queue.releaseResourceLock(held, task: holder, modelContext: context) }

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let selected = ExecutionRequestAdmissionScheduler.nextCandidate(
            from: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: [],
            resourceIsAvailable: { candidate in
                queue.canAcquireResourceLock(
                    for: candidate.task,
                    resourceKey: queue.resourceKey(for: candidate.request, task: candidate.task),
                    accessMode: queue.resourceAccess(for: candidate.request, task: candidate.task)
                )
            }
        )

        #expect(selected?.request.id == request.id)
        #expect(queue.resourceAccess(for: request, task: candidateTask) == .readOnly)
    }

    @Test("Candidate resource predicate skips an exclusive request but admits a shared peer")
    func sharedHolderBlocksExclusiveButNotSharedCandidate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let resourceKey = "/tmp/astra-scheduler-mixed-access"
        let workspace = Workspace(name: "Mixed", primaryPath: resourceKey)
        let holder = AgentTask(title: "Holder", goal: "Read current state", workspace: workspace)
        let writer = AgentTask(title: "Writer", goal: "Modify current state", workspace: workspace)
        let reader = AgentTask(title: "Reader", goal: "Summarize current state", workspace: workspace)
        context.insert(workspace)
        context.insert(holder)
        context.insert(writer)
        context.insert(reader)

        let writerRequest = TaskTurnRequest(
            task: writer,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [TaskExecutionResourceClaim(
                kind: .workspace,
                key: resourceKey,
                access: .exclusive
            )],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        let readerRequest = TaskTurnRequest(
            task: reader,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [TaskExecutionResourceClaim(
                kind: .workspace,
                key: resourceKey,
                access: .shared
            )],
            submittedAt: Date(timeIntervalSince1970: 11)
        )
        context.insert(writerRequest)
        context.insert(readerRequest)
        try context.save()

        let queue = TaskQueue(poolSize: 1)
        let held = try #require(queue.acquireResourceLockIfAvailable(
            task: holder,
            resourceKey: resourceKey,
            accessMode: .readOnly,
            runMode: "test"
        ))
        defer { queue.releaseResourceLock(held, task: holder, modelContext: context) }

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let selected = ExecutionRequestAdmissionScheduler.nextCandidate(
            from: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: [],
            resourceIsAvailable: { candidate in
                queue.canAcquireResourceLock(
                    for: candidate.task,
                    resourceKey: queue.resourceKey(for: candidate.request, task: candidate.task),
                    accessMode: queue.resourceAccess(for: candidate.request, task: candidate.task)
                )
            }
        )

        #expect(selected?.request.id == readerRequest.id)
        #expect(queue.resourceAccess(for: writerRequest, task: writer) == .write)
        #expect(queue.resourceAccess(for: readerRequest, task: reader) == .readOnly)
    }

    @Test("An earlier global writer prevents later readers from starving it across workspaces")
    @MainActor
    func globalWriterReservationPreventsReaderStarvation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstWorkspace = Workspace(name: "First", primaryPath: "/tmp/astra-fairness-first")
        let secondWorkspace = Workspace(name: "Second", primaryPath: "/tmp/astra-fairness-second")
        let holder = AgentTask(title: "Holder", goal: "Read account", workspace: firstWorkspace)
        let writer = AgentTask(title: "Writer", goal: "Update account", workspace: secondWorkspace)
        let laterReader = AgentTask(title: "Later reader", goal: "Read account", workspace: firstWorkspace)
        let unrelated = AgentTask(title: "Unrelated", goal: "Read another account", workspace: secondWorkspace)
        [firstWorkspace, secondWorkspace].forEach(context.insert)
        [holder, writer, laterReader, unrelated].forEach(context.insert)

        let writerRequest = TaskTurnRequest(
            task: writer,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [
                TaskExecutionResourceClaim(
                    kind: .workspace,
                    key: secondWorkspace.primaryPath,
                    access: .shared
                ),
                TaskExecutionResourceClaim(
                    kind: .accountSession,
                    key: "provider:shared-account",
                    access: .exclusive
                )
            ],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        let readerRequest = TaskTurnRequest(
            task: laterReader,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [
                TaskExecutionResourceClaim(
                    kind: .workspace,
                    key: firstWorkspace.primaryPath,
                    access: .shared
                ),
                TaskExecutionResourceClaim(
                    kind: .accountSession,
                    key: "provider:shared-account",
                    access: .shared
                )
            ],
            submittedAt: Date(timeIntervalSince1970: 11)
        )
        let unrelatedRequest = TaskTurnRequest(
            task: unrelated,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [
                TaskExecutionResourceClaim(
                    kind: .workspace,
                    key: secondWorkspace.primaryPath,
                    access: .shared
                ),
                TaskExecutionResourceClaim(
                    kind: .accountSession,
                    key: "provider:other-account",
                    access: .shared
                )
            ],
            submittedAt: Date(timeIntervalSince1970: 12)
        )
        [writerRequest, readerRequest, unrelatedRequest].forEach(context.insert)
        try context.save()

        let queue = TaskQueue(poolSize: 2)
        let holderClaims = TaskExecutionResourceBroker.lockClaims(
            for: [TaskExecutionResourceClaim(
                kind: .accountSession,
                key: "provider:shared-account",
                access: .shared
            )],
            taskID: holder.id,
            requestID: UUID(),
            runMode: "test"
        )
        let held = try #require(queue.acquireResourceLocksIfAvailable(holderClaims, task: holder))
        defer { queue.releaseResourceLocks(held, task: holder, modelContext: context) }

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let candidates = Dictionary(
            uniqueKeysWithValues: projection.ordered.map { ($0.request.id, $0) }
        )
        let writerCandidate = try #require(candidates[writerRequest.id])
        let readerCandidate = try #require(candidates[readerRequest.id])
        let unrelatedCandidate = try #require(candidates[unrelatedRequest.id])

        #expect(!queue.canAdmitResourceClaims(
            for: writerCandidate,
            in: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: []
        ))
        #expect(!queue.canAdmitResourceClaims(
            for: readerCandidate,
            in: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: []
        ))
        #expect(queue.canAdmitResourceClaims(
            for: unrelatedCandidate,
            in: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: []
        ))
    }

    @Test("Queue snapshot exposes durable backlog breadth without task content")
    func queueSnapshotReportsStateAndProjectBreadth() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspaces = (0..<3).map {
            Workspace(name: "Private \($0)", primaryPath: "/private/queue-snapshot-\($0)")
        }
        let tasks = workspaces.enumerated().map { index, workspace in
            AgentTask(title: "Secret \(index)", goal: "Never log this", workspace: workspace)
        }
        workspaces.forEach(context.insert)
        tasks.forEach(context.insert)

        let states: [TaskTurnRequestState] = [.waitingForWorker, .waitingForResource, .running]
        for (index, task) in tasks.enumerated() {
            context.insert(TaskTurnRequest(
                task: task,
                messageEventID: UUID(),
                sequence: 1,
                state: states[index],
                submittedAt: Date(timeIntervalSince1970: 100 + Double(index))
            ))
        }
        try context.save()

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let fields = ExecutionRequestQueueSnapshot.fields(
            projection: projection,
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(fields["active_request_count"] == "3")
        #expect(fields["admittable_task_count"] == "3")
        #expect(fields["active_task_count"] == "3")
        #expect(fields["active_workspace_count"] == "3")
        #expect(fields["waiting_worker_count"] == "1")
        #expect(fields["waiting_resource_count"] == "1")
        #expect(fields["running_request_count"] == "1")
        #expect(fields["oldest_wait_seconds"] == "100")

        let values = fields.values.joined(separator: " ")
        #expect(!values.contains("Secret"))
        #expect(!values.contains("Never log this"))
        #expect(!values.contains("/private/"))
    }

    @Test("Task-local sequence wins over an inverted submission timestamp")
    func taskLocalSequenceCannotBeOvertakenByTimestamp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "FIFO", primaryPath: "/tmp/astra-sequence-fifo")
        let task = AgentTask(title: "FIFO", goal: "Preserve order", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        let first = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 1,
            submittedAt: Date(timeIntervalSince1970: 20)
        )
        let second = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 2,
            submittedAt: Date(timeIntervalSince1970: 10)
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)

        #expect(projection.ordered.count == 1)
        #expect(projection.ordered.first?.request.id == first.id)
    }

    @Test("Three-project backlog remains FIFO per task and bypasses a blocked project at scale")
    func threeProjectStressAcceptance() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspaces = (0..<3).map {
            Workspace(name: "Project \($0)", primaryPath: "/tmp/astra-stress-project-\($0)")
        }
        workspaces.forEach(context.insert)

        var tasks: [AgentTask] = []
        var firstRequestIDs: [UUID] = []
        for index in 0..<60 {
            let task = AgentTask(
                title: "Task \(index)",
                goal: "Concurrent acceptance",
                workspace: workspaces[index % workspaces.count]
            )
            context.insert(task)
            tasks.append(task)

            let first = TaskTurnRequest(
                task: task,
                messageEventID: UUID(),
                sequence: 1,
                submittedAt: Date(timeIntervalSince1970: Double(index))
            )
            let second = TaskTurnRequest(
                task: task,
                messageEventID: UUID(),
                sequence: 2,
                submittedAt: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
            context.insert(first)
            context.insert(second)
            firstRequestIDs.append(first.id)
        }
        try context.save()

        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        #expect(projection.activeRequests.count == 120)
        #expect(projection.ordered.count == 60)
        #expect(projection.ordered.map(\.request.id) == firstRequestIDs)

        let blockedWorkspaceID = workspaces[0].id
        let selected = ExecutionRequestAdmissionScheduler.nextCandidate(
            from: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: [],
            resourceIsAvailable: { $0.task.workspace?.id != blockedWorkspaceID }
        )

        #expect(selected?.task.id == tasks[1].id)
        let fields = ExecutionRequestQueueSnapshot.fields(projection: projection)
        #expect(fields["active_request_count"] == "120")
        #expect(fields["active_task_count"] == "60")
        #expect(fields["active_workspace_count"] == "3")
    }
}
