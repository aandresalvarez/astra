import Foundation
import ASTRACore
import ASTRAModels

struct AgentRuntimeProviderSettings: Equatable, Sendable {
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

    var configuredExecutablePaths: [AgentRuntimeID: String] {
        executablePaths
    }

    mutating func setExecutablePath(_ path: String, for runtime: AgentRuntimeID) {
        executablePaths[runtime] = path
    }

    func homeDirectory(for runtime: AgentRuntimeID) -> String {
        homeDirectories[runtime] ?? ""
    }

    var configuredHomeDirectories: [AgentRuntimeID: String] {
        homeDirectories
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
        providerSettings: AgentRuntimeProviderSettings = AgentRuntimeProviderSettings(),
        defaultRuntimeID: AgentRuntimeID = .claudeCode
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
        self.providerSettings = resolvedSettings
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

    var configuredProviderSettings: AgentRuntimeProviderSettings {
        providerSettings
    }

    mutating func setHomeDirectory(_ path: String, for runtime: AgentRuntimeID) {
        providerSettings.setHomeDirectory(path, for: runtime)
    }

    mutating func setProviderSettings(_ settings: AgentRuntimeProviderSettings) {
        providerSettings = settings
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
