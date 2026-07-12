import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeContextContinuityContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Context continuity replay eval")
@MainActor
struct ContextContinuityReplayEvalTests {
    @Test("approved plan survives follow-up and provider switch")
    func approvedPlanSurvivesFollowUpAndProviderSwitch() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeContextContinuityContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Continuity Plan", primaryPath: root)
        let task = AgentTask(
            title: "Plan continuity",
            goal: "Draft an implementation plan",
            workspace: workspace,
            runtime: .claudeCode
        )
        context.insert(workspace)
        context.insert(task)

        let plan = TaskPlanPayload(
            title: "Context continuity plan",
            goal: "Ship the approved context continuity plan",
            steps: [
                TaskPlanPayloadStep(id: "inspect", title: "Inspect current prompt state"),
                TaskPlanPayloadStep(id: "verify", title: "Run focused continuity tests")
            ]
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: context)
        try context.save()

        let claudePrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "continue with the approved plan",
            task: task
        )
        #expect(claudePrompt.contains("Approved goal: Ship the approved context continuity plan"))
        #expect(claudePrompt.contains("Current objective: Ship the approved context continuity plan"))
        #expect(claudePrompt.contains("Next likely action: Continue with plan step: Inspect current prompt state"))

        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        let copilotPrompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "continue after switching providers",
            task: task
        )
        #expect(copilotPrompt.contains("Current objective: Ship the approved context continuity plan"))
        #expect(copilotPrompt.contains("Approved goal: Ship the approved context continuity plan"))
        #expect(copilotPrompt.contains("Next likely action: Continue with plan step: Inspect current prompt state"))
        #expect(!copilotPrompt.contains("Native Continuation Policy:"))
    }

    @Test("failed test command survives provider switch")
    func failedTestCommandSurvivesProviderSwitch() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeContextContinuityContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Continuity Failure", primaryPath: root)
        let task = AgentTask(
            title: "Failure continuity",
            goal: "Fix the context continuity regression",
            workspace: workspace,
            runtime: .claudeCode,
            validationStrategy: .runTests
        )
        task.sessionId = "claude-native-session"
        task.testCommand = "swift test --filter ContextContinuityReplayEvalTests"
        context.insert(workspace)
        context.insert(task)

        let run = TaskRun(task: task)
        run.status = RunStatus.completed
        run.startedAt = Date(timeIntervalSince1970: 100)
        run.completedAt = Date(timeIntervalSince1970: 120)
        run.output = "Implemented a first attempt."
        run.stopReason = "completed"
        context.insert(run)
        let validationEvent = TaskEvent(
            task: task,
            type: "error",
            payload: "Tests failed:\nContextContinuityReplayEvalTests.failedMarker",
            run: run
        )
        validationEvent.timestamp = Date(timeIntervalSince1970: 121)
        context.insert(validationEvent)
        task.status = .failed
        try context.save()

        TaskContextStateManager.recordTurn(task: task, run: run, message: "Run focused continuity tests")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "switch provider and fix the failure",
            task: task
        )
        #expect(prompt.contains("Current objective: Fix the context continuity regression"))
        #expect(prompt.contains("Verification: failed via run_tests"))
        #expect(prompt.contains("Completion verified: no"))
        #expect(prompt.contains("Verification command: swift test --filter ContextContinuityReplayEvalTests"))
        #expect(prompt.contains("ContextContinuityReplayEvalTests.failedMarker"))
        #expect(!prompt.contains("Native Continuation Policy:"))
    }

    @Test("fork checkpoint replay excludes later source history")
    func forkCheckpointReplayExcludesLaterSourceHistory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeContextContinuityContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Continuity Fork", primaryPath: root)
        let source = AgentTask(title: "Source", goal: "Try branch A then branch B", workspace: workspace)
        context.insert(workspace)
        context.insert(source)

        let firstRun = TaskRun(task: source)
        firstRun.status = RunStatus.completed
        firstRun.startedAt = Date(timeIntervalSince1970: 10)
        firstRun.completedAt = Date(timeIntervalSince1970: 20)
        firstRun.output = "BRANCH_A_KEEP_MARKER"
        firstRun.stopReason = "completed"
        context.insert(firstRun)

        let secondRun = TaskRun(task: source)
        secondRun.status = RunStatus.completed
        secondRun.startedAt = Date(timeIntervalSince1970: 30)
        secondRun.completedAt = Date(timeIntervalSince1970: 40)
        secondRun.output = "BRANCH_B_DROP_MARKER"
        secondRun.stopReason = "completed"
        context.insert(secondRun)
        try context.save()

        let forked = try AgentTask.fork(from: source, upToRun: firstRun, in: context)
        try context.save()

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "continue from the checkpoint",
            task: forked
        )
        #expect(prompt.contains("Checkpoint:"))
        #expect(prompt.contains("source runs after the checkpoint are not authoritative"))
        #expect(prompt.contains("BRANCH_A_KEEP_MARKER"))
        #expect(!prompt.contains("BRANCH_B_DROP_MARKER"))
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-context-continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
}
