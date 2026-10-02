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
