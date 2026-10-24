import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime repair context")
struct RuntimeRepairContextTests {
    @Test("Captured CLI repair survives result encoding without persisting environment credentials")
    func resultRoundTrip() throws {
        let stop = try #require(CLISessionExpiryClassifier.stop(
            content: "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            command: "gh api user"
        ))
        let captured = try #require(stop.repairContext)
        var action = captured.repair
        action.checkEnvironment = ["GH_TOKEN": "must-not-persist-token"]
        action.checkWorkingDirectory = "/private/process-only"
        let context = RuntimeRepairContext(providerBinary: captured.providerBinary,
                                           message: "Translated display text", repair: action, offersAction: true)
        let result = AgentProcessResult(exitCode: 1, runtimeStopReason: stop.reason,
                                        runtimeStopMessage: context.message, runtimeRepairContext: context)
        let data = try JSONEncoder().encode(result)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("must-not-persist-token"))
        #expect(!text.contains("/private/process-only"))
        let decoded = try JSONDecoder().decode(AgentProcessResult.self, from: data)
        #expect(decoded.runtimeRepairContext?.repair.command == "gh auth login")
        #expect(decoded.runtimeRepairContext?.message == "Translated display text")
        #expect(decoded.runtimeRepairContext?.repair.checkEnvironment == nil)
        // Old durable results remain readable; their missing evidence does
        // not authorize an action until a new failure captures one.
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "runtimeRepairContext")
        let old = try JSONDecoder().decode(AgentProcessResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.runtimeRepairContext == nil)
    }

    @Test("The monitor captures the repair alongside the original execution failure")
    func monitorCapturesContext() throws {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "Bash", id: "auth", input: ["command": "gh api user"]), process: nil)
        #expect(monitor.processEvent(.toolResult(toolId: "auth", content: "You are not logged into any GitHub hosts.", isError: true), process: nil))
        let captured = try #require(monitor.runtimeRepairContext)
        #expect(captured.providerBinary == "gh")
        #expect(captured.repair.command == "gh auth login")
        #expect(captured.message == monitor.runtimeStopMessage)
    }

    @MainActor
    @Test("A committed typed stop survives display changes and is the resume check's owner")
    func structuredOutcomeOwnsResume() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let modelContext = container.mainContext
        let task = AgentTask(title: "Auth", goal: "Read GitHub")
        task.status = .running
        modelContext.insert(task)
        let run = TaskRun(task: task)
        modelContext.insert(run)
        let captured = RuntimeRepairContext(providerBinary: "gh", message: "Localized failure",
                                            repair: CLISessionExpiryClassifier.gitHub.repair, offersAction: true)
        let result = AgentProcessResult(exitCode: 1, runtimeStopReason: "capability_session_expired",
                                        runtimeStopMessage: "This message is not a repair contract", runtimeRepairContext: captured)
        #expect(RuntimeStopOutcome.apply(result, task: task, run: run, modelContext: modelContext, phase: .run))
        try modelContext.save()
        #expect(task.status == .failed)
        let event = try #require(task.events.first { $0.type == TaskEventTypes.System.runtimeRepairContext.rawValue })
        #expect(RuntimeRepairContext.decode(from: event.payload) == captured)
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                                      payload: CLISessionExpiryClassifier.googleCloud.stopMessage, run: run))
        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: TaskQueue(poolSize: 0))
        #expect(coordinator.pendingRepair(for: task)?.checkBinary == "gh")
        // A newer context version is not understood by this binary. It must
        // not fall back to an older executable repair or parse newer prose.
        var future = try #require(JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any])
        future["version"] = 2
        event.payload = try #require(String(data: JSONSerialization.data(withJSONObject: future), encoding: .utf8))
        #expect(coordinator.pendingRepair(for: task)?.command == nil)
    }

    @MainActor
    @Test("The dock reads a saved manual repair from the same typed owner as Resume", arguments: [false, true])
    func manualTypedStopRemainsVisible(futureVersion: Bool) async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let task = AgentTask(title: "Manual auth", goal: "Read the selected host")
        task.status = .running
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let repair = CLISessionExpiryClassifier.gitHub.onHost("github.example.com").repair
        let captured = RuntimeRepairContext(providerBinary: "gh", message: "Localized manual setup",
            repair: repair, offersAction: false)
        let result = AgentProcessResult(exitCode: 1, runtimeStopReason: "capability_session_expired",
            runtimeRepairContext: captured)
        try #require(RuntimeStopOutcome.apply(result, task: task, run: run, modelContext: context, phase: .run))
        try #require(!task.events.contains { $0.type == TaskEventTypes.System.runtimeRepairRequired.rawValue })
        if futureVersion {
            let event = try #require(task.events.first { $0.type == TaskEventTypes.System.runtimeRepairContext.rawValue })
            var json = try #require(JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any])
            json["version"] = 2
            event.payload = try #require(String(data: JSONSerialization.data(withJSONObject: json), encoding: .utf8))
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeRepairRequired,
                payload: CLISessionExpiryClassifier.googleCloud.repair.encoded(), run: run))
        }
        try context.save()
        let saved = ModelContext(container)
        let snapshots = try saved.fetch(FetchDescriptor<TaskEvent>()).sorted { $0.timestamp < $1.timestamp }
            .map(TaskEventSnapshot.init(event:))
        let visible = TaskRunStopEvidence.repair(events: snapshots, runID: run.id)
        #expect(visible != nil)
        #expect(visible?.command == nil)
        #expect(visible?.verb == (futureVersion ? "Review" : "Check"))
        var checked: RepairAction?
        let guidance = await TaskRepairAction.perform(visible, check: { checked = $0; return false },
            run: { _ in Issue.record("The dock cannot execute a legacy action over a typed manual stop"); return .refused })
        #expect(guidance != nil)
        if futureVersion {
            #expect(visible?.checkBinary == nil)
            #expect(checked == nil)
        } else {
            #expect(checked?.checkArguments == ["auth", "status", "--active", "--hostname", "github.example.com"])
        }
        #expect(task.status == .failed)
    }

    @MainActor
    @Test("A result without captured evidence offers manual review rather than a repair parsed from prose")
    func missingContextIsManual() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let modelContext = container.mainContext
        let task = AgentTask(title: "Auth", goal: "Review")
        task.status = .running
        modelContext.insert(task)
        let run = TaskRun(task: task)
        modelContext.insert(run)
        let result = AgentProcessResult(exitCode: 1, runtimeStopReason: "capability_session_expired",
                                        runtimeStopMessage: CLISessionExpiryClassifier.googleCloud.stopMessage)
        #expect(RuntimeStopOutcome.apply(result, task: task, run: run, modelContext: modelContext, phase: .run))
        try modelContext.save()
        #expect(!task.events.contains { $0.type == TaskEventTypes.System.runtimeRepairRequired.rawValue })
        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: TaskQueue(poolSize: 0))
        let repair = try #require(coordinator.pendingRepair(for: task))
        #expect(repair.command == nil)
        #expect(repair.checkBinary == nil)
    }
}
