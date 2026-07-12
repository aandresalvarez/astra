import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
enum AgentRuntimeRunPersistence {
    static func recordSessionTurn(
        task: AgentTask,
        run: TaskRun,
        message: String
    ) {
        let folder = (try? TaskWorkspaceAccess(task: task).ensureTaskFolder()) ?? ""
        guard !folder.isEmpty else { return }

        SessionHistoryManager.recordTurn(
            taskFolder: folder,
            taskTitle: task.title,
            turnMessage: message,
            output: run.output,
            tokensUsed: run.tokensUsed,
            costUSD: run.costUSD,
            fileChanges: run.fileChanges,
            redactions: AgentSensitiveRedactions.values(for: task),
            durationMs: run.completedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) }
        )
        TaskContextStateManager.recordTurn(task: task, run: run, message: message)

        // Tier 2 objective re-assessment: opt-in, background-only, and gated by
        // its own deterministic trigger predicate (turn/hash/staleness) so it
        // never runs on every turn even when the setting is on. Never awaited
        // here -- this must stay off the render/refresh path (INVARIANTS #2).
        if UserDefaults.standard.bool(forKey: AppStorageKeys.objectiveDriftDetectionEnabled) {
            Task { @MainActor in
                await ObjectiveAssessmentService.assessIfNeeded(task: task)
            }
        } else {
            // Setting is off: drop any stale assessment left over from when it
            // was previously enabled so follow-up framing reverts to Tier-1-only
            // behavior immediately, per the Settings copy's "failures leave
            // existing behavior unchanged" contract. Synchronous and cheap (a
            // no-op when nothing is persisted); see
            // ObjectiveAssessmentService.clearAssessmentIfDriftDetectionDisabled.
            ObjectiveAssessmentService.clearAssessmentIfDriftDetectionDisabled(task: task)
        }
    }

    static func finalizeAndPersist(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        handoffDiscoveredFiles: [TaskOutputDiscoveredFile]? = nil
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        // File discovery is independent of SwiftData. Prepare it asynchronously
        // before the ordered model commit so directory traversal does not
        // monopolize the main actor. No SwiftData model crosses actors.
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let discoveredFiles: [TaskOutputDiscoveredFile]
        if let handoffDiscoveredFiles {
            discoveredFiles = handoffDiscoveredFiles
        } else {
            discoveredFiles = await TaskOutputDiscovery.filesAsync(in: taskFolder)
        }
        // Bound the inline output blob now that the run is finalized. Session
        // history already captured the full output via recordSessionTurn before
        // this call, so nothing the user can re-open is lost. Assign only when it
        // actually changes to avoid a needless SwiftData write.
        let cappedOutput = TaskRunOutputCap.capped(run.output)
        if cappedOutput != run.output {
            run.output = cappedOutput
        }

        let artifactReconciliation = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(
            discoveredFiles,
            for: task,
            modelContext: modelContext
        )
        AgentEventCompactor.compactEvents(for: task, modelContext: modelContext)
        AgentPolicyManifestService.recordPostRunSummary(task: task, run: run, modelContext: modelContext)
        TaskWorkerHandoffService.recordCreatedIfNeeded(
            task: task,
            run: run,
            modelContext: modelContext,
            discoveredFiles: discoveredFiles
        )
        MissionHardeningService.recordCheckpoint(task: task, run: run, modelContext: modelContext)

        let finishedAt = Date()
        task.updatedAt = finishedAt
        if task.isTerminal {
            task.completedAt = finishedAt
        }
        task.markUnreadForCurrentStatus(at: finishedAt)

        let auditFields = fields(
            task: task,
            run: run,
            phase: phase,
            persistedArtifactCount: artifactReconciliation.createdArtifacts.count
        )
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: auditFields
        )

        var telemetryFields = auditFields
        telemetryFields["task_id"] = PerformanceTelemetryFields.abbreviatedID(task.id)
        telemetryFields["run_id"] = PerformanceTelemetryFields.abbreviatedID(run.id)
        PerformanceTelemetry.logIfNeeded(
            "run_finalize_persist",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.backgroundThresholdMilliseconds,
            fields: telemetryFields
        )
    }

    static func fields(
        task: AgentTask,
        run: TaskRun,
        phase: RunPhase,
        persistedArtifactCount: Int = 0
    ) -> [String: String] {
        let start = DispatchTime.now().uptimeNanoseconds
        let runEvents = task.events.filter { $0.run?.id == run.id }
        let responseEventCount = runEvents.filter { $0.type == "agent.response" }.count
        let thinkingEventCount = runEvents.filter { $0.type == "agent.thinking" }.count
        let toolUseEventCount = runEvents.filter { $0.type == "tool.use" }.count
        let toolResultEventCount = runEvents.filter { $0.type == "tool.result" }.count
        let errorEventCount = runEvents.filter { $0.type == "error" }.count
        let artifactCount = task.artifacts.count
        var fields: [String: String] = [
            "phase": phase.rawValue,
            "runtime": run.runtimeID ?? task.resolvedRuntimeID.rawValue,
            "task_status": task.status.rawValue,
            "run_status": run.status.rawValue,
            "run_stop_reason": run.stopReason,
            "exit_code": run.exitCode.map(String.init) ?? "none",
            "provider_version": run.providerVersion ?? "unknown"
        ]
        fields["run_output_chars"] = String(run.output.count)
        fields["run_output_bucket"] = PerformanceTelemetryFields.byteBucket(run.output.utf8.count)
        fields["event_count"] = String(task.events.count)
        fields["response_event_count"] = String(responseEventCount)
        fields["thinking_event_count"] = String(thinkingEventCount)
        fields["tool_use_event_count"] = String(toolUseEventCount)
        fields["tool_result_event_count"] = String(toolResultEventCount)
        fields["error_event_count"] = String(errorEventCount)
        fields["run_event_count"] = String(runEvents.count)
        fields["file_changes"] = String(run.fileChanges.count)
        fields["artifact_count"] = String(artifactCount)
        fields["task_artifacts"] = String(artifactCount)
        fields["persisted_task_output_artifacts"] = String(persistedArtifactCount)
        fields["tokens_input"] = String(run.inputTokens)
        fields["tokens_output"] = String(run.outputTokens)
        PerformanceTelemetry.logIfNeeded(
            "run_persistence_fields",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
                "run_id": PerformanceTelemetryFields.abbreviatedID(run.id),
                "event_count": PerformanceTelemetryFields.count(task.events.count),
                "run_event_count": PerformanceTelemetryFields.count(runEvents.count),
                "artifact_count": PerformanceTelemetryFields.count(task.artifacts.count)
            ]
        )
        return fields
    }
}
