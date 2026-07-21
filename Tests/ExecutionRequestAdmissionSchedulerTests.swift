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
            resourceIsAvailable: { $0.id != taskA.id }
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
            resourceIsAvailable: { $0.workspace?.id != blockedWorkspaceID }
        )

        #expect(selected?.task.id == tasks[1].id)
        let fields = ExecutionRequestQueueSnapshot.fields(projection: projection)
        #expect(fields["active_request_count"] == "120")
        #expect(fields["active_task_count"] == "60")
        #expect(fields["active_workspace_count"] == "3")
    }
}
