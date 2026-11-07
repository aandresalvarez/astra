import Foundation
import Darwin
import SwiftData
import ASTRAModels

/// Standalone synthetic fixture enrichment. No app/provider is started and no
/// credential is read. Compile against the matching benchmark model objects.
@main
struct ExportRequestFixture {
    private static func fail(_ message: String) -> Never {
        fputs(message + "\n", stderr)
        exit(2)
    }
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fail("usage: ExportRequestFixture GENERATED_FIXTURE_COPY") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard try String(contentsOf: root.appendingPathComponent("synthetic-export-fixture.txt"), encoding: .utf8)
                == "20261106:representative" else { fail("requires a generated synthetic fixture") }
        let container = try ModelContainer(for: ASTRASchema.current,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("source.store"))])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try context.fetchCount(FetchDescriptor<TaskTurnRequest>()) == 0,
              try context.fetchCount(FetchDescriptor<TaskEvent>()) == 75000 else { fail("fixture count drift") }
        let taskID = UUID(uuidString: "20261106-0000-0000-0002-000000000000")!
        let runID = UUID(uuidString: "20261106-0000-0000-0003-000000000000")!
        let eventID = UUID(uuidString: "20261106-0000-0000-0004-000000000000")!
        guard let task = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first,
              let run = try context.fetch(FetchDescriptor<TaskRun>(predicate: #Predicate { $0.id == runID })).first,
              let event = try context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == eventID })).first else {
            fail("fixture owner missing")
        }
        task.runtimeID = "claude" // Synthetic identity; no provider call.
        task.model = "synthetic-model"
        task.status = .completed
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 1)
        task.completedAt = run.completedAt
        task.updatedAt = run.completedAt!
        // This old display event survives the mirror only through its owned
        // request. The workload's full-event count therefore checks that path.
        event.type = "user.message"
        event.category = "conversation"
        let request = TaskTurnRequest(task: task, messageEventID: eventID, sequence: 1, kind: .initial,
            state: .completed, submittedAt: Date(timeIntervalSince1970: 0))
        request.id = UUID(uuidString: "20261106-0000-0000-0005-000000000000")!
        request.runID = run.id
        request.terminalAt = run.completedAt
        request.terminalReason = "synthetic_completed"
        context.insert(request)
        try context.save()
        let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>())
        guard requests.count == 1, requests.allSatisfy({ $0.executionPolicySnapshot?.taskOwnerID != nil }) else {
            fail("typed execution ownership was not captured")
        }
        print("SYNTHETIC_REQUEST_FIXTURE requests=1 events=75000 owner_policy_present=true credentials=none")
    }
}
