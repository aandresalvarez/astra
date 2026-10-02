import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import HostControlToolSupport
@testable import ASTRA

@Suite("History handoff worker")
@MainActor
struct HistoryHandoffWorkerTests {
    @Test("Budget rejection cannot authorize an old session under new settings", arguments: ["model", "capability", "unchanged"])
    func budgetRejectedHandoff(change: String) async throws {
        let (root, container, task, fake, worker) = try makeSessionFixture()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        defer { try? FileManager.default.removeItem(atPath: root) }
        await continueTask(task, worker: worker, context: context)
        #expect(fake.receivedPrompts.count == 1)
        let originalRun = try #require(task.runs.first)
        let originalSignature = try #require(originalRun.providerLaunchSignatureJSON)
        #expect(originalRun.providerSessionId == "original-session")

        if change == "model" { task.model = "claude-opus-4-6" }
        if change == "capability" {
            let skill = Skill(name: "Cache Agent", skillDescription: "Investigate cache behavior",
                allowedTools: ["Read"], behaviorInstructions: "Use cache-specific diagnostics.")
            skill.workspace = task.workspace
            context.insert(skill)
            task.skills = [skill]
        }
        task.tokenBudget = 1
        await continueTask(task, worker: worker, context: context)
        let rejectedRun = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(rejectedRun.status == .budgetExceeded)
        #expect(fake.receivedPrompts.count == 1)
        #expect(rejectedRun.providerLaunchSignatureJSON == nil)
        #expect(rejectedRun.providerSessionId == nil)
        #expect(!task.events.contains { $0.run?.id == rejectedRun.id && $0.type == ProviderLaunchSignatureService.eventType })
        #expect(task.sessionId == "original-session")
        #expect(originalRun.providerLaunchSignatureJSON == originalSignature)
        try context.save()

        // Retry using a new context so admission depends on durable state.
        let retryContext = ModelContext(context.container)
        let taskID = task.id
        let retryTask = try #require(try retryContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })).first)
        retryTask.tokenBudget = 0
        fake.streamLines = startedLines(sessionID: "retry-session")
        await continueTask(retryTask, worker: worker, context: retryContext)
        #expect(fake.receivedPrompts.count == 2)
        #expect(fake.receivedNativeSessions.last! == (change == "unchanged" ? "original-session" : nil))
        let retryRun = try #require(retryTask.runs.max { $0.startedAt < $1.startedAt })
        #expect(retryRun.providerSessionId == "retry-session")
        #expect(retryRun.providerLaunchSignatureJSON != nil)

        await continueTask(retryTask, worker: worker, context: retryContext)
        #expect(fake.receivedNativeSessions.last! == "retry-session")
    }

    @Test("An admitted fresh launch without a provider session cannot relabel an old session")
    func failedFreshLaunchCannotAuthorizeOldSession() async throws {
        let (root, container, task, fake, worker) = try makeSessionFixture()
        let context = container.mainContext
        defer { withExtendedLifetime(container) {} }
        defer { try? FileManager.default.removeItem(atPath: root) }
        await continueTask(task, worker: worker, context: context)
        task.model = "claude-opus-4-6"
        fake.streamLines = []
        fake.result = AgentProcessResult(exitCode: 1, error: "Launch dependency unavailable")
        await continueTask(task, worker: worker, context: context)
        let failedRun = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(fake.receivedNativeSessions.last! == nil)
        #expect(failedRun.providerLaunchSignatureJSON != nil)
        #expect(failedRun.providerSessionId == nil)
        #expect(task.sessionId == "original-session")
        fake.result = AgentProcessResult(exitCode: 0)
        fake.streamLines = startedLines(sessionID: "new-session")
        await continueTask(task, worker: worker, context: context)
        #expect(fake.receivedPrompts.count == 3)
        #expect(fake.receivedNativeSessions.last! == nil)
        #expect(task.sessionId == "new-session")
    }

