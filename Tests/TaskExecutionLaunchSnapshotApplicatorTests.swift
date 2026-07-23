import Testing
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Task execution launch snapshot applicator")
struct TaskExecutionLaunchSnapshotApplicatorTests {
    @Test("Queued request uses a detached immutable configuration and preserves editable state")
    func buildsDetachedCompleteSnapshot() throws {
        let workspace = Workspace(name: "Queued workspace", primaryPath: "/tmp/queued-workspace")
        let task = AgentTask(title: "Queued", goal: "Run", workspace: workspace)
        let priorRun = TaskRun(task: task)
        priorRun.status = .completed
        let priorEvent = TaskEvent(task: task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "prior")
        task.runs = [priorRun]
        task.events = [priorEvent]
        task.runtimeID = "codex_cli"
        task.model = "submitted-model"
        task.tokenBudget = 1_234
        task.runtimeExplicitlySelected = true
        task.maxTurns = 7
        task.isolationStrategy = .gitBranch
        task.validationStrategy = .runTests
        task.testCommand = "swift test"
        task.useAgentTeam = true
        task.teamSize = 4
        task.teamInstructions = "submitted team"
        task.executionRootPath = "/tmp/submitted-root"
        task.executionEnvironmentSnapshotJSON = "{\"submitted\":true}"
        task.templateHooksJSON = "submitted-hooks"
        task.skillSnapshotsJSON = "submitted-skills"
        task.runtimePermissionGrantsJSON = "submitted-grants"
        let request = TaskTurnRequest(task: task, messageEventID: .init(), sequence: 1)

        task.runtimeID = "claude_code"
        task.model = "edited-model"
        task.tokenBudget = 9_999
        task.runtimeExplicitlySelected = false
        task.maxTurns = 2
        task.isolationStrategy = .copy
        task.validationStrategy = .manual
        task.testCommand = ""
        task.useAgentTeam = false
        task.teamSize = 2
        task.teamInstructions = "edited team"
        task.executionRootPath = "/tmp/edited-root"
        task.executionEnvironmentSnapshotJSON = "{\"edited\":true}"
        task.templateHooksJSON = "edited-hooks"
        task.skillSnapshotsJSON = "edited-skills"
        task.runtimePermissionGrantsJSON = "edited-grants"

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let launchTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(launchTask.runtimeID == "codex_cli")
        #expect(launchTask.model == "submitted-model")
        #expect(launchTask.tokenBudget == 1_234)
        #expect(launchTask.maxTurns == 7)
        #expect(launchTask.isolationStrategy == .gitBranch)
        #expect(launchTask.validationStrategy == .runTests)
        #expect(launchTask.executionRootPath == "/tmp/submitted-root")
        #expect(launchTask.runtimePermissionGrantsJSON == "submitted-grants")
        #expect(launchTask.workspace?.primaryPath == workspace.primaryPath)
        #expect(launchTask.events.contains { $0.id == priorEvent.id })
        #expect(launchTask.runs.contains { $0.id == priorRun.id })
        #expect(task.workspace === workspace)
        #expect(task.events.contains { $0.id == priorEvent.id })
        #expect(task.runs.contains { $0.id == priorRun.id })
        #expect(priorEvent.task === task)
        #expect(priorRun.task === task)

        #expect(task.runtimeID == "claude_code")
        #expect(task.model == "edited-model")
        #expect(task.tokenBudget == 9_999)
        #expect(task.maxTurns == 2)
        #expect(task.isolationStrategy == .copy)
        #expect(task.validationStrategy == .manual)
        #expect(task.executionRootPath == "/tmp/edited-root")
        #expect(task.runtimePermissionGrantsJSON == "edited-grants")
    }
}
