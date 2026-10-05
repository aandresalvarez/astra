import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

extension CopilotCLIRuntimeAdapter {
    /// Session files can outlive the CLI's ability to load them (copilot-cli #2899: schema-incompatible
    /// state reports `No session or task matched`), so the store probe still finds them. When the CLI
    /// explicitly rejects the resumed session, clear it so the retry starts fresh instead of passing the
    /// same rejected `--resume` ID again.
    func shouldClearStaleSessionOnFailure(phase: RunPhase, result: AgentProcessResult) -> Bool {
        guard phase == .resume else { return false }
        let error = result.error?.lowercased() ?? ""
        return (error.contains("no session") && error.contains("matched"))
            || (error.contains("session") && error.contains("could not be loaded"))
    }

    /// Session discovery and the usage fallback are separate: a stream can report usage without naming its
    /// session, and that session must still be adopted so the next follow-up can resume it natively.
    @MainActor
    func recordPostProcessEvents(context: AgentRuntimePostProcessContext) {
        let task = context.task
        let run = context.run
        let ownSession = run.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needsUsage = run.tokensUsed == 0
        guard ownSession.isEmpty || needsUsage else { return }
        let accepts: (String, Date) -> Bool = ownSession.isEmpty
            ? CopilotSessionMetricsReader.launchCreatedSessionFilter(
                task: task, run: run, runStartedAt: context.runStartedAt)
            : { sessionID, _ in sessionID == ownSession }
        var seenHomes: Set<String> = []
        var session: CopilotSessionCandidate?
        for home in [context.homeDirectory, CopilotCLIRuntime.defaultHome()] where session == nil {
            let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenHomes.insert(trimmed).inserted else { continue }
            session = CopilotSessionMetricsReader.newestTaskSession(
                copilotHome: trimmed,
                taskID: task.id,
                modifiedSince: context.runStartedAt.addingTimeInterval(-CopilotSessionMetricsReader.metricsWindow),
                accepts: accepts
            )
        }
        guard let session else { return }
        if ownSession.isEmpty {
            CopilotSessionMetricsReader.adoptSession(session.sessionID, task: task, run: run)
        }
        guard needsUsage, let metrics = session.metrics else { return }
        AgentEventRecorder.recordCopilotEvent(
            metrics.event,
            to: task,
            run: run,
            modelContext: context.modelContext, recordingMode: context.recordingMode,
            recordingState: context.recordingState
        )
        if let parsed = AgentEventRecorder.parsedEvent(from: metrics.event) {
            context.onEvent(parsed)
        }
        AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
            "source": "copilot_session_state",
            "session_id_prefix": String(metrics.sessionID.prefix(8)),
            "tokens_total": String(metrics.totalTokens),
            "tokens_input": String(metrics.inputTokens),
            "tokens_output": String(metrics.outputTokens),
            "turns": metrics.turns.map(String.init) ?? "unknown",
            "duration_ms": metrics.durationMs.map(String.init) ?? "unknown"
        ])
    }
}
