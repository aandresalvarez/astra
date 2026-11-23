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
    /// the row ends up with the input the call ran with. Only an id that tells
    /// calls apart reaches here (see the recorder's `tool.use` case).
    static func updateOpenUse(_ open: TaskEvent, payload: String, task: AgentTask) {
        let redacted = RunSecretRedactionScope.redact(payload, taskID: task.id)
        guard open.payload != redacted else { return }
        open.payload = redacted
        // The row keeps its timestamp: it is when the call started, and the
        // order operations, narration and answer selection read. The
        // incremental reader only refetches rows at or after its cursor, so it
        // is told to read again in full instead.
        task.updatedAt = Date()
        TaskThreadHistoryInvalidation.invalidate(taskID: task.id)
        TaskThreadChangeNotifier.post(taskID: task.id, source: "tool_use_updated")
    }

    /// A denied call gets no result: the denial is what ended it. Closes the
    /// open call the denial names — by its id, or by its tool's name when
    /// exactly one open call used that tool — and nothing when it names none,
    /// so a denial that arrives twice, or for a call already finished, adds
    /// no record.
    static func recordDenied(
        tool: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState?
    ) {
        guard let recordingState, let callID = recordingState.openOperationID(deniedTool: tool, run: run) else { return }
        recordingState.holdOperationStatus(
            .init(outcome: .failed, exitCode: nil, providerStatus: ToolOperationRecord.deniedStatus), id: callID, run: run
        )
        recordFinished(
            callID: callID, isError: true, resultEvent: nil,
            task: task, run: run, modelContext: modelContext, recordingState: recordingState
        )
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
        // An error result is a failure whatever the status said, except a call
        // the provider says was cancelled: that stays a cancellation.
        let reported = finished?.status?.outcome
        let outcome: AgentOperationOutcome = reported == .cancelled ? .cancelled : (isError ? .failed : (reported ?? .succeeded))
        let record = ToolOperationRecord(
            callID: callID,
            tool: finished?.tool,
            outcome: outcome,
            exitCode: finished?.status?.exitCode,
            providerStatus: finished?.status?.providerStatus,
            hasOutput: resultEvent != nil,
            useEventID: finished?.use?.id,
            resultEventID: resultEvent?.id,
            finishedAt: Date(),
            groupID: finished?.group?.id,
            candidateUseEventIDs: finished?.group?.listed
        )
        // The run's open batch takes the record in place; a full one, or a
        // recording with no state to remember it in, starts a new row.
        if let open = recordingState?.openOperationBatch(for: run),
           var batch = ToolOperationBatch.decode(from: open.payload),
           batch.operations.count < ToolOperationBatch.capacity,
           case let payload = TaskEvent.payloadString(ToolOperationBatch(operations: batch.operations + [record])),
           payload.count <= ToolOperationBatch.payloadCharacterLimit {
            batch.operations.append(record)
            open.payload = RunSecretRedactionScope.redact(payload, taskID: task.id)
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
