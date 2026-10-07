import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Durable run events own the two boundaries: result captured, then verdict
/// committed. Workers, plans and startup use this same protocol. A captured
/// result is never a reason to launch the original provider turn again.
@MainActor
enum RuntimeTurnSettlementService {
    struct ApprovedPlan: Codable {
        let plan: TaskPlanPayload
        let step: TaskPlanPayloadStep?
    }

    struct Checkpoint: Codable {
        var version = 1
        let requestID: UUID?
        let result: AgentProcessResult
        let runtime: AgentRuntimeID
        let phase: RunPhase
        let executionPath: String
        let launchSnapshot: AgentTaskLaunchSnapshot
        let permissionPolicy: PermissionPolicy
        let sandboxEnforcement: ExecutionSandboxEnforcement?
        let verifierRuntime: AgentUtilityRuntimeConfiguration
        let timeoutSeconds: TimeInterval
        let budgetEnforcementMode: String
        let effectiveTokenBudget: Int
        let tokensUsed: Int
        let agentReportedError: Bool
        let cancelled: Bool
        let failureDiagnostic: AgentRuntimeFailureDiagnostic?
        let approvedPlan: ApprovedPlan?
        let chainedGoal: String
        let scheduleID: UUID?
        var sessionMessage: String? = nil
    }

    struct Verdict: Codable {
        var version = 1
        let requestState: TaskTurnRequestState
        let reason: String
        let chainedTaskID: UUID?
        let chainedGoal: String?
        let scheduleID: UUID?
    }

    enum Failure: Error {
        case missingCheckpoint, incompatibleCheckpoint, recoverySubmissionFailed, invalidRequestOwner, rejectedRequestTransition
    }

    static func checkpoint(for run: TaskRun, task: AgentTask) throws -> Checkpoint? {
        guard let event = task.events.first(where: {
            !$0.isDeleted && $0.run?.id == run.id && $0.type == TaskEventTypes.System.runtimeResultCaptured.rawValue
        }) else { return nil }
        let value = try JSONDecoder().decode(Checkpoint.self, from: Data(event.payload.utf8))
        guard value.version == 1 else { throw Failure.incompatibleCheckpoint }
        return value
    }

    static func verdict(for run: TaskRun, task: AgentTask) -> Verdict? {
        task.events.first {
            !$0.isDeleted && $0.run?.id == run.id && $0.type == TaskEventTypes.System.runtimeTurnSettled.rawValue
        }.flatMap { event in
            guard let value = try? JSONDecoder().decode(Verdict.self, from: Data(event.payload.utf8)), value.version == 1 else { return nil }
            return value
        }
    }

    static func hasUnsettledResult(task: AgentTask, run: TaskRun) -> Bool {
        task.events.contains {
            !$0.isDeleted && $0.run?.id == run.id && $0.type == TaskEventTypes.System.runtimeResultCaptured.rawValue
        } && verdict(for: run, task: task) == nil
    }

