import Foundation
import ASTRACore
import ASTRAModels

/// Utility title failures must not trigger repeated launches with the same
/// broken authentication/configuration across a batch of unrelated chats.
@MainActor
enum TaskTitleGenerationService {
    struct Outcome {
        let title: String?
        let shouldStopBatch: Bool
    }

    static func generate(goal: String, workspacePath: String, configuration: AgentUtilityRuntimeConfiguration) async -> Outcome {
        let baseRuntime = configuration
        let prompt = """
        Generate a short title (3-6 words) for this task. Return ONLY the title, nothing else. \
        Use sentence case. Be specific about the action and subject. Examples:
        - "Review Jira ticket summary" not "Help with Jira"
        - "Fix login page CSS" not "Fix the bug"
        - "Analyze BRIE evaluation data" not "Data analysis task"

        Task: \(String(goal.prefix(500)))
        """

        let modelCandidates = [
            baseRuntime.model,
            AgentRuntimeAdapterRegistry.defaultModel(for: baseRuntime.runtime)
        ].reduce(into: [String]()) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }

        var lastFailureFields: [String: String] = [:]
        var attempted = 0
        var shouldStopBatch = false
        for candidate in modelCandidates {
            var candidateRuntime = baseRuntime
            candidateRuntime.model = candidate
            attempted += 1
            let result = await AgentUtilityRuntimeRunner.runPrompt(
                prompt,
                workspacePath: workspacePath,
                configuration: candidateRuntime
            )

            guard result.exitCode == 0 else {
                lastFailureFields = titleGenerationFailureFields(result: result, model: candidate)
                AppLogger.audit(.specExtractionFailed, category: "Worker", fields: [
                    "operation": "title_generation",
                    "model": candidate,
                    "runtime": candidateRuntime.runtime.rawValue,
                    "result": "candidate_failed",
                    "exit_code": String(result.exitCode),
                    "error_summary": lastFailureFields["error_summary"] ?? "none"
                ], level: .debug)
                let diagnostic = AgentRuntimeFailureDiagnostic.classify(runtime: candidateRuntime.runtime,
                    model: candidate, exitCode: result.exitCode, rawError: result.error,
                    runOutput: result.output, providerVersion: nil, stream: nil)
                guard diagnostic.category == .modelUnavailable else {
                    shouldStopBatch = true
                    break
                }
                continue
            }

            // Sanitise at the source: trim, strip quotes, and collapse the
            // occasional self-doubled output ("New greetingNew greeting") so the
            // stored title is clean and no view layer has to paper over it.
            let title = TaskTitleSanitizer.sanitizeGeneratedTitle(result.output)
            guard !title.isEmpty, title.count <= 80 else { continue }
            return Outcome(title: title, shouldStopBatch: false)
        }

        var fields = lastFailureFields
        fields["operation"] = "title_generation"
        fields["result"] = "all_candidates_failed"
        fields["candidate_count"] = String(attempted)
        AppLogger.audit(.specExtractionFailed, category: "Worker", fields: fields, level: .warning)
        return Outcome(title: nil, shouldStopBatch: shouldStopBatch)
    }

    private static func titleGenerationFailureFields(result: AgentUtilityRunResult, model: String) -> [String: String] {
        let rawSummary = !result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.error
            : result.output
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "model": model,
            "exit_code": String(result.exitCode),
            "stderr_chars": String(result.error.count),
            "stdout_chars": String(result.output.count),
            "error_summary": summary.isEmpty ? "empty_process_output" : String(summary.prefix(240))
        ]
    }

}
