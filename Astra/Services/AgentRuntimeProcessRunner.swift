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
        let taskEnv = task.resolvedEnvironmentVariables
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

                lineBuffer.append(chunk)
                var buffer = lineBuffer.value
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineIndex])
                    buffer = String(buffer[buffer.index(after: newlineIndex)...])
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        onLine(line)
                        for parsed in StreamEventParser.parseAll(line: line) {
                            _ = monitor.processEvent(parsed, process: process)
                        }
                    }
                }
                lineBuffer.value = buffer
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
                let remaining = lineBuffer.value
                if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                    onLine(remaining)
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
        timeoutSeconds: TimeInterval,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        let taskEnv = task.resolvedEnvironmentVariables
        let allowed = task.resolvedClaudeAllowedTools
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
            let capabilities = CopilotCLIRuntime.capabilities(executablePath: executable)
            let model = Self.model(task.model, for: .copilotCLI)
            let plan = CopilotCLIRuntime.buildCommand(
                executablePath: executable,
                prompt: prompt,
                model: model,
                workspacePath: workspacePath,
                additionalPaths: task.workspace?.additionalPaths ?? [],
                permissionPolicy: permissionPolicy,
                allowedTools: allowed,
                timeoutSeconds: timeoutSeconds,
                capabilities: capabilities,
                taskEnvironment: taskEnv,
                copilotHome: copilotHome
            )

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

                lineBuffer.append(chunk)
                var buffer = lineBuffer.value
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineIndex])
                    buffer = String(buffer[buffer.index(after: newlineIndex)...])
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    onLine(line, plan.parsesJSONLines)
                    let parsedEvents = plan.parsesJSONLines
                        ? CopilotStreamEventParser.parseAll(line: line)
                        : [ParsedEvent.text(text: line)]
                    for parsed in parsedEvents {
                        _ = monitor.processEvent(parsed, process: process)
                    }
                }
                lineBuffer.value = buffer
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
                let remaining = lineBuffer.value
                if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onLine(remaining, plan.parsesJSONLines)
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
        let taskEnv = task.resolvedEnvironmentVariables
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

                lineBuffer.append(chunk)
                var buffer = lineBuffer.value
                while let newlineIndex = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineIndex])
                    buffer = String(buffer[buffer.index(after: newlineIndex)...])
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        onLine(line)
                        for parsed in StreamEventParser.parseAll(line: line) {
                            _ = monitor.processEvent(parsed, process: process)
                        }
                    }
                }
                lineBuffer.value = buffer
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
                let remaining = lineBuffer.value
                if !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
                    onLine(remaining)
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
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.agentPathSuffix)"
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
