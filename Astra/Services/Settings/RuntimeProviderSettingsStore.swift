import Foundation
import ASTRACore

enum RuntimeProviderSettingsStore {
    static func executablePathKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return "claudePath"
        case .copilotCLI:
            return "copilotPath"
        default:
            return "astra.runtime.\(AppStorageKeys.storageComponent(for: runtime)).executablePath.v1"
        }
    }

    static func homeDirectoryKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .copilotCLI:
            return "astra.copilot.homeDirectory.v1"
        default:
            return "astra.runtime.\(AppStorageKeys.storageComponent(for: runtime)).homeDirectory.v1"
        }
    }

    static func settings(
        for runtimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs,
        defaults: UserDefaults = .standard
    ) -> AgentRuntimeProviderSettings {
        var settings = AgentRuntimeProviderSettings()
        for runtime in runtimes {
            settings.setExecutablePath(executablePath(for: runtime, defaults: defaults), for: runtime)
            settings.setHomeDirectory(homeDirectory(for: runtime, defaults: defaults), for: runtime)
        }
        if settings.homeDirectory(for: .copilotCLI).isEmpty {
            settings.setHomeDirectory(CopilotCLIRuntime.channelHome(), for: .copilotCLI)
        }
        return settings
    }

    static func executablePath(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: executablePathKey(for: runtime))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func setExecutablePath(
        _ path: String,
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(path, forKey: executablePathKey(for: runtime))
        bumpRevision(defaults: defaults)
    }

    static func homeDirectory(for runtime: AgentRuntimeID, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: homeDirectoryKey(for: runtime))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func setHomeDirectory(
        _ path: String,
        for runtime: AgentRuntimeID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(path, forKey: homeDirectoryKey(for: runtime))
        bumpRevision(defaults: defaults)
    }

    static func signature(
        for runtimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs,
        defaults: UserDefaults = .standard
    ) -> String {
        runtimes
            .map { runtime in
                [
                    runtime.rawValue,
                    executablePath(for: runtime, defaults: defaults),
                    homeDirectory(for: runtime, defaults: defaults)
                ].joined(separator: "=")
            }
            .joined(separator: "\u{1F}")
    }

    private static func bumpRevision(defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) + 1,
                     forKey: AppStorageKeys.runtimeProviderSettingsRevision)
    }
}
