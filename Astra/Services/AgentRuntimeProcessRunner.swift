import Foundation
import ASTRACore

final class AgentRuntimeProcessRunner {
    private var currentProcess: Process?

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
        timeoutSeconds: TimeInterval,
        onLine: @escaping (String) -> Void
    ) async -> AgentProcessResult {
        let taskEnv = Self.scopedEnvironmentVariables(for: task)
        let allowed = task.resolvedClaudeAllowedTools
        let tokenBudget = Self.tokenBudget(for: task)

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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)

            var args = ["-p", prompt, "--model", task.model, "--output-format", "stream-json", "--verbose"]
            args += permissionPolicy.cliArguments
            Self.ensureSubAgentPermissions(at: workspacePath, policy: permissionPolicy, allowedTools: allowed)
            if task.maxTurns > 0 {
                args += ["--max-turns", String(task.maxTurns)]
            }
            if !allowed.isEmpty {
                args += ["--allowedTools"] + allowed
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
            process.environment = Self.environment(
                phase: "run",
                task: task,
                taskEnv: taskEnv,
                includeClaudeTeamFlag: true
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: tokenBudget,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                taskID: task.id
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
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

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    errorOutput.append(string)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if let chunk = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
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
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
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
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded
                ))
            }

            currentProcess = process
            do {
                try process.run()
            } catch {
                resumeOnce(AgentProcessResult(exitCode: -1, error: error.localizedDescription))
                return
            }

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
        allowedToolsOverride: [String]? = nil,
        timeoutSeconds: TimeInterval,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let taskEnv = Self.scopedEnvironmentVariables(for: task)
        let allowed = allowedToolsOverride ?? task.resolvedClaudeAllowedTools
        let tokenBudget = task.tokenBudget == 0 ? Int.max : task.tokenBudget

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
            let localToolCommands = Self.copilotLocalToolCommands(for: task)
            let plan = CopilotCLIRuntime.buildCommand(
                executablePath: executable,
                prompt: prompt,
                model: model,
                workspacePath: workspacePath,
                additionalPaths: additionalPaths,
                permissionPolicy: permissionPolicy,
                allowedTools: allowed,
                timeoutSeconds: timeoutSeconds,
                capabilities: capabilities,
                taskEnvironment: taskEnv,
                copilotHome: copilotHome,
                includeAstraToolsPath: Self.hasActiveCLITools(task),
                localToolCommands: localToolCommands
            )

            AppLogger.audit(.runtimeProviderDetected, category: "Worker", taskID: task.id, fields: [
                "runtime": AgentRuntimeID.copilotCLI.rawValue,
                "provider_version": providerVersion ?? "unknown",
                "executable_configured": String(!copilotPath.isEmpty),
                "executable_exists": String(FileManager.default.isExecutableFile(atPath: executable))
            ], level: .debug)

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
                "permission_policy": permissionPolicy.rawValue,
                "allowed_tools_count": String(allowed.count),
                "allowed_tools_override": String(allowedToolsOverride != nil),
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

            let process = Process()
            process.executableURL = URL(fileURLWithPath: plan.executablePath)
            process.arguments = plan.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
            process.environment = plan.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeID.copilotCLI.supportsAstraRunProtocol
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: tokenBudget,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                taskID: task.id
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
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

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    errorOutput.append(string)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if let chunk = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
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
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
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
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded
                ))
            }

            currentProcess = process
            do {
                try process.run()
            } catch {
                resumeOnce(AgentProcessResult(exitCode: -1, error: error.localizedDescription, providerVersion: providerVersion))
                return
            }

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
    func runClaudeResume(
        sessionId: String,
        message: String,
        task: AgentTask,
        workspacePath: String,
        claudePath: String,
        permissionPolicy: PermissionPolicy,
        timeoutSeconds: TimeInterval,
        onLine: @escaping (String) -> Void
    ) async -> AgentProcessResult {
        let taskEnv = Self.scopedEnvironmentVariables(for: task)
        let allowed = task.resolvedClaudeAllowedTools
        let baseBudget = task.tokenBudget
        let remainingBudget = baseBudget == 0 ? Int.max : max(1000, baseBudget - task.tokensUsed)

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

            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)

            var args = ["-p", message, "--resume", sessionId, "--output-format", "stream-json", "--verbose"]
            args += permissionPolicy.cliArguments
            Self.ensureSubAgentPermissions(at: workspacePath, policy: permissionPolicy, allowedTools: allowed)
            if task.maxTurns > 0 {
                args += ["--max-turns", String(task.maxTurns)]
            }
            if !allowed.isEmpty {
                args += ["--allowedTools"] + allowed
            }
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
            process.environment = Self.environment(
                phase: "resume",
                task: task,
                taskEnv: taskEnv,
                includeClaudeTeamFlag: true
            )

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let errorOutput = AgentLockedBuffer()
            let lineBuffer = AgentLockedBuffer()
            let eventPipeline = AgentRuntimeEventPipelineBox(
                supportsAstraRunProtocol: AgentRuntimeID.claudeCode.supportsAstraRunProtocol
            )
            let monitor = AgentProcessMonitor(
                tokenBudget: remainingBudget,
                maxTurns: task.maxTurns,
                maxRepetitions: 8,
                idleTimeoutSeconds: timeoutSeconds,
                taskID: task.id
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
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

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let string = String(data: data, encoding: .utf8) {
                    errorOutput.append(string)
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if let chunk = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
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
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
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
                    timedOut: monitor.timedOut,
                    repetitionKilled: monitor.repetitionKilled,
                    maxTurnsExceeded: monitor.maxTurnsExceeded
                ))
            }

            currentProcess = process
            do {
                try process.run()
            } catch {
                resumeOnce(AgentProcessResult(exitCode: -1, error: error.localizedDescription))
            }

            monitor.startWatchdog(process: process)
        }
    }

    @MainActor
    private static func tokenBudget(for task: AgentTask) -> Int {
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

    private static func model(_ model: String, for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return model.isEmpty ? runtime.defaultModel : model
        case .copilotCLI:
            if model.isEmpty { return runtime.defaultModel }
            if model == "claude-sonnet-4-6" || model == "claude-opus-4-6" || model == "claude-haiku-4-5-20251001" {
                return runtime.defaultModel
            }
            return model
        }
    }

    @MainActor
    private static func environment(
        phase: String,
        task: AgentTask,
        taskEnv: [String: String],
        includeClaudeTeamFlag: Bool
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var pathSuffix = RuntimePathResolver.shellPathSuffix
        if hasActiveCLITools(task) {
            pathSuffix += ":\(RuntimePathResolver.astraToolsPath)"
        }
        env["PATH"] = (env["PATH"] ?? "") + ":\(pathSuffix)"
        if includeClaudeTeamFlag {
            env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
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
    private static func scopedEnvironmentVariables(for task: AgentTask) -> [String: String] {
        var taskEnv = task.resolvedEnvironmentVariables
        if hasStanfordOutlookMailAccess(task) {
            taskEnv["ASTRA_CHANNEL"] = AppChannel.current.rawValue
            taskEnv["ASTRA_MAIL_REGISTRY_PATH"] = StanfordOutlookMail.registryURL.path
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
