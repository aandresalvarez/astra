import AppKit
import Foundation
import SwiftData

enum WorkspaceAppActionExecutionError: LocalizedError, Equatable {
    case missingAction(String)
    case unsupportedActionType(String)
    case missingTable
    case missingRecord
    case missingSource
    case missingRequirement(String)
    case missingMappedBinding(String)
    case missingPrimaryKey(String)
    case missingTaskGoal
    case missingPipelineSteps(String)
    case missingLoopBounds(String)
    case loopTimeout(String)
    case unsupportedExportFormat(String)
    case invalidUtilityAction(String)
    case approvalRequired(String)
    case agentRecommendationRequired(String)
    case gateBlocked(String)
    case capabilityWriteUnavailable(String)
    case permissionDenied(String)
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAction(let actionID):
            "Workspace app action '\(actionID)' was not found."
        case .unsupportedActionType(let type):
            "Workspace app action type '\(type)' is not supported yet."
        case .missingTable:
            "Workspace app storage action requires a table."
        case .missingRecord:
            "Workspace app storage write action requires a record."
        case .missingSource:
            "Workspace app capability read action requires a source."
        case .missingRequirement(let requirementID):
            "Workspace app action references unknown requirement '\(requirementID)'."
        case .missingMappedBinding(let requirementID):
            "Workspace app action requirement '\(requirementID)' is not mapped to a capability implementation."
        case .missingPrimaryKey(let table):
            "Workspace app storage table '\(table)' must declare a primary key for this action."
        case .missingTaskGoal:
            "Workspace app task action requires a task goal."
        case .missingPipelineSteps(let actionID):
            "Workspace app pipeline action '\(actionID)' must declare at least one step."
        case .missingLoopBounds(let actionID):
            "Workspace app loop action '\(actionID)' must declare steps, max iterations, timeout, and a stop condition."
        case .loopTimeout(let actionID):
            "Workspace app loop action '\(actionID)' exceeded its timeout."
        case .unsupportedExportFormat(let format):
            "Workspace app artifact export format '\(format)' is not supported."
        case .invalidUtilityAction(let message):
            message
        case .approvalRequired(let actionID):
            "Workspace app gate '\(actionID)' requires human approval before execution can continue."
        case .agentRecommendationRequired(let actionID):
            "Workspace app agent recommendation gate '\(actionID)' requires an agent recommendation before execution can continue."
        case .gateBlocked(let actionID):
            "Workspace app gate '\(actionID)' blocked execution."
        case .capabilityWriteUnavailable(let actionID):
            "Workspace app capability write action '\(actionID)' does not have a deterministic write implementation."
        case .permissionDenied(let message):
            message
        case .storageFailed(let message):
            "Workspace app storage action failed: \(message)"
        }
    }
}

struct WorkspaceAppActionInput: Codable, Sendable, Equatable {
    var table: String?
    var record: [String: WorkspaceAppStorageValue]
    var limit: Int
    var exportFormat: String?
    var taskTitle: String?
    var taskGoal: String?
    var confirmedDestructive: Bool
    var confirmedApproval: Bool
    var agentRecommendationDecision: String?
    // B1 output binding: rows produced by the previous pipeline/loop step,
    // threaded forward so a downstream step can consume upstream output.
    var boundRows: [[String: WorkspaceAppStorageValue]]

    init(
        table: String? = nil,
        record: [String: WorkspaceAppStorageValue] = [:],
        limit: Int = 100,
        exportFormat: String? = nil,
        taskTitle: String? = nil,
        taskGoal: String? = nil,
        confirmedDestructive: Bool = false,
        confirmedApproval: Bool = false,
        agentRecommendationDecision: String? = nil,
        boundRows: [[String: WorkspaceAppStorageValue]] = []
    ) {
        self.table = table
        self.record = record
        self.limit = limit
        self.exportFormat = exportFormat
        self.taskTitle = taskTitle
        self.taskGoal = taskGoal
        self.confirmedDestructive = confirmedDestructive
        self.confirmedApproval = confirmedApproval
        self.agentRecommendationDecision = agentRecommendationDecision
        self.boundRows = boundRows
    }

    // The effective record for a write step: an explicit record wins; otherwise
    // the first row bound from the previous step (B1 output binding).
    var effectiveRecord: [String: WorkspaceAppStorageValue] {
        record.isEmpty ? (boundRows.first ?? [:]) : record
    }

    func bindingForward(rows: [[String: WorkspaceAppStorageValue]]) -> WorkspaceAppActionInput {
        var copy = self
        copy.boundRows = rows
        return copy
    }
}

struct WorkspaceAppActionExecutionResult: Equatable {
    var run: WorkspaceAppRun
    var rows: [[String: WorkspaceAppStorageValue]]
    var outputSummary: String
}

struct WorkspaceAppCapabilityWriteResult: Sendable, Equatable {
    var outputSummary: String
    var rows: [[String: WorkspaceAppStorageValue]]

    init(outputSummary: String, rows: [[String: WorkspaceAppStorageValue]] = []) {
        self.outputSummary = outputSummary
        self.rows = rows
    }
}

protocol WorkspaceAppCapabilityWriteClient {
    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppCapabilityWriteResult
}

struct WorkspaceAppUnavailableCapabilityWriteClient: WorkspaceAppCapabilityWriteClient {
    func write(
        action: WorkspaceAppActionSpec,
        requirement: WorkspaceAppRequirement,
        binding: WorkspaceAppDependencyBinding,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppCapabilityWriteResult {
        throw WorkspaceAppActionExecutionError.capabilityWriteUnavailable(action.id)
    }
}

protocol WorkspaceAppUtilityActionClient {
    func openURL(_ url: URL)
    func copyToClipboard(_ text: String)
    func showNotification(title: String, body: String)
}

struct WorkspaceAppDefaultUtilityActionClient: WorkspaceAppUtilityActionClient {
    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showNotification(title: String, body: String) {
        AppLogger.info(
            "Workspace app notification requested: \(title) (\(body.count) body characters)",
            category: "WorkspaceApps"
        )
    }
}

struct WorkspaceAppRunRecorder {
    func startRun(
        app: WorkspaceApp,
        actionID: String,
        trigger: WorkspaceAppRunTrigger,
        inputSummary: String,
        modelContext: ModelContext
    ) -> WorkspaceAppRun {
        let run = WorkspaceAppRun(
            workspaceID: app.workspaceID,
            appID: app.id,
            appLogicalID: app.logicalID,
            actionID: actionID,
            trigger: trigger,
            inputSummary: inputSummary
        )
        modelContext.insert(run)
        recordEvent(
            run: run,
            type: "workspaceApp.action.started",
            payload: ["actionID": .text(actionID), "trigger": .text(trigger.rawValue)],
            modelContext: modelContext
        )
        return run
    }

    func completeRun(
        _ run: WorkspaceAppRun,
        outputSummary: String,
        modelContext: ModelContext
    ) {
        run.status = .completed
        run.completedAt = Date()
        run.outputSummary = outputSummary
        recordEvent(
            run: run,
            type: "workspaceApp.action.completed",
            payload: ["summary": .text(outputSummary)],
            modelContext: modelContext
        )
    }

    func failRun(
        _ run: WorkspaceAppRun,
        error: Error,
        blocked: Bool = false,
        modelContext: ModelContext
    ) {
        run.status = blocked ? .blocked : .failed
        run.completedAt = Date()
        run.errorMessage = String(describing: error)
        recordEvent(
            run: run,
            type: blocked ? "workspaceApp.action.blocked" : "workspaceApp.action.failed",
            payload: ["error": .text(String(describing: error))],
            modelContext: modelContext
        )
    }