    private func makeSessionFixture() throws -> (String, ModelContainer, AgentTask, FakeAgentProcessRunner, AgentRuntimeWorker) {
        let root = NSTemporaryDirectory() + "admitted-handoff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workspace = Workspace(name: "Handoff", primaryPath: root)
        let task = AgentTask(title: "Handoff", goal: "Investigate cache behavior", workspace: workspace, runtime: .claudeCode)
        task.tokenBudget = 0
        task.status = .completed
        context.insert(workspace); context.insert(task)
        try context.save()
        let fake = FakeAgentProcessRunner()
        fake.streamLines = startedLines(sessionID: "original-session")
        let worker = AgentRuntimeWorker(processRunner: fake, providerSettingsSnapshotProvider: { .headlessScenario })
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.budgetEnforcementModeOverride = .hardStop
        worker.claudePath = "/bin/sh"
        return (root, container, task, fake, worker)
    }

    private func startedLines(sessionID: String) -> [String] {
        ["{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(sessionID)\",\"model\":\"claude-sonnet-4-6\"}",
         #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Completed the investigation."}]}}"#]
    }

    private func continueTask(_ task: AgentTask, worker: AgentRuntimeWorker, context: ModelContext) async {
        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(task: task, message: "Continue investigating cache behavior", modelContext: context) { _ in }
    }

    @Test("Worker uses wider fresh history and binds durable evidence for detached launch tasks")
    func freshAndNativeHandoffs() async throws {
        let root = NSTemporaryDirectory() + "history-handoff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workspace = Workspace(name: "Handoff", primaryPath: root)
        let task = AgentTask(title: "Handoff", goal: "Continue investigating", workspace: workspace, runtime: .claudeCode)
        context.insert(workspace); context.insert(task)
        for turn in 1...9 {
            let run = TaskRun(task: task)
            run.status = .completed
            run.startedAt = Date(timeIntervalSince1970: Double(turn))
            run.completedAt = run.startedAt.addingTimeInterval(1)
            run.setOutput("TURN_\(turn)_EVIDENCE")
            context.insert(run)
            #expect(AgentRuntimeRunPersistence.recordSessionTurn(task: task, run: run, message: "Investigate turn \(turn)"))
        }
        let evidence = TaskEvent(task: task, type: "tool.result", payload: "ORIGINAL_TOOL_RESULT")
        context.insert(evidence)
        task.sessionId = "missing-signature-session"
        task.status = .completed
        try context.save()
        let fake = FakeAgentProcessRunner()
        fake.streamLines = [
            #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"valid-session","model":"claude-sonnet-4-6"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Completed the investigation."}]}}"#
        ]
        var boundReaderWorked = false
        var lastRunID: UUID?
        fake.onLaunch = { launchTask, runID in
            #expect(launchTask.modelContext == nil)
            lastRunID = runID
            let reader = HostControlBrokerSessionRegistry.shared.historyReader(taskID: task.id, runID: runID)
            let request = TaskHistoryReadRequest.parse(["event_id": evidence.id.uuidString])!
            boundReaderWorked = (try? reader?.readHistory(request)["payload"] as? String) == "ORIGINAL_TOOL_RESULT"
        }
        let worker = AgentRuntimeWorker(processRunner: fake, providerSettingsSnapshotProvider: { .headlessScenario })
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.claudePath = "/bin/sh"
        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(task: task, message: "Continue investigating", modelContext: context) { _ in }
        #expect(fake.receivedPrompts.count == 1)
        #expect(fake.receivedNativeSessions.first! == nil)
        #expect(fake.receivedPrompts.first?.contains("TURN_1_EVIDENCE") == true)
        #expect(fake.receivedPrompts.first?.contains("Original task evidence") == true)
        #expect(boundReaderWorked)
        #expect(HostControlBrokerSessionRegistry.shared.historyReader(taskID: task.id, runID: lastRunID) == nil)

        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(task: task, message: "Continue investigating", modelContext: context) { _ in }
        #expect(fake.receivedPrompts.count == 2)
        #expect(fake.receivedNativeSessions.last! == "valid-session")
        #expect(fake.receivedPrompts.last?.contains("TURN_1_EVIDENCE") == false)
        // A model change invalidates the provider signature on the same runtime.
        task.model = "claude-opus-4-6"
        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(task: task, message: "Continue investigating", modelContext: context) { _ in }
        #expect(fake.receivedPrompts.count == 3)
        #expect(fake.receivedNativeSessions.last! == nil)
        #expect(fake.receivedPrompts.last?.contains("TURN_1_EVIDENCE") == true)
    }
}
