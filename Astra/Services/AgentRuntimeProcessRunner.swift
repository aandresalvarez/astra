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
    private var currentProcess: AgentRuntimeProcessControl?

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeAdapter,
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
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let plan = adapter.makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
            prompt: prompt,
            task: task,
            workspacePath: workspacePath,
            executablePath: executablePath,
            copilotHome: homeDirectory,
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            permissionManifest: permissionManifest,
            timeoutSeconds: timeoutSeconds
        ))
        return await runProcess(
            adapter: adapter,
            plan: plan,
            task: task,
            permissionManifest: permissionManifest,
            budgetEnforcementMode: budgetEnforcementMode,
            timeoutSeconds: timeoutSeconds,
            onLine: onLine
        )
    }

    @MainActor
    private func runProcess(
        adapter: any AgentRuntimeAdapter,
        plan: AgentRuntimeProcessLaunchPlan,
        task: AgentTask,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
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
                environment: plan.environment
            )

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: plan.runtime.supportsAstraRunProtocol
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
                onLine(line, plan.parsesJSONLines)
                for parsed in adapter.parseProcessEvents(line: line, parsesJSONLines: plan.parsesJSONLines) {
                    for filtered in eventPipeline.process(parsed) {
                        _ = monitor.processEvent(filtered, process: process)
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

            currentProcess = process
            monitor.startWatchdog(process: process)
        }
    }

    static func copilotAdditionalPaths(for task: AgentTask) -> [String] {
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
        Array(Set(TaskCapabilityResolver(task: task).allLocalTools.compactMap { tool in
            guard tool.toolType != "mcp" else { return nil }
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        })).sorted()
    }

    @MainActor
    static func effectiveTokenBudget(for task: AgentTask) -> Int {
        let baseBudget = task.tokenBudget
        if baseBudget == 0 {
            return Int.max
        }
        if task.useAgentTeam {
            let tokenBudget = baseBudget * max(2, task.teamSize)
            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "event": "team_budget_scaled",
                "base_budget": String(baseBudget),
                "team_size": String(max(2, task.teamSize)),
                "token_budget": String(tokenBudget)
            ])
            return tokenBudget
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
        var env = ProcessInfo.processInfo.environment
        var pathParts = [env["PATH"] ?? ""]
        pathParts.append(contentsOf: pathPrefix(for: task, taskEnv: taskEnv))
        var pathSuffix = RuntimePathResolver.shellPathSuffix
        if hasActiveCLITools(task) || taskEnv["ASTRA_BROWSER_URL"] != nil {
            pathSuffix += ":\(RuntimePathResolver.astraToolsPath)"
        }
        pathParts.append(pathSuffix)
        env["PATH"] = pathParts.filter { !$0.isEmpty }.joined(separator: ":")
        if includeClaudeTeamFlag {
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        }
        for (key, value) in claudeProviderEnvironment() {
            env[key] = value
        }
        for (key, value) in taskEnv {
            env[key] = value
        }
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
            let existing = try? String(contentsOfFile: shimPath, encoding: .utf8)
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
    static func scopedEnvironmentVariables(for task: AgentTask) -> [String: String] {
        var taskEnv = TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables
        if hasStanfordOutlookMailAccess(task) {
            taskEnv["ASTRA_CHANNEL"] = AppChannel.current.rawValue
            taskEnv["ASTRA_MAIL_REGISTRY_PATH"] = StanfordOutlookMail.registryURL.path
        }
        for (key, value) in ShelfBrowserBridgeRegistry.shared.environmentVariables(for: task.id) {
            taskEnv[key] = value
        }
        return taskEnv
    }

    @MainActor
    static func hasActiveCLITools(_ task: AgentTask) -> Bool {
        TaskCapabilityResolver(task: task).allLocalTools.contains { tool in
            tool.toolType != "mcp" && !tool.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @MainActor
    private static func hasStanfordOutlookMailAccess(_ task: AgentTask) -> Bool {
        TaskCapabilityResolver(task: task).allConnectors.contains { $0.isStanfordOutlookMail } ||
            TaskCapabilityResolver(task: task).allLocalTools.contains { $0.command == StanfordOutlookMail.toolCommand }
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
