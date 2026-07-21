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
}
