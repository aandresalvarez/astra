import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Plugin repair credential overrides")
struct PluginRepairCredentialOverrideTests {
    private static let overrides = [
        "CLOUDSDK_AUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
        "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", "CLOUDSDK_CORE_ACCOUNT",
        "CLOUDSDK_ACTIVE_CONFIG_NAME", "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT"
    ]

    @Test("A launch-selected Google identity makes sign-in check-only", arguments: overrides)
    func selectedIdentityCannotLaunchLogin(key: String) {
        let original = CLISessionExpiryClassifier.googleCloud.repair
        let environment = [key: "synthetic-selected-identity"]
        let action = original.checking(in: environment).targetingCredentialStore(environment)
        #expect(action.command == nil)
        #expect(action.executionCommand == nil)
        #expect(action.verb == "Check")
        #expect(action.checkBinary == original.checkBinary)
        #expect(action.checkArguments == original.checkArguments)
        #expect(action.checkEnvironment == environment)
        // An empty overlay does not select another credential. ADC remains
        // separate from the ordinary gcloud principal, as before.
        #expect(original.targetingCredentialStore([key: ""]).command == original.command)
        #expect(CLISessionExpiryClassifier.gitHub.repair.targetingCredentialStore(environment).command != nil)
        #expect(original.targetingCredentialStore(["GOOGLE_APPLICATION_CREDENTIALS": "/tmp/adc.json"]).command == original.command)
    }

    @Test("The stopped task, dock action and Resume keep the selected Google credential", arguments: [
        "CLOUDSDK_AUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE"
    ], [false, true])
    func projectedCredentialSurvivesStopAndRecheck(key: String, legacy: Bool) async throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workspace = Workspace(name: "Cloud repair", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(title: "Projects", goal: "List Google Cloud projects", workspace: workspace, runtime: .claudeCode)
        task.status = .running
        task.sessionId = "synthetic-cloud-session"
        let marker = "synthetic-process-only-credential"
        task.skillSnapshots = [SkillSnapshotConfig(
            id: UUID().uuidString, name: "Google Cloud", icon: "cloud", description: "Google Cloud projects",
            allowedTools: ["Bash"], disallowedTools: [], customTools: [], behaviorInstructions: "",
            environmentKeys: [key], environmentValues: [marker], isGlobal: false,
            connectorIDs: nil, localToolIDs: nil, connectorSnapshots: nil, localToolSnapshots: nil,
            createdAt: Date(), updatedAt: Date())]
        context.insert(workspace)
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "Bash", id: "cloud", input: ["command": "gcloud projects list"]), process: nil)
        try #require(monitor.processEvent(.toolResult(toolId: "cloud", content:
            "ERROR: (gcloud.projects.list) There was a problem refreshing your current auth tokens: Reauthentication failed. Please run gcloud auth login.",
            isError: true), process: nil))
        let captured = try #require(monitor.runtimeRepairContext)
        try #require(RuntimeStopOutcome.apply(AgentProcessResult(exitCode: 1, runtimeStopReason: "capability_session_expired",
            runtimeRepairContext: captured), task: task, run: run, modelContext: context, phase: .run))
        try context.save()
        let typed = try #require(task.events.first { $0.type == TaskEventTypes.System.runtimeRepairContext.rawValue })
        let saved = try #require(RuntimeRepairContext.decode(from: typed.payload))
        #expect(!saved.offersAction)
        #expect(saved.repair.command == nil)
        #expect(!typed.payload.contains(marker))
        #expect(!task.events.contains { $0.type == TaskEventTypes.System.runtimeRepairRequired.rawValue })
        let snapshots = legacy
            ? [TaskEventSnapshot(event: TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeRepairRequired,
                payload: captured.repair.encoded(), run: run))]
            : task.events.map(TaskEventSnapshot.init(event:))
        let visible = try #require(TaskRunStopEvidence.presentationRepair(events: snapshots, runID: run.id, task: task))
        #expect(visible.command == nil)
        #expect(visible.verb == "Check")
        let action = try #require(await TaskRunStopEvidence.signInRepair(events: snapshots, runID: run.id, task: task))
        #expect(action.command == nil)
        #expect(action.checkEnvironment == [key: marker])
        #expect(action.checkArguments == captured.repair.checkArguments)
        var checked: RepairAction?
        let guidance = await TaskRepairAction.perform(action, check: { checked = $0; return false },
            run: { _ in Issue.record("A selected credential must not launch an ambient sign-in"); return .refused })
        #expect(checked?.checkEnvironment == [key: marker])
        #expect(guidance?.title == "Setup needs attention")
        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue(poolSize: 0))
        let resumeChecks = OSAllocatedUnfairLock(initialState: [[String: String]?]())
        coordinator.repairCheck = { repair in
            resumeChecks.withLock { $0.append(repair.checkEnvironment) }
            return false
        }
        await coordinator.resumeTask(task)?.value
        await coordinator.retryTask(task)?.value
        #expect(resumeChecks.withLock { $0 } == [[key: marker], [key: marker]])
        #expect(task.status == .failed)
        withExtendedLifetime(container) {}
    }
}
