import Foundation
import SwiftData
@testable import ASTRA
import ASTRACore

/// Binary runner that never spawns a process. Scenario tests exercise
/// worker behavior (budgets, shutdown, event parsing) against fake CLI
/// scripts; the pre-launch readiness gate's real liveness probes are
/// load-sensitive process spawns that made those tests flaky under full
/// parallel `swift test`. Every probe answers instantly as a healthy,
/// authenticated CLI: "logged in" satisfies the auth-session detectors and
/// the trailing ASTRA_READY line satisfies Antigravity's live account check.
struct InstantSuccessBinaryRunner: BinaryRunner {
    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        RunResult(outcome: .exited(code: 0), stdout: "logged in 1.0.0\nASTRA_READY", stderr: "")
    }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        stdin: Data?
    ) async -> RunResult {
        RunResult(outcome: .exited(code: 0), stdout: "logged in 1.0.0\nASTRA_READY", stderr: "")
    }
}

extension AgentRuntimeWorker {
    /// Worker for runtime scenario tests: identical to a production worker
    /// except the readiness gate probes through `InstantSuccessBinaryRunner`,
    /// so the gate is deterministic and the test reaches the behavior under
    /// test. Tests that exercise readiness *failure* inject a blocked report
    /// directly (see AgentRuntimeComponentTests) and are unaffected.
    @MainActor
    static func scenarioWorker() -> AgentRuntimeWorker {
        let runner = AgentRuntimeProcessRunner { permissionPolicy in
            let enforcement: ExecutionSandboxEnforcement = permissionPolicy == .autonomous ? .strict : .bestEffort
            return ExecutionSandboxSettings(enforcement: enforcement)
        }
        let worker = AgentRuntimeWorker(
            processRunner: runner,
            providerSettingsSnapshotProvider: { .headlessScenario }
        )
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        // Capability prerequisites (e.g. `gh auth status` for the GitHub
        // capability) go through a separate checker than the runtime
        // readiness gate above. Without this, a scenario that enables a
        // capability with a real CLI prerequisite would shell out to the
        // host's actual `gh`/`gcloud`/etc. and depend on ambient machine
        // auth state instead of the fake CLI scripts the harness controls.
        worker.preflightCache = PreflightCache(checker: EnvironmentHealthChecker(runner: InstantSuccessBinaryRunner()))
        return worker
    }
}

extension TaskQueue {
    @MainActor
    static func scenarioQueue(poolSize: Int = 3) -> TaskQueue {
        TaskQueue(poolSize: poolSize) {
            AgentRuntimeWorker.scenarioWorker()
        }
    }
}

enum DirectWorkerLaunchAdmission {
    @MainActor
    @discardableResult
    static func admitInitialRun(_ task: AgentTask, modelContext: ModelContext) -> TaskStateMachine.TransitionResult {
        if task.status == .draft {
            TaskStateMachine.enqueueFromUITestSeed(task, modelContext: modelContext)
        }
        return TaskStateMachine.admitQueuedTaskToRuntime(task, modelContext: modelContext)
    }

    @MainActor
    @discardableResult
    static func admitContinuation(_ task: AgentTask, modelContext: ModelContext) -> TaskStateMachine.TransitionResult {
        TaskStateMachine.admitContinuationToRuntime(task, modelContext: modelContext)
    }

    @MainActor
    @discardableResult
    static func admitApprovedPlanRun(_ task: AgentTask, modelContext: ModelContext) -> TaskStateMachine.TransitionResult {
        if task.status != .queued {
            TaskStateMachine.enqueueApprovedPlanRun(task, modelContext: modelContext)
        }
        return TaskStateMachine.admitQueuedTaskToRuntime(task, modelContext: modelContext)
    }
}

extension ProviderSettingsSnapshot {
    /// Deterministic, non-Vertex settings snapshot for tests that inject a
    /// fake process runner/binary runner and must not depend on this
    /// machine's ambient `UserDefaults` (e.g. a developer's Vertex config).
    static var headlessScenario: ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            providerSettings: AgentRuntimeProviderSettings(),
            providerSettingsRevision: 0,
            providerSettingsSignature: "headless-scenario",
            claudeProvider: .anthropic,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        )
    }
}
