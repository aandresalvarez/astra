import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskContextStateContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Task context state")
@MainActor
struct TaskContextStateTests {
    @Test("recording a run writes canonical JSON and markdown state")
    func recordsCurrentStateFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "State", primaryPath: root)
        let task = AgentTask(title: "Explore context", goal: "Explore whether ASTRA needs a context index", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        task.status = .completed
        run.status = .completed
        run.stopReason = "completed"
        run.output = "We decided to avoid vector databases and start with a current-state checkpoint."
        run.completedAt = Date()
        run.appendFileChange(StoredFileChange(from: FileChange(
            path: "\(root)/Astra/Services/AgentPromptBuilder.swift",
            changeType: .edit,
            content: nil,
            oldString: nil,
            newString: nil,
            timestamp: Date()
        )))
        context.insert(run)

        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "Should we use a vector database?"
        )

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.mode == .completed)
        #expect(state.startingRequest == "Explore whether ASTRA needs a context index")
        #expect(state.turns.count == 1)
        #expect(state.turns[0].ask == "Should we use a vector database?")
        #expect(state.turns[0].summary.contains("avoid vector databases"))
        #expect(state.filesChanged.contains { $0.hasSuffix("AgentPromptBuilder.swift") })
        #expect(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(TaskContextStateManager.jsonFileName)))
        #expect(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(TaskContextStateManager.markdownFileName)))
    }

    @Test("first user request wins over later edited task goal")
    func startingRequestUsesFirstConversationMessage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Original Request", primaryPath: root)
        let task = AgentTask(title: "Edited", goal: "Edited execution goal", workspace: workspace)
        let event = TaskEvent(task: task, type: "user.message", payload: "Original exploratory request")
        event.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(workspace)
        context.insert(task)
        context.insert(event)

        TaskContextStateManager.refresh(task: task)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.startingRequest == "Original exploratory request")
        #expect(state.currentObjective == "Edited execution goal")
    }

    @Test("turn numbering follows saved state and deterministic output paths")
    func turnNumberingUsesStateFloorAndFormattedOutputPath() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Turns", primaryPath: root)
        let task = AgentTask(title: "Number turns", goal: "Keep turn numbers stable", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let firstRun = TaskRun(task: task)
        firstRun.status = .completed
        firstRun.stopReason = "completed"
        firstRun.output = "first output"
        firstRun.completedAt = Date()
        context.insert(firstRun)
        TaskContextStateManager.recordTurn(task: task, run: firstRun, message: "first ask")

        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let outputs = (folder as NSString).appendingPathComponent("outputs")
        try FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)
        try "stale first output".write(
            toFile: (outputs as NSString).appendingPathComponent("turn_001.md"),
            atomically: true,
            encoding: .utf8
        )

        let secondRun = TaskRun(task: task)
        secondRun.status = .completed
        secondRun.stopReason = "completed"
        secondRun.output = "second output"
        secondRun.completedAt = Date()
        context.insert(secondRun)
        TaskContextStateManager.recordTurn(task: task, run: secondRun, message: "second ask")

        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.turns.map(\.turn) == [1, 2])
        #expect(state.turns.map(\.outputFile) == ["outputs/turn_001.md", "outputs/turn_002.md"])
    }

    @Test("approved plans refresh state with explicit planning mode and approved goal")
    func planApprovalRecordsApprovedGoal() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Goal", primaryPath: root)
        let task = AgentTask(title: "Plan context", goal: "Improve ASTRA context handoff", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Context handoff v1",
            goal: "Add a local current-state checkpoint for ASTRA threads",
            steps: [
                TaskPlanPayloadStep(id: "state", title: "Add state file", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "prompt", title: "Inject state into prompts", likelyTools: ["Edit"])
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)

        let state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        #expect(state.mode == .planning)
        #expect(state.approvedGoal == "Add a local current-state checkpoint for ASTRA threads")
        #expect(state.decisions.contains("Approved goal: Add a local current-state checkpoint for ASTRA threads"))
        #expect(state.nextLikelyAction == "Continue with plan step: Add state file")
    }

    @Test("follow-up prompts include thread intent and history lookup rule")
    func followUpPromptIncludesThreadIntent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Prompt", primaryPath: root)
        let task = AgentTask(title: "Context prompt", goal: "Explore better follow-up memory", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Current-state checkpoints are simpler than a search index for the first iteration."
        run.completedAt = Date()
        context.insert(run)
        AgentRuntimeRunPersistence.recordSessionTurn(
            task: task,
            run: run,
            message: "What should we build first?"
        )

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "What did we decide about vectors?",
            task: task
        )
        #expect(prompt.contains("Thread Intent:"))
        #expect(prompt.contains("Current-state checkpoints are simpler"))
        #expect(prompt.contains(TaskContextStateManager.jsonFileName))
        #expect(prompt.contains("History Lookup Rule:"))
        #expect(prompt.contains("Goal: Explore better follow-up memory"))
    }

    @Test("prompt diagnostics report state and history sizes")
    func promptDiagnosticsReportStatePresence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeTaskContextStateContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Diagnostics", primaryPath: root)
        let task = AgentTask(title: "Diagnostics", goal: "Measure prompt context", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        run.output = "Diagnostics should include current-state size."
        run.completedAt = Date()
        context.insert(run)
        AgentRuntimeRunPersistence.recordSessionTurn(task: task, run: run, message: "measure")

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "continue", task: task)
        let fields = TaskContextStateManager.promptDiagnosticsFields(task: task, prompt: prompt, phase: "resume")
        #expect(fields["has_thread_intent"] == "true")
        #expect(Int(fields["state_json_chars"] ?? "0", radix: 10) ?? 0 > 0)
        #expect(Int(fields["session_history_chars"] ?? "0", radix: 10) ?? 0 > 0)
        #expect(fields["output_file_count"] == "1")
        #expect(Int(fields["output_latest_chars"] ?? "0", radix: 10) ?? 0 > 0)
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-context-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
