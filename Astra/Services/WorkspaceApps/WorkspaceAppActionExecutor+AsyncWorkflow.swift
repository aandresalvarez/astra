import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

extension WorkspaceAppActionExecutor {
    @MainActor
    func executeAsyncWorkflow(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        trigger: WorkspaceAppRunTrigger,
        surface: WorkspaceAppBridgeSurface,
        modelContext: ModelContext
    ) async throws -> WorkspaceAppActionExecutionResult {
        let run = recorder.startRun(
            app: app,
            actionID: action.id,
            trigger: trigger,
            inputSummary: inputSummary(input),
            modelContext: modelContext
        )

        do {
            try enforcePermission(for: action, app: app, input: input, surface: surface)
            let result = try await executeAsyncWorkflowStep(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                surface: surface,
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
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace,
                modelContext: modelContext
            )
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: result.rows,
                outputSummary: result.outputSummary
            )
        } catch let suspension as WorkspaceAppPipelineSuspension {
            markWaiting(run: run, suspension: suspension, workspace: workspace, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(suspension.pipelineActionID)' is waiting on \(suspension.taskIDs.count) task(s)."
            )
        } catch let approval as WorkspaceAppApprovalSuspension {
            markWaitingForApproval(run: run, suspension: approval, workspace: workspace, modelContext: modelContext)
            return WorkspaceAppActionExecutionResult(
                run: run,
                rows: [],
                outputSummary: "Workflow '\(approval.pipelineActionID)' is waiting for approval of '\(approval.gateActionID)'."
            )
        } catch {
            recorder.failRun(run, error: error, blocked: isPermissionError(error), modelContext: modelContext)
            WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            throw error
        }
    }

    func workflowRequiresAsyncExecution(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest
    ) throws -> Bool {
        if action.type == "capability.read" || action.type == "capability.write" {
            return true
        }
        let childIDs: [String]
        switch action.type {
        case "pipeline.run", "loop.run":
            childIDs = action.steps
        case "gate.branch":
            childIDs = [action.thenStep, action.elseStep].compactMap { $0 }
        default:
            return false
        }
        for childID in childIDs {
            let child = try actionSpec(actionID: childID, manifest: manifest)
            if try workflowRequiresAsyncExecution(action: child, manifest: manifest) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func executeAsyncWorkflowStep(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        surface: WorkspaceAppBridgeSurface,
        modelContext: ModelContext
    ) async throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        switch action.type {
        case "capability.read":
            return try await executeCapabilityReadAsyncStep(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                surface: surface,
                modelContext: modelContext
            )
        case "capability.write":
            return try await executeCapabilityWriteAsyncStep(
                action: action,
                app: app,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        case "pipeline.run":
            return try await executeAsyncPipeline(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                surface: surface,
                modelContext: modelContext
            )
        case "loop.run":
            return try await executeAsyncLoop(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                surface: surface,
                modelContext: modelContext
            )
        case "gate.branch":
            return try await executeAsyncBranch(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                surface: surface,
                modelContext: modelContext
            )
        default:
            return try execute(
                action: action,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: input,
                run: run,
                modelContext: modelContext
            )
        }
    }

    @MainActor
    private func executeCapabilityReadAsyncStep(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        surface: WorkspaceAppBridgeSurface,
        modelContext: ModelContext
    ) async throws -> (
        rows: [[String: WorkspaceAppStorageValue]],
        outputSummary: String,
        linkedTaskID: UUID?,
        linkedArtifactPath: String?
    ) {
        let request = WorkspaceAppCapabilityReadRequest(
            action: action,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input,
            surface: surface
        )
        let pipeline = WorkspaceAppCapabilityReadPipeline(sourceResolver: sourceResolver, readPolicy: readPolicy)
        let resolved = try await pipeline.resolveAsync(request)
        let payload = WorkspaceAppCapabilityReadPipeline.auditPayload(for: resolved, async: true)
        recorder.recordEvent(
            run: run,
            type: "workspaceApp.capability.read",
            payload: payload,
            modelContext: modelContext
        )
        return (resolved.rows, resolved.outputSummary, nil, nil)
    }

    @MainActor
    // Internal (not private) so the resume path in the main file can continue a
    // suspended pipeline through the async step executor — a resumed workflow may
    // have a connector `capability.read` step after the barrier that only the
    // async resolver can service.
    func executeAsyncPipeline(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        surface: WorkspaceAppBridgeSurface,
        modelContext: ModelContext,
        startIndex: Int = 0,
        initialBoundRows: [[String: WorkspaceAppStorageValue]] = []
    ) async throws -> (
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
        var carriesHumanApproval = try hasHumanApprovalGate(before: startIndex, in: action, manifest: manifest)

        for (index, stepID) in action.steps.enumerated() {
            guard index >= startIndex else { continue }
            let step = try actionSpec(actionID: stepID, manifest: manifest)
            var stepInput = input.bindingForward(rows: rows)
            stepInput.confirmedApproval = pipelineStepHasApproval(
                step: step,
                index: index,
                startIndex: startIndex,
                input: input,
                carriesHumanApproval: carriesHumanApproval
            )
            try enforcePermission(for: step, app: app, input: stepInput, surface: surface)
            if step.type == "gate.humanApproval", !stepInput.confirmedApproval {
                recorder.recordEvent(
                    run: run,
                    type: "workspaceApp.pipeline.step.awaitingApproval",
                    payload: [
                        "pipelineID": .text(action.id),
                        "stepID": .text(stepID),
                        "stepIndex": .integer(Int64(index)),
                        "boundRows": .integer(Int64(rows.count)),
                        "boundRowsJSON": .text(WorkspaceAppApprovalResumeContext.boundRowsPayloadString(rows))
                    ],
                    modelContext: modelContext
                )
                throw WorkspaceAppApprovalSuspension(
                    pipelineActionID: action.id,
                    gateStepIndex: index,
                    gateActionID: stepID,
                    boundRows: rows
                )
            }
            if step.type == "gate.humanApproval", stepInput.confirmedApproval {
                carriesHumanApproval = true
            }
            if step.type == "task.createAndRun" {
                try enforceAppAgentBudget(app: app, run: run, launching: 1, modelContext: modelContext)
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
            if step.type == "task.fanOut" {
                guard let childID = step.fanOutStep?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !childID.isEmpty,
                      let childTemplate = manifest.actions.first(where: { $0.id == childID }) else {
                    throw WorkspaceAppActionExecutionError.unsupportedActionType(step.type)
                }
                let fanRows = stepInput.boundRows
                if fanRows.isEmpty { continue }
                try enforceAppAgentBudget(app: app, run: run, launching: fanRows.count, modelContext: modelContext)
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
            let result = try await executeAsyncWorkflowStep(
                action: step,
                app: app,
                workspace: workspace,
                manifest: manifest,
                dependencyBindings: dependencyBindings,
                input: stepInput,
                run: run,
                surface: surface,
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

    @MainActor
    private func executeAsyncLoop(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        surface: WorkspaceAppBridgeSurface,
        modelContext: ModelContext
    ) async throws -> (
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
                let stepInput = input.bindingForward(rows: rows)
                try enforcePermission(for: step, app: app, input: stepInput, surface: surface)
                let result = try await executeAsyncWorkflowStep(
                    action: step,
                    app: app,
                    workspace: workspace,
                    manifest: manifest,
                    dependencyBindings: dependencyBindings,
                    input: stepInput,
                    run: run,
                    surface: surface,
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

    @MainActor
    private func executeAsyncBranch(
        action: WorkspaceAppActionSpec,
        app: WorkspaceApp,
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        dependencyBindings: [WorkspaceAppDependencyBinding],
        input: WorkspaceAppActionInput,
        run: WorkspaceAppRun,
        surface: WorkspaceAppBridgeSurface,
        modelContext: ModelContext
    ) async throws -> (
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
            return (input.boundRows, "Branch '\(action.id)' took no step.", nil, nil)
        }
        try enforcePermission(for: target, app: app, input: input, surface: surface)
        return try await executeAsyncWorkflowStep(
            action: target,
            app: app,
            workspace: workspace,
            manifest: manifest,
            dependencyBindings: dependencyBindings,
            input: input,
            run: run,
            surface: surface,
            modelContext: modelContext
        )
    }
}
