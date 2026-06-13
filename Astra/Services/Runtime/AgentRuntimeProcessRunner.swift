import Foundation
import ASTRACore

struct AgentRuntimeBudgetProfile: Sendable, Equatable {
    let runtime: AgentRuntimeID
    let launchOverheadTokens: Int

    func estimatedLaunchInputTokens(prompt: String) -> Int {
        AgentProcessMonitor.estimatedTokenCount(for: prompt) + launchOverheadTokens
    }

    static func profile(for runtime: AgentRuntimeID) -> AgentRuntimeBudgetProfile {
        AgentRuntimeAdapterRegistry.adapter(for: runtime).budgetProfile
    }
}

final class AgentRuntimeProcessRunner {
    typealias SandboxSettingsProvider = @MainActor (PermissionPolicy) -> ExecutionSandboxSettings

    private var currentProcess: AgentRuntimeProcessControl?
    private let sandboxSettingsProvider: SandboxSettingsProvider

    init(sandboxSettingsProvider: @escaping SandboxSettingsProvider = { permissionPolicy in
        ExecutionSandboxSettings.current(permissionPolicy: permissionPolicy)
    }) {
        self.sandboxSettingsProvider = sandboxSettingsProvider
    }

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    /// Either a launch plan ready to run, or a fail-closed result that blocks the
    /// run (strict sandbox enforcement when the sandbox cannot be applied).
    enum SandboxedPlanOutcome {
        case plan(AgentRuntimeProcessLaunchPlan)
        case blocked(AgentProcessResult)
    }

    /// Pure mapping from a sandbox decision to a launch outcome. Extracted from
    /// `sandboxedPlan` so the security-critical branch — `failClosed` MUST block
    /// the run and never fall through to running unconfined — is unit-testable
    /// without spawning a process or constructing a full adapter. A regression
    /// that turned `.failClosed` into `.plan` would otherwise run the provider
    /// unconfined under strict/autonomous with no test to catch it.
    static func sandboxOutcome(
        for decision: ExecutionSandboxDecision,
        originalPlan: AgentRuntimeProcessLaunchPlan
    ) -> SandboxedPlanOutcome {
        switch decision {
        case .applied(let wrapped, _):
            return .plan(wrapped)
        case .skipped, .fallback:
            return .plan(originalPlan)
        case .failClosed(let reason):
            let message = "ASTRA could not apply the macOS execution sandbox (\(reason)) and strict enforcement is enabled, so the run was blocked."
            return .blocked(AgentProcessResult(
                exitCode: -1,
                error: message,
                runtimeStopReason: "sandbox_unavailable",
                runtimeStopMessage: message
            ))
        }
    }

