import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Replays only ASTRA's outcome/validation work from a durable provider result.
/// Neither this service nor startup recovery invokes the original provider turn.
@MainActor
enum RuntimeTurnOutcomeService {
    static func apply(checkpoint: RuntimeTurnSettlementService.Checkpoint, task: AgentTask,
                      run: TaskRun, modelContext: ModelContext,
                      permissionPromotionPersistence: (() throws -> Void)? = nil) async throws {
        let result = checkpoint.result
        let selectedRuntime = checkpoint.runtime
        let runtimeAdapter = AgentRuntimeAdapterRegistry.adapter(for: selectedRuntime)
        let auditPhase = checkpoint.phase
        let executionTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(checkpoint.launchSnapshot, from: task)
        let executionPath = checkpoint.executionPath
        let launchPermissionPolicy = checkpoint.permissionPolicy
        let timeoutSeconds = checkpoint.timeoutSeconds
        let validationModel = checkpoint.verifierRuntime.model
        let claudePath = checkpoint.verifierRuntime.claudePath
        let budgetEnforcementMode = BudgetEnforcementMode(rawValue: checkpoint.budgetEnforcementMode) ?? .hardStop
        let budgetSnapshot = AgentRuntimeBudgetSnapshot(effectiveTokenBudget: checkpoint.effectiveTokenBudget,
                                                      tokensUsed: checkpoint.tokensUsed)
        let processSucceeded = result.exitCode == 0 || result.terminatedAfterTerminalProgress
        let failureDiagnostic = checkpoint.failureDiagnostic
        if !checkpoint.cancelled, task.status != .cancelled,
           try RuntimeTurnSettlementService.reconcilePermissions(checkpoint: checkpoint, task: task,
               run: run, modelContext: modelContext, includeOpenRequests: false) { return }
        if checkpoint.cancelled || task.status == .cancelled {
            run.status = .cancelled
            run.typedStopReason = .cancelled
            TaskStateMachine.cancelFromRuntime(task, modelContext: modelContext)
        } else if result.policyApprovalRequired {
            TaskRuntimeOutcomeTransition.applyPolicyApproval(
                task: task,
                run: run,
                approvalMessage: result.policyApprovalMessage,
                modelContext: modelContext
            )
        } else if result.timedOut {
            run.status = .timeout
            run.typedStopReason = .timeout
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                                  payload: runtimeAdapter.timeoutPayload(
                                    phase: auditPhase,
                                    timeoutSeconds: timeoutSeconds
                                  ), run: run)
            modelContext.insert(event)
        } else if result.maxTurnsExceeded {
            run.status = .budgetExceeded
            run.typedStopReason = .maxTurnsReached
            TaskStateMachine.exceedBudgetFromRuntime(task, modelContext: modelContext)
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Budget.exceeded,
                                  payload: runtimeAdapter.maxTurnsPayload(phase: auditPhase, task: task), run: run)
            modelContext.insert(event)
        } else if Self.applyRuntimeStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: auditPhase) {
        } else if Self.applyRepetitionStopIfNeeded(result, task: task, run: run, modelContext: modelContext, phase: auditPhase) {
        } else if result.policyViolation {
            run.status = .failed
            run.typedStopReason = .policyViolation
            TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext)
            let event = TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.error,
                payload: result.policyViolationMessage ?? "ASTRA stopped the provider because observed activity violated the run policy.",
                run: run
            )
            modelContext.insert(event)
        } else if AgentRuntimeBudgetPolicy.shouldTreatAsBudgetExceeded(
            result: result,
            budget: budgetSnapshot,
            budgetEnforcementMode: budgetEnforcementMode
        ) {
            run.status = .budgetExceeded
            run.typedStopReason = .maxBudgetReached
            TaskStateMachine.exceedBudgetFromRuntime(task, modelContext: modelContext)
            let outcome = result.budgetExceeded ? "Process killed." : "Provider reported usage above budget."
            let payload = "Token budget exceeded (\(task.tokensUsed)/\(budgetSnapshot.effectiveTokenBudget)). \(outcome)"
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Budget.exceeded,
                                  payload: payload, run: run)
            modelContext.insert(event)
        } else if processSucceeded, !checkpoint.agentReportedError,
                  try RuntimeTurnSettlementService.reconcilePermissions(checkpoint: checkpoint, task: task, run: run, modelContext: modelContext, persist: permissionPromotionPersistence) {
        } else if processSucceeded,
                  runtimeAdapter.requiresVisibleResultForSuccessfulRun(phase: auditPhase),
                  Self.applyEmptySuccessfulRunIfNeeded(
                    runtimeAdapter: runtimeAdapter,
                    task: task,
                    run: run,
                    modelContext: modelContext,
                    result: result,
                    phase: auditPhase
                  ) {
        } else if processSucceeded {
            run.status = .completed
            run.typedStopReason = .completed
            AgentRuntimeBudgetPolicy.recordFinalBudgetWarningIfNeeded(
                result: result,
                task: task,
                run: run,
                modelContext: modelContext,
                phase: auditPhase,
                budgetEnforcementMode: budgetEnforcementMode
            )
            let blockedFromCompleting = await AgentRuntimeCompletionValidation.applyCompletionBlocksIfNeeded(
                task: task, run: run, modelContext: modelContext,
                workspacePath: executionPath,
                agentReportedError: checkpoint.agentReportedError
            )
            if !blockedFromCompleting {
                if runtimeAdapter.shouldValidateSuccessfulRun(phase: auditPhase) {
                    // Frozen on launchTask, same as the budget above.
                    switch executionTask.validationStrategy {
                    case .manual:
                        let completed = await TaskSuccessfulCompletionService.apply(
                            task: task,
                            run: run,
                            modelContext: modelContext,
                            successPayload: runtimeAdapter.manualCompletionPayload(phase: auditPhase),
                            permissionPolicy: launchPermissionPolicy
                        )
                        if completed {
                            await AgentRuntimeCompletionValidation.applyAutomaticBaselineVerificationIfNeeded(
                                task: task,
                                run: run,
                                modelContext: modelContext,
                                workspacePath: executionPath,
                                sandboxEnforcementSnapshot: checkpoint.sandboxEnforcement
                            )
                        }
                    case .runTests:
                        let testEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Running validation tests...", run: run)
                        modelContext.insert(testEvent)
                        // Frozen on executionTask like the strategy switch above:
                        // testCommand is part of AgentTaskLaunchSnapshot, so a
                        // command edited after admission must not be what grades
                        // this run. executionTask also carries the executionRootPath
                        // the run actually used, so tests execute where it ran.
                        let testResult = await ValidationService.runTests(
                            task: executionTask,
                            commandRunner: ShellValidationCommandRunner(
                                sandboxEnforcementSnapshot: checkpoint.sandboxEnforcement
                            )
                        )
                        switch testResult {
                        case .passed(let details):
                            _ = await TaskSuccessfulCompletionService.apply(
                                task: task,
                                run: run,
                                modelContext: modelContext,
                                successPayload: "\(ValidationOutcomeMarker.testsPassed.rawValue). \(String(details.prefix(300)))",
                                permissionPolicy: launchPermissionPolicy
                            )
                        case .failed(let details):
                            TaskStateMachine.failFromValidation(task, modelContext: modelContext)
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.testsFailed.rawValue):\n\(String(details.prefix(500)))", run: run)
                            modelContext.insert(event)
                        case .error(let msg):
                            TaskStateMachine.pauseForValidationReview(task, modelContext: modelContext)
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.validationError.rawValue): \(msg). Needs manual review.", run: run)
                            modelContext.insert(event)
                        }
                    case .aiCheck:
                        let checkEvent = TaskEvent(task: task, eventType: TaskEventTypes.Tool.use, payload: "Running AI self-check...", run: run)
                        modelContext.insert(checkEvent)
                        let aiResult = await ValidationService.aiCheck(
                            task: task,
                            claudePath: claudePath,
                            model: validationModel,
                            utilityRuntime: checkpoint.verifierRuntime,
                            workspacePath: executionPath
                        )
                        switch aiResult {
                        case .passed(let details):
                            _ = await TaskSuccessfulCompletionService.apply(
                                task: task,
                                run: run,
                                modelContext: modelContext,
                                successPayload: "\(ValidationOutcomeMarker.aiCheckPassed.rawValue). \(String(details.prefix(300)))",
                                permissionPolicy: launchPermissionPolicy
                            )
                        case .failed(let details):
                            TaskStateMachine.pauseForValidationReview(task, modelContext: modelContext)
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.aiCheckFlagged.rawValue) issues:\n\(String(details.prefix(500)))", run: run)
                            modelContext.insert(event)
                        case .error(let msg):
                            TaskStateMachine.pauseForValidationReview(task, modelContext: modelContext)
                            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: "\(ValidationOutcomeMarker.aiCheckError.rawValue): \(msg). Needs manual review.", run: run)
                            modelContext.insert(event)
                        }
                    }
                } else {
                    let completed = await TaskSuccessfulCompletionService.apply(
                        task: task,
                        run: run,
                        modelContext: modelContext,
                        successPayload: runtimeAdapter.manualCompletionPayload(phase: auditPhase),
                        permissionPolicy: launchPermissionPolicy
                    )
                    if completed {
                        await AgentRuntimeCompletionValidation.applyAutomaticBaselineVerificationIfNeeded(
                            task: task,
                            run: run,
                            modelContext: modelContext,
                            workspacePath: executionPath,
                            sandboxEnforcementSnapshot: checkpoint.sandboxEnforcement
                        )
                    }
                }
            }
        } else if RuntimePermissionApprovalGate.shouldPause(
            failureDiagnostic: failureDiagnostic,
            task: task,
            run: run
        ) {
            run.status = .failed
            run.typedStopReason = .permissionApprovalRequired
            TaskStateMachine.pauseForRuntimePermission(task, modelContext: modelContext)
            let payload = TaskPermissionContinuation.attach(Self.permissionApprovalRequestPayload(
                diagnostic: failureDiagnostic,
                result: result
            ), continuation: TaskPermissionContinuation.capture(task: task, run: run, modelContext: modelContext))
            TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionApprovalRequested, payload: payload, run: run)
            modelContext.insert(event)
        } else {
            run.status = .failed
            run.typedStopReason = AgentRuntimeWorker.durableFailureStopReason(category: failureDiagnostic?.category)
            if runtimeAdapter.shouldClearStaleSessionOnFailure(phase: auditPhase, result: result) {
                task.sessionId = nil
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                                      payload: "Session expired or not found. Session cleared - retry will start fresh.", run: run)
                modelContext.insert(event)
                AppLogger.audit(.workerSessionCleared, category: "Worker", taskID: task.id, fields: [
                    "reason": "stale_session",
                    "runtime": selectedRuntime.rawValue
                ], level: .warning)
            } else {
                let prefix = runtimeAdapter.failurePayloadPrefix(phase: auditPhase, exitCode: result.exitCode)
                let payload = failureDiagnostic?.userFacingPayload(
                    prefix: prefix
                ) ?? AgentRuntimeFailurePayload.enriched(
                    prefix: prefix,
                    rawError: result.error,
                    task: task
                )
                let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run)
                modelContext.insert(event)
            }
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
        }
    }

    @MainActor
    private static func applyEmptySuccessfulRunIfNeeded(
        runtimeAdapter: any AgentRuntimePostRunDiagnostics,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        result: AgentProcessResult,
        phase: RunPhase
    ) -> Bool {
        let visibleOutput = !run.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visibleFileResult = TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: run)
        guard !visibleOutput, !visibleFileResult else {
            return false
        }

        run.status = .failed
        run.typedStopReason = .noUsableResult
        TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext)

        let providerName = runtimeAdapter.descriptor.displayName
        let requiredArtifact = TaskDeliverableExpectation.owesDeliverable(task, run: run)
        let antigravityDiagnostic = runtimeAdapter.id == .antigravityCLI
            ? AntigravityCLIRuntime.diagnosticSummary(
                logPath: AntigravityCLIRuntime.diagnosticLogPath(task: task, runID: run.id)
            )
            : nil
        var payload = requiredArtifact
            ? "\(providerName) finished with exit code 0 but did not return text output and did not create a usable file for this run. Retry this task or switch providers."
            : "\(providerName) finished with exit code 0 but did not return text output or create a visible file. Retry this task or switch providers."
        if let antigravityDiagnostic {
            payload += " \(antigravityDiagnostic.message) Diagnostic log: \(antigravityDiagnostic.logPath)"
        }
        if let error = result.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            payload += " Provider stderr: \(String(RuntimeReadinessRedactor.redacted(error).prefix(300)))"
        }
        let event = TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run)
        modelContext.insert(event)
        var auditFields = [
            "runtime": runtimeAdapter.id.rawValue,
            "phase": phase.rawValue,
            "exit_code": String(result.exitCode),
            "run_output_chars": String(run.output.count),
            "file_changes": String(run.fileChanges.count),
            "run_scoped_file_result": String(visibleFileResult),
            "requires_artifact": String(requiredArtifact),
            "stderr_bytes": String(result.error?.utf8.count ?? 0)
        ]
        if let antigravityDiagnostic {
            auditFields.merge(antigravityDiagnostic.auditFields) { _, new in new }
        }
        AppLogger.audit(.runtimeEmptyOutput, category: "Worker", taskID: task.id, fields: auditFields, level: .warning)
        return true
    }

    private static func permissionApprovalRequestPayload(
        diagnostic: AgentRuntimeFailureDiagnostic?,
        result: AgentProcessResult
    ) -> String {
        let providerDetail = result.error?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        let detail = providerDetail.map { "\n\nProvider detail:\n\($0)" } ?? ""
        let message = diagnostic?.category == .permissionDenied
            ? diagnostic?.userMessage
            : "The provider needs a runtime permission before it can continue."
        return """
        \(message ?? "The provider needs a runtime permission before it can continue.")

        Approve to continue this task with one-time expanded runtime permissions.\(detail)
        """
    }

    @MainActor
    private static func applyRuntimeStopIfNeeded(
        _ result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) -> Bool {
        guard let reason = result.runtimeStopReason, !reason.isEmpty else { return false }

        run.status = .failed
        run.typedStopReason = TaskRunStopReason.custom(reason)
        if AgentRuntimeWorker.isTerminalRuntimeStop(reason) {
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
        } else {
            TaskStateMachine.pauseForRuntimeReview(task, modelContext: modelContext)
        }

        let payload = result.runtimeStopMessage
            ?? "ASTRA stopped the provider because browser control reached a terminal guardrail: \(reason)."
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error, payload: payload, run: run))
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "phase": phase.rawValue,
            "reason": reason,
            "source": "runtime_stop"
        ], level: .error)
        return true
    }

    @MainActor
    private static func applyRepetitionStopIfNeeded(
        _ result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase
    ) -> Bool {
        guard result.repetitionKilled else { return false }

        run.status = .failed
        run.typedStopReason = .repetitionDetected
        TaskStateMachine.failFromRuntime(task, modelContext: modelContext)

        modelContext.insert(TaskEvent(
            task: task,
            type: "error",
            payload: "Repetition loop detected. ASTRA stopped the provider after repeated identical runtime events.",
            run: run
        ))
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id, fields: [
            "phase": phase.rawValue,
            "reason": "repetition_detected",
            "source": "runtime_repetition_guard"
        ], level: .error)
        return true
    }

}
