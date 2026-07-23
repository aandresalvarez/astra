import Testing
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Task execution launch snapshot applicator")
struct TaskExecutionLaunchSnapshotApplicatorTests {
    @Test("Queued request launches with its immutable configuration and restores editable state")
    func appliesAndRestoresCompleteSnapshot() throws {
        let task = AgentTask(title: "Queued", goal: "Run")
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

        let restoration = try #require(TaskExecutionLaunchSnapshotApplicator.apply(request: request, to: task))
        #expect(task.runtimeID == "codex_cli")
        #expect(task.model == "submitted-model")
        #expect(task.tokenBudget == 1_234)
        #expect(task.maxTurns == 7)
        #expect(task.isolationStrategy == .gitBranch)
        #expect(task.validationStrategy == .runTests)
        #expect(task.executionRootPath == "/tmp/submitted-root")
        #expect(task.runtimePermissionGrantsJSON == "submitted-grants")

        restoration.restore(task)
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
