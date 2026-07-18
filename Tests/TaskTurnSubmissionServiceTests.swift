import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task turn submission")
@MainActor
struct TaskTurnSubmissionServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("Submission atomically persists the message and waiting request")
    func submissionPersistsMessageAndRequest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Follow up", goal: "Persist before admission")
        context.insert(task)
        try context.save()

        let result = TaskTurnSubmissionService.submit(
            message: "  Please continue safely.  ",
            for: task,
            into: context,
            at: Date(timeIntervalSince1970: 1_000)
        )
        guard case let .success(submission) = result else {
            Issue.record("Expected durable submission")
            return
        }

        let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>())
        let events = try context.fetch(FetchDescriptor<TaskEvent>())
        #expect(requests.count == 1)
        #expect(events.count == 1)
        #expect(requests[0].id == submission.requestID)
        #expect(requests[0].messageEventID == submission.eventID)
        #expect(requests[0].state == .waitingForWorker)
        #expect(requests[0].sequence == 1)
        #expect(events[0].id == submission.eventID)
        #expect(events[0].payload == "Please continue safely.")
        #expect(try TaskTurnRequestRepository.requests(for: task, in: context).map(\.id) == [submission.requestID])
    }

    @Test("Requests retain FIFO order and only allow guarded transitions")
    func requestsUseFifoAndGuardedTransitions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "FIFO", goal: "Keep turns ordered")
        context.insert(task)

        let first = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1)
        let second = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2)
        context.insert(second)
        context.insert(first)
        try context.save()

        #expect(try TaskTurnRequestRepository.activeRequests(for: task, in: context).map(\.id) == [first.id, second.id])
        let admitted = TaskTurnRequestStateMachine.transition(first, to: .admitted)
        #expect(admitted.changed)
        #expect(first.admittedAt != nil)
        let illegal = TaskTurnRequestStateMachine.transition(first, to: .completed)
        #expect(!illegal.changed)
        #expect(illegal.rejection == .illegalTransition(from: .admitted, to: .completed))
    }
}
