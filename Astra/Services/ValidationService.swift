import Foundation
import SwiftData

enum ValidationResult {
    case passed(details: String)
    case failed(details: String)
    case error(String)
}

enum ValidationService {
    /// Run tests in the task's workspace using the configured test command.
    static func runTests(task: AgentTask) async -> ValidationResult {
        let command = task.testCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .error("No test command configured")
        }

        AppLogger.audit(.validationStarted, category: "Validation", taskID: task.id, fields: [
            "command_length": String(command.count),
            "workspace_id": task.workspace?.id.uuidString ?? "none"
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.shellPathSuffix)"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")

        if result.exitCode == 0 {
            AppLogger.audit(.validationPassed, category: "Validation", taskID: task.id, fields: [
                "exit_code": String(result.exitCode)
            ])
            return .passed(details: output.isEmpty ? "All tests passed" : String(output.suffix(500)))
        } else {
            AppLogger.audit(.validationFailed, category: "Validation", taskID: task.id, fields: [
                "exit_code": String(result.exitCode)
            ], level: .error)
            return .failed(details: String(output.suffix(1000)))
        }
    }

    /// AI self-check: ask the configured utility runtime to review the changes for correctness.
    static func aiCheck(
        task: AgentTask,
        claudePath: String,
        model: String = "claude-haiku-4-5-20251001",
        utilityRuntime: AgentUtilityRuntimeConfiguration? = nil
    ) async -> ValidationResult {
        let utilityRuntime = utilityRuntime ?? .claude(path: claudePath, model: model)
        guard let latestRun = task.runs.sorted(by: { $0.startedAt > $1.startedAt }).first else {
            return .error("No run to validate")
        }

        let changes = latestRun.fileChanges
        guard !changes.isEmpty else {
            return .error("No file changes to review")
        }

        var changeSummary = ""
        for change in changes.prefix(10) {
            changeSummary += "[\(change.changeType)] \(change.path)\n"
            if change.changeType == "Edit" {
                if let old = change.oldString { changeSummary += "- \(old.prefix(200))\n" }
                if let new = change.newString { changeSummary += "+ \(new.prefix(200))\n" }
            }
        }

        let prompt = """
        Review the agent's work for correctness. The task goal was: "\(task.goal)"

        Changes made:
        \(changeSummary)

        Agent's output: \(latestRun.output.prefix(500))

        Reply with ONLY "PASS" or "FAIL" on the first line, followed by a brief explanation.
        """

        AppLogger.audit(.validationStarted, category: "Validation", taskID: task.id, fields: [
            "mode": "ai_self_check",
            "changes_count": String(changes.count)
        ])

        let result = await AgentUtilityRuntimeRunner.runPrompt(
            prompt,
            workspacePath: TaskWorkspaceAccess(task: task).effectiveWorkspacePath,
            configuration: utilityRuntime
        )
        guard result.exitCode == 0 else {
            return .error("AI check provider failed: \(String(result.error.prefix(300)))")
        }
        let trimmed = result.output

        if trimmed.uppercased().hasPrefix("PASS") {
            AppLogger.audit(.validationPassed, category: "Validation", taskID: task.id, fields: [
                "mode": "ai_self_check"
            ])
            return .passed(details: trimmed)
        } else if trimmed.uppercased().hasPrefix("FAIL") {
            AppLogger.audit(.validationFailed, category: "Validation", taskID: task.id, fields: [
                "mode": "ai_self_check"
            ], level: .warning)
            return .failed(details: trimmed)
        } else {
            return .passed(details: "AI response: \(String(trimmed.prefix(300)))")
        }
    }
}
