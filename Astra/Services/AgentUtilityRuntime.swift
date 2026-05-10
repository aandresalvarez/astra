import Foundation
import ASTRACore

struct AgentUtilityRuntimeConfiguration: Equatable {
    var runtime: AgentRuntimeID
    var model: String
    var claudePath: String
    var copilotPath: String
    var copilotHome: String

    init(
        runtime: AgentRuntimeID = .claudeCode,
        model: String? = nil,
        claudePath: String = RuntimePathResolver.detectClaudePath(),
        copilotPath: String = CopilotCLIRuntime.detectPath(),
        copilotHome: String = CopilotCLIRuntime.channelHome()
    ) {
        self.runtime = runtime
        self.model = model ?? runtime.defaultModel
        self.claudePath = claudePath
        self.copilotPath = copilotPath
        self.copilotHome = copilotHome
    }

    static func claude(
        path: String = RuntimePathResolver.detectClaudePath(),
        model: String = AgentRuntimeID.claudeCode.defaultModel
    ) -> AgentUtilityRuntimeConfiguration {
        AgentUtilityRuntimeConfiguration(runtime: .claudeCode, model: model, claudePath: path)
    }
}

enum AgentUtilityToolMode: Equatable {
    case none
    case readOnly
}

struct AgentUtilityRunResult: Equatable {
    var exitCode: Int
    var output: String
    var error: String
}

enum AgentUtilityRuntimeRunner {
    static func runPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode = .none
    ) async -> AgentUtilityRunResult {
        switch configuration.runtime {
        case .claudeCode:
            return await runClaudePrompt(
                prompt,
                workspacePath: workspacePath,
                configuration: configuration,
                toolMode: toolMode
            )
        case .copilotCLI:
            return await runCopilotPrompt(
                prompt,
                workspacePath: workspacePath,
                configuration: configuration,
                toolMode: toolMode
            )
        }
    }

    private static func runClaudePrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let executable = configuration.claudePath.isEmpty
            ? RuntimePathResolver.detectClaudePath()
            : configuration.claudePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var args = [
            "-p",
            prompt,
            "--model",
            AgentRuntimeProcessRunner.translatedModelForProvider(configuration.model)
        ]
        if toolMode == .readOnly {
            args += [
                "--allowedTools",
                "Read,Glob,Grep",
                "--disallowedTools",
                "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"
            ]
        }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        process.environment = claudeEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        return AgentUtilityRunResult(exitCode: result.exitCode, output: result.stdout, error: result.stderr)
    }

    private static func runCopilotPrompt(
        _ prompt: String,
        workspacePath: String,
        configuration: AgentUtilityRuntimeConfiguration,
        toolMode: AgentUtilityToolMode
    ) async -> AgentUtilityRunResult {
        let executable = configuration.copilotPath.isEmpty
            ? CopilotCLIRuntime.detectPath()
            : configuration.copilotPath
        let capabilities = CopilotCLIRuntime.capabilities(executablePath: executable)
        let allowedTools = toolMode == .readOnly ? ["Read", "Glob", "Grep"] : []
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: executable,
            prompt: prompt,
            model: AgentRuntimeProcessRunner.model(configuration.model, for: .copilotCLI),
            workspacePath: workspacePath,
            additionalPaths: [],
            permissionPolicy: .restricted,
            allowedTools: allowedTools,
            timeoutSeconds: 120,
            capabilities: capabilities,
            taskEnvironment: [:],
            copilotHome: configuration.copilotHome
        )

        try? FileManager.default.createDirectory(atPath: configuration.copilotHome, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
        process.environment = plan.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let result = await AsyncProcessRunner.run(process, stdout: stdoutPipe, stderr: stderrPipe)
        let output = plan.parsesJSONLines
            ? extractCopilotText(from: result.stdout)
            : result.stdout
        return AgentUtilityRunResult(exitCode: result.exitCode, output: output, error: result.stderr)
    }

    private static func claudeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.shellPathSuffix)"
        for (key, value) in AgentRuntimeProcessRunner.claudeProviderEnvironment() {
            env[key] = value
        }
        return env
    }

    private static func extractCopilotText(from output: String) -> String {
        var pieces: [String] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            for event in CopilotStreamEventParser.parseAgentEvents(line: line) {
                switch event {
                case .text(let text):
                    pieces.append(text)
                case .completed(let summary):
                    if let summary, !summary.isEmpty {
                        pieces.append(summary)
                    }
                case .failed(let message):
                    pieces.append(message)
                default:
                    continue
                }
            }
        }
        let joined = pieces.joined()
        return joined.isEmpty ? output : joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
