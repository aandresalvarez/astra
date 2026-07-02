import Foundation
import SwiftData
import ASTRACore

struct OpenCodeCLIRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "opencode-cli"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [OpenCodeCLIRuntimeAdapter()]
    }
}

struct OpenCodeCLIRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .openCodeCLI,
        displayName: "OpenCode CLI",
        executableName: OpenCodeCLIRuntime.executableName,
        installHint: "Install OpenCode, then run `opencode auth login` to authenticate.",
        authHint: "Run `opencode auth login`, or verify providers with `opencode auth list`.",
        prerequisite: CommonCLIPrerequisites.openCode,
        defaultModel: OpenCodeCLIRuntime.defaultModelName(),
        defaultModels: OpenCodeCLIRuntime.availableModelNames(),
        supportsAstraRunProtocol: true
    )
    let readinessCheckID = "opencode-cli"
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .openCodeCLI, launchOverheadTokens: 0)
    let recordsStreamTelemetry = true
    let recordsInferredFileChanges = true

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? OpenCodeCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func missingExecutableAuditReason() -> String {
        "opencode_cli_not_found"
    }

    func missingExecutableStopReason() -> String? {
        "missing_opencode"
    }

    func missingExecutableMessage(executablePath _: String) -> String {
        "OpenCode CLI not found. Install OpenCode, then authenticate with `opencode auth login`."
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        "OpenCode started working on: \(task.goal)"
    }

    func connectorPreflightContextText(
        task _: AgentTask,
        promptOverride: String?,
        startPayload: String,
        sessionMessage _: String?,
        phase _: String
    ) -> String {
        promptOverride ?? startPayload
    }

    func shouldPrepareIsolation(phase _: String) -> Bool {
        true
    }

    func shouldValidateSuccessfulRun(phase _: String) -> Bool {
        true
    }

    func requiresVisibleResultForSuccessfulRun(phase _: String) -> Bool {
        true
    }

    func manualCompletionPayload(phase _: String) -> String {
        "OpenCode finished."
    }

    func failurePayloadPrefix(phase _: String, exitCode: Int) -> String {
        "OpenCode exited with code \(exitCode)."
    }

    func timeoutPayload(phase _: String, timeoutSeconds: TimeInterval) -> String {
        "Task idle timeout - no output for \(Int(timeoutSeconds))s. Process killed."
    }

    func maxTurnsPayload(phase _: String, task: AgentTask) -> String {
        "Max turns reached (\(task.maxTurns)). Process killed."
    }

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: String
    ) -> String {
        promptOverride == nil ? task.goal : (startPayload ?? task.goal)
    }

    func policyAdapter(runtimeCapabilities _: AgentRuntimePolicyCapabilities) -> any ProviderPolicyAdapter {
        OpenCodePolicyAdapter()
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
                    id: "opencode-account",
                    title: "OpenCode account",
                    detail: "CLI is available. Run a readiness check to verify provider credentials.",
                    state: .ready,
                    remediation: nil
                ))
            } else if let executable = cliStatus.executable {
                checks.append(await checkOpenCodeAuth(executable: executable, probes: probes))
            }
        }
        return RuntimeReadinessReport(checks: checks)
    }

    private func checkOpenCodeAuth(
        executable: String,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let result = await probes.run(path: executable, args: ["auth", "list"])
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "opencode-account",
                title: "OpenCode account",
                detail: RuntimeReadinessDiagnostics.detail(
                    from: result,
                    fallback: "OpenCode auth list did not pass."
                ),
                state: .blocked,
                remediation: CommonCLIPrerequisites.openCode.authHint
            )
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        if OpenCodeCLIRuntime.authListShowsConfiguredCredentials(output) {
            return RuntimeReadinessCheck(
                id: "opencode-account",
                title: "OpenCode account",
                detail: "OpenCode reports configured provider credentials.",
                state: .ready,
                remediation: nil
            )
        }

        return RuntimeReadinessCheck(
            id: "opencode-account",
            title: "OpenCode account",
            detail: "No OpenCode credentials are configured.",
            state: .blocked,
            remediation: CommonCLIPrerequisites.openCode.authHint
        )
    }

    func installPlan(detectExecutable: @Sendable (String) -> String) -> RuntimeCLIInstallPlan? {
        if let brew = detectedExecutable(named: "brew", detectExecutable: detectExecutable) {
            return RuntimeCLIInstallPlan(
                runtime: id,
                installerName: "Homebrew",
                executablePath: brew,
                arguments: ["install", "opencode"],
                displayCommand: "brew install opencode"
            )
        }
        guard let npm = detectedExecutable(named: "npm", detectExecutable: detectExecutable) else {
            return nil
        }
        return RuntimeCLIInstallPlan(
            runtime: id,
            installerName: "npm",
            executablePath: npm,
            arguments: ["install", "-g", "opencode-ai"],
            displayCommand: "npm install -g opencode-ai"
        )
    }

    func modelAvailabilityCheck(configuration: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let configuredPath = configuration.executablePath(for: id)
        let executable = configuredPath.isEmpty ? OpenCodeCLIRuntime.detectPath() : configuredPath
        let models = OpenCodeCLIRuntime.modelNames(executablePath: executable) ?? OpenCodeCLIRuntime.availableModelNames()
        await RuntimeModelAvailability.persistObservedAvailableModels(models, for: id, authority: modelAvailabilityAuthority)
        return RuntimeReadinessCheck(
            id: "opencode-models",
            title: "OpenCode models",
            detail: "Available: \(models.joined(separator: ", "))",
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
        let executable = context.executablePath.isEmpty ? OpenCodeCLIRuntime.detectPath() : context.executablePath
        let providerVersion = OpenCodeCLIRuntime.versionSummary(executablePath: executable)
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let providerModel = OpenCodeCLIRuntime.resolvedModelName(model)
        let additionalPaths = AgentRuntimeProcessRunner.runtimeAdditionalPaths(for: context.task)
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let hostControlTools = HostControlPlaneMCPProjection.enabledToolNames(
            task: context.task,
            environment: executionEnvironment,
            contextText: context.contextText
        )
        let plan = OpenCodeCLIRuntime.buildCommand(
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
            permissionArguments: context.requiredProviderPolicyRender(for: id).openCodeLaunchPermissionArguments()
        )
        var commandPlannedFields = [
            "runtime": id.rawValue,
            "phase": context.phase,
            "model": model,
            "provider_model": providerModel,
            "permission_policy": effectivePermissionPolicy.rawValue,
            "parses_json_lines": String(plan.parsesJSONLines),
            "additional_paths_count": String(additionalPaths.count),
            "task_env_count": String(taskEnv.count),
            "uses_run": String(plan.arguments.contains("run")),
            "uses_json_format": String(plan.arguments.contains("json")),
            "uses_dir": String(plan.arguments.contains("--dir")),
            "uses_model": String(plan.arguments.contains("--model")),
            "uses_dangerous_skip_permissions": String(plan.arguments.contains("--dangerously-skip-permissions"))
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
        OpenCodeCLIRuntime.parseEvents(line: line, parsesJSONLines: parsesJSONLines)
    }

    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? {
        OpenCodeCLIRuntime.blockingMessage(line: line, parsesJSONLines: parsesJSONLines)
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines: Bool) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: OpenCodeCLIRuntime.parseAgentEvents(
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
        AgentEventRecorder.recordOpenCodeEvent(
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
        let executable = configuredPath.isEmpty ? OpenCodeCLIRuntime.detectPath() : configuredPath
        let model = AgentRuntimeProcessRunner.model(configuration.model, for: id)
        let permissionPolicy: PermissionPolicy = toolMode == .readOnly ? .interactive : .restricted
        let plan = OpenCodeCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: prompt,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: [],
            permissionPolicy: permissionPolicy,
            timeoutSeconds: configuration.timeoutSeconds,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.openCodeLaunchPermissionArguments(policy: permissionPolicy)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        process.environment = plan.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        let result = await AsyncProcessRunner.run(
            process,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            timeoutSeconds: configuration.timeoutSeconds
        )
        return AgentUtilityRunResult(
            exitCode: result.exitCode,
            output: OpenCodeCLIRuntime.extractUtilityText(from: result.stdout),
            error: result.stderr
        )
    }
}
