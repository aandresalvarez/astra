import Foundation
import ASTRACore

// #region agent log
private func _utilDebugLog(_ location: String, _ message: String, _ data: [String: Any], _ hypothesis: String) {
    let payload: [String: Any] = [
        "sessionId": "57c8bc", "runId": "helper-fix", "hypothesisId": hypothesis,
        "location": location, "message": message, "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    guard let d = try? JSONSerialization.data(withJSONObject: payload),
          let line = (String(data: d, encoding: .utf8).map { $0 + "\n" })?.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/Users/alvaro1/Documents/Coral/Code/Astra/.cursor/debug-57c8bc.log")
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        try? h.write(contentsOf: line)
    } else {
        try? line.write(to: url)
    }
}
// #endregion

struct AgentUtilityRuntimeConfiguration: Equatable {
    var runtime: AgentRuntimeID
    var model: String
    private var providerSettings: AgentRuntimeProviderSettings

    init(
        runtime: AgentRuntimeID = TaskExecutionDefaults.runtime,
        model: String? = nil,
        claudePath: String = RuntimePathResolver.detectClaudePath(),
        copilotPath: String = CopilotCLIRuntime.detectPath(),
        copilotHome: String = CopilotCLIRuntime.channelHome(),
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
        self.model = RuntimeModelAvailability.normalizedModel(model ?? "", for: runtime)
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
        // #region agent log
        let _dbgStart = Date()
        _utilDebugLog("AgentUtilityRuntime.swift:runPrompt-enter", "utility prompt start", ["runtime": configuration.runtime.rawValue, "model": configuration.model, "executable": configuration.executablePath(for: configuration.runtime), "promptLen": prompt.count, "toolMode": "\(toolMode)"], "E,F,H")
        // #endregion
        let result = await AgentRuntimeAdapterRegistry
            .adapter(for: configuration.runtime)
            .runUtilityPrompt(
                prompt,
                workspacePath: workspacePath,
                configuration: configuration,
                toolMode: toolMode
            )
        // #region agent log
        _utilDebugLog("AgentUtilityRuntime.swift:runPrompt-exit", "utility prompt end", ["runtime": configuration.runtime.rawValue, "exitCode": result.exitCode, "outputLen": result.output.count, "errorPrefix": String(result.error.prefix(200)), "elapsedMs": Int(Date().timeIntervalSince(_dbgStart) * 1000)], "E,F")
        // #endregion
        return result
    }
}
