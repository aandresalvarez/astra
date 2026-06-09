import Foundation
import ASTRACore

struct AgentUtilityRuntimeConfiguration: Equatable {
    static let defaultTimeoutSeconds: TimeInterval = 60

    var runtime: AgentRuntimeID
    private var normalizedModel: String
    var model: String {
        get { normalizedModel }
        set { normalizedModel = RuntimeModelAvailability.normalizedModel(newValue, for: runtime) }
    }
    var timeoutSeconds: TimeInterval
    private var providerSettings: AgentRuntimeProviderSettings

    init(
        runtime: AgentRuntimeID = TaskExecutionDefaults.runtime,
        model: String? = nil,
        claudePath: String = RuntimePathResolver.detectClaudePath(),
        copilotPath: String = CopilotCLIRuntime.detectPath(),
        copilotHome: String = CopilotCLIRuntime.channelHome(),
        timeoutSeconds: TimeInterval = AgentUtilityRuntimeConfiguration.defaultTimeoutSeconds,
        providerSettings: AgentRuntimeProviderSettings = AgentRuntimeProviderSettings()
    ) {
        var resolvedSettings = providerSettings
        if resolvedSettings.executablePath(for: .claudeCode).isEmpty {
            resolvedSettings.setExecutablePath(claudePath, for: .claudeCode)
        }
        if resolvedSettings.executablePath(for: .copilotCLI).isEmpty {
            resolvedSettings.setExecutablePath(copilotPath, for: .copilotCLI)
        }
        if resolvedSettings.homeDirectory(for: .copilotCLI).isEmpty {
            resolvedSettings.setHomeDirectory(copilotHome, for: .copilotCLI)
        }
        self.runtime = runtime
        self.normalizedModel = RuntimeModelAvailability.normalizedModel(model ?? "", for: runtime)
        self.timeoutSeconds = timeoutSeconds
        self.providerSettings = resolvedSettings
    }

    var claudePath: String {
        get { providerSettings.executablePath(for: .claudeCode) }
        set { providerSettings.setExecutablePath(newValue, for: .claudeCode) }
    }

    var copilotPath: String {
        get { providerSettings.executablePath(for: .copilotCLI) }
        set { providerSettings.setExecutablePath(newValue, for: .copilotCLI) }
    }

    var copilotHome: String {
        get { providerSettings.homeDirectory(for: .copilotCLI) }
        set { providerSettings.setHomeDirectory(newValue, for: .copilotCLI) }
    }

    func executablePath(for runtime: AgentRuntimeID) -> String {
        providerSettings.executablePath(for: runtime)
    }

    func homeDirectory(for runtime: AgentRuntimeID) -> String {
        providerSettings.homeDirectory(for: runtime)
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
