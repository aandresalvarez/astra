import Foundation
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
        let worker = AgentRuntimeWorker()
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        return worker
    }
}
