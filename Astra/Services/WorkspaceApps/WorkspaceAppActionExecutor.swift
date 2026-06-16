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
    let taskID: UUID
    let pipelineActionID: String
    let nextStepIndex: Int
}

struct WorkspaceAppActionExecutor {
    var storageService = WorkspaceAppStorageService()
    var sourceResolver = WorkspaceAppSourceResolver()
    var capabilityWriteClient: any WorkspaceAppCapabilityWriteClient = WorkspaceAppNativeCapabilityWriteClient()
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
                outputSummary: "Workflow '\(suspension.pipelineActionID)' is waiting on task \(suspension.taskID.uuidString)."
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
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.run.resumed",
            payload: [
                "pipelineID": .text(pipelineID),
                "fromStepIndex": .integer(Int64(startIndex)),
                "boundRows": .integer(Int64(taskOutputRows.count))
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
                input: WorkspaceAppActionInput(boundRows: taskOutputRows),
                run: run,
                modelContext: modelContext,
                startIndex: startIndex,
                initialBoundRows: taskOutputRows
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
                outputSummary: "Workflow '\(suspension.pipelineActionID)' is waiting on task \(suspension.taskID.uuidString)."
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
        run.linkedTaskID = suspension.taskID
        run.pendingActionID = suspension.pipelineActionID
        run.pendingStepIndex = suspension.nextStepIndex
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.run.waiting",
            payload: [
                "taskID": .text(suspension.taskID.uuidString),
                "pipelineID": .text(suspension.pipelineActionID),
                "nextStepIndex": .integer(Int64(suspension.nextStepIndex))
            ],
            modelContext: modelContext
        )
        try? modelContext.save()
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
            guard let table = input.table else { throw WorkspaceAppActionExecutionError.missingTable }
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
            let stepInput = input.bindingForward(rows: rows)
            // Enforce the step's permission BEFORE any side effect (incl. launching
            // an async agent task), so an unapproved workflow can't queue work.
            try enforcePermission(for: step, app: app, input: stepInput)
            // B2: await an async agent step — launch the task and suspend the run
            // until it completes (resumed via WorkspaceAppActionExecutor.resume).
            if step.type == "task.createAndRun" {
                let task = try createTask(
                    action: step,
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
                    taskID: task.id,
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
        let goal = normalized(
            input.taskGoal,
            action.taskGoal,
            fallback: ""
        )
        guard !goal.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingTaskGoal
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

    private func effect(for actionType: String) -> WorkspaceAppContractEffect {
        switch actionType {
        case "appStorage.query", "capability.read", "task.open", "artifact.open", "artifact.export", "url.open", "clipboard.copy", "pipeline.run", "loop.run", "gate.humanApproval", "gate.expression", "rows.reduce", "gate.branch":
            .read
        case "gate.agentRecommendation":
            .read
        case "appStorage.insert", "appStorage.update", "notification.show", "task.createDraft":
            .localWrite
        case "capability.write", "task.createAndRun":
            .externalWrite
        case "appStorage.delete":
            .destructive
        default:
            .externalWrite
        }
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
