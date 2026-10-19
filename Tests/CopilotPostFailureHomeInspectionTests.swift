import Testing
import ASTRACore
@testable import ASTRA

@Suite("Copilot post-failure home inspection")
@MainActor
struct CopilotPostFailureHomeInspectionTests {
    @Test("Only silent host failures acquire filesystem evidence",
          arguments: ["silent", "warning", "blank-lines", "stderr", "run-output", "failure-output", "startup-log", "json-event", "parsed-event",
                      "success", "other-exit", "runtime-stop", "timeout", "budget", "max-turns", "policy-stop", "approval", "repetition", "reaped",
                      "cancelled", "container", "other-runtime"])
    func acquisitionPolicy(mode: String) async {
        let result = AgentProcessResult(
            exitCode: mode == "success" ? 0 : (mode == "other-exit" ? 2 : 1),
            error: mode == "stderr" ? "Authentication failed" : (mode == "warning" ? "Warning: deprecated option" : nil),
            providerFailureOutput: mode == "failure-output" ? "Model unavailable" : nil,
            policyViolation: mode == "policy-stop", policyApprovalRequired: mode == "approval",
            runtimeStopReason: mode == "runtime-stop" ? "cancelled" : nil,
            budgetExceeded: mode == "budget", terminatedAfterTerminalProgress: mode == "reaped",
            timedOut: mode == "timeout", repetitionKilled: mode == "repetition", maxTurnsExceeded: mode == "max-turns"
        )
        let telemetry = AgentRuntimeStreamTelemetry()
        if mode == "json-event" { telemetry.recordRawLine(parsesJSONLines: true) }
        if mode == "blank-lines" { telemetry.recordRawLine(parsesJSONLines: false) }
        if mode == "parsed-event" { telemetry.recordParsed([.text(text: "partial response")]) }
        var inspections = 0
        _ = await CopilotPostFailureHomeInspection.inspect(
            runtime: mode == "other-runtime" ? .codexCLI : .copilotCLI,
            result: result, runOutput: mode == "run-output" ? "Partial answer" : "",
            stream: telemetry.snapshot(), startupEvidence: mode == "startup-log" ? "[ERROR] other cause" : nil,
            cancelled: mode == "cancelled", providerRunsInsideContainer: mode == "container"
        ) {
            inspections += 1
            return nil
        }
        #expect(inspections == (["silent", "warning", "blank-lines"].contains(mode) ? 1 : 0))
    }
}
