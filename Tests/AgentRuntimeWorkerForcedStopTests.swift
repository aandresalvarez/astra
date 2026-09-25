import Testing
import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Feeds the worker `lines` as provider output and returns `result`, so a test
/// can end a run the way a watchdog or a limit does without a real process.
private final class ScriptedAgentProcessRunner: AgentRuntimeProcessRunning {
    let lines: [String]
    let result: AgentProcessResult

    init(lines: [String], result: AgentProcessResult) {
        self.lines = lines
        self.result = result
    }

    func cancel() {}

    func isHostControlBrokerAvailable() -> Bool { true }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        phase: RunPhase,
        contextText: String,
        nativeContinuationSessionID: String?,
        runID: UUID?,
        launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?,
        runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        for line in lines {
            onLine(line, true)
        }
        return result
    }
}

@Suite("AgentRuntimeWorker forced stops")
@MainActor
struct AgentRuntimeWorkerForcedStopTests {
    @Test("A write left without a result is dropped when ASTRA stopped the run, even at exit 0")
    func runtimeStoppedRunDropsUnresolvedWrites() async throws {
        // A watchdog stop closes stdin first, and the provider can exit 0.
        let stopped = AgentProcessResult(exitCode: 0, runtimeStopReason: "provider_active_tool_stalled")
        let afterStop = try await unresolvedWritePaths(after: stopped)
        #expect(afterStop.isEmpty)
        // Without a stop the provider dropped the result, and the write stays.
        let afterCleanExit = try await unresolvedWritePaths(after: AgentProcessResult(exitCode: 0))
        #expect(afterCleanExit.count == 1)
    }

    /// Runs a Claude turn that announces a Write and never reports its result.
    private func unresolvedWritePaths(after result: AgentProcessResult) async throws -> [String] {
        let testDir = "/tmp/forced_stop_runner_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Forced Stop Workspace", primaryPath: testDir)
        context.insert(workspace)
        let task = AgentTask(title: "Stopped write", goal: "Write the notes", workspace: workspace)
        task.status = .queued
        context.insert(task)
        try context.save()

        let runner = ScriptedAgentProcessRunner(
            lines: [
                #"{"type":"system","subtype":"init","session_id":"session-stop","model":"claude-sonnet-4-6"}"#,
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_stalled","name":"Write","input":{"file_path":"\#(testDir)/notes.md","content":"x"}}]}}"#
            ],
            result: result
        )
        let worker = AgentRuntimeWorker(
            processRunner: runner,
            providerSettingsSnapshotProvider: { .headlessScenario }
        )
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.claudePath = "/bin/sh"

        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: context)
        await worker.execute(task: task, modelContext: context) { _ in }

        return task.runs.flatMap(\.fileChanges).map(\.path)
    }
}
