import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

enum TaskExternalOperationRegistrationOutcome: Equatable {
    case registered(UUID)
    case alreadyRegistered(UUID)
    case rejected
}

/// Converts a trusted backend start receipt into task-owned control-plane
/// state. Task events are audit output only; they are never registration input.
@MainActor
enum TaskExternalOperationRegistrationService {
    static let backendKind = WorkspaceManagedJobStartReceipt.backend
    private static let maximumStructuredResultBytes = 16 * 1024

    static func registerStructuredStartResult(
        _ content: String,
        toolResultID: String,
        observedToolName: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        now: Date = Date()
    ) -> TaskExternalOperationRegistrationOutcome {
        // Must decode against the LAUNCH runtime, not the task's currently
        // selected one (the composer can retarget task.runtimeID while this
        // turn is still active) — mirrors AgentEventRecorder's redaction
        // guard, which already uses run.launchRuntimeID. A mismatch here
        // would reject a runtime-specific observed name that the recorder's
        // guard already accepted, delaying registration until a later
        // provider-exit or startup reconciliation recovers it.
        guard DockerWorkspaceMCPProjection.canonicalToolName(
            fromObservedToolName: observedToolName,
            runtime: run.launchRuntimeID(fallback: task.resolvedRuntimeID)
        ) == "workspace_job_start",
              // The provider stream id and the MCP JSON-RPC id are separate
              // protocol domains and are not required to be equal. Binding is
              // instead established by the provider's exact tool-use/result
              // pair (`toolResultID` + `observedToolName`) and then by matching
              // the structured receipt to the trusted backend record.
              !toolResultID.isEmpty,
              content.utf8.count <= maximumStructuredResultBytes,
              let data = content.data(using: .utf8),
              let result = try? JSONDecoder().decode(WorkspaceManagedJobStructuredResult.self, from: data),
              (try? result.validate()) != nil,
              let receipt = result.startReceipt else {
            logRejected(taskID: task.id, reason: "untrusted_or_malformed_structured_result")
            return .rejected
        }

        return registerVerifiedReceipt(
            receipt,
            jobID: result.jobID,
            task: task,
            run: run,
            modelContext: modelContext,
            now: now
        )
    }