    /// The only normal/restart settlement pipeline. Streaming transport has
    /// already ended; completion effects require its committed return value.
    static func settle(checkpoint: Checkpoint, task: AgentTask, run: TaskRun, modelContext: ModelContext,
                       permissionPromotionPersistence: (() throws -> Void)? = nil,
                       verdictPersistence: (() throws -> Void)? = nil,
                       sessionProjection: (() -> Bool)? = nil, autoExport: Bool = true) async -> Bool {
        if verdict(for: run, task: task) != nil { return true }
        // A workspace edited while the run was suspended must not receive this run's export.
        var autoExport = autoExport
        if !TaskExecutionResourcePreparation.isCurrent(task: task, scope: checkpoint.launchSnapshot.resourceScope) {
            autoExport = false
        }
        do {
            try checkpoint.bindExecutionStorage(task: task, modelContext: modelContext)
            if let id = checkpoint.requestID {
                guard let owner = try TaskTurnRequestRepository.request(id: id, in: modelContext),
                      owner.taskID == task.id, owner.runID == run.id else { throw Failure.invalidRequestOwner }
            }
            var alreadyPrepared = false
            if let prepared = try RuntimeSettlementProgress.prepared(task: task, run: run) {
                RuntimeSettlementProgress.restore(prepared, task: task, modelContext: modelContext)
                alreadyPrepared = prepared.finalizationComplete ?? true
            } else if RuntimeSettlementProgress.event(TaskEventTypes.System.runtimeSettlementStarted, task: task, run: run) != nil {
                pauseForReconciliation(task: task, run: run, modelContext: modelContext,
                    reason: "runtime_settlement_uncertain",
                    message: "Result settlement was interrupted before validation finished. Review validation and external changes before retrying; ASTRA did not rerun them.")
                return commit(checkpoint: checkpoint, task: task, run: run, modelContext: modelContext,
                    persist: verdictPersistence, autoExport: autoExport)
            } else {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeSettlementStarted,
                    payload: "Outcome settlement started. Validation must not be replayed without a prepared result.", run: run))
                try save(task: task, modelContext: modelContext, operation: "runtime_settlement_started", persist: nil,
                    autoExport: autoExport)
                try await RuntimeTurnOutcomeService.apply(checkpoint: checkpoint, task: task, run: run,
                    modelContext: modelContext, permissionPromotionPersistence: permissionPromotionPersistence)
                await validatePlan(checkpoint: checkpoint, task: task, run: run, modelContext: modelContext)
                // Validation effects are durable before writing derived files.
                // Projection I/O failures can retry without re-executing work.
                RuntimeSettlementProgress.stagePrepared(task: task, run: run, modelContext: modelContext,
                    finalizationComplete: false)
                try save(task: task, modelContext: modelContext, operation: "runtime_outcome_validated", persist: nil,
                    autoExport: autoExport)
            }
            let request = try checkpoint.requestID.flatMap { try TaskTurnRequestRepository.request(id: $0, in: modelContext) }
            let message = checkpoint.sessionMessage ?? request?.executionPolicySnapshot?.turnIntentSnapshot?.acceptedTurn ?? task.goal
            guard sessionProjection?() ?? AgentRuntimeRunPersistence.recordSessionTurn(task: task, run: run, message: message,
                executionContext: checkpoint.executionContext(for: task)) else {
                throw Failure.recoverySubmissionFailed
            }
            if alreadyPrepared {
                return commit(checkpoint: checkpoint, task: task, run: run, modelContext: modelContext,
                    persist: verdictPersistence, autoExport: autoExport)
            }
            guard await AgentRuntimeRunPersistence.finalizeAndPersist(task: task, run: run,
                modelContext: modelContext, phase: checkpoint.phase, executionContext: checkpoint.executionContext(for: task), autoExport: autoExport,
                persist: {
                    RuntimeSettlementProgress.stagePrepared(task: task, run: run, modelContext: modelContext)
                    do {
                        try save(task: task, modelContext: modelContext, operation: "runtime_outcome_prepared", persist: nil,
                            autoExport: autoExport)
                    } catch { return false }
                    return commit(checkpoint: checkpoint, task: task, run: run, modelContext: modelContext,
                        persist: verdictPersistence, autoExport: autoExport)
                }) else {
                reportPersistenceFailure(task: task, run: run, modelContext: modelContext)
                return false
            }
            return true
        } catch {
            if run.typedStopReason == .permissionApprovalRequired,
               TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task) {
                // The provider stopped for permission. If the promotion save
                // failed transiently, commit that pause with the captured
                // result; a later user approval must not wait behind a running
                // request whose provider has already exited.
                TaskPermissionContinuation.reportPromotionPersistenceFailure(task: task, run: run, modelContext: modelContext)
                return commit(checkpoint: checkpoint, task: task, run: run, modelContext: modelContext,
                    autoExport: autoExport)
            }
            reportPersistenceFailure(task: task, run: run, modelContext: modelContext)
            return false
        }
    }

    /// Called only after the provider event queue is drained. Receipts and the
    /// result checkpoint share a save; no process callback can save a receipt.
    static func capture(_ checkpoint: Checkpoint, task: AgentTask, run: TaskRun,
                        modelContext: ModelContext, persist: (() throws -> Void)? = nil) throws {
        if try self.checkpoint(for: run, task: task) == nil {
            modelContext.insert(TaskEvent.structuredPayloadEvent(task: task,
                type: TaskEventTypes.System.runtimeResultCaptured.rawValue, payload: checkpoint, run: run))
        }
        LivePermissionApprovalRecovery.stageAcknowledgements(task: task, run: run,
            requestIDs: checkpoint.result.acknowledgedPermissionRequestIDs, modelContext: modelContext)
        try save(task: task, modelContext: modelContext, operation: "runtime_result_captured", persist: persist)
    }

    /// Resolves live delivery before any completion/plan verdict. A successful
    /// write without completion is uncertain; a known unwritten response can
    /// safely transfer the granted authority to a continuation of this turn.
    static func reconcilePermissions(checkpoint: Checkpoint, task: AgentTask, run: TaskRun,
                                     modelContext: ModelContext, persist: (() throws -> Void)? = nil,
                                     includeOpenRequests: Bool = true) throws -> Bool {
        let missing = try LivePermissionApprovalRecovery.unacknowledgedCommits(task: task, run: run,
            acknowledgedRequestIDs: checkpoint.result.acknowledgedPermissionRequestIDs, modelContext: modelContext)
        if !missing.isEmpty {
            if missing.contains(where: { checkpoint.result.writtenPermissionRequestIDs.contains($0.requestID) }) {
                pauseForReconciliation(task: task, run: run, modelContext: modelContext)
            } else {
                run.recordPermissionApprovalRequired()
                TaskStateMachine.pauseForRuntimePermission(task, modelContext: modelContext)
                if let plan = checkpoint.approvedPlan, let step = plan.step {
                    TaskPlanService.recordStepProgress(type: TaskPlanEventTypes.stepStarted, planID: plan.plan.planID,
                        stepID: step.id, status: .running, task: task, modelContext: modelContext, run: run,
                        reason: "Approved response was not written; continuation must finish this step.")
                }
            }
            return true
        }
        guard includeOpenRequests else { return false }
        return try TaskPermissionContinuation.applyBlockingOutcomeIfNeeded(task: task, run: run,
            modelContext: modelContext, persist: persist)
    }

    static func validatePlan(checkpoint: Checkpoint, task: AgentTask, run: TaskRun,
                             modelContext: ModelContext) async {
        guard let plan = checkpoint.approvedPlan else { return }
        if task.status == .completed {
            let accepted: Bool
            if let step = plan.step {
                accepted = await ApprovedPlanRuntimeSettlement.finalizeApprovedPlanStep(step, plan: plan.plan,
                    task: task, executionContext: checkpoint.executionContext(for: task),
                    sandboxEnforcementSnapshot: checkpoint.sandboxEnforcement,
                    modelContext: modelContext, verifierRuntime: checkpoint.verifierRuntime)
            } else {
                accepted = await ApprovedPlanRuntimeSettlement.finalizeApprovedFullPlan(plan.plan, task: task,
                    executionContext: checkpoint.executionContext(for: task), sandboxEnforcementSnapshot: checkpoint.sandboxEnforcement,
                    modelContext: modelContext, verifierRuntime: checkpoint.verifierRuntime)
            }
            if !accepted, run.status == .completed {
                run.status = .failed
                run.typedStopReason = .custom("approved_plan_finalization_rejected")
            }
        } else if task.isTerminal {
            TaskPlanService.recordExecutionFailed(planID: plan.plan.planID, task: task,
                modelContext: modelContext, reason: task.status.rawValue)
        }
    }

    /// The terminal request, verdict and continuation/effect intent are saved
    /// together. Failed persistence leaves the checkpoint recoverable and
    /// never releases a chained task or schedule result.
    @discardableResult
    static func commit(checkpoint: Checkpoint, task: AgentTask, run: TaskRun, modelContext: ModelContext,
                       persist: (() throws -> Void)? = nil, autoExport: Bool = true) -> Bool {
        if verdict(for: run, task: task) != nil { return true }
        var transitionedRequest: TaskTurnRequest?
        var priorRequest: TaskTurnRequestSnapshot?
        do {
            if RuntimeSettlementProgress.event(TaskEventTypes.System.runtimeOutcomePrepared, task: task, run: run) == nil {
                RuntimeSettlementProgress.stagePrepared(task: task, run: run, modelContext: modelContext)
            }
            let request = try checkpoint.requestID.flatMap { try TaskTurnRequestRepository.request(id: $0, in: modelContext) }
            if checkpoint.requestID != nil {
                guard let request, request.taskID == task.id, request.runID == run.id else {
                    throw Failure.invalidRequestOwner
                }
            }
            transitionedRequest = request
            priorRequest = request?.snapshot
            let state: TaskTurnRequestState = run.status == .completed ? .completed : run.status == .cancelled ? .cancelled : .failed
            if let request {
                let transition = TaskTurnRequestStateMachine.transition(request, to: state, runID: run.id,
                    terminalReason: run.stopReason.isEmpty ? run.status.rawValue : run.stopReason)
                guard transition.rejection == nil else { throw Failure.rejectedRequestTransition }
            }
            let adapter = AgentRuntimeAdapterRegistry.adapter(for: checkpoint.runtime)
            let requests = try TaskTurnRequestRepository.requests(for: task, in: modelContext)
            let latest = checkpoint.requestID == nil || requests.last?.id == checkpoint.requestID
            let completed = task.status == .completed && state == .completed && latest && !task.isDone
            let chain = completed && checkpoint.phase == .run && adapter.performsPostRunFollowUps(phase: checkpoint.phase)
                && !checkpoint.chainedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let event = TaskEvent.structuredPayloadEvent(task: task, type: TaskEventTypes.System.runtimeTurnSettled.rawValue,
                payload: Verdict(requestState: state, reason: run.stopReason, chainedTaskID: chain ? UUID() : nil,
                    chainedGoal: chain ? checkpoint.chainedGoal : nil,
                    scheduleID: task.isTerminal && latest ? checkpoint.scheduleID : nil), run: run)
            modelContext.insert(event)
            let recoveryCount = try LivePermissionApprovalRecovery.recoverForSettlement(task: task, run: run,
                modelContext: modelContext, acknowledgedRequestIDs: checkpoint.result.acknowledgedPermissionRequestIDs, persist: {
                    try save(task: task, modelContext: modelContext, operation: "runtime_turn_settled", persist: persist,
                        autoExport: autoExport)
                })
            if recoveryCount == 0 {
                try save(task: task, modelContext: modelContext, operation: "runtime_turn_settled", persist: persist,
                    autoExport: autoExport)
            }
            RuntimeSettlementProgress.pruneSettledCaptures(task: task, modelContext: modelContext)
            // Validation awaited above, so drift is re-evaluated immediately before exporting.
            let exportNow = autoExport
                && TaskExecutionResourcePreparation.isCurrent(task: task, scope: checkpoint.launchSnapshot.resourceScope)
            do { try save(task: task, modelContext: modelContext, operation: "runtime_checkpoint_pruned", persist: nil, autoExport: exportNow, exportsWorkspace: true) }
            catch { AppLogger.error("Settled runtime checkpoint cleanup will be retried.", category: "Persistence") }
            return true
        } catch {
            if let transitionedRequest, let priorRequest {
                TaskTurnRequestStateMachine.restoreUncommittedTransition(transitionedRequest, snapshot: priorRequest)
            }
            // Delete only the tentative verdict. Captured result/receipts must
            // remain staged so a later save cannot discard observed execution.
            for event in task.events where event.run?.id == run.id
                && event.type == TaskEventTypes.System.runtimeTurnSettled.rawValue { modelContext.delete(event) }
            reportPersistenceFailure(task: task, run: run, modelContext: modelContext)
            return false
        }
    }

    static func dispatchChainedTask(task: AgentTask, run: TaskRun, modelContext: ModelContext) {
        guard let verdict = verdict(for: run, task: task), let id = verdict.chainedTaskID,
              let goal = verdict.chainedGoal, !task.isDone,
              RuntimeSettlementProgress.event(TaskEventTypes.System.runtimeChainedWorkDispatched, task: task, run: run) == nil else { return }
        // Older dispatches had no typed receipt. Their durable chained event
        // still proves dispatch, even if the user subsequently deleted the child.
        if task.events.contains(where: { !$0.isDeleted && $0.type == TaskEventTypes.Task.chained.rawValue
            && ($0.run?.id == run.id || ($0.run == nil && $0.timestamp >= (run.completedAt ?? run.startedAt))) }) {
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeChainedWorkDispatched,
                payload: id.uuidString, run: run))
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext)
            return
        }
        ChainedTaskSubmissionService.create(from: task, run: run, modelContext: modelContext, taskID: id, goal: goal)
    }

    /// The consumed intent is persisted with the schedule projection, so a
    /// crash cannot publish it twice. Legacy results retain their old route.
    static func stageScheduleRouting(task: AgentTask, scheduleID: UUID, modelContext: ModelContext) -> Bool {
        guard let run = task.runs.max(by: { $0.startedAt < $1.startedAt }) else { return true }
        guard !hasUnsettledResult(task: task, run: run) else { return false }
        guard let verdict = verdict(for: run, task: task) else { return true }
        guard verdict.scheduleID == scheduleID,
              !task.events.contains(where: { $0.run?.id == run.id
                  && $0.type == TaskEventTypes.System.runtimeScheduleResultRouted.rawValue }) else { return false }
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeScheduleResultRouted,
            payload: scheduleID.uuidString, run: run))
        return true
    }

    static func pauseForReconciliation(task: AgentTask, run: TaskRun, modelContext: ModelContext,
        reason: String = "permission_delivery_uncertain",
        message: String = "Approval was saved, but ASTRA cannot confirm the provider's result. Review existing results and external changes before retrying. No automatic replay was started.") {
        run.status = .failed
        run.typedStopReason = .custom(reason)
        TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext)
        if !task.events.contains(where: { $0.run?.id == run.id
            && $0.type == TaskEventTypes.System.runtimeReconciliationRequired.rawValue }) {
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeReconciliationRequired,
                payload: message, run: run))
        }
    }

    static func reportPersistenceFailure(task: AgentTask, run: TaskRun, modelContext: ModelContext) {
        AppLogger.audit(.taskFailed, category: "Persistence", taskID: task.id,
            fields: ["operation": "runtime_settlement", "result": "not_committed"], level: .error)
        TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext)
        if !task.events.contains(where: { $0.run?.id == run.id && $0.type == TaskEventTypes.System.error.rawValue
            && $0.payload.contains("settlement could not be saved") }) {
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                payload: "The result settlement could not be saved. ASTRA stopped before follow-up work; the captured result remains available for recovery.", run: run))
        }
    }

    private static func save(task: AgentTask, modelContext: ModelContext, operation: String,
                             persist: (() throws -> Void)?, autoExport: Bool = true,
                             exportsWorkspace: Bool = false) throws {
        if let persist { try persist() }
        else if exportsWorkspace && autoExport {
            // One final mirror export once the verdict is durable; intermediate saves stay export-free.
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: task.workspace,
                modelContext: modelContext, taskID: task.id, auditFields: ["operation": operation])
        } else {
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                modelContext: modelContext, taskID: task.id, auditFields: ["operation": operation])
        }
    }
}
