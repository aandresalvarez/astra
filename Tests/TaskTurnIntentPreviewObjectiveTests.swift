import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// `TaskTurnIntentResolver.preview` runs after every pause in typing, and
/// resolving the active objective reconstructs the plan from the task's events
/// — the single most expensive thing on that path. `activationText` is the only
/// reader of `activeObjective`, and it consults it only for a referential turn
/// that has nothing to inherit, so the preview resolves it just for that case.
///
/// These pin both halves: an ordinary turn does not pay for it, and the
/// referential fallback that needs it still gets it.
@Suite("Turn intent preview objective resolution")
@MainActor
struct TaskTurnIntentPreviewObjectiveTests {
    /// The container is returned so it outlives the test body; letting it
    /// deallocate tears the model instances out from under the assertions.
    private func makeTask(
        goal: String,
        priorUserTurns: [String]
    ) throws -> (task: AgentTask, container: ModelContainer, root: URL) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-intent-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Preview", primaryPath: root.path)
        context.insert(workspace)
        let task = AgentTask(title: "Preview", goal: goal, workspace: workspace, runtime: .claudeCode)
        context.insert(task)
        for (offset, turn) in priorUserTurns.enumerated() {
            let event = TaskEvent(
                task: task,
                type: TaskEventTypes.Conversation.userMessage.rawValue,
                payload: turn
            )
            event.timestamp = Date(timeIntervalSince1970: TimeInterval(offset + 1))
            context.insert(event)
        }
        try context.save()
        return (task, container, root)
    }

    @Test("An ordinary turn does not resolve the active objective")
    func ordinaryTurnSkipsObjectiveResolution() throws {
        let environment = try makeTask(goal: "Review the ticket", priorUserTurns: ["Earlier request"])
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let intent = TaskTurnIntentResolver.preview(
            for: environment.task,
            acceptedTurn: "Summarize the findings"
        )

        #expect(!intent.isReferential)
        #expect(intent.activeObjective == nil)
        // The text admission actually scores is unchanged by skipping it.
        #expect(intent.activationText == "Summarize the findings")
    }

    @Test("A referential turn still inherits the prior user turn")
    func referentialTurnInheritsPriorTurn() throws {
        let environment = try makeTask(
            goal: "Review the ticket",
            priorUserTurns: ["Write the SSH operating procedure"]
        )
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let intent = TaskTurnIntentResolver.preview(
            for: environment.task,
            acceptedTurn: "continue"
        )

        #expect(intent.isReferential)
        #expect(intent.inheritedTurn == "Write the SSH operating procedure")
        #expect(intent.activationText.contains("Write the SSH operating procedure"))
    }

    /// The case the narrowing must not break: referential with nothing to
    /// inherit is exactly when `activationText` falls back to the objective, so
    /// the preview still has to resolve it.
    @Test("A referential turn with nothing to inherit still resolves the objective")
    func referentialTurnWithoutPriorTurnResolvesObjective() throws {
        let environment = try makeTask(goal: "Review the ticket", priorUserTurns: [])
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let intent = TaskTurnIntentResolver.preview(
            for: environment.task,
            acceptedTurn: "continue"
        )

        #expect(intent.isReferential)
        #expect(intent.inheritedTurn == nil)
        #expect(intent.activeObjective == "Review the ticket")
        #expect(intent.activationText.contains("Review the ticket"))
    }

    /// The durable launch path is not the typing path and keeps resolving the
    /// objective for every turn, referential or not.
    @Test("The captured launch intent still carries the objective for an ordinary turn")
    func captureStillResolvesObjective() throws {
        let environment = try makeTask(goal: "Review the ticket", priorUserTurns: ["Earlier request"])
        let container = environment.container
        defer {
            _ = container
            try? FileManager.default.removeItem(at: environment.root)
        }

        let intent = TaskTurnIntentResolver.capture(
            for: environment.task,
            sourceEventID: nil,
            acceptedTurn: "Summarize the findings",
            includeTaskInputs: false
        )

        #expect(!intent.isReferential)
        #expect(intent.activeObjective != nil)
    }
}