    /// Closes the launch-to-registration crash window. Enumeration is confined
    /// to the task-derived trusted job root, and every candidate must carry the
    /// full task/run owner receipt written before detached launch.
    /// `cleanupTerminalExecutors` is enabled only by the STARTUP adoption pass
    /// (no provider sessions are live at launch): a job that finished while
    /// ASTRA was down is adopted directly in a terminal state, is never polled
    /// (`runDueChecks` excludes terminal rows), and its backend `observe`
    /// cleanup therefore never runs — the crash-left executor container would
    /// stay up indefinitely. Mid-session reconciliation callers keep it off so
    /// a live provider's shared container is never stopped underneath it.
    @discardableResult
    static func reconcileTrustedBackendRecords(
        task: AgentTask,
        modelContext: ModelContext,
        now: Date = Date(),
        cleanupTerminalExecutors: Bool = false
    ) -> [TaskExternalOperationRegistrationOutcome] {
        // Imported/shared registrations are a hard no-contact boundary, but it
        // is scoped to each imported operation's OWN identity, not the whole
        // task: `registerVerifiedReceipt` returns `.alreadyRegistered` for any
        // receipt whose externalIdentity matches an existing (including
        // quarantined) row, so a quarantined import is never re-adopted or
        // contacted. A task-wide bail here would instead suppress adoption of
        // a NEW locally-launched receipt merely because unrelated imported
        // history exists — leaving that fresh job unmonitored after a crash in
        // the launch-to-registration window, with orphan recovery then
        // terminalizing its run and exposing a duplicate-launch retry.

        let jobRoot = DockerWorkspaceMCPProjection.jobRootHostPath(task: task)
        guard !jobRoot.isEmpty else { return [] }
        let records: [WorkspaceManagedJobRecord]
        do {
            records = try WorkspaceManagedJobStore(rootPath: jobRoot).listTrustedRecords()
        } catch {
            AppLogger.audit(.workerBlocked, category: "ExternalOperation", taskID: task.id, fields: [
                "operation": "reconcile_backend_records",
                "result": "trusted_listing_rejected",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
            return []
        }

        // NOT uniqueKeysWithValues: workspace config import does not enforce
        // run-ID uniqueness, so a malformed/duplicated imported config could
        // otherwise trap this startup-path initializer and prevent launch.
        let runsByID = Dictionary(task.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            guard let receipt = record.startReceipt,
                  receipt.taskID == task.id,
                  let run = runsByID[receipt.runID],
                  (try? receipt.validate(jobID: record.jobID)) != nil else {
                logRejected(taskID: task.id, reason: "backend_owner_mismatch")
                return nil
            }
            let outcome = registerVerifiedReceipt(
                receipt,
                jobID: record.jobID,
                task: task,
                run: run,
                modelContext: modelContext,
                now: now
            )
            if cleanupTerminalExecutors,
               case .registered(let operationID) = outcome,
               let operation = operations(taskID: task.id, modelContext: modelContext)
                   .first(where: { $0.id == operationID }),
               operation.executionState.isTerminalObservation {
                cleanupExecutorForAdoptedTerminalJob(
                    operation: operation,
                    receipt: receipt,
                    task: task,
                    modelContext: modelContext
                )
            }
            return outcome
        }
    }

    /// Startup-only guarded idle cleanup for a job that terminalized while
    /// ASTRA was down. Mirrors the backend `observe` path's cleanup, including
    /// its container-identity check and `cleanupExecutorIfIdle`'s fail-closed
    /// nonterminal-work guard.
    private static func cleanupExecutorForAdoptedTerminalJob(
        operation: TaskExternalOperation,
        receipt: WorkspaceManagedJobStartReceipt,
        task: AgentTask,
        modelContext: ModelContext
    ) {
        let resolver = WorkspaceManagedJobBackendLocatorResolver(modelContext: modelContext)
        let request = TaskExternalOperationBackendRequest(
            operationID: operation.id,
            taskID: task.id,
            originatingRunID: operation.originatingRunID,
            externalIdentity: operation.externalIdentity,
            backendKind: operation.backendKindRaw,
            backendJobID: operation.backendJobID
        )
        guard let locator = resolver.locator(for: request),
              let configuration = locator.configuration,
              receipt.containerName == configuration.containerName else { return }
        let executor = DockerWorkspaceCommandExecutor(configuration: configuration)
        let manager = DockerWorkspaceJobManager(configuration: configuration, executor: executor)
        let cleaned = manager.cleanupExecutorIfIdle()
        AppLogger.audit(.taskCompleted, category: "ExternalOperation", taskID: task.id, fields: [
            "operation": "cleanup_adopted_terminal_executor",
            "result": cleaned ? "stopped_or_absent" : "preserved"
        ])
    }

    /// The launch-time execution root for a wake's target operation, if it
    /// persisted one and it names a real filesystem path (not the `task:`
    /// fallback used when the task had no resolvable working directory at
    /// launch). Both resource-lock admission and worker execution must run a
    /// terminal wake in THIS root — the workspace's active path is
    /// user-mutable while the job runs, so recomputing from the task's
    /// current state can validate the wrong filesystem state entirely.
    static func launchExecutionRoot(
        operationID: UUID,
        modelContext: ModelContext
    ) -> String? {
        var descriptor = FetchDescriptor<TaskExternalOperation>(
            predicate: #Predicate<TaskExternalOperation> { $0.id == operationID }
        )
        descriptor.fetchLimit = 1
        guard let key = (try? modelContext.fetch(descriptor).first)?.launchResourceKey,
              !key.hasPrefix("task:") else {
            return nil
        }
        return key
    }

    /// Any of the task's operations' persisted launch-time root (excluding the
    /// `task:` no-path fallback). Isolation is prepared once per task and
    /// reused deterministically, so every operation the task owns shares the
    /// same launch root; the first one found is sufficient. For callers that
    /// need the launch root WITHOUT a specific operation in hand (isolation
    /// cleanup on task/workspace deletion).
    static func taskLaunchExecutionRoot(taskID: UUID, modelContext: ModelContext) -> String? {
        operations(taskID: taskID, modelContext: modelContext)
            .compactMap(\.launchResourceKey)
            .first { !$0.hasPrefix("task:") }
    }

    static func operations(taskID: UUID, modelContext: ModelContext) -> [TaskExternalOperation] {
        let descriptor = FetchDescriptor<TaskExternalOperation>(
            predicate: #Predicate<TaskExternalOperation> { $0.taskID == taskID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    static func activeOperation(
        taskID: UUID,
        originatingRunID: UUID,
        modelContext: ModelContext
    ) -> TaskExternalOperation? {
        operations(taskID: taskID, modelContext: modelContext).first {
            $0.originatingRunID == originatingRunID
                && [.active, .validating].contains($0.monitoringState)
        }
    }

    private static func registerVerifiedReceipt(
        _ receipt: WorkspaceManagedJobStartReceipt,
        jobID: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        now: Date
    ) -> TaskExternalOperationRegistrationOutcome {
        guard receipt.taskID == task.id,
              receipt.runID == run.id,
              run.task?.id == task.id,
              (try? receipt.validate(jobID: jobID)) != nil else {
            logRejected(taskID: task.id, reason: "receipt_owner_mismatch")
            return .rejected
        }

        let store = WorkspaceManagedJobStore(
            rootPath: DockerWorkspaceMCPProjection.jobRootHostPath(task: task)
        )
        guard let authoritative = try? store.load(jobID: jobID),
              authoritative.startReceipt == receipt else {
            logRejected(taskID: task.id, reason: "authoritative_record_mismatch")
            return .rejected
        }

        if let existing = operation(
            externalIdentity: receipt.externalIdentity,
            modelContext: modelContext
        ) {
            return .alreadyRegistered(existing.id)
        }

        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        let originatingRevision = taskFolder.isEmpty
            ? nil
            : TaskContextStateManager.load(taskFolder: taskFolder)?.updatedAt
        let initialExecutionState = executionState(for: authoritative.status)
        let initialMonitoringState: TaskExternalOperationMonitoringState
        if initialExecutionState == .processCompleted {
            initialMonitoringState = .validating
        } else if initialExecutionState.isTerminalObservation {
            initialMonitoringState = .completed
        } else {
            initialMonitoringState = .active
        }
        let operation = TaskExternalOperation(
            taskID: task.id,
            externalIdentity: receipt.externalIdentity,
            originatingRunID: run.id,
            backendKindRaw: backendKind,
            backendJobID: authoritative.jobID,
            originatingContextRevision: originatingRevision,
            executionState: initialExecutionState,
            observationHealth: .healthy,
            monitoringState: initialMonitoringState,
            nextCheckAt: initialExecutionState.isTerminalObservation ? nil : now,
            createdAt: now
        )
        if initialExecutionState.isTerminalObservation {
            operation.terminalObservedAt = now
        }
        // Freeze the LAUNCH-TIME execution root for resource exclusion. The
        // workspace's active path is user-mutable while the detached job runs;
        // recomputing the holder key later would drift exclusion to the new
        // path and leave the actually-mounted root unprotected.
        operation.launchResourceKey = TaskQueue.resourceKey(for: task)
        modelContext.insert(operation)
        // Registration is the durable ownership boundary. Move the task out of
        // provider-owned Running immediately so a later provider timeout,
        // budget exit, or crash cannot expose a retry that duplicates the job.
        _ = TaskExternalOperationProviderLifecycleService.beginMonitoringAtRegistration(
            operation: operation,
            task: task,
            run: run,
            modelContext: modelContext,
            at: now
        )
        // Registration is only a durable ownership boundary once it is actually
        // ON DISK. SwiftData autosave gives no timing guarantee, and the next
        // guaranteed save happens only after the provider run finishes — a
        // crash in that window would lose the operation row and the task/run
        // transition while the detached backend job stays live, and startup
        // reconciliation would then reject the receipt (its run row is gone),
        // leaving unregistered work that a retry can duplicate. Commit
        // synchronously before reporting `.registered`.
        let saved = WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "external_operation_registered"]
        )
        guard saved else {
            // A registration that is not on disk is not an ownership boundary.
            // Reporting `.registered` on a failed save would leave the task
            // transition, run, and operation in memory only — a crash before a
            // later successful save loses the run row, startup adoption then
            // rejects the receipt, and the live detached job faces a duplicate
            // retry. Roll the half-applied registration back and reject.
            modelContext.rollback()
            logRejected(taskID: task.id, reason: "registration_save_failed")
            return .rejected
        }
        AppLogger.audit(.taskStarted, category: "ExternalOperation", taskID: task.id, fields: [
            "operation": "register",
            "backend": backendKind,
            "external_identity": receipt.externalIdentity,
            "originating_run_id": run.id.uuidString
        ])
        return .registered(operation.id)
    }

    private static func operation(
        externalIdentity: String,
        modelContext: ModelContext
    ) -> TaskExternalOperation? {
        let descriptor = FetchDescriptor<TaskExternalOperation>(
            predicate: #Predicate<TaskExternalOperation> { $0.externalIdentity == externalIdentity }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private static func executionState(
        for status: WorkspaceManagedJobStatus
    ) -> TaskExternalOperationExecutionState {
        switch status {
        case .queued: .queued
        case .running: .running
        case .succeeded: .processCompleted
        case .failed: .failed
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        }
    }

    private static func logRejected(taskID: UUID, reason: String) {
        AppLogger.audit(.workerBlocked, category: "ExternalOperation", taskID: taskID, fields: [
            "operation": "register",
            "result": "rejected",
            "reason": reason
        ], level: .warning)
    }
}
