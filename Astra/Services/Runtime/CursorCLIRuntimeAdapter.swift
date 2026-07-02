import Foundation
import SwiftData
import ASTRACore

struct CursorCLIRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "cursor-cli"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [CursorCLIRuntimeAdapter()]
    }
}

struct CursorCLIRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .cursorCLI,
        displayName: "Cursor CLI",
        executableName: CursorCLIRuntime.executableName,
        installHint: "Install Cursor CLI, then run `cursor-agent login` to authenticate.",
        authHint: "Run `cursor-agent login`, or verify the current login with `cursor-agent status`.",
        prerequisite: CommonCLIPrerequisites.cursor,
        defaultModel: CursorCLIRuntime.defaultModelName(),
        defaultModels: CursorCLIRuntime.availableModelNames(),
        supportsAstraRunProtocol: true
    )
    let readinessCheckID = "cursor-cli"
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .cursorCLI, launchOverheadTokens: 0)
    let recordsStreamTelemetry = true
    let recordsInferredFileChanges = true

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? CursorCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func missingExecutableAuditReason() -> String {
        "cursor_cli_not_found"
    }

    func missingExecutableStopReason() -> String? {
        "missing_cursor"
    }

    func missingExecutableMessage(executablePath _: String) -> String {
        ProviderMessages.missingExecutable(
            providerName: "Cursor",
            installAction: "Install Cursor CLI",
            authAction: "authenticate with `cursor-agent login`."
        )
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        ProviderMessages.start(providerName: "Cursor", goal: task.goal)
    }

    func connectorPreflightContextText(
        task _: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage _: String?,
        phase _: RunPhase
    ) -> String {
        promptOverride ?? startPayload
    }

    func shouldPrepareIsolation(phase _: RunPhase) -> Bool {
        true
    }

    func shouldValidateSuccessfulRun(phase _: RunPhase) -> Bool {
        true
    }

    func requiresVisibleResultForSuccessfulRun(phase _: RunPhase) -> Bool {
        true
    }

    func manualCompletionPayload(phase _: RunPhase) -> String {
        ProviderMessages.manualCompletion(providerName: "Cursor", phase: .run)
    }

    func failurePayloadPrefix(phase _: RunPhase, exitCode: Int) -> String {
        ProviderMessages.failurePrefix(providerName: "Cursor", phase: .run, exitCode: exitCode)
    }

    func timeoutPayload(phase _: RunPhase, timeoutSeconds: TimeInterval) -> String {
        ProviderMessages.timeout(phase: .run, timeoutSeconds: timeoutSeconds)
    }

    func maxTurnsPayload(phase _: RunPhase, task: AgentTask) -> String {
        ProviderMessages.maxTurns(phase: .run, maxTurns: task.maxTurns)
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: RunPhase
    ) -> String {
        promptOverride == nil ? task.goal : (startPayload ?? task.goal)
    }

    func policyAdapter(runtimeCapabilities _: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter {
        CursorPolicyAdapter()
    }

    func providerConfigOwnership(workspacePath _: String) -> PolicyConfigOwnership {
        .generated
    }

    func existingProviderConfigSummary(workspacePath _: String) -> String? {
        nil
    }

    func readinessReport(
        configuration: RuntimeReadinessConfiguration,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessReport {
        let prerequisite = descriptor.prerequisite
        let executable = probes.resolvedExecutable(
            configuredPath: configuration.executablePath(for: id),
            binary: prerequisite.binary
        )
        let cliStatus = await probes.checkExecutable(
            id: readinessCheckID,
            title: prerequisite.displayName,
            executable: executable,
            args: prerequisite.livenessArgs,
            missingDetail: "\(prerequisite.displayName) was not found.",
            installHint: prerequisite.installHint
        )

        var checks = [cliStatus.check]
        if cliStatus.isReady {
            if configuration.scope == .availability {
                checks.append(RuntimeReadinessCheck(
                    id: "cursor-account",
                    title: "Cursor account",
                    detail: "CLI is available. Run a readiness check to verify login status.",
                    state: .ready,
                    remediation: nil
                ))
            } else if let executable = cliStatus.executable {
                checks.append(await checkCursorAuth(executable: executable, probes: probes))
            }
        }
        return RuntimeReadinessReport(checks: checks)
    }

    private func checkCursorAuth(
        executable: String,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let result = await probes.run(path: executable, args: ["status"])
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "cursor-account",
                title: "Cursor account",
                detail: RuntimeReadinessDiagnostics.detail(
                    from: result,
                    fallback: "Cursor auth status did not pass."
                ),
                state: .blocked,
                remediation: CommonCLIPrerequisites.cursor.authHint
            )
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        if RuntimeReadinessDiagnostics.showsAuthenticatedSession(output) {
            return RuntimeReadinessCheck(
                id: "cursor-account",
                title: "Cursor account",
                detail: "Cursor reports an authenticated session.",
                state: .ready,
                remediation: nil
            )
        }

        return RuntimeReadinessCheck(
            id: "cursor-account",
            title: "Cursor account",
            detail: RuntimeReadinessDiagnostics.detail(
                from: result,
                fallback: "Cursor responded, but no authenticated session was detected."
            ),
            state: .blocked,
            remediation: CommonCLIPrerequisites.cursor.authHint
        )
    }

    func modelAvailabilityCheck(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty ? CursorCLIRuntime.detectPath() : configuredPath
        let models = CursorCLIRuntime.modelDetails(executablePath: executable)
            ?? CursorCLIRuntime.availableModelNames().map { RuntimeModelDetail(value: $0) }
        await RuntimeModelAvailability.persistObservedAvailableModelDetails(models, for: id, authority: modelAvailabilityAuthority)
        return RuntimeReadinessCheck(
            id: "cursor-models",
            title: "Cursor models",
            detail: "Available: \(models.map(\.value).joined(separator: ", "))",
            state: .ready,
            remediation: nil
        )
    }

    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: context.task,
            contextText: context.contextText,
            executionPolicy: context.executionPolicy
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let pathPrefix = AgentRuntimeProcessRunner.pathPrefix(for: context.task, taskEnv: taskEnv)
        let executable = context.executablePath.isEmpty ? CursorCLIRuntime.detectPath() : context.executablePath
        let providerVersion = CursorCLIRuntime.versionSummary(executablePath: executable)
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let providerModel = CursorCLIRuntime.resolvedModelName(model)
        let additionalPaths = AgentRuntimeProcessRunner.runtimeAdditionalPaths(for: context.task)
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let hostControlTools = HostControlPlaneMCPProjection.enabledToolNames(
            task: context.task,
            environment: executionEnvironment,
            contextText: context.contextText
        )
        let plan = CursorCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: context.prompt,
            model: providerModel,
            workspacePath: context.workspacePath,
            additionalPaths: additionalPaths,
            permissionPolicy: effectivePermissionPolicy,
            timeoutSeconds: context.timeoutSeconds,
            taskEnvironment: taskEnv,
            pathPrefix: pathPrefix,
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(
                context.task,
                contextText: context.contextText
            )
                || taskEnv["ASTRA_BROWSER_URL"] != nil,
            permissionArguments: context.requiredProviderPolicyRender(for: id).cursorLaunchPermissionArguments()
        )
        var commandPlannedFields = [
            "runtime": id.rawValue,
            "phase": context.phase.rawValue,
            "model": model,
            "provider_model": providerModel,
            "permission_policy": effectivePermissionPolicy.rawValue,
            "parses_json_lines": String(plan.parsesJSONLines),
            "additional_paths_count": String(additionalPaths.count),
            "task_env_count": String(taskEnv.count),
            "uses_print": String(plan.arguments.contains("--print")),
            "uses_stream_json": String(plan.arguments.contains("stream-json")),
            "uses_workspace": String(plan.arguments.contains("--workspace")),
            "uses_trust": String(plan.arguments.contains("--trust")),
            "uses_sandbox": String(plan.arguments.contains("--sandbox")),
            "uses_force": String(plan.arguments.contains("--force"))
        ]
        commandPlannedFields.merge(
            HostControlPlaneRuntimeLaunchGuard.planMetadata(runtime: id, requiredTools: hostControlTools),
            uniquingKeysWith: { current, _ in current }
        )

        return AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: context.workspacePath,
            environment: plan.environment,
            browserShimDirectory: browserShimDirectory,
            providerVersion: providerVersion,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: [],
            providerDetectedFields: [
                "runtime": id.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
                "executable_path": executable,
                "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(executable),
                "provider_home_configured": String(!context.providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ],
            commandPlannedFields: commandPlannedFields
        )
    }

    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        CursorCLIRuntime.parseEvents(line: line, parsesJSONLines: parsesJSONLines)
    }

    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? {
        CursorCLIRuntime.blockingMessage(line: line, parsesJSONLines: parsesJSONLines)
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines: Bool) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: CursorCLIRuntime.parseAgentEvents(
            line: line,
            parsesJSONLines: parsesJSONLines
        ))
    }

    func processWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        pipeline: AgentRuntimeEventPipelineBox
    ) -> [AgentRuntimeRecordedEvent] {
        guard case .agent(let agentEvent) = event else { return [] }
        return pipeline.process(agentEvent).map(AgentRuntimeRecordedEvent.agent)
    }

    func flushWorkerStreamEvents(pipeline: AgentRuntimeEventPipelineBox) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: pipeline.flushAgentEvents())
    }

    @MainActor
    func recordWorkerStreamEvent(
        _ event: AgentRuntimeRecordedEvent,
        mode _: AgentRuntimeRecordingMode,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        recordingState: AgentEventRecordingState
    ) {
        guard case .agent(let agentEvent) = event else { return }
        AgentEventRecorder.recordCursorEvent(
            agentEvent,
            to: task,
            run: run,
            modelContext: modelContext,
            recordingState: recordingState
        )
    }

    func callbackEvent(from event: AgentRuntimeRecordedEvent) -> ParsedEvent? {
        guard let agentEvent = event.agentEvent else { return nil }
        return AgentEventRecorder.parsedEvent(from: agentEvent)
    }

    func runUtilityPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty ? CursorCLIRuntime.detectPath() : configuredPath
        let model = AgentRuntimeProcessRunner.model(configuration.model, for: id)
        let permissionPolicy: PermissionPolicy = toolMode == .readOnly ? .interactive : .restricted
        let plan = CursorCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: prompt,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: [],
            permissionPolicy: permissionPolicy,
            timeoutSeconds: configuration.timeoutSeconds,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.cursorLaunchPermissionArguments(policy: permissionPolicy)
        )

        let processPlan = AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            currentDirectory: workspacePath,
            environment: plan.environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: plan.parsesJSONLines
        )
        return await AgentRuntimeProcessRunner().runUtilityProcess(
            AgentUtilityLaunchPlan(
                process: processPlan,
                providerHomeDirectory: configuration.homeDirectory(for: id),
                permissionPolicy: permissionPolicy,
                timeoutSeconds: configuration.timeoutSeconds
            ),
            outputTransform: { output in
                CursorCLIRuntime.extractUtilityText(from: output)
            }
        )
    }
}
