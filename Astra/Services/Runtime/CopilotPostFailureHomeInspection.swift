import Foundation
import ASTRACore

/// Acquire filesystem evidence only when it can change the failure diagnosis.
/// The caller captures its final launch environment lazily and performs the
/// actual inspection off the main actor.
@MainActor
enum CopilotPostFailureHomeInspection {
    static func inspect(
        runtime: AgentRuntimeID, result: AgentProcessResult, runOutput: String,
        stream: AgentRuntimeStreamTelemetrySnapshot?, startupEvidence: String?,
        cancelled: Bool, providerRunsInsideContainer: Bool,
        inspector: @MainActor () async -> CopilotHomeAccessReport?
    ) async -> CopilotHomeAccessReport? {
        guard runtime == .copilotCLI, result.exitCode == 1, !providerRunsInsideContainer,
              !cancelled, !Task.isCancelled, !result.stoppedByASTRA else { return nil }
        // Reuse the classifier's evidence normalization and category policy.
        // Benign stderr warnings and blank framing lines are still silent;
        // substantive stderr, stdout, startup logs or parsed events are not.
        let output = [runOutput, result.providerFailureOutput]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: runtime, model: "", exitCode: result.exitCode, rawError: result.error,
            runOutput: output, providerVersion: result.providerVersion, stream: stream,
            timedOut: result.timedOut, budgetExceeded: result.budgetExceeded,
            maxTurnsExceeded: result.maxTurnsExceeded, startupEvidence: startupEvidence
        )
        guard AgentRuntimeFailureDiagnostic.copilotHomeEvidenceCanExplain(
            category: diagnostic.category, exitCode: result.exitCode, rawError: result.error,
            runOutput: output, startupEvidence: startupEvidence, stream: stream
        ) else { return nil }
        return await inspector()
    }
}
