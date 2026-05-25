import Foundation
import ASTRACore

struct AgentUtilityRuntimeConfiguration: Equatable {
    var runtime: AgentRuntimeID
    var model: String
    var claudePath: String
    var copilotPath: String
    var copilotHome: String

    init(
        runtime: AgentRuntimeID = TaskExecutionDefaults.runtime,
        model: String? = nil,
        claudePath: String = RuntimePathResolver.detectClaudePath(),
        copilotPath: String = CopilotCLIRuntime.detectPath(),
        copilotHome: String = CopilotCLIRuntime.channelHome()
    ) {
        self.runtime = runtime
        self.model = RuntimeModelAvailability.normalizedModel(model ?? "", for: runtime)
        self.claudePath = claudePath
        self.copilotPath = copilotPath
        self.copilotHome = copilotHome
    }

    static func claude(
        path: String = RuntimePathResolver.detectClaudePath(),
        model: String = TaskExecutionDefaults.model
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
        await AgentRuntimeAdapterRegistry
            .adapter(for: configuration.runtime)
            .runUtilityPrompt(
                prompt,
                workspacePath: workspacePath,
                configuration: configuration,
                toolMode: toolMode
            )
    }
}