    func recordEvent(
        run: WorkspaceAppRun,
        type: String,
        payload: [String: WorkspaceAppStorageValue],
        modelContext: ModelContext
    ) {
        modelContext.insert(WorkspaceAppRunEvent(
            runID: run.id,
            workspaceID: run.workspaceID,
            appID: run.appID,
            actionID: run.actionID,
            type: type,
            payload: Self.payloadString(payload)
        ))
    }

    private static func payloadString<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

// B2: thrown by a pipeline when a step launches an async agent task the workflow
// must await. The top-level execute() catches it, persists the resume point on the
// run, and marks the run `.waiting` (not failed). resume() continues from there
// once the task completes.
private struct WorkspaceAppPipelineSuspension: Error {
    // A SET of awaited task ids (one element for a B2 single task.createAndRun step,
    // N for a C1 task.fanOut barrier).
    let taskIDs: [UUID]
    let pipelineActionID: String
    let nextStepIndex: Int
}

/// Human-in-the-loop: thrown when a pipeline reaches an un-approved `gate.humanApproval` step, so the
/// run suspends to `.waiting` pending a HUMAN decision (resumed via `resumeWithApproval`) instead of
/// failing — the executor analogue of the task suspension above.
private struct WorkspaceAppApprovalSuspension: Error {
    let pipelineActionID: String
    let gateStepIndex: Int
    let gateActionID: String
}

struct WorkspaceAppActionExecutor {
    var storageService = WorkspaceAppStorageService()
    var sourceResolver = WorkspaceAppSourceResolver()
    var capabilityWriteClient: any WorkspaceAppCapabilityWriteClient = WorkspaceAppNativeCapabilityWriteClient()
    var asyncCapabilityWriteClient: any WorkspaceAppAsyncCapabilityWriteClient = WorkspaceAppNativeAsyncCapabilityWriteClient()
    var utilityActionClient: any WorkspaceAppUtilityActionClient = WorkspaceAppDefaultUtilityActionClient()
    var recorder = WorkspaceAppRunRecorder()

    @MainActor
    func execute(
        actionID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        input: WorkspaceAppActionInput = WorkspaceAppActionInput(),
        trigger: WorkspaceAppRunTrigger = .user,
        modelContext: ModelContext
    ) throws -> WorkspaceAppActionExecutionResult {
        let run = recorder.startRun(
            app: app,
            actionID: actionID,
            trigger: trigger,
            inputSummary: inputSummary(input),
            modelContext: modelContext
        )

        do {
            let action = try actionSpec(actionID: actionID, manifest: manifest)
            try enforcePermission(for: action, app: app, input: input)
            let result = try execute(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
            run.linkedTaskID = result.linkedTaskID
            run.linkedArtifactPath = result.linkedArtifactPath
            if let linkedTaskID = result.linkedTaskID {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.task.created",
                    payload: ["taskID": .text(linkedTaskID.uuidString)],
                    modelContext: modelContext
                )
            }
            if let linkedArtifactPath = result.linkedArtifactPath {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.artifact.exported",
                    payload: ["path": .text(linkedArtifactPath)],
                    modelContext: modelContext
                )
            }
            recorder.completeRun(run, outputSummary: result.outputSummary, modelContext: modelContext)
            app.lastRunAt = Date()
            app.updatedAt = Date()
            try modelContext.save()
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: result.rows,
                outputSummary: result.outputSummary
            )
        } catch let suspension as WorkspaceAppPipelineSuspension {
            markWaiting(run: run, suspension: suspension, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(suspension.pipelineActionID)' is waiting on \(suspension.taskIDs.count) task(s)."
            )
        } catch let approval as WorkspaceAppApprovalSuspension {
            markWaitingForApproval(run: run, suspension: approval, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(approval.pipelineActionID)' is waiting for approval of '\(approval.gateActionID)'."
            )
        } catch {
            recorder.failRun(
                run,
                error: error,
                blocked: isPermissionError(error),
                modelContext: modelContext
            )
            try? modelContext.save()
            throw error
        }
    }

