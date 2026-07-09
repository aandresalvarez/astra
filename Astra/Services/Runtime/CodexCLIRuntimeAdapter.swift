import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

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
        supportsAstraRunProtocol: true,
        supportsNativeContinuation: true,
        supportsMCPServers: true
    )
    let readinessCheckID = "codex-cli"
    let budgetProfile = AgentRuntimeBudgetProfile(runtime: .codexCLI, launchOverheadTokens: 0)
    let recordsStreamTelemetry = true
    let recordsInferredFileChanges = true
    let providerRuntimeMessages = ProviderRuntimeMessages.codex

    func launchSettings(configuration: AgentRuntimeConfiguration) -> AgentRuntimeLaunchSettings {
        let configuredPath = configuration.executablePath(for: id)
        return AgentRuntimeLaunchSettings(
            executablePath: configuredPath.isEmpty ? CodexCLIRuntime.detectPath() : configuredPath,
            homeDirectory: configuration.homeDirectory(for: id)
        )
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

    func sessionTurnMessage(
        task: AgentTask,
        promptOverride: String?,
        startPayload: String?,
        sessionMessage _: String?,
        phase _: RunPhase
    ) -> String {
        providerRuntimeMessages.sessionTurnMessage(task: task, promptOverride: promptOverride, startPayload: startPayload)
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

    func installPlan(detectExecutable: @Sendable (String) -> String) -> RuntimeCLIInstallPlan? {
        guard let npm = detectedExecutable(named: "npm", detectExecutable: detectExecutable) else {
            return nil
        }
        return RuntimeCLIInstallPlan(
            runtime: id,
            installerName: "npm",
            executablePath: npm,
            arguments: ["install", "-g", "@openai/codex"],
            displayCommand: "npm install -g @openai/codex"
        )
    }

    func modelAvailabilityCheck(configuration _: RuntimeReadinessConfiguration) async -> RuntimeReadinessCheck {
        let models = CodexCLIRuntime.availableModelNames()
        await RuntimeModelAvailability.persistObservedAvailableModels(models, for: id, authority: modelAvailabilityAuthority)
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
            contextText: context.contextText,
            executionPolicy: context.executionPolicy
        )
        let browserShimDirectory = AgentRuntimeProcessRunner.browserToolShimDirectory(
            for: context.task,
            taskEnv: taskEnv
        )
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicy(default: context.permissionPolicy)
        let pathPrefix = AgentRuntimeProcessRunner.pathPrefix(for: context.task, taskEnv: taskEnv)
        let executable = context.executablePath.isEmpty ? CodexCLIRuntime.detectPath() : context.executablePath
        let providerVersion = CodexCLIRuntime.versionSummary(executablePath: executable)
        let model = AgentRuntimeProcessRunner.model(context.taskSnapshot.model, for: id)
        let providerModel = CodexCLIRuntime.resolvedModelName(model)
        let additionalPaths = AgentRuntimeProcessRunner.runtimeWritablePaths(for: context.task)
        let resumingNativeSession = !(context.nativeContinuationSessionID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: context.task)
        let mcpProjection = CodexMCPLaunchProjection.resolve(
            task: context.task,
            workspacePath: context.workspacePath,
            runID: context.runID,
            executionEnvironment: executionEnvironment,
            contextText: context.contextText,
            taskEnvironment: taskEnv
        )
        let launchTaskEnv = taskEnv
            .merging(mcpProjection.workspaceExecutorEnvironment) { current, _ in current }
            .merging(mcpProjection.hostControlEnvironment) { current, _ in current }
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: context.prompt,
            model: providerModel,
            workspacePath: context.workspacePath,
            additionalPaths: additionalPaths,
            permissionPolicy: effectivePermissionPolicy,
            timeoutSeconds: context.timeoutSeconds,
            taskEnvironment: launchTaskEnv,
            providerHomeDirectory: context.providerHomeDirectory,
            pathPrefix: pathPrefix,
            includeAstraToolsPath: AgentRuntimeProcessRunner.hasActiveCLITools(
                context.task,
                contextText: context.contextText
            )
                || taskEnv["ASTRA_BROWSER_URL"] != nil,
            mcpConfigArguments: mcpProjection.configArguments,
            resumeSessionID: context.nativeContinuationSessionID,
            permissionArguments: context.requiredProviderPolicyRender(for: id).codexLaunchPermissionArguments(
                resumingNativeSession: resumingNativeSession
            )
        )
        let directoriesToCreate = CodexCLIRuntime.directoriesToCreate(
            providerHomeDirectory: context.providerHomeDirectory,
            environment: plan.environment
        )
        let sandboxReadablePaths = CodexCLIRuntime.sandboxReadablePaths(
            providerHomeDirectory: context.providerHomeDirectory,
            environment: plan.environment
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
            sandboxReadablePaths: sandboxReadablePaths,
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
                "phase": context.phase.rawValue,
                "model": model,
                "provider_model": providerModel,
                "permission_policy": effectivePermissionPolicy.rawValue,
                "parses_json_lines": String(plan.parsesJSONLines),
                "additional_paths_count": String(additionalPaths.count),
                "task_env_count": String(taskEnv.count),
                "uses_json": String(plan.arguments.contains("--json")),
                "uses_cd": String(plan.arguments.contains("--cd")),
                "uses_skip_git_repo_check": String(plan.arguments.contains("--skip-git-repo-check")),
                "uses_native_continuation": String(context.nativeContinuationSessionID != nil),
                "sandbox_readable_path_count": String(sandboxReadablePaths.count),
                "mcp_server_count": String(mcpProjection.servers.count),
                "uses_mcp_config_overrides": String(!mcpProjection.configArguments.isEmpty),
                "mcp_server_ids": mcpProjection.servers.map(\.server.id).sorted().joined(separator: ","),
                "docker_workspace_executor": String(DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment)),
                "docker_workspace_executor_supported": String(mcpProjection.dockerWorkspaceExecutorSupported),
                "docker_workspace_executor_unsupported_detail": mcpProjection.dockerWorkspaceUnsupportedDetail,
                "docker_workspace_tool": DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment) ? DockerWorkspaceMCPProjection.providerToolPermission : "none",
                "docker_workspace_mcp_env_key_count": String(mcpProjection.workspaceExecutorEnvironment.count),
                "host_control_plane_tool_count": String(HostControlPlaneMCPProjection.toolNames.count),
                "host_control_plane_supported": String(mcpProjection.hostControlPlaneSupported),
                "host_control_plane_mcp_env_key_count": String(mcpProjection.hostControlEnvironment.count),
                "docker_workspace_container_env_key_count": String(DockerExecutionPlanner.credentialProjectionEnvironment(environment: executionEnvironment).count),
                "docker_workspace_credential_projection_count": String(executionEnvironment.effectiveCredentialProjections.count),
                "browser_bridge_mcp_tool": mcpProjection.browserBridgeMCPToolSupported ? BrowserBridgeMCPProjection.providerToolPermission : "none"
            ]
        )
    }

    func shouldClearStaleSessionOnFailure(phase: RunPhase, result: AgentProcessResult) -> Bool {
        guard phase == .resume else { return false }
        let error = result.error?.lowercased() ?? ""
        return error.contains("session") && (error.contains("not found") || error.contains("no such"))
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
        mode: AgentRuntimeRecordingMode,
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
            recordingMode: mode,
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
            providerHomeDirectory: configuration.homeDirectory(for: id),
            permissionArguments: ProviderPolicyRender.codexLaunchPermissionArguments(
                policy: permissionPolicy,
                resumingNativeSession: false
            )
        )

        // Utility prompts are one-shot structured generations (e.g. App Studio manifests), not
        // interactive agent sessions. Run codex at LOW reasoning so it answers promptly instead
        // of deliberating (and exploring the workspace) past the timeout and forcing a fallback.
        // Output validity is still enforced by the caller's validation + repair loop.
        var arguments = plan.arguments
        if let execIndex = arguments.firstIndex(of: "exec") {
            arguments.insert(contentsOf: ["-c", "model_reasoning_effort=\"low\""], at: execIndex + 1)
        }
        let processPlan = AgentRuntimeProcessLaunchPlan(
            runtime: id,
            executablePath: plan.executablePath,
            arguments: arguments,
            currentDirectory: workspacePath,
            environment: plan.environment,
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: plan.parsesJSONLines,
            directoriesToCreate: CodexCLIRuntime.directoriesToCreate(
                providerHomeDirectory: configuration.homeDirectory(for: id),
                environment: plan.environment
            ),
            sandboxReadablePaths: CodexCLIRuntime.sandboxReadablePaths(
                providerHomeDirectory: configuration.homeDirectory(for: id),
                environment: plan.environment
            )
        )
        return await AgentRuntimeProcessRunner().runUtilityProcess(
            AgentUtilityLaunchPlan(
                process: processPlan,
                providerHomeDirectory: configuration.homeDirectory(for: id),
                permissionPolicy: permissionPolicy,
                timeoutSeconds: configuration.timeoutSeconds
            ),
            outputTransform: { output in
                CodexCLIRuntime.extractUtilityText(from: output)
            }
        )
    }
}
