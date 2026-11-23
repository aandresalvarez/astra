import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Writes the durable records that keep a tool operation's identity and
/// outcome: `tool.operation` as calls finish and `runtime.background_job`
/// when a provider job ends. The `tool.use` and `tool.result` rows keep the
/// text payloads their readers expect; these records sit beside them.
@MainActor
enum AgentToolOperationRecording {
    /// A provider repeating an open call — OpenCode sends one frame per state
    /// change — updates the row it already has, so one call stays one row and
    /// the row ends up with the input the call ran with.
    static func updateOpenUse(_ open: TaskEvent, payload: String, task: AgentTask) {
        let redacted = RunSecretRedactionScope.redact(payload, taskID: task.id)
        guard open.payload != redacted else { return }
        open.payload = redacted
        // The incremental transcript read only refetches rows at or after its
        // cursor; the bump is what makes an in-place change visible to it.
        let changedAt = Date()
        open.timestamp = changedAt
        task.updatedAt = changedAt
        TaskThreadChangeNotifier.post(taskID: task.id, source: "tool_use_updated")
    }

    /// Called for every tool result, including one with no output. The
    /// provider's own status decides the outcome when it gave one; an error
    /// result is a failure whatever the status said.
    static func recordFinished(
        callID: String,
        isError: Bool,
        resultEvent: TaskEvent?,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState?
    ) {
        let finished = recordingState?.finishToolOperation(id: callID, run: run)
        let outcome: AgentOperationOutcome = isError ? .failed : (finished?.status?.outcome ?? .succeeded)
        let record = ToolOperationRecord(
            callID: callID,
            tool: finished?.tool,
            outcome: outcome,
            exitCode: finished?.status?.exitCode,
            providerStatus: finished?.status?.providerStatus,
            hasOutput: resultEvent != nil,
            useEventID: finished?.use?.id,
            resultEventID: resultEvent?.id,
            finishedAt: Date()
        )
        // The run's open batch takes the record in place; a full one, or a
        // recording with no state to remember it in, starts a new row.
        if let open = recordingState?.openOperationBatch(for: run),
           var batch = ToolOperationBatch.decode(from: open.payload),
           batch.operations.count < ToolOperationBatch.capacity {
            batch.operations.append(record)
            open.payload = RunSecretRedactionScope.redact(TaskEvent.payloadString(batch), taskID: task.id)
            let changedAt = Date()
            open.timestamp = changedAt
            task.updatedAt = changedAt
            return
        }
        let event = TaskEvent.structuredPayloadEvent(
            task: task,
            eventType: TaskEventTypes.Tool.operation,
            payload: ToolOperationBatch(operations: [record]),
            run: run
        )
        modelContext.insert(event)
        recordingState?.setOpenOperationBatch(event, for: run)
    }

    static func record(
        _ signal: AgentOperationSignal,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState?
    ) {
        switch signal {
        case .progress:
            // Liveness only: partial output is never a result and is not kept.
            break
        case .finished(let operationID, let outcome, let exitCode, let providerStatus):
            recordingState?.holdOperationStatus(
                .init(outcome: outcome, exitCode: exitCode, providerStatus: providerStatus),
                id: operationID,
                run: run
            )
        case .backgroundJobFinished(let job):
            recordingState?.breakConversationCoalescing(for: run)
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task, eventType: TaskEventTypes.Tool.backgroundJob, payload: BackgroundJobRecord(job), run: run
            ))
        }
    }
}