    // B2: resume a workflow run that suspended on an async agent task. Continues the
    // pending pipeline from the saved step, binding the completed task's output
    // forward. If a later step launches another task, the run suspends again.
    @MainActor
    func resume(
        run: WorkspaceAppRun,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        taskOutputRows: [[String: WorkspaceAppStorageValue]] = [],
        consumedTokens: Int = 0,
        modelContext: ModelContext
    ) throws -> WorkspaceAppActionExecutionResult {
        guard run.status == .waiting, let pipelineID = run.pendingActionID else {
            throw WorkspaceAppActionExecutionError.unsupportedActionType(
                "resume requires a waiting run with a pending workflow action"
            )
        }
        // B3: accumulate the awaited task's token usage and enforce the workflow's
        // whole-run budget — block (don't fail) the run if it overruns.
        run.consumedTokens += consumedTokens
        if WorkspaceAppWorkflowBudget.exceedsBudget(
            consumed: run.consumedTokens,
            manifest: manifest,
            pipelineActionID: pipelineID
        ) {
            run.status = .blocked
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.run.budgetExceeded",
                payload: [
                    "pipelineID": .text(pipelineID),
                    "consumedTokens": .integer(Int64(run.consumedTokens)),
                    "budget": .integer(Int64(WorkspaceAppWorkflowBudget.declaredTokenBudget(
                        for: manifest, pipelineActionID: pipelineID
                    )))
                ],
                modelContext: modelContext
            )
            try? modelContext.save()
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(pipelineID)' blocked: token budget exceeded (\(run.consumedTokens) tokens consumed)."
            )
        }
        let action = try actionSpec(actionID: pipelineID, manifest: manifest)
        let startIndex = run.pendingStepIndex
        run.status = .running
        // Slice 10 output binding: map the awaited task step's captured answer onto its declared
        // outputBinding (rename to `field`, optional JSON parse, optional persist to storage) BEFORE
        // threading it to the next step. The awaited task step sits at startIndex - 1.
        let boundRows = applyOutputBinding(
            taskOutputRows: taskOutputRows,
            pipeline: action,
            awaitedStepIndex: startIndex - 1,
            app: app,
            workspace: workspace,
            manifest: manifest,
            modelContext: modelContext
        )
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.run.resumed",
            payload: [
                "pipelineID": .text(pipelineID),
                "fromStepIndex": .integer(Int64(startIndex)),
                "boundRows": .integer(Int64(boundRows.count))
            ],
            modelContext: modelContext
        )
        do {
            let result = try executePipeline(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: WorkspaceAppActionInput(boundRows: boundRows),
                run: run,
                modelContext: modelContext,
                startIndex: startIndex,
                initialBoundRows: boundRows
            )
            run.linkedArtifactPath = result.linkedArtifactPath ?? run.linkedArtifactPath
            run.pendingActionID = nil
            recorder.completeRun(run, outputSummary: result.outputSummary, modelContext: modelContext)
            app.lastRunAt = Date()
            app.updatedAt = Date()
            try modelContext.save()
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: result.rows,
                outputSummary: result.outputSummary
            )
        } catch let suspension as WorkspaceAppPipelineSuspension {
            markWaiting(run: run, suspension: suspension, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(suspension.pipelineActionID)' is waiting on \(suspension.taskIDs.count) task(s)."
            )
        } catch let approval as WorkspaceAppApprovalSuspension {
            markWaitingForApproval(run: run, suspension: approval, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(approval.pipelineActionID)' is waiting for approval of '\(approval.gateActionID)'."
            )
        } catch {
            recorder.failRun(run, error: error, blocked: isPermissionError(error), modelContext: modelContext)
            try? modelContext.save()
            throw error
        }
    }

    private func markWaiting(
        run: WorkspaceAppRun,
        suspension: WorkspaceAppPipelineSuspension,
        modelContext: ModelContext
    ) {
        run.status = .waiting
        run.awaitedTaskIDs = suspension.taskIDs
        run.linkedTaskID = suspension.taskIDs.first  // single-await fast path / back-compat
        run.pendingActionID = suspension.pipelineActionID
        run.pendingStepIndex = suspension.nextStepIndex
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.run.waiting",
            payload: [
                "taskIDs": .text(suspension.taskIDs.map(\.uuidString).joined(separator: ",")),
                "taskCount": .integer(Int64(suspension.taskIDs.count)),
                "pipelineID": .text(suspension.pipelineActionID),
                "nextStepIndex": .integer(Int64(suspension.nextStepIndex))
            ],
            modelContext: modelContext
        )
        try? modelContext.save()
    }

    private func markWaitingForApproval(
        run: WorkspaceAppRun,
        suspension: WorkspaceAppApprovalSuspension,
        modelContext: ModelContext
    ) {
        run.status = .waiting
        run.pendingActionID = suspension.pipelineActionID
        run.pendingStepIndex = suspension.gateStepIndex
        run.pendingApprovalActionID = suspension.gateActionID
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.run.awaitingApproval",
            payload: [
                "pipelineID": .text(suspension.pipelineActionID),
                "gateID": .text(suspension.gateActionID),
                "stepIndex": .integer(Int64(suspension.gateStepIndex))
            ],
            modelContext: modelContext
        )
        try? modelContext.save()
    }

    /// Resume a run suspended on a human-approval gate: on approve, re-run the pipeline from the
    /// gate step with the approval granted (later gates re-prompt); on reject, fail the run. This is
    /// what the attention queue's Approve/Reject buttons call.
    @MainActor
    @discardableResult
    func resumeWithApproval(
        run: WorkspaceAppRun,
        approved: Bool,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        modelContext: ModelContext
    ) throws -> WorkspaceAppActionExecutionResult {
        guard run.status == .waiting,
              let gateID = run.pendingApprovalActionID,
              let pipelineID = run.pendingActionID else {
            throw WorkspaceAppActionExecutionError.unsupportedActionType(
                "resumeWithApproval requires a run waiting on a human-approval gate"
            )
        }
        run.pendingApprovalActionID = nil

        guard approved else {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.approval.rejected",
                payload: ["pipelineID": .text(pipelineID), "gateID": .text(gateID)],
                modelContext: modelContext
            )
            run.status = .failed
            run.completedAt = Date()
            run.errorMessage = "Approval rejected for '\(gateID)'."
            run.pendingActionID = nil
            try? modelContext.save()
            return WorkspaceAppActionExecutionResult(
                run: run, rows: [],
                outputSummary: "Workflow '\(pipelineID)' rejected at approval gate '\(gateID)'."
            )
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.approval.confirmed",
            payload: ["pipelineID": .text(pipelineID), "gateID": .text(gateID)],
            modelContext: modelContext
        )
        let action = try actionSpec(actionID: pipelineID, manifest: manifest)
        let startIndex = run.pendingStepIndex
        run.status = .running
        do {
            let result = try executePipeline(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: WorkspaceAppActionInput(confirmedApproval: true),
                run: run,
                modelContext: modelContext,
                startIndex: startIndex,
                initialBoundRows: []
            )
            run.linkedArtifactPath = result.linkedArtifactPath ?? run.linkedArtifactPath
            run.pendingActionID = nil
            recorder.completeRun(run, outputSummary: result.outputSummary, modelContext: modelContext)
            app.lastRunAt = Date()
            app.updatedAt = Date()
            try modelContext.save()
            return WorkspaceAppActionExecutionResult(run: run, rows: result.rows, outputSummary: result.outputSummary)
        } catch let suspension as WorkspaceAppPipelineSuspension {
            markWaiting(run: run, suspension: suspension, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run, rows: [],
                outputSummary: "Workflow '\(suspension.pipelineActionID)' is waiting on \(suspension.taskIDs.count) task(s)."
            )
        } catch let approval as WorkspaceAppApprovalSuspension {
            markWaitingForApproval(run: run, suspension: approval, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run, rows: [],
                outputSummary: "Workflow '\(approval.pipelineActionID)' is waiting for approval of '\(approval.gateActionID)'."
            )
        } catch {
            recorder.failRun(run, error: error, blocked: isPermissionError(error), modelContext: modelContext)
            try? modelContext.save()
            throw error
        }
    }

    private func actionSpec(actionID: String, manifest: WorkspaceAppManifest) throws -> WorkspaceAppActionSpec {
        guard let action = manifest.actions.first(where: { $0.id == actionID }) else {
            throw WorkspaceAppActionExecutionError.missingAction(actionID)
        }
        return action
    }

    private func enforcePermission(
        for action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        input: WorkspaceAppActionInput
    ) throws {
        switch effect(for: action.type) {
        case .read:
            return
        case .localWrite:
            guard app.permissionMode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform local write action '\(action.id)'."
                )
            }
        case .externalWrite:
            if app.permissionMode == .preApproved {
                return
            }
            if app.permissionMode == .approvalRequired {
                guard input.confirmedApproval else {
                    throw WorkspaceAppActionExecutionError.permissionDenied(
                        "External write action '\(action.id)' requires explicit approval before execution."
                    )
                }
                return
            }
            if app.permissionMode == .draftOnly {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Draft-only workspace apps cannot submit external write action '\(action.id)'."
                )
            }
            throw WorkspaceAppActionExecutionError.permissionDenied(
                "Read-only workspace apps cannot submit external write action '\(action.id)'."
            )
        case .destructive:
            guard app.permissionMode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform destructive action '\(action.id)'."
                )
            }
            guard input.confirmedDestructive else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Destructive action '\(action.id)' requires explicit confirmation before execution."
                )
            }
        }
    }

    /// Async execution path for `capability.write` — the one action type that needs real network I/O
    /// (the executor's synchronous path can't `await` an HTTP transport without blocking the UI).
    /// Every other action type delegates to the proven synchronous `execute`, so the keystone is
    /// untouched. The write goes through `asyncCapabilityWriteClient`, whose default native client
    /// performs the real REDCap import when a transport is configured for the binding (unconfigured →
    /// capabilityWriteUnavailable). The UI calls this from a Task for capability.write buttons.
    @MainActor
    @discardableResult
    func executeAsync(
        actionID: String,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding] = [],
        input: WorkspaceAppActionInput = WorkspaceAppActionInput(),
        trigger: WorkspaceAppRunTrigger = .user,
        modelContext: ModelContext
    ) async throws -> WorkspaceAppActionExecutionResult {
        let action = try actionSpec(actionID: actionID, manifest: manifest)
        guard action.type == "capability.write" else {
            return try execute(
                actionID: actionID, app: app, workspace: workspace, manifest: manifest,
                dependencyBindings: dependencyBindings, input: input, trigger: trigger, modelContext: modelContext
            )
        }

        let run = recorder.startRun(
            app: app, actionID: actionID, trigger: trigger, inputSummary: inputSummary(input), modelContext: modelContext
        )
        do {
            try enforcePermission(for: action, app: app, input: input)
            guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let requirementID = normalized(action.requirementRef, fallback: "")
            guard !requirementID.isEmpty else { throw WorkspaceAppActionExecutionError.missingRequirement("") }
            guard let requirement = manifest.requirements.first(where: { $0.id == requirementID }) else {
                throw WorkspaceAppActionExecutionError.missingRequirement(requirementID)
            }
            guard let binding = dependencyBindings.first(where: {
                $0.appID == app.id && $0.requirementID == requirementID && $0.status == .mapped
            }) else {
                throw WorkspaceAppActionExecutionError.missingMappedBinding(requirementID)
            }
            let result = try await asyncCapabilityWriteClient.write(
                action: action, requirement: requirement, binding: binding, input: input
            )
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.capability.write",
                payload: [
                    "actionID": .text(action.id),
                    "requirementID": .text(requirementID),
                    "contract": .text(binding.contract),
                    "operation": .text(action.operation ?? ""),
                    "async": .bool(true)
                ],
                modelContext: modelContext
            )
            recorder.completeRun(run, outputSummary: result.outputSummary, modelContext: modelContext)
            app.lastRunAt = Date()
            app.updatedAt = Date()
            try? modelContext.save()
            return WorkspaceAppActionExecutionResult(run: run, rows: result.rows, outputSummary: result.outputSummary)
        } catch {
            recorder.failRun(run, error: error, blocked: isPermissionError(error), modelContext: modelContext)
            try? modelContext.save()
            throw error
        }
    }

    private func execute(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        ))
        switch action.type {
        case "appStorage.insert":
            // Fall back to the action's declared table (matching update/delete/query) so an insert
            // used as a pipeline step — where bindingForward leaves input.table nil — resolves its
            // target instead of throwing missingTable.
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            let insertRecord = input.effectiveRecord
            guard !insertRecord.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            do {
                try storageService.insertRecord(insertRecord, into: table, databaseURL: databaseURL)
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
            return ([], "Inserted 1 record into \(table).", nil, nil)
        case "appStorage.update":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            let updateRecord = input.effectiveRecord
            guard !updateRecord.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let primaryKey = try primaryKeyColumn(in: table, manifest: manifest)
            do {
                try storageService.updateRecord(
                    updateRecord,
                    in: table,
                    primaryKey: primaryKey,
                    databaseURL: databaseURL
                )
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
            return ([], "Updated 1 record in \(table).", nil, nil)
        case "appStorage.delete":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let primaryKey = try primaryKeyColumn(in: table, manifest: manifest)
            guard let primaryKeyValue = input.record[primaryKey] else {
                throw WorkspaceAppActionExecutionError.storageFailed(
                    String(describing: WorkspaceAppStorageError.missingPrimaryKeyValue(primaryKey))
                )
            }
            do {
                try storageService.deleteRecord(
                    from: table,
                    primaryKey: primaryKey,
                    value: primaryKeyValue,
                    databaseURL: databaseURL
                )
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
            return ([], "Deleted 1 record from \(table).", nil, nil)
        case "appStorage.query":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            do {
                let rows = try storageService.records(in: table, databaseURL: databaseURL, limit: input.limit)
                return (rows, "Read \(rows.count) records from \(table).", nil, nil)
            } catch {
                throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
            }
        case "capability.read":
            return try executeCapabilityRead(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "capability.write":
            return try executeCapabilityWrite(
                action: action,
                app: app,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "artifact.export":
            let artifactURL = try exportStorageArtifact(
                action: action,
                manifest: manifest,
                input: input,
                workspace: workspace,
                app: app,
                databaseURL: databaseURL
            )
            return (
                [],
                "Exported \(artifactURL.lastPathComponent).",
                nil,
                artifactURL.path
            )
        case "notification.show":
            return try executeShowNotification(action: action, run: run, modelContext: modelContext)
        case "url.open":
            return try executeOpenURL(action: action, run: run, modelContext: modelContext)
        case "clipboard.copy":
            return try executeCopyToClipboard(action: action, run: run, modelContext: modelContext)
        case "task.createDraft":
            let task = try createTask(
                action: action,
                app: app,
                manifest: manifest,
                input: input,
                workspace: workspace,
                status: .draft,
                modelContext: modelContext
            )
            return ([], "Created draft task '\(task.title)'.", task.id, nil)
        case "task.createAndRun":
            let task = try createTask(
                action: action,
                app: app,
                manifest: manifest,
                input: input,
                workspace: workspace,
                status: .queued,
                modelContext: modelContext
            )
            return ([], "Queued task '\(task.title)'.", task.id, nil)
        case "gate.humanApproval":
            return try executeHumanApprovalGate(
                action: action,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "gate.expression":
            return try executeExpressionGate(
                action: action,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "gate.agentRecommendation":
            return try executeAgentRecommendationGate(
                action: action,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "pipeline.run":
            return try executePipeline(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "loop.run":
            return try executeLoop(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "rows.reduce":
            return executeReduce(action: action, input: input, run: run, modelContext: modelContext)
        case "gate.branch":
            return try executeBranch(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        default:
            throw WorkspaceAppActionExecutionError.unsupportedActionType(action.type)
        }
    }

    // C2: evaluate a predicate against the upstream bound output and run exactly one
    // chosen target step inline (then/else). Synchronous, non-suspending — branch
    // targets are validator-restricted to non-task action types.
    private func executeBranch(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let gateOperator = WorkspaceAppExpressionGateOperator(
            rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }
        // Condition on UPSTREAM produced output (boundRows), falling back to the input record.
        let actualValue = input.boundRows.first?[field] ?? input.record[field]
        let passed = evaluateExpressionGate(
            gateOperator: gateOperator,
            actualValue: actualValue,
            expectedValue: action.gateValue
        )
        let targetID = passed ? action.thenStep : action.elseStep
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.branch.evaluated",
            payload: [
                "branchID": .text(action.id),
                "passed": .bool(passed),
                "target": .text(targetID ?? "none")
            ],
            modelContext: modelContext
        )
        guard let targetID,
              let target = manifest.actions.first(where: { $0.id == targetID }) else {
            // No branch taken (e.g. no elseStep on a failed predicate) — pass the rows through.
            return (input.boundRows, "Branch '\(action.id)' took no step.", nil, nil)
        }
        try enforcePermission(for: target, app: app, input: input)
        return try execute(
            action: target,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input,
            run: run,
            modelContext: modelContext
        )
    }

    // C3: fold the previous step's bound rows into one row (count/sum/concat/first/last).
    // A pure in-memory fan-in — the natural consumer of a multi-row producer (a query
    // or a task.fanOut barrier). Reads the full input.boundRows (not effectiveRecord,
    // which collapses to the first row).
    private func executeReduce(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let strategy = action.reduceStrategy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "count"
        let column = action.reduceColumn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inputRows = input.boundRows

        let outputKey: String
        let value: WorkspaceAppStorageValue
        switch strategy {
        case "sum":
            outputKey = column
            value = .real(inputRows.reduce(0.0) { $0 + (numericValue($1[column]) ?? 0) })
        case "concat":
            outputKey = column
            let parts = inputRows.compactMap { row -> String? in
                switch row[column] {
                case .none, .some(.null): return nil
                case .some(let cell): return describeGateValue(cell)
                }
            }
            value = .text(parts.joined(separator: ", "))
        case "first":
            outputKey = column
            value = inputRows.first?[column] ?? .null
        case "last":
            outputKey = column
            value = inputRows.last?[column] ?? .null
        default: // count
            outputKey = column.isEmpty ? "count" : column
            value = .integer(Int64(inputRows.count))
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.rows.reduced",
            payload: [
                "strategy": .text(strategy),
                "column": .text(column),
                "inputRows": .integer(Int64(inputRows.count))
            ],
            modelContext: modelContext
        )
        return ([[outputKey: value]], "Reduced \(inputRows.count) rows by \(strategy).", nil, nil)
    }

    private func executeShowNotification(
        action: WorkspaceAppActionSpec,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let title = normalized(action.notificationTitle, action.label, fallback: "")
        let body = normalized(action.notificationBody, fallback: "")
        guard !title.isEmpty || !body.isEmpty else {
            throw WorkspaceAppActionExecutionError.invalidUtilityAction(
                "Notification action '\(action.id)' must declare a title or body."
            )
        }
        utilityActionClient.showNotification(title: title, body: body)
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.notification.shown",
            payload: [
                "actionID": .text(action.id),
                "title": .text(title),
                "bodyLength": .integer(Int64(body.count))
            ],
            modelContext: modelContext
        )
        return ([], "Showed notification '\(title.isEmpty ? action.id : title)'.", nil, nil)
    }

    private func executeOpenURL(
        action: WorkspaceAppActionSpec,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let targetURL = normalized(action.targetURL, fallback: "")
        guard let url = URL(string: targetURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw WorkspaceAppActionExecutionError.invalidUtilityAction(
                "URL open action '\(action.id)' must declare an http or https URL."
            )
        }
        utilityActionClient.openURL(url)
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.url.opened",
            payload: ["actionID": .text(action.id), "url": .text(url.absoluteString)],
            modelContext: modelContext
        )
        return ([], "Opened \(url.absoluteString).", nil, nil)
    }

    private func executeCopyToClipboard(
        action: WorkspaceAppActionSpec,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let text = normalized(action.clipboardText, fallback: "")
        guard !text.isEmpty else {
            throw WorkspaceAppActionExecutionError.invalidUtilityAction(
                "Clipboard copy action '\(action.id)' must declare text to copy."
            )
        }
        utilityActionClient.copyToClipboard(text)
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.clipboard.copied",
            payload: ["actionID": .text(action.id), "characterCount": .integer(Int64(text.count))],
            modelContext: modelContext
        )
        return ([], "Copied \(text.count) characters to the clipboard.", nil, nil)
    }

    private func executeHumanApprovalGate(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let prompt = action.approvalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? action.approvalPrompt ?? "Approval required."
            : "Approval required."
        if !input.confirmedApproval {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.approval.requested",
                payload: [
                    "actionID": .text(action.id),
                    "prompt": .text(prompt),
                    "decisions": .text(action.approvalDecisions.joined(separator: ","))
                ],
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.approvalRequired(action.id)
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.approval.confirmed",
            payload: ["actionID": .text(action.id), "prompt": .text(prompt)],
            modelContext: modelContext
        )
        return ([], "Approval gate '\(action.id)' confirmed.", nil, nil)
    }

    private func executeExpressionGate(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !field.isEmpty,
              let gateOperator = WorkspaceAppExpressionGateOperator(
                rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              ) else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }

        let actualValue = input.record[field]
        let passed = evaluateExpressionGate(
            gateOperator: gateOperator,
            actualValue: actualValue,
            expectedValue: action.gateValue
        )
        let eventPayload: [String: WorkspaceAppStorageValue] = [
            "actionID": .text(action.id),
            "field": .text(field),
            "operator": .text(gateOperator.rawValue),
            "actualValue": .text(describeGateValue(actualValue)),
            "expectedValue": .text(describeGateValue(action.gateValue))
        ]

        if !passed {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.gate.blocked",
                payload: eventPayload,
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.gate.passed",
            payload: eventPayload,
            modelContext: modelContext
        )
        return ([], "Expression gate '\(action.id)' passed.", nil, nil)
    }

    private func executeAgentRecommendationGate(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let prompt = action.agentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let policyMode = action.agentPolicyMode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let decisions = Set(action.agentDecisions)
        let decision = input.agentRecommendationDecision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requiresApproval = action.agentRequiresApproval || policyMode == "approvalRequired"

        guard !prompt.isEmpty, !decisions.isEmpty, !policyMode.isEmpty else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }
        if decision.isEmpty {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.agentRecommendation.requested",
                payload: agentRecommendationPayload(
                    action: action,
                    prompt: prompt,
                    policyMode: policyMode,
                    decision: nil,
                    requiresApproval: requiresApproval
                ),
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.agentRecommendationRequired(action.id)
        }
        guard decisions.contains(decision) else {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.agentRecommendation.blocked",
                payload: agentRecommendationPayload(
                    action: action,
                    prompt: prompt,
                    policyMode: policyMode,
                    decision: decision,
                    requiresApproval: requiresApproval
                ),
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }
        if requiresApproval && !input.confirmedApproval {
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.agentRecommendation.approvalRequested",
                payload: agentRecommendationPayload(
                    action: action,
                    prompt: prompt,
                    policyMode: policyMode,
                    decision: decision,
                    requiresApproval: true
                ),
                modelContext: modelContext
            )
            throw WorkspaceAppActionExecutionError.approvalRequired(action.id)
        }

        recorder.recordEvent(
            run: run,
            type: "workspaceApp.agentRecommendation.accepted",
            payload: agentRecommendationPayload(
                action: action,
                prompt: prompt,
                policyMode: policyMode,
                decision: decision,
                requiresApproval: requiresApproval
            ),
            modelContext: modelContext
        )
        return ([], "Agent recommendation gate '\(action.id)' accepted '\(decision)'.", nil, nil)
    }

    private func executeCapabilityRead(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let sourceID = normalized(action.sourceRef, input.table, action.table, fallback: "")
        guard !sourceID.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingSource
        }
        let resolved = try sourceResolver.resolve(
            sourceID: sourceID,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: WorkspaceAppSourceResolutionInput(limit: input.limit, parameters: input.record)
        )
        var payload: [String: WorkspaceAppStorageValue] = [
            "sourceID": .text(resolved.sourceID),
            "rowCount": .integer(Int64(resolved.rows.count))
        ]
        if let requirementID = resolved.requirementID {
            payload["requirementID"] = .text(requirementID)
        }
        if let implementationID = resolved.implementationID {
            payload["implementationID"] = .text(implementationID)
        }
        if let provider = resolved.provider {
            payload["provider"] = .text(provider)
        }
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.capability.read",
            payload: payload,
            modelContext: modelContext
        )
        return (resolved.rows, resolved.outputSummary, nil, nil)
    }

    private func executeCapabilityWrite(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
        let requirementID = normalized(action.requirementRef, fallback: "")
        guard !requirementID.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingRequirement("")
        }
        guard let requirement = manifest.requirements.first(where: { $0.id == requirementID }) else {
            throw WorkspaceAppActionExecutionError.missingRequirement(requirementID)
        }
        guard let binding = dependencyBindings.first(where: {
            $0.appID == app.id && $0.requirementID == requirementID && $0.status == .mapped
        }) else {
            throw WorkspaceAppActionExecutionError.missingMappedBinding(requirementID)
        }
        let result = try capabilityWriteClient.write(
            action: action,
            requirement: requirement,
            binding: binding,
            input: input
        )
        var payload: [String: WorkspaceAppStorageValue] = [
            "actionID": .text(action.id),
            "requirementID": .text(requirementID),
            "contract": .text(binding.contract),
            "operation": .text(action.operation ?? ""),
            "recordKeys": .text(input.record.keys.sorted().joined(separator: ","))
        ]
        if let implementationID = binding.implementationID {
            payload["implementationID"] = .text(implementationID)
        }
        if let provider = binding.provider {
            payload["provider"] = .text(provider)
        }
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.capability.write",
            payload: payload,
            modelContext: modelContext
        )
        return (result.rows, result.outputSummary, nil, nil)
    }

    private func executePipeline(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext,
        startIndex: Int = 0,
        initialBoundRows: [[String: WorkspaceAppStorageValue]] = []
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        guard !action.steps.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingPipelineSteps(action.id)
        }

        var rows = initialBoundRows
        var summaries: [String] = []
        var linkedTaskID: UUID?
        var linkedArtifactPath: String?

        for (index, stepID) in action.steps.enumerated() {
            guard index >= startIndex else { continue }
            let step = try actionSpec(actionID: stepID, manifest: manifest)
            // B1 output binding: each step sees the previous step's rows.
            var stepInput = input.bindingForward(rows: rows)
            // Human approval applies ONLY to the gate being resumed (at startIndex); a later
            // gate.humanApproval step must re-prompt rather than inherit the prior approval.
            if index > startIndex { stepInput.confirmedApproval = false }
            // Enforce the step's permission BEFORE any side effect (incl. launching
            // an async agent task), so an unapproved workflow can't queue work.
            try enforcePermission(for: step, app: app, input: stepInput)
            // Human-in-the-loop: a gate.humanApproval step that isn't pre-approved suspends the run
            // to `.waiting` pending a human decision (resumed via resumeWithApproval), rather than
            // failing the run — this is what makes the attention queue actionable.
            if step.type == "gate.humanApproval", !stepInput.confirmedApproval {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.pipeline.step.awaitingApproval",
                    payload: ["pipelineID": .text(action.id), "stepID": .text(stepID)],
                    modelContext: modelContext
                )
                throw WorkspaceAppApprovalSuspension(
                    pipelineActionID: action.id,
                    gateStepIndex: index,
                    gateActionID: stepID
                )
            }
            // B2: await an async agent step — launch the task and suspend the run
            // until it completes (resumed via WorkspaceAppActionExecutor.resume).
            if step.type == "task.createAndRun" {
                let task = try createTask(
                    action: step,
                    app: app,
                    manifest: manifest,
                    input: stepInput,
                    workspace: workspace,
                    status: .queued,
                    modelContext: modelContext
                )
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.pipeline.step.suspended",
                    payload: [
                        "pipelineID": .text(action.id),
                        "stepID": .text(stepID),
                        "taskID": .text(task.id.uuidString)
                    ],
                    modelContext: modelContext
                )
                throw WorkspaceAppPipelineSuspension(
                    taskIDs: [task.id],
                    pipelineActionID: action.id,
                    nextStepIndex: index + 1
                )
            }
            // C1: parallel fan-out — launch one queued agent task per upstream bound
            // row, then suspend the run on a barrier over the whole set. The permission
            // gate above covers the whole fan-out once. Zero rows launches nothing and
            // continues (so the run never strands in .waiting).
            if step.type == "task.fanOut" {
                guard let childID = step.fanOutStep?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !childID.isEmpty,
                      let childTemplate = manifest.actions.first(where: { $0.id == childID }) else {
                    throw WorkspaceAppActionExecutionError.unsupportedActionType(step.type)
                }
                let fanRows = stepInput.boundRows
                if fanRows.isEmpty { continue }
                var launchedIDs: [UUID] = []
                for row in fanRows {
                    let task = try createTask(
                        action: childTemplate,
                        app: app,
                        manifest: manifest,
                        input: stepInput.bindingForward(rows: [row]),
                        workspace: workspace,
                        status: .queued,
                        modelContext: modelContext
                    )
                    launchedIDs.append(task.id)
                }
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.pipeline.step.fannedOut",
                    payload: [
                        "pipelineID": .text(action.id),
                        "stepID": .text(stepID),
                        "taskCount": .integer(Int64(launchedIDs.count))
                    ],
                    modelContext: modelContext
                )
                throw WorkspaceAppPipelineSuspension(
                    taskIDs: launchedIDs,
                    pipelineActionID: action.id,
                    nextStepIndex: index + 1
                )
            }
            let result = try execute(
                action: step,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: stepInput,
                run: run,
                modelContext: modelContext
            )
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.pipeline.step.completed",
                payload: [
                    "pipelineID": .text(action.id),
                    "stepID": .text(stepID),
                    "boundRows": .integer(Int64(stepInput.boundRows.count)),
                    "outputRows": .integer(Int64(result.rows.count)),
                    "summary": .text(result.outputSummary)
                ],
                modelContext: modelContext
            )
            rows = result.rows
            summaries.append("\(stepID): \(result.outputSummary)")
            linkedTaskID = result.linkedTaskID ?? linkedTaskID
            linkedArtifactPath = result.linkedArtifactPath ?? linkedArtifactPath
        }

        return (
            rows,
            "Pipeline '\(action.id)' completed \(action.steps.count) steps. " + summaries.joined(separator: " "),
            linkedTaskID,
            linkedArtifactPath
        )
    }

    private func executeLoop(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        modelContext: ModelContext
    ) throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        guard !action.steps.isEmpty,
              let maxIterations = action.maxIterations,
              maxIterations > 0,
              let timeoutSeconds = action.timeoutSeconds,
              timeoutSeconds > 0,
              action.delaySeconds.map({ $0 >= 0 }) ?? true,
              let stopOperator = WorkspaceAppExpressionGateOperator(
                rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              ),
              let stopField = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stopField.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingLoopBounds(action.id)
        }

        let startedAt = Date()
        let delaySeconds = action.delaySeconds ?? 0
        var rows: [[String: WorkspaceAppStorageValue]] = []
        var summaries: [String] = []
        var linkedTaskID: UUID?
        var linkedArtifactPath: String?
        var completedIterations = 0
        var stoppedByCondition = false

        for iteration in 1...maxIterations {
            if Date().timeIntervalSince(startedAt) > TimeInterval(timeoutSeconds) {
                throw WorkspaceAppActionExecutionError.loopTimeout(action.id)
            }
            completedIterations = iteration
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.loop.iteration.started",
                payload: [
                    "loopID": .text(action.id),
                    "iteration": .integer(Int64(iteration)),
                    "maxIterations": .integer(Int64(maxIterations)),
                    "timeoutSeconds": .integer(Int64(timeoutSeconds)),
                    "delaySeconds": .integer(Int64(delaySeconds))
                ],
                modelContext: modelContext
            )

            for stepID in action.steps {
                let step = try actionSpec(actionID: stepID, manifest: manifest)
                // B1 output binding: each step sees the previous step's rows.
                let stepInput = input.bindingForward(rows: rows)
                try enforcePermission(for: step, app: app, input: stepInput)
                let result = try execute(
                    action: step,
                    app: app,
                    workspace: workspace,
                    manifest: manifest,
                    dependencyBindings: dependencyBindings,
                    input: stepInput,
                    run: run,
                    modelContext: modelContext
                )
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.loop.step.completed",
                    payload: [
                        "loopID": .text(action.id),
                        "iteration": .integer(Int64(iteration)),
                        "stepID": .text(stepID),
                        "boundRows": .integer(Int64(stepInput.boundRows.count)),
                        "summary": .text(result.outputSummary)
                    ],
                    modelContext: modelContext
                )
                rows = result.rows
                summaries.append("iteration \(iteration) \(stepID): \(result.outputSummary)")
                linkedTaskID = result.linkedTaskID ?? linkedTaskID
                linkedArtifactPath = result.linkedArtifactPath ?? linkedArtifactPath
            }

            stoppedByCondition = evaluateExpressionGate(
                gateOperator: stopOperator,
                actualValue: input.record[stopField],
                expectedValue: action.gateValue
            )
            recorder.recordEvent(
                run: run,
                type: "workspaceApp.loop.iteration.completed",
                payload: [
                    "loopID": .text(action.id),
                    "iteration": .integer(Int64(iteration)),
                    "stopConditionMet": .bool(stoppedByCondition)
                ],
                modelContext: modelContext
            )
            if stoppedByCondition {
                break
            }
        }

        let stopSummary = stoppedByCondition ? "stop condition met" : "max iterations reached"
        return (
            rows,
            "Loop '\(action.id)' completed \(completedIterations) iterations; \(stopSummary). " + summaries.joined(separator: " "),
            linkedTaskID,
            linkedArtifactPath
        )
    }

    private func primaryKeyColumn(
        in tableName: String,
        manifest: WorkspaceAppManifest
    ) throws -> String {
        guard let table = manifest.storage?.tables.first(where: { $0.name == tableName }),
              let primaryKey = table.columns.first(where: \.primaryKey)?.name else {
            throw WorkspaceAppActionExecutionError.missingPrimaryKey(tableName)
        }
        return primaryKey
    }

    private func exportStorageArtifact(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        workspace: Workspace,
        app: WorkspaceApp,
        databaseURL: URL
    ) throws -> URL {
        guard let table = input.table ?? action.table else {
            throw WorkspaceAppActionExecutionError.missingTable
        }
        let format = normalized(input.exportFormat, action.exportFormat, fallback: "csv").lowercased()
        let rows: [[String: WorkspaceAppStorageValue]]
        do {
            rows = try storageService.records(in: table, databaseURL: databaseURL, limit: input.limit)
        } catch {
            throw WorkspaceAppActionExecutionError.storageFailed(String(describing: error))
        }

        let directory = WorkspaceFileLayout.appArtifactExportDirectory(
            workspacePath: workspace.primaryPath,
            appID: app.logicalID
        )
        guard !directory.isEmpty else {
            throw WorkspaceAppActionExecutionError.storageFailed("Workspace path is unavailable.")
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        switch format {
        case "csv":
            let url = try nextExportURL(directory: directoryURL, table: table, pathExtension: "csv")
            let columns = exportColumns(rows, manifest: manifest, table: table)
            try csvData(rows: rows, columns: columns).write(to: url, options: .atomic)
            return url
        case "json":
            let url = try nextExportURL(directory: directoryURL, table: table, pathExtension: "json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rows)
            try data.write(to: url, options: .atomic)
            return url
        default:
            throw WorkspaceAppActionExecutionError.unsupportedExportFormat(format)
        }
    }

    private func nextExportURL(
        directory: URL,
        table: String,
        pathExtension: String
    ) throws -> URL {
        let safeTable = table.replacingOccurrences(of: ".", with: "-")
        let first = directory.appendingPathComponent("\(safeTable).\(pathExtension)")
        guard FileManager.default.fileExists(atPath: first.path) else {
            return first
        }
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(safeTable)-\(suffix).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func exportColumns(
        _ rows: [[String: WorkspaceAppStorageValue]],
        manifest: WorkspaceAppManifest,
        table: String
    ) -> [String] {
        if let declaredColumns = manifest.storage?.tables.first(where: { $0.name == table })?.columns.map(\.name),
           !declaredColumns.isEmpty {
            return declaredColumns
        }
        var columns: [String] = []
        var seen = Set<String>()
        for row in rows {
            for key in row.keys.sorted() where seen.insert(key).inserted {
                columns.append(key)
            }
        }
        return columns
    }

    private func csvData(
        rows: [[String: WorkspaceAppStorageValue]],
        columns: [String]
    ) -> Data {
        let lines = [columns.map(csvField).joined(separator: ",")] + rows.map { row in
            columns
                .map { csvField(exportValue(row[$0])) }
                .joined(separator: ",")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func exportValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .null, nil:
            ""
        case .text(let value):
            value
        case .integer(let value):
            "\(value)"
        case .real(let value):
            value.formatted(.number.precision(.fractionLength(0...12)))
        case .bool(let value):
            value ? "true" : "false"
        }
    }

    private func createTask(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        workspace: Workspace,
        status: TaskStatus,
        modelContext: ModelContext
    ) throws -> AgentTask {
        let title = normalized(
            input.taskTitle,
            action.taskTitle,
            action.label,
            fallback: "\(manifest.app.name) task"
        )
        var goal = normalized(
            input.taskGoal,
            action.taskGoal,
            fallback: ""
        )
        guard !goal.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingTaskGoal
        }
        // Slice 10 Phase 3 named variables: interpolate {{field}} placeholders in the goal from the
        // prior step's captured fields (boundRows / record), so a goal can reference an earlier
        // step's output by name (e.g. "Implement {{summary}}").
        goal = Self.interpolatePlaceholders(goal, input: input)
        // Slice 10 input binding: inject the app's own data (the prior step's rows, or a local
        // storage table) into the goal so the AI step can see what it's working on — closing the
        // "AI steps remember the workspace, not the app's data" gap.
        if let binding = action.inputBinding {
            goal += inputBindingGoalBlock(binding, input: input, app: app, workspace: workspace)
        }

        let task = AgentTask(title: title, goal: goal, workspace: workspace)
        task.status = status
        task.inputs = [
            "Created from Workspace App '\(manifest.app.name)' (\(manifest.app.id)).",
            "Workspace App action: \(action.id)"
        ]
        modelContext.insert(task)
        return task
    }

    /// Slice 10: renders the input-binding data as a labeled JSON block appended to the agent goal.
    /// Reads ONLY app-owned data (the prior step's boundRows, or a local storage table) — never an
    /// external capability — so it adds no egress beyond what the app already reads locally.
    private func inputBindingGoalBlock(
        _ binding: WorkspaceAppActionInputBinding,
        input: WorkspaceAppActionInput,
        app: WorkspaceApp,
        workspace: Workspace
    ) -> String {
        let limit = min(max(binding.limit ?? 50, 1), 200)
        let rows: [[String: WorkspaceAppStorageValue]]
        switch binding.source {
        case "table":
            guard let table = binding.table?.trimmingCharacters(in: .whitespacesAndNewlines), !table.isEmpty else { return "" }
            let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
                workspacePath: workspace.primaryPath,
                appID: app.logicalID
            ))
            rows = (try? storageService.records(in: table, databaseURL: databaseURL, limit: limit)) ?? []
        default:  // "boundRows"
            rows = Array(input.boundRows.prefix(limit))
        }
        guard !rows.isEmpty else { return "" }
        let label = binding.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = (label?.isEmpty == false) ? label! : "Input data"
        return "\n\n\(header) (\(rows.count) record\(rows.count == 1 ? "" : "s")):\n\(Self.jsonStringify(rows))"
    }

    /// Slice 10 Phase 3: substitute `{{field}}` placeholders from the prior step's captured fields
    /// (record takes precedence over boundRows.first), so a goal can name an earlier step's output.
    static func interpolatePlaceholders(_ text: String, input: WorkspaceAppActionInput) -> String {
        guard text.contains("{{") else { return text }
        let variables = (input.boundRows.first ?? [:]).merging(input.record) { _, new in new }
        var result = text
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: displayString(value))
        }
        return result
    }

    /// Plain-text rendering of a storage value (for goal interpolation).
    static func displayString(_ value: WorkspaceAppStorageValue) -> String {
        switch value {
        case .null: return ""
        case .text(let string): return string
        case .integer(let int): return String(int)
        case .real(let double): return String(double)
        case .bool(let bool): return bool ? "true" : "false"
        }
    }

    /// Deterministic JSON for a row set (sorted keys). WorkspaceAppStorageValue encodes as a scalar
    /// (single-value container), so this yields clean `[{"col": value}]` JSON the agent can read.
    static func jsonStringify(_ rows: [[String: WorkspaceAppStorageValue]]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rows), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    /// Slice 10 output binding: maps a completed agent task's captured answer (threaded in under the
    /// `output` key by the resumption service) onto the awaited step's declared `outputBinding` —
    /// renaming it to `field` (optionally JSON-parsing the answer into columns) and, when a `table`
    /// is declared, persisting the row to local storage so the agent's result becomes durable app data.
    func applyOutputBinding(
        taskOutputRows: [[String: WorkspaceAppStorageValue]],
        pipeline: WorkspaceAppActionSpec,
        awaitedStepIndex: Int,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        modelContext: ModelContext
    ) -> [[String: WorkspaceAppStorageValue]] {
        guard awaitedStepIndex >= 0, awaitedStepIndex < pipeline.steps.count,
              let step = manifest.actions.first(where: { $0.id == pipeline.steps[awaitedStepIndex] }),
              let binding = step.outputBinding else {
            return taskOutputRows
        }
        let captureJSON = (binding.capture ?? "text") == "json"
        let mapped: [[String: WorkspaceAppStorageValue]] = taskOutputRows.map { row in
            var out = row
            let answer: String
            if case let .text(value)? = row["output"] { answer = value } else { answer = "" }
            if captureJSON,
               let data = answer.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in object { out[key] = Self.storageValue(fromJSON: value) }
            }
            out[binding.field] = .text(answer)
            return out
        }

        if let tableName = binding.table?.trimmingCharacters(in: .whitespacesAndNewlines), !tableName.isEmpty,
           let schema = manifest.storage?.tables.first(where: { $0.name == tableName }) {
            let columns = Set(schema.columns.map(\.name))
            let primaryKey = schema.columns.first(where: { $0.primaryKey })?.name
            let databaseURL = URL(fileURLWithPath: WorkspaceFileLayout.appDatabaseFile(
                workspacePath: workspace.primaryPath,
                appID: app.logicalID
            ))
            for row in mapped {
                var record = row.filter { columns.contains($0.key) }
                if let primaryKey, record[primaryKey] == nil {
                    record[primaryKey] = .text(UUID().uuidString)
                }
                guard !record.isEmpty else { continue }
                try? storageService.insertRecord(record, into: tableName, databaseURL: databaseURL)
            }
        }
        return mapped
    }

    /// Maps a JSONSerialization native (String / NSNumber / bool) to a WorkspaceAppStorageValue.
    static func storageValue(fromJSON value: Any) -> WorkspaceAppStorageValue {
        if let string = value as? String { return .text(string) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if number.doubleValue == Double(number.int64Value) { return .integer(number.int64Value) }
            return .real(number.doubleValue)
        }
        return .null
    }

    private func effect(for actionType: String) -> WorkspaceAppContractEffect {
        WorkspaceAppActionEffect.effect(for: actionType)
    }

    private func inputSummary(_ input: WorkspaceAppActionInput) -> String {
        let table = input.table ?? "none"
        let taskGoal = input.taskGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "present" : "none"
        let exportFormat = input.exportFormat ?? "none"
        let agentDecision = input.agentRecommendationDecision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "present" : "none"
        return "table=\(table); recordKeys=\(input.record.keys.sorted().joined(separator: ",")); limit=\(input.limit); exportFormat=\(exportFormat); taskGoal=\(taskGoal); confirmedDestructive=\(input.confirmedDestructive); confirmedApproval=\(input.confirmedApproval); agentRecommendationDecision=\(agentDecision)"
    }

    private func isPermissionError(_ error: Error) -> Bool {
        if case WorkspaceAppActionExecutionError.permissionDenied = error {
            return true
        }
        if case WorkspaceAppActionExecutionError.approvalRequired = error {
            return true
        }
        if case WorkspaceAppActionExecutionError.agentRecommendationRequired = error {
            return true
        }
        if case WorkspaceAppActionExecutionError.gateBlocked = error {
            return true
        }
        return false
    }

    private func agentRecommendationPayload(
        action: WorkspaceAppActionSpec,
        prompt: String,
        policyMode: String,
        decision: String?,
        requiresApproval: Bool
    ) -> [String: WorkspaceAppStorageValue] {
        [
            "actionID": .text(action.id),
            "prompt": .text(prompt),
            "decisions": .text(action.agentDecisions.joined(separator: ",")),
            "decision": .text(decision ?? ""),
            "policyMode": .text(policyMode),
            "tokenBudget": .integer(Int64(action.agentTokenBudget ?? 0)),
            "requiresApproval": .bool(requiresApproval),
            "inputBindings": .text(action.agentInputBindings.joined(separator: ","))
        ]
    }

    private func evaluateExpressionGate(
        gateOperator: WorkspaceAppExpressionGateOperator,
        actualValue: WorkspaceAppStorageValue?,
        expectedValue: WorkspaceAppStorageValue?
    ) -> Bool {
        switch gateOperator {
        case .exists:
            return actualValue != nil && actualValue != .null
        case .notExists:
            return actualValue == nil || actualValue == .null
        case .equals:
            return actualValue == expectedValue
        case .notEquals:
            return actualValue != expectedValue
        case .greaterThan:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison > 0
        case .greaterThanOrEquals:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison >= 0
        case .lessThan:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison < 0
        case .lessThanOrEquals:
            guard let comparison = numericComparison(actualValue, expectedValue) else { return false }
            return comparison <= 0
        }
    }

    private func numericComparison(
        _ actualValue: WorkspaceAppStorageValue?,
        _ expectedValue: WorkspaceAppStorageValue?
    ) -> Int? {
        guard let actualNumber = numericValue(actualValue),
              let expectedNumber = numericValue(expectedValue) else {
            return nil
        }
        if actualNumber < expectedNumber { return -1 }
        if actualNumber > expectedNumber { return 1 }
        return 0
    }

    private func numericValue(_ value: WorkspaceAppStorageValue?) -> Double? {
        switch value {
        case .integer(let value):
            return Double(value)
        case .real(let value):
            return value
        case .text(let value):
            return Double(value)
        case .bool, .null, nil:
            return nil
        }
    }

    private func describeGateValue(_ value: WorkspaceAppStorageValue?) -> String {
        switch value {
        case .null, nil:
            return "null"
        case .text(let value):
            return value
        case .integer(let value):
            return "\(value)"
        case .real(let value):
            return value.formatted(.number.precision(.fractionLength(0...12)))
        case .bool(let value):
            return value ? "true" : "false"
        }
    }

    private func normalized(_ candidates: String?..., fallback: String) -> String {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback
    }
}
