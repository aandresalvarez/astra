import Foundation
import ASTRACore

struct AgentRuntimeProviderSettings {
    private var executablePaths: [AgentRuntimeID: String]
    private var homeDirectories: [AgentRuntimeID: String]

    init(
        executablePaths: [AgentRuntimeID: String] = [:],
        homeDirectories: [AgentRuntimeID: String] = [:]
    ) {
        self.executablePaths = executablePaths
        self.homeDirectories = homeDirectories
    }

    func executablePath(for runtime: AgentRuntimeID) -> String {
        executablePaths[runtime] ?? ""
    }

    mutating func setExecutablePath(_ path: String, for runtime: AgentRuntimeID) {
        executablePaths[runtime] = path
    }

    func homeDirectory(for runtime: AgentRuntimeID) -> String {
        homeDirectories[runtime] ?? ""
    }

    mutating func setHomeDirectory(_ path: String, for runtime: AgentRuntimeID) {
        homeDirectories[runtime] = path
    }
}

struct AgentRuntimeConfiguration {
    private var providerSettings: AgentRuntimeProviderSettings
    var defaultRuntimeID: AgentRuntimeID

    init(
        claudePath: String = RuntimePathResolver.detectClaudePath(),
        copilotPath: String = CopilotCLIRuntime.detectPath(),
        copilotHome: String = CopilotCLIRuntime.channelHome(),
        defaultRuntimeID: AgentRuntimeID = .claudeCode
    ) {
        self.providerSettings = AgentRuntimeProviderSettings(
            executablePaths: [
                .claudeCode: claudePath,
                .copilotCLI: copilotPath
            ],
            homeDirectories: [
                .copilotCLI: copilotHome
            ]
        )
        self.defaultRuntimeID = defaultRuntimeID
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

    mutating func setExecutablePath(_ path: String, for runtime: AgentRuntimeID) {
        providerSettings.setExecutablePath(path, for: runtime)
    }

    func homeDirectory(for runtime: AgentRuntimeID) -> String {
        providerSettings.homeDirectory(for: runtime)
    }

    mutating func setHomeDirectory(_ path: String, for runtime: AgentRuntimeID) {
        providerSettings.setHomeDirectory(path, for: runtime)
    }

    func selectedRuntime(for task: AgentTask) -> AgentRuntimeID {
        AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: task.runtimeID,
            fallback: defaultRuntimeID
        )
    }

    mutating func resolvedCopilotPath() -> String {
        if copilotPath.isEmpty {
            copilotPath = CopilotCLIRuntime.detectPath()
        }
        return copilotPath
    }
}
