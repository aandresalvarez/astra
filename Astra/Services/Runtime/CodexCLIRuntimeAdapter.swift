import Foundation
import SwiftData
import ASTRACore

struct CodexCLIRuntimeAdapterProvider: AgentRuntimeAdapterProvider {
    let providerID = "codex-cli"
    var runtimeAdapters: [any AgentRuntimeAdapter] {
        [CodexCLIRuntimeAdapter()]
    }
}

struct CodexCLIRuntimeAdapter: AgentRuntimeAdapter {
    var id: AgentRuntimeID { descriptor.id }
    let descriptor = AgentRuntimeDescriptor(
        id: .codexCLI,
        displayName: "Codex CLI",
        executableName: CodexCLIRuntime.executableName,
        installHint: "Install Codex CLI, then run `codex login` to authenticate.",
        authHint: "Run `codex login`, or verify the current login with `codex doctor`.",
        prerequisite: CommonCLIPrerequisites.codex,
        defaultModel: CodexCLIRuntime.defaultModelName(),
        defaultModels: CodexCLIRuntime.availableModelNames(),
        supportsAstraRunProtocol: true
    )
    let readinessCheckID = "codex-cli"
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .codexCLI, launchOverheadTokens: 0)
    let recordsStreamTelemetry = true
    let recordsInferredFileChanges = true

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? CodexCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
    }

    func missingExecutableAuditReason() -> String {
        "codex_cli_not_found"
    }

    func missingExecutableStopReason() -> String? {
        "missing_codex"
    }

    func missingExecutableMessage(executablePath _: String) -> String {
        "Codex CLI not found. Install Codex CLI, then authenticate with `codex login`."
    }

    func defaultStartEventPayload(task: AgentTask) -> String {
        "Codex started working on: \(task.goal)"
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
        "Codex finished."
    }

    func failurePayloadPrefix(phase _: String, exitCode: Int) -> String {
        "Codex exited with code \(exitCode)."
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
        CodexPolicyAdapter()
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
                    id: "codex-account",
                    title: "Codex account",
                    detail: "CLI is available. Run a readiness check to verify login status.",
                    state: .ready,
                    remediation: nil
                ))
            } else if let executable = cliStatus.executable {
                checks.append(await checkCodexAuth(executable: executable, probes: probes))
            }
        }
        return RuntimeReadinessReport(checks: checks)
    }

    private func checkCodexAuth(
        executable: String,
        probes: RuntimeReadinessProbeContext
    ) async -> RuntimeReadinessCheck {
        let result = await probes.run(path: executable, args: ["login", "status"])
        guard result.isSuccess else {
            return RuntimeReadinessCheck(
                id: "codex-account",
                title: "Codex account",
                detail: RuntimeReadinessDiagnostics.detail(
                    from: result,
                    fallback: "Codex login status did not pass."
                ),
                state: .blocked,
                remediation: CommonCLIPrerequisites.codex.authHint
            )
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        if RuntimeReadinessDiagnostics.showsAuthenticatedSession(output) {
            return RuntimeReadinessCheck(
                id: "codex-account",
                title: "Codex account",
                detail: "Codex reports an authenticated session.",
                state: .ready,
                remediation: nil
            )
        }

        return RuntimeReadinessCheck(
            id: "codex-account",
            title: "Codex account",
            detail: RuntimeReadinessDiagnostics.detail(
                from: result,
                fallback: "Codex responded, but no authenticated session was detected."
            ),
            state: .blocked,
            remediation: CommonCLIPrerequisites.codex.authHint
        )
    }

    func modelAvailabilityCheck(configuration _: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let models = CodexCLIRuntime.availableModelNames()
        RuntimeModelAvailability.persistAvailableModels(models, for: id, authority: modelAvailabilityAuthority)
        return RuntimeReadinessCheck(
            id: "codex-models",
            title: "Codex models",
            detail: "Available: \(models.joined(separator: ", "))",
            state: .ready,
            remediation: nil
        )
    }

    @MainActor
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
        let taskEnv = AgentRuntimeProcessRunner.scopedEnvironmentVariables(
            for: context.task,
            contextText: context.contextText
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let pathPrefix = AgentRuntimeProcessRunner.pathPrefix(for: context.task, taskEnv: taskEnv)
        let executable = context.executablePath.isEmpty ? CodexCLIRuntime.detectPath() : context.executablePath
        let providerVersion = CodexCLIRuntime.versionSummary(executablePath: executable)
        let model = AgentRuntimeProcessRunner.model(context.task.model, for: id)
        let providerModel = CodexCLIRuntime.resolvedModelName(model)
        let additionalPaths = AgentRuntimeProcessRunner.runtimeAdditionalPaths(for: context.task)
        let directoriesToCreate = CodexCLIRuntime.directoriesToCreate(
            providerHomeDirectory: context.providerHomeDirectory
        )

        let plan = CodexCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: context.prompt,
            model: providerModel,
            workspacePath: context.workspacePath,
            additionalPaths: additionalPaths,
            permissionPolicy: effectivePermissionPolicy,
            timeoutSeconds: context.timeoutSeconds,
            taskEnvironment: taskEnv,
            providerHomeDirectory: context.providerHomeDirectory,
            pathPrefix: pathPrefix,
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(context.task)
                || taskEnv["ASTRA_BROWSER_URL"] != nil
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
            directoriesToCreate: directoriesToCreate,
            providerDetectedFields: [
                "runtime": id.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!context.executablePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
                "executable_path": executable,
                "executable_mtime": AgentRuntimeProcessRunner.fileModificationTimestamp(executable),
                "provider_home_configured": String(!context.providerHomeDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ],
            commandPlannedFields: [
                "runtime": id.rawValue,
                "phase": context.phase,
                "model": model,
                "provider_model": providerModel,
                "permission_policy": effectivePermissionPolicy.rawValue,
                "parses_json_lines": String(plan.parsesJSONLines),
                "additional_paths_count": String(additionalPaths.count),
                "task_env_count": String(taskEnv.count),
                "uses_json": String(plan.arguments.contains("--json")),
                "uses_cd": String(plan.arguments.contains("--cd")),
                "uses_skip_git_repo_check": String(plan.arguments.contains("--skip-git-repo-check"))
            ]
        )
    }

    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] {
        CodexCLIRuntime.parseEvents(line: line, parsesJSONLines: parsesJSONLines)
    }

    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? {
        CodexCLIRuntime.blockingMessage(line: line, parsesJSONLines: parsesJSONLines)
    }

    func parseWorkerStreamEvents(line: String, parsesJSONLines: Bool) -> AgentRuntimeStreamEventBatch {
        AgentRuntimeStreamEventBatch(agentEvents: CodexCLIRuntime.parseAgentEvents(
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
        AgentEventRecorder.recordCodexEvent(
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
        let executable = configuredPath.isEmpty ? CodexCLIRuntime.detectPath() : configuredPath
        let model = AgentRuntimeProcessRunner.model(configuration.model, for: id)
        let permissionPolicy: PermissionPolicy = toolMode == .readOnly ? .interactive : .restricted
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: prompt,
            model: model,
            workspacePath: workspacePath,
            additionalPaths: [],
            permissionPolicy: permissionPolicy,
            timeoutSeconds: configuration.timeoutSeconds,
            taskEnvironment: [:],
            providerHomeDirectory: configuration.homeDirectory(for: id)
        )

        for directory in CodexCLIRuntime.directoriesToCreate(providerHomeDirectory: configuration.homeDirectory(for: id)) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

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
            output: CodexCLIRuntime.extractUtilityText(from: result.stdout),
            error: result.stderr
        )
    }
}
