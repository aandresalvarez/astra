import Foundation
import ASTRACore

/// Validation commands get the same reaping and process-group cleanup as
/// provider utilities, including cancellation and timeout paths.
enum RuntimeValidationCommandRunner {
    static func run(path: String, arguments: [String], environment: [String: String],
                    directory: String, timeout: TimeInterval) async -> ValidationCommandResult {
        let started = ProcessInfo.processInfo.systemUptime
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: path,
            arguments: arguments, currentDirectory: directory, environment: environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let result = await AgentRuntimeProcessRunner.runScopedUtilityProcess(plan, timeoutSeconds: timeout,
            stdoutLineHandler: nil, stderrChunkHandler: nil,
            completion: { .init(exitCode: $0, output: $1, error: $2) },
            launchError: { .init(exitCode: -1, output: "", error: $0) },
            timeoutResult: { _ in .init(exitCode: -1, output: "", error: "Validation command timed out.") })
        return .init(exitCode: result.exitCode, stdout: result.output, stderr: result.error,
            launchError: result.exitCode == -1 ? result.error : nil,
            timedOut: result.error == "Validation command timed out.", cancelled: Task.isCancelled,
            elapsedTime: ProcessInfo.processInfo.systemUptime - started)
    }
}
