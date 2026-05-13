import Foundation
import ASTRACore

struct AgentRuntimeBudgetProfile: Sendable, Equatable {
    let runtime: AgentRuntimeID
    let launchOverheadTokens: Int

    func estimatedLaunchInputTokens(prompt: String) -> Int {
        AgentProcessMonitor.estimatedTokenCount(for: prompt) + launchOverheadTokens
    }

    static func profile(for runtime: AgentRuntimeID) -> AgentRuntimeBudgetProfile {
        switch runtime {
        case .claudeCode:
            // Claude Code includes its system prompt, tool schemas, and runtime context
            // in billed input. Recent local runs report roughly 120k input tokens before
            // user-visible output, so low budgets must be rejected before launch.
            return AgentRuntimeBudgetProfile(runtime: runtime, launchOverheadTokens: 120_000)
        case .copilotCLI:
            return AgentRuntimeBudgetProfile(runtime: runtime, launchOverheadTokens: 0)
        }
    }
}

final class AgentRuntimeProcessRunner {
    private var currentProcess: AgentRuntimeProcessControl?

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    @MainActor
    func runClaudeProcess(
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        claudePath: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        budgetEnforcementMode: BudgetEnforcementMode = .configuredDefault,
        timeoutSeconds: TimeInterval,
        onLine: @escaping (String) -> Void
    ) async -> AgentProcessResult {
        let taskEnv = Self.scopedEnvironmentVariables(for: task)
        let effectivePermissionPolicy = executionPolicy.permissionPolicy(default: permissionPolicy)
        let allowed = executionPolicy.allowedTools(default: task.resolvedProviderAllowedTools)
        let tokenBudget = Self.effectiveTokenBudget(for: task)

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
            let model = Self.model(task.model, for: .claudeCode)
            var args = ["-p", prompt, "--model", Self.translatedModelForProvider(model), "--output-format", "stream-json", "--verbose"]
            args += effectivePermissionPolicy.cliArguments
            Self.ensureSubAgentPermissions(at: workspacePath, policy: effectivePermissionPolicy, allowedTools: allowed)
            if task.maxTurns > 0 {
                args += ["--max-turns", String(task.maxTurns)]
            }
            if !allowed.isEmpty {
                args += ["--allowedTools"] + allowed
            }
            let processEnvironment = Self.environment(
                phase: "run",
                task: task,
                taskEnv: taskEnv,
                includeClaudeTeamFlag: true
            )

            AppLogger.audit(.runtimeProviderDetected, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.claudeCode.rawValue,
                "executable_configured": String(!claudePath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: claudePath)),
                "executable_path": claudePath,
                "executable_mtime": Self.fileModificationTimestamp(claudePath)
            ], level: .debug, fieldMaxLength: 220)

            AppLogger.audit(.runtimeCommandPlanned, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.claudeCode.rawValue,
                "phase": "run",
                "model": model,
                "provider_model": Self.translatedModelForProvider(model),
                "permission_policy": effectivePermissionPolicy.rawValue,
                "allowed_tools_count": String(allowed.count),
                "allowed_tools_override": String(executionPolicy.allowedToolsOverride != nil),
                "task_env_count": String(taskEnv.count),
                "max_turns": String(task.maxTurns)
            ], level: .debug)

            let process = AgentExecutionScopedProcess(
                executablePath: claudePath,
                arguments: args,
                currentDirectory: workspacePath,
                environment: processEnvironment
            )

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: tokenBudget,
                budgetEnforcementMode: budgetEnforcementMode,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                taskID: task.id
            )

            process.stdoutFileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }

                for line in lineBuffer.appendAndDrainLines(chunk) {
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        onLine(line)
                        for parsed in StreamEventParser.parseAll(line: line) {
                            for filtered in eventPipeline.process(parsed) {
                                _ = monitor.processEvent(filtered, process: process)
                            }
                        }
                    }
                }
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
                    for line in lineBuffer.appendAndDrainLines(chunk) {
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            onLine(line)
                            for parsed in StreamEventParser.parseAll(line: line) {
                                for filtered in eventPipeline.process(parsed) {
                                    _ = monitor.processEvent(filtered, process: process)
                                }
                            }
                        }
                    }
                }
                if let string = String(
                    data: proc.stderrFileHandle.readDataToEndOfFile(),
                    encoding: .utf8
                ), !string.isEmpty {
                    errorOutput.append(string)
                }
                let remaining = lineBuffer.drainRemaining()
                if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                    onLine(remaining)
                    for parsed in StreamEventParser.parseAll(line: remaining) {
                        for filtered in eventPipeline.process(parsed) {
                            _ = monitor.processEvent(filtered, process: process)
                        }
                    }
                }
                for filtered in eventPipeline.flushParsedEvents() {
                    _ = monitor.processEvent(filtered, process: process)
                }
                let error = errorOutput.value
                resumeOnce(AgentProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    error: error.isEmpty ? nil : error,
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
                resumeOnce(AgentProcessResult(exitCode: -1, error: error.localizedDescription))
                return
            }

            currentProcess = process
            monitor.startWatchdog(process: process)
        }
    }

    @MainActor
    func runCopilotProcess(
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        copilotPath: String,
        copilotHome: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        budgetEnforcementMode: BudgetEnforcementMode = .configuredDefault,
        timeoutSeconds: TimeInterval,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let taskEnv = Self.scopedEnvironmentVariables(for: task)
        let effectivePermissionPolicy = executionPolicy.permissionPolicy(default: permissionPolicy)
        let allowed = executionPolicy.allowedTools(default: task.resolvedProviderAllowedTools)
        let tokenBudget = Self.effectiveTokenBudget(for: task)
        let pathPrefix = Self.pathPrefix(for: task, taskEnv: taskEnv)

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

            let executable = copilotPath.isEmpty ? CopilotCLIRuntime.detectPath() : copilotPath
            let providerVersion = CopilotCLIRuntime.versionSummary(executablePath: executable)
            let capabilities = CopilotCLIRuntime.capabilities(executablePath: executable)
            let model = Self.model(task.model, for: .copilotCLI)
            let additionalPaths = Self.copilotAdditionalPaths(for: task)
            var localToolCommands = Self.copilotLocalToolCommands(for: task)
            if taskEnv["ASTRA_BROWSER_URL"] != nil {
                localToolCommands.append("astra-browser")
            }
            let plan = CopilotCLIRuntime.buildCommand(
                executablePath: executable,
                prompt: prompt,
                model: model,
                workspacePath: workspacePath,
                additionalPaths: additionalPaths,
                permissionPolicy: effectivePermissionPolicy,
                allowedTools: allowed,
                timeoutSeconds: timeoutSeconds,
                capabilities: capabilities,
                taskEnvironment: taskEnv,
                copilotHome: copilotHome,
                pathPrefix: pathPrefix,
                includeAstraToolsPath: Self.hasActiveCLITools(task) || taskEnv["ASTRA_BROWSER_URL"] != nil,
                localToolCommands: localToolCommands
            )

            AppLogger.audit(.runtimeProviderDetected, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!copilotPath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable)),
                "executable_path": executable,
                "executable_mtime": Self.fileModificationTimestamp(executable)
            ], level: .debug, fieldMaxLength: 220)

            AppLogger.audit(.runtimeCommandPlanned, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "phase": "run",
                "model": model,
                "parses_json_lines": String(plan.parsesJSONLines),
                "supports_output_format_json": String(capabilities.supportsOutputFormatJSON),
                "supports_streaming_flag": String(capabilities.supportsStreamingFlag),
                "supports_no_ask_user": String(capabilities.supportsNoAskUser),
                "supports_secret_env_vars": String(capabilities.supportsSecretEnvVars),
                "supports_silent": String(capabilities.supportsSilent),
                "supports_allow_all_tools": String(capabilities.supportsAllowAllTools),
                "requires_allow_all_tools": String(capabilities.requiresAllowAllToolsForPrompt),
                "permission_policy": effectivePermissionPolicy.rawValue,
                "allowed_tools_count": String(allowed.count),
                "allowed_tools_override": String(executionPolicy.allowedToolsOverride != nil),
                "local_tool_commands_count": String(localToolCommands.count),
                "additional_paths_count": String(additionalPaths.count),
                "task_env_count": String(taskEnv.count),
                "uses_output_format_json": String(plan.arguments.contains("--output-format=json")),
                "uses_stream_flag": String(plan.arguments.contains("--stream=on")),
                "uses_no_ask_user": String(plan.arguments.contains("--no-ask-user")),
                "uses_secret_env_vars": String(plan.arguments.contains("--secret-env-vars")),
                "uses_silent": String(plan.arguments.contains("--silent")),
                "uses_allow_all_tools": String(plan.arguments.contains("--allow-all-tools")),
                "uses_allow_tool": String(plan.arguments.contains("--allow-tool"))
            ], level: .debug)

            try? FileManager.default.createDirectory(atPath: copilotHome, withIntermediateDirectories: true)

            let process = AgentExecutionScopedProcess(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                currentDirectory: workspacePath,
                environment: plan.environment
            )

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeID.copilotCLI.supportsAstraRunProtocol
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: tokenBudget,
                budgetEnforcementMode: budgetEnforcementMode,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                taskID: task.id
            )

            process.stdoutFileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }

                for line in lineBuffer.appendAndDrainLines(chunk) {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    onLine(line, plan.parsesJSONLines)
                    let parsedEvents = plan.parsesJSONLines
                        ? CopilotStreamEventParser.parseAll(line: line)
                        : CopilotStreamEventParser.parsePlainText(line: line)
                    for parsed in parsedEvents {
                        for filtered in eventPipeline.process(parsed) {
                            _ = monitor.processEvent(filtered, process: process)
                        }
                    }
                    if CopilotStreamEventParser.isBlockingPlainTextPermissionPrompt(line: line) {
                        errorOutput.append("Copilot is waiting for a permission approval ASTRA cannot answer directly: \(line)\n")
                        process.terminate()
                    }
                }
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
                    for line in lineBuffer.appendAndDrainLines(chunk) {
                        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        onLine(line, plan.parsesJSONLines)
                        let parsedEvents = plan.parsesJSONLines
                            ? CopilotStreamEventParser.parseAll(line: line)
                            : CopilotStreamEventParser.parsePlainText(line: line)
                        for parsed in parsedEvents {
                            for filtered in eventPipeline.process(parsed) {
                                _ = monitor.processEvent(filtered, process: process)
                            }
                        }
                        if CopilotStreamEventParser.isBlockingPlainTextPermissionPrompt(line: line) {
                            errorOutput.append("Copilot is waiting for a permission approval ASTRA cannot answer directly: \(line)\n")
                            process.terminate()
                        }
                    }
                }
                if let string = String(
                    data: proc.stderrFileHandle.readDataToEndOfFile(),
                    encoding: .utf8
                ), !string.isEmpty {
                    errorOutput.append(string)
                }
                let remaining = lineBuffer.drainRemaining()
                if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onLine(remaining, plan.parsesJSONLines)
                    let parsedEvents = plan.parsesJSONLines
                        ? CopilotStreamEventParser.parseAll(line: remaining)
                        : CopilotStreamEventParser.parsePlainText(line: remaining)
                    for parsed in parsedEvents {
                        for filtered in eventPipeline.process(parsed) {
                            _ = monitor.processEvent(filtered, process: process)
                        }
                    }
                    if CopilotStreamEventParser.isBlockingPlainTextPermissionPrompt(line: remaining) {
                        errorOutput.append("Copilot is waiting for a permission approval ASTRA cannot answer directly: \(remaining)\n")
                        process.terminate()
                    }
                }
                for filtered in eventPipeline.flushParsedEvents() {
                    _ = monitor.processEvent(filtered, process: process)
                }
                let error = errorOutput.value
                resumeOnce(AgentProcessResult(
                    exitCode: Int(proc.terminationStatus),
                    error: error.isEmpty ? nil : error,
                    providerVersion: providerVersion,
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
                resumeOnce(AgentProcessResult(exitCode: -1, error: error.localizedDescription, providerVersion: providerVersion))
                return
            }

            currentProcess = process
            monitor.startWatchdog(process: process)
        }
    }

    private static func copilotAdditionalPaths(for task: AgentTask) -> [String] {
        var paths = task.runtimeAdditionalPaths
        if !task.effectiveWorkspacePath.isEmpty {
            paths.append(task.effectiveWorkspacePath)
        }
        if !task.taskFolder.isEmpty {
            paths.append(task.taskFolder)
        }
        return Array(Set(paths.filter { !$0.isEmpty })).sorted()
    }

    @MainActor
    private static func copilotLocalToolCommands(for task: AgentTask) -> [String] {
        Array(Set(task.allLocalTools.compactMap { tool in
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

    private static func fileModificationTimestamp(_ path: String) -> String {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            return "unknown"
        }
        return String(Int(modified.timeIntervalSince1970))
    }

    @MainActor
    private static func environment(
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
    private static func pathPrefix(for task: AgentTask, taskEnv: [String: String]) -> [String] {
        guard let browserShimDirectory = prepareBrowserToolShimIfNeeded(task: task, taskEnv: taskEnv) else {
            return []
        }
        return [browserShimDirectory]
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

        guard fileManager.isExecutableFile(atPath: realToolPath),
              realToolPath.rangeOfCharacter(from: .newlines) == nil,
              !task.taskFolder.isEmpty else {
            return nil
        }

        let shimDirectory = (task.taskFolder as NSString).appendingPathComponent(".runtime-bin")
        let shimPath = (shimDirectory as NSString).appendingPathComponent("astra-browser")
        let script = """
        #!/bin/sh
        export ASTRA_BROWSER_URL=\(shellSingleQuoted(endpoint))
        exec \(shellSingleQuoted(realToolPath)) "$@"
        """

        do {
            try fileManager.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)
            let existing = try? String(contentsOfFile: shimPath, encoding: .utf8)
            if existing != script {
                try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shimPath)
            AppLogger.audit(.shelfBrowserAction, category: "Browser", taskID: task.id, fields: [
                "action": "browser_tool_shim",
                "result": "ready",
                "has_endpoint": "true"
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
    private static func scopedEnvironmentVariables(for task: AgentTask) -> [String: String] {
        var taskEnv = task.resolvedEnvironmentVariables
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
    private static func hasActiveCLITools(_ task: AgentTask) -> Bool {
        task.allLocalTools.contains { tool in
            tool.toolType != "mcp" && !tool.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @MainActor
    private static func hasStanfordOutlookMailAccess(_ task: AgentTask) -> Bool {
        task.allConnectors.contains { $0.isStanfordOutlookMail } ||
            task.allLocalTools.contains { $0.command == StanfordOutlookMail.toolCommand }
    }

    private static func ensureSubAgentPermissions(
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