    /// Builds the launch plan and applies the macOS execution sandbox to it.
    /// Returns the (possibly wrapped) plan, or — under strict enforcement when
    /// the sandbox cannot be applied — a fail-closed `AgentProcessResult` so the
    /// run never proceeds unconfined. All decisions are audited.
    /// Internal (not private) so the sandbox wiring — decision, auditing, and the
    /// fail-closed translation — is unit-testable with a fake adapter without
    /// spawning a process.
    @MainActor
    func sandboxedPlan(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        context: AgentRuntimeProcessLaunchContext
    ) -> SandboxedPlanOutcome {
        let plan = adapter.makeProcessLaunchPlan(context: context)
        // Use the run's effective permission policy (an execution-policy override
        // wins over the base policy) so best-effort correctly escalates to strict
        // for override-autonomous runs — matching how the preflight manifest
        // resolves the sandbox tier.
        let effectivePermissionPolicy = context.executionPolicy.permissionPolicyOverride ?? context.permissionPolicy
        let settings = sandboxSettingsProvider(effectivePermissionPolicy)
        // Multi-path workspaces: the agent is granted the workspace's additional
        // paths + input dirs (same set passed to providers via `--add-dir` and
        // honored by the in-band policy guard), so include them in the sandbox's
        // writable allowlist or the kernel would block legitimate writes.
        let decision = ExecutionSandbox.decide(
            plan: plan,
            providerHomeDirectory: context.providerHomeDirectory,
            additionalWritablePaths: Self.runtimeAdditionalPaths(for: context.task),
            settings: settings
        )
        let taskID = context.task.id
        switch decision {
        case .applied(_, let writableRoots):
            AppLogger.audit(.sandboxApplied, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "read_scope": settings.readScope.rawValue,
                "read_scope_audit": String(settings.readScope == .audit),
                "writable_root_count": String(writableRoots.count),
                "allow_network": String(settings.allowNetwork)
            ], level: .debug)
        case .skipped(let reason):
            AppLogger.audit(.sandboxSkipped, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "reason": reason
            ], level: .debug)
        case .fallback(let reason):
            AppLogger.audit(.sandboxFallback, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "reason": reason
            ], level: .warning)
        case .failClosed(let reason):
            AppLogger.audit(.sandboxFailed, category: "Worker", taskID: taskID, fields: [
                "runtime": plan.runtime.rawValue,
                "enforcement": settings.enforcement.rawValue,
                "reason": reason
            ], level: .error)
        }

        return Self.sandboxOutcome(for: decision, originalPlan: plan)
    }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        permissionManifest: RunPermissionManifest? = nil,
        budgetEnforcementMode: BudgetEnforcementMode = .configuredDefault,
        timeoutSeconds: TimeInterval,
        phase: String = "run",
        contextText: String = "",
        nativeContinuationSessionID: String? = nil,
        runID: UUID? = nil,
        liveApprovalsEnabled: Bool = false,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)? = nil,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let launchContext = AgentRuntimeProcessLaunchContext(
            prompt: prompt,
            task: task,
            workspacePath: workspacePath,
            executablePath: executablePath,
            providerHomeDirectory: homeDirectory,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            permissionManifest: permissionManifest,
            timeoutSeconds: timeoutSeconds,
            phase: phase,
            contextText: contextText,
            nativeContinuationSessionID: nativeContinuationSessionID,
            runID: runID,
            liveApprovalsEnabled: liveApprovalsEnabled && onInteractiveAsk != nil
        )
        if let sharedStateKey = adapter.sharedLaunchStateKey(context: launchContext) {
            do {
                try await AgentRuntimeSharedStateGate.shared.acquire(sharedStateKey)
            } catch is CancellationError {
                return AgentProcessResult(
                    exitCode: -1,
                    error: "Task cancelled before acquiring provider shared state.",
                    runtimeStopReason: "cancelled",
                    runtimeStopMessage: "Task cancelled before acquiring provider shared state."
                )
            } catch {
                return AgentProcessResult(exitCode: -1, error: error.localizedDescription)
            }
            let plan: AgentRuntimeProcessLaunchPlan
            switch sandboxedPlan(adapter: adapter, context: launchContext) {
            case .plan(let resolvedPlan):
                plan = resolvedPlan
            case .blocked(let blockedResult):
                await AgentRuntimeSharedStateGate.shared.release(sharedStateKey)
                return blockedResult
            }
            let result = await runProcess(
                adapter: adapter,
                plan: plan,
                task: task,
                permissionManifest: permissionManifest,
                budgetEnforcementMode: budgetEnforcementMode,
                timeoutSeconds: timeoutSeconds,
                onInteractiveAsk: onInteractiveAsk,
                onLine: onLine
            )
            await AgentRuntimeSharedStateGate.shared.release(sharedStateKey)
            return result
        }

        let plan: AgentRuntimeProcessLaunchPlan
        switch sandboxedPlan(adapter: adapter, context: launchContext) {
        case .plan(let resolvedPlan):
            plan = resolvedPlan
        case .blocked(let blockedResult):
            return blockedResult
        }
        return await runProcess(
            adapter: adapter,
            plan: plan,
            task: task,
            permissionManifest: permissionManifest,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            onInteractiveAsk: onInteractiveAsk,
            onLine: onLine
        )
    }

    @MainActor
    private func runProcess(
        adapter: any AgentRuntimeProcessEventParsing,
        plan: AgentRuntimeProcessLaunchPlan,
        task: AgentTask,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)? = nil,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let tokenBudget = Self.effectiveTokenBudget(for: task)
        let taskID = task.id

        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var hasResumed = false
            let resumeOnce: (AgentProcessResult) -> Void = { result in
                resumeLock.lock()
                guard !hasResumed else { resumeLock.unlock(); return }
                hasResumed = true
                resumeLock.unlock()
                continuation.resume(returning: result)
            }

            AppLogger.audit(
                .runtimeProviderDetected,
                category: "Worker",
                taskID: task.id,
                fields: plan.providerDetectedFields,
                level: .debug,
                fieldMaxLength: 220
            )
            AppLogger.audit(
                .runtimeCommandPlanned,
                category: "Worker",
                taskID: task.id,
                fields: plan.commandPlannedFields,
                level: .debug
            )

            for directory in plan.directoriesToCreate where !directory.isEmpty {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }

            let process = AgentExecutionScopedProcess(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                currentDirectory: plan.currentDirectory,
                environment: plan.environment,
                providesStdinChannel: plan.interactiveAsk != nil
            )

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeAdapterRegistry.supportsAstraRunProtocol(for: plan.runtime)
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: tokenBudget,
                budgetEnforcementMode: budgetEnforcementMode,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                taskID: task.id,
                policyGuard: permissionManifest.map(AgentRuntimePolicyGuard.init)
            )

            let handleLine: (String) -> Void = { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if plan.interactiveAsk != nil,
                   let control = ClaudeControlProtocol.controlRequest(from: trimmed) {
                    Self.answerControlRequest(
                        control,
                        process: process,
                        monitor: monitor,
                        taskID: taskID,
                        onInteractiveAsk: onInteractiveAsk
                    )
                    return
                }
                onLine(line, plan.parsesJSONLines)
                for parsed in adapter.parseProcessEvents(line: line, parsesJSONLines: plan.parsesJSONLines) {
                    for filtered in eventPipeline.process(parsed) {
                        _ = monitor.processEvent(filtered, process: process)
                    }
                    // Stream-json input providers wait for the next stdin
                    // message after a turn ends; EOF on the terminal result is
                    // what lets the process exit.
                    if plan.interactiveAsk != nil, case .result = parsed {
                        process.closeStdinChannel()
                    }
                }
                if let message = adapter.blockingProcessPermissionMessage(
                    line: line,
                    parsesJSONLines: plan.parsesJSONLines
                ) {
                    errorOutput.append(message)
                    process.terminate()
                }
            }

            process.stdoutFileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }

                lineBuffer.appendAndProcessLines(chunk, handleLine)
            }

            process.stderrFileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    errorOutput.append(string)
                }
            }

            process.terminationHandler = { proc in
                InFlightPermissionCenter.shared.failAll(taskID: taskID)
                proc.stdoutFileHandle.readabilityHandler = nil
                proc.stderrFileHandle.readabilityHandler = nil
                if let chunk = String(
                    data: proc.stdoutFileHandle.readDataToEndOfFile(),
                    encoding: .utf8
                ), !chunk.isEmpty {
                    lineBuffer.appendAndProcessLines(chunk, handleLine)
                }
                if let string = String(
                    data: proc.stderrFileHandle.readDataToEndOfFile(),
                    encoding: .utf8
                ), !string.isEmpty {
                    errorOutput.append(string)
                }
                handleLine(lineBuffer.drainRemaining())
                for filtered in eventPipeline.flushParsedEvents() {
                    _ = monitor.processEvent(filtered, process: process)
                }
                let error = errorOutput.value
                Self.cleanupBrowserToolShim(at: plan.browserShimDirectory, taskID: taskID)
                resumeOnce(AgentProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    error: error.isEmpty ? nil : error,
                    providerVersion: plan.providerVersion,
                    policyViolation: monitor.policyViolation,
                    policyViolationMessage: monitor.policyViolationMessage,
                    policyApprovalRequired: monitor.policyApprovalRequired,
                    policyApprovalMessage: monitor.policyApprovalMessage,
                    runtimeStopReason: monitor.runtimeStopReason,
                    runtimeStopMessage: monitor.runtimeStopMessage,
                    budgetExceeded: monitor.budgetExceeded,
                    budgetWarning: monitor.budgetWarning,
                    finalReportedBudgetExceededAfterCompletion: monitor.finalReportedBudgetExceededAfterCompletion,
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded
                ))
            }

            do {
                try process.run()
            } catch {
                Self.cleanupBrowserToolShim(at: plan.browserShimDirectory, taskID: taskID)
                resumeOnce(AgentProcessResult(
                    exitCode: -1,
                    error: error.localizedDescription,
                    providerVersion: plan.providerVersion
                ))
                return
            }

            if let interactiveAsk = plan.interactiveAsk {
                process.writeStdinLine(interactiveAsk.initialStdinMessage)
            }
            currentProcess = process
            monitor.startWatchdog(process: process)
        }
    }

    /// Answers a provider control request. `can_use_tool` asks are routed to the
    /// worker's hook (which surfaces them in the UI and awaits the user); every
    /// other subtype gets an immediate error response so the provider never
    /// blocks on an unanswered request. A heartbeat keeps the idle watchdog from
    /// killing the run while the user decides.
    private static func answerControlRequest(
        _ control: ClaudeControlProtocol.ControlRequest,
        process: AgentExecutionScopedProcess,
        monitor: AgentProcessMonitor,
        taskID: UUID,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?
    ) {
        guard control.subtype == "can_use_tool", let onInteractiveAsk else {
            if let response = ClaudeControlProtocol.errorResponse(
                requestID: control.requestID,
                message: "ASTRA does not handle control requests of subtype \(control.subtype)."
            ) {
                process.writeStdinLine(response)
            }
            return
        }
        let request = AgentInteractiveAskRequest(
            requestID: control.requestID,
            toolName: control.toolName ?? "Tool",
            inputSummary: control.inputSummary,
            commandText: control.commandText
        )
        let heartbeat = Task.detached {
            while !Task.isCancelled {
                monitor.recordActivity()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        Task.detached {
            let outcome = await onInteractiveAsk(request)
            heartbeat.cancel()
            monitor.recordActivity()
            let response: String?
            switch outcome {
            case .allow:
                response = ClaudeControlProtocol.allowResponse(for: control)
            case .deny(let message):
                response = ClaudeControlProtocol.denyResponse(for: control, message: message)
            }
            if let response {
                process.writeStdinLine(response)
            }
        }
    }

    static func copilotAdditionalPaths(for task: AgentTask) -> [String] {
        runtimeAdditionalPaths(for: task)
    }

    static func runtimeAdditionalPaths(for task: AgentTask) -> [String] {
        var paths = TaskWorkspaceAccess(task: task).runtimeAdditionalPaths
        if !TaskWorkspaceAccess(task: task).effectiveWorkspacePath.isEmpty {
            paths.append(TaskWorkspaceAccess(task: task).effectiveWorkspacePath)
        }
        if !TaskWorkspaceAccess(task: task).taskFolder.isEmpty {
            paths.append(TaskWorkspaceAccess(task: task).taskFolder)
        }
        return Array(Set(paths.filter { !$0.isEmpty })).sorted()
    }

    @MainActor
    static func copilotLocalToolCommands(for task: AgentTask) -> [String] {
        runtimeLocalToolCommands(for: task)
    }

    @MainActor
    static func runtimeLocalToolCommands(for task: AgentTask) -> [String] {
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope()
        return Array(Set(capabilityScope.localTools.compactMap { tool in
            guard tool.toolType != "mcp" else { return nil }
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        })).sorted()
    }

    @MainActor
    static func effectiveTokenBudget(for task: AgentTask) -> Int {
        let baseBudget = task.tokenBudget
        let tokenBudget = effectiveTokenBudget(
            baseBudget: baseBudget,
            usesAgentTeam: task.useAgentTeam,
            teamSize: task.teamSize
        )
        if task.useAgentTeam, baseBudget != 0 {
            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "event": "team_budget_scaled",
                "base_budget": String(baseBudget),
                "team_size": String(max(2, task.teamSize)),
                "token_budget": String(tokenBudget)
            ])
        }
        return tokenBudget
    }

    static func effectiveTokenBudget(baseBudget: Int, usesAgentTeam: Bool, teamSize: Int) -> Int {
        if baseBudget == 0 {
            return Int.max
        }
        if usesAgentTeam {
            return baseBudget * max(2, teamSize)
        }
        return baseBudget
    }

    static func estimatedLaunchInputTokens(prompt: String, runtime: AgentRuntimeID) -> Int {
        AgentRuntimeBudgetProfile.profile(for: runtime).estimatedLaunchInputTokens(prompt: prompt)
    }

    static func launchOverheadTokens(for runtime: AgentRuntimeID) -> Int {
        AgentRuntimeBudgetProfile.profile(for: runtime).launchOverheadTokens
    }

    static func model(_ model: String, for runtime: AgentRuntimeID) -> String {
        RuntimeModelAvailability.normalizedModel(model, for: runtime)
    }

    static func fileModificationTimestamp(_ path: String) -> String {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            return "unknown"
        }
        return String(Int(modified.timeIntervalSince1970))
    }

    @MainActor
    static func environment(
        phase: String,
        task: AgentTask,
        taskEnv: [String: String],
        includeClaudeTeamFlag: Bool
    ) -> [String: String] {
        let prefixPaths = pathPrefix(for: task, taskEnv: taskEnv)
        var extraVars: [String: String] = [:]
        if includeClaudeTeamFlag {
            extraVars["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }
        for (key, value) in claudeProviderEnvironment() {
            extraVars[key] = value
        }
        for (key, value) in taskEnv {
            extraVars[key] = value
        }
        let env = RuntimeProcessEnvironment.enriched(
            additionalPaths: prefixPaths,
            extraVariables: extraVars
        )
        if !taskEnv.isEmpty {
            AppLogger.audit(.workerEnvironmentInjected, category: "Worker", taskID: task.id, fields: [
                "phase": phase,
                "env_count": String(taskEnv.count)
            ])
        }
        return env
    }

    @MainActor
    static func pathPrefix(for task: AgentTask, taskEnv: [String: String]) -> [String] {
        guard let browserShimDirectory = prepareBrowserToolShimIfNeeded(task: task, taskEnv: taskEnv) else {
            return []
        }
        return [browserShimDirectory]
    }

    @MainActor
    static func browserToolShimDirectory(for task: AgentTask, taskEnv: [String: String]) -> String? {
        guard taskEnv["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let taskFolder = TaskWorkspaceAccess(task: task).taskFolder
        guard !taskFolder.isEmpty else { return nil }
        return (taskFolder as NSString).appendingPathComponent(".runtime-bin")
    }

    @MainActor
    static func prepareBrowserToolShimIfNeeded(
        task: AgentTask,
        taskEnv: [String: String],
        fileManager: FileManager = .default,
        realToolPath: String = (RuntimePathResolver.astraToolsPath as NSString).appendingPathComponent("astra-browser")
    ) -> String? {
        guard let endpoint = taskEnv["ASTRA_BROWSER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty,
              endpoint.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        let browserToken = taskEnv["ASTRA_BROWSER_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if browserToken?.rangeOfCharacter(from: .newlines) != nil {
            return nil
        }

        guard fileManager.isExecutableFile(atPath: realToolPath),
              realToolPath.rangeOfCharacter(from: .newlines) == nil,
              !TaskWorkspaceAccess(task: task).taskFolder.isEmpty else {
            return nil
        }

        let shimDirectory = (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent(".runtime-bin")
        let shimPath = (shimDirectory as NSString).appendingPathComponent("astra-browser")
        let tokenExport = browserToken?.isEmpty == false
            ? "\nexport ASTRA_BROWSER_TOKEN=\(shellSingleQuoted(browserToken!))"
            : ""
        let script = """
        #!/bin/sh
        export ASTRA_BROWSER_URL=\(shellSingleQuoted(endpoint))\(tokenExport)
        exec \(shellSingleQuoted(realToolPath)) "$@"
        """

        do {
            try fileManager.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimDirectory)
            let existing = try? HostFileAccessBroker(fileManager: fileManager).readString(
                at: URL(fileURLWithPath: shimPath),
                encoding: .utf8,
                intent: .astraManagedStorage(root: URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder, isDirectory: true))
            )
            if existing != script {
                try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimPath)
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: task.id, fields: [
                "action": "browser_tool_shim",
                "result": "ready",
                "has_endpoint": "true",
                "has_token": String(browserToken?.isEmpty == false)
            ], level: .debug)
            return shimDirectory
        } catch {
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: task.id, fields: [
                "action": "browser_tool_shim",
                "result": "failed",
                "error": error.localizedDescription
            ], level: .warning)
            return nil
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func cleanupBrowserToolShim(at directory: String?, taskID: UUID) {
        guard let directory, !directory.isEmpty else { return }
        do {
            try FileManager.default.removeItem(atPath: directory)
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: taskID, fields: [
                "action": "browser_tool_shim",
                "result": "cleaned"
            ], level: .debug)
        } catch {
            guard FileManager.default.fileExists(atPath: directory) else { return }
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: taskID, fields: [
                "action": "browser_tool_shim",
                "result": "cleanup_failed",
                "error": error.localizedDescription
            ], level: .warning)
        }
    }

    /// Resolves the Claude provider env vars from `@AppStorage` so the spawned
    /// `claude` CLI inherits the user's chosen routing (Anthropic vs Vertex).
    /// GUI apps don't pick up shell env from `.zshrc`, so this is the only
    /// place Vertex routing reaches the runtime.
    ///
    /// For Vertex, model aliases matter just as much as the routing flag —
    /// the Anthropic-format model IDs ASTRA passes via `--model` (e.g.
    /// `claude-haiku-4-5-20251001`) don't exist as-is on Vertex. The
    /// `ANTHROPIC_DEFAULT_*_MODEL` env vars remap them to Vertex aliases
    /// (e.g. `claude-haiku-4-5@20251001`). `ANTHROPIC_MODEL` and
    /// `ANTHROPIC_SMALL_FAST_MODEL` are auto-derived from the opus/haiku
    /// fields to match common Vertex setups.
    static func claudeProviderEnvironment() -> [String: String] {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: AppStorageKeys.claudeProvider) ?? ClaudeProvider.anthropic.rawValue
        guard let provider = ClaudeProvider(rawValue: raw) else { return [:] }
        switch provider {
        case .anthropic:
            return [:]
        case .vertex:
            let project = trimmedDefault(AppStorageKeys.claudeVertexProjectID)
            let region = trimmedDefault(AppStorageKeys.claudeVertexRegion)
            guard !project.isEmpty, !region.isEmpty else { return [:] }

            var env: [String: String] = [
                "CLAUDE_CODE_USE_VERTEX": "1",
                "ANTHROPIC_VERTEX_PROJECT_ID": project,
                "CLOUD_ML_REGION": region
            ]

            let opus = trimmedDefault(AppStorageKeys.claudeVertexOpusModel)
            let sonnet = trimmedDefault(AppStorageKeys.claudeVertexSonnetModel)
            let haiku = trimmedDefault(AppStorageKeys.claudeVertexHaikuModel)

            if !opus.isEmpty {
                env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = opus
                // ANTHROPIC_MODEL is the CLI's selected model when no --model
                // flag is passed. Mirror Anthropic's recommended setup where
                // it equals the opus alias.
                env["ANTHROPIC_MODEL"] = opus
            }
            if !sonnet.isEmpty {
                env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = sonnet
            }
            if !haiku.isEmpty {
                env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
                // The "small fast model" used internally by claude-code for
                // helper calls (title gen, summarisation). Pair with haiku.
                env["ANTHROPIC_SMALL_FAST_MODEL"] = haiku
            }

            return env
        }
    }

    private static func trimmedDefault(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When Vertex routing is on, translate an Anthropic-format model ID
    /// (e.g. `claude-haiku-4-5-20251001`) into the Vertex alias the user
    /// configured in Settings (e.g. `claude-haiku-4-5@20251001`).
    /// Tier is detected by family prefix (`haiku` / `sonnet` / `opus`).
    /// If Vertex is off, or no alias is set for that tier, the original
    /// model ID is returned unchanged so non-Vertex flows are untouched.
    ///
    /// `ANTHROPIC_DEFAULT_*_MODEL` env vars only kick in when the CLI is
    /// invoked with the bare tier name (`haiku`); ASTRA passes specific
    /// dated IDs via `--model`, so we have to do the substitution here.
    static func translatedModelForProvider(_ model: String) -> String {
        let raw = UserDefaults.standard.string(forKey: AppStorageKeys.claudeProvider)
            ?? ClaudeProvider.anthropic.rawValue
        guard ClaudeProvider(rawValue: raw) == .vertex else { return model }

        let lower = model.lowercased()
        let key: String
        if lower.hasPrefix("claude-haiku") {
            key = AppStorageKeys.claudeVertexHaikuModel
        } else if lower.hasPrefix("claude-sonnet") {
            key = AppStorageKeys.claudeVertexSonnetModel
        } else if lower.hasPrefix("claude-opus") {
            key = AppStorageKeys.claudeVertexOpusModel
        } else {
            return model
        }

        let alias = trimmedDefault(key)
        return alias.isEmpty ? model : alias
    }

    @MainActor
    static func scopedEnvironmentVariables(for task: AgentTask, contextText: String = "") -> [String: String] {
        let capabilityScope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        var taskEnv = capabilityScope.resolver.resolvedEnvironmentVariables
        if hasStanfordOutlookMailAccess(in: capabilityScope) {
            taskEnv["ASTRA_CHANNEL"] = AppChannel.current.rawValue
            taskEnv["ASTRA_MAIL_REGISTRY_PATH"] = StanfordOutlookMail.registryURL.path
        }
        if TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText) {
            for (key, value) in ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id) {
                guard isBrowserBridgeEnvKeyAllowed(key) else {
                    AppLogger.audit(.capabilityChatContext, category: "Capabilities", taskID: task.id, fields: [
                        "source": "browser_bridge_env",
                        "result": "non_namespaced_key_dropped",
                        "key": key
                    ], level: .warning)
                    continue
                }
                taskEnv[key] = value
            }
        }
        return taskEnv
    }

    /// Namespace invariant for the Shelf browser bridge: it may only
    /// contribute its own `ASTRA_BROWSER_*` variables, never overwrite
    /// PATH/HOME or connector credentials. The trailing underscore keeps the
    /// namespace explicit so an unrelated future `ASTRA_BROWSERX` key can't
    /// slip through.
    static func isBrowserBridgeEnvKeyAllowed(_ key: String) -> Bool {
        key.hasPrefix("ASTRA_BROWSER_")
    }

    @MainActor
    static func hasActiveCLITools(_ task: AgentTask) -> Bool {
        TaskCapabilityResolver(task: task).promptScope().localTools.contains { tool in
            tool.toolType != "mcp" && !tool.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasStanfordOutlookMailAccess(in capabilityScope: TaskCapabilityPromptScope) -> Bool {
        capabilityScope.connectors.contains { $0.isStanfordOutlookMail } ||
            capabilityScope.localTools.contains { $0.command == StanfordOutlookMail.toolCommand }
    }

    static func providerAllowedTools(
        for runtime: AgentRuntimeID,
        baseAllowedTools: [String],
        permissionManifest: RunPermissionManifest?
    ) -> [String] {
        guard let permissionManifest,
              permissionManifest.providerID == runtime,
              !permissionManifest.approvalGrants.isEmpty else {
            return baseAllowedTools
        }
        let runtimeGrants = PermissionBroker.providerRuntimeGrantStrings(
            for: permissionManifest.approvalGrants,
            runtime: runtime
        )
        return Array(Set(baseAllowedTools + runtimeGrants)).sorted()
    }

    static func providerRuntimeSupportToolPermissions(
        for runtime: AgentRuntimeID,
        permissionManifest: RunPermissionManifest?
    ) -> [String] {
        guard let permissionManifest,
              permissionManifest.providerID == runtime else {
            return []
        }
        return Array(Set(permissionManifest.providerRender.runtimeSupportTools.compactMap { descriptor in
            let permission = descriptor.providerNativePermission?.trimmingCharacters(in: .whitespacesAndNewlines)
            return permission?.isEmpty == false ? permission : nil
        })).sorted()
    }

    static func providerAskFirstToolPermissions(
        for runtime: AgentRuntimeID,
        permissionManifest: RunPermissionManifest?
    ) -> [String] {
        guard let permissionManifest,
              permissionManifest.providerID == runtime,
              permissionManifest.providerRender.permissionMode == PermissionPolicy.restricted.rawValue else {
            return []
        }

        switch runtime {
        case .claudeCode:
            return Array(Set(permissionManifest.providerRender.askFirstTools.compactMap(claudeProviderToolPermission))).sorted()
        default:
            return []
        }
    }

    private static func claudeProviderToolPermission(_ tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let openParen = trimmed.firstIndex(of: "("),
           trimmed.hasSuffix(")") {
            let rawTool = String(trimmed[..<openParen])
            guard let canonicalTool = canonicalClaudeToolName(rawTool) else { return nil }
            let patternStart = trimmed.index(after: openParen)
            let pattern = String(trimmed[patternStart..<trimmed.index(before: trimmed.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ":", with: " ")
            return pattern.isEmpty ? canonicalTool : "\(canonicalTool)(\(pattern))"
        }

        return canonicalClaudeToolName(trimmed)
    }

    private static func canonicalClaudeToolName(_ tool: String) -> String? {
        switch tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "read", "view": return "Read"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "write", "create": return "Write"
        case "edit": return "Edit"
        case "multiedit", "multi_edit": return "MultiEdit"
        case "bash", "shell": return "Bash"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "agent": return "Agent"
        default: return nil
        }
    }

    static func ensureSubAgentPermissions(
        at workspacePath: String,
        policy: PermissionPolicy,
        allowedTools: [String]
    ) {
        if ClaudeSettingsStore.ensureSubAgentPermissions(
            at: workspacePath,
            policy: policy,
            allowedTools: allowedTools
        ) {
            AppLogger.audit(.workerStarted, category: "Worker", fields: [
                "event": "subagent_permissions_ensured",
                "policy": policy.rawValue
            ])
        }
    }
}
