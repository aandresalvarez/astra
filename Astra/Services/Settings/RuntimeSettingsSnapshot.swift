import Foundation
import Combine
import ASTRACore

struct ProviderSettingsSnapshot: Equatable, Sendable {
    var providerSettings: AgentRuntimeProviderSettings
    var providerSettingsRevision: Int
    var providerSettingsSignature: String
    var claudeProvider: ClaudeProvider
    var vertexProjectID: String
    var vertexRegion: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String

    var availabilityConfiguration: RuntimeProviderAvailabilityConfiguration {
        RuntimeProviderAvailabilityConfiguration(
            providerSettings: providerSettings,
            claudeProvider: claudeProvider,
            vertexProjectID: vertexProjectID,
            vertexRegion: vertexRegion,
            vertexOpusModel: vertexOpusModel,
            vertexSonnetModel: vertexSonnetModel,
            vertexHaikuModel: vertexHaikuModel
        )
    }

    var signature: String {
        [
            providerSettingsSignature,
            String(providerSettingsRevision),
            providerSettings.executablePath(for: .claudeCode),
            providerSettings.executablePath(for: .copilotCLI),
            claudeProvider.rawValue,
            vertexProjectID,
            vertexRegion,
            vertexOpusModel,
            vertexSonnetModel,
            vertexHaikuModel
        ].joined(separator: "|")
    }

    func readinessConfiguration(for runtime: AgentRuntimeID) -> RuntimeReadinessConfiguration {
        availabilityConfiguration.readinessConfiguration(for: runtime)
    }

    func modelRefreshSignature(runtime: AgentRuntimeID, executablePath: String) -> String {
        RuntimeModelRefreshSignature.make(
            runtime: runtime,
            executablePath: executablePath,
            providerSettings: providerSettings,
            claudeProviderRaw: claudeProvider.rawValue,
            claudeVertexOpusModel: vertexOpusModel,
            claudeVertexSonnetModel: vertexSonnetModel,
            claudeVertexHaikuModel: vertexHaikuModel
        )
    }
}

struct RuntimeSettingsSnapshot: Equatable, Sendable {
    var defaultRuntime: AgentRuntimeID
    var defaultModel: String
    var defaultBudget: Int
    var skipPermissions: Bool
    var defaultPolicyLevelRaw: String
    var providerSnapshot: ProviderSettingsSnapshot
    var runtimeModelCache: RuntimeModelAvailabilityCache
    var runtimeModelCacheRevision: Int

    var normalizedDefaultModel: String {
        RuntimeModelAvailability.normalizedModel(
            defaultModel,
            for: defaultRuntime,
            cache: runtimeModelCache
        )
    }

    var modelCacheSignature: String {
        ([String(runtimeModelCacheRevision)] + AgentRuntimeAdapterRegistry.runtimeIDs.map { runtime in
            "\(runtime.rawValue)=\(runtimeModelCache.rawSnapshot(for: runtime))"
        }).joined(separator: "|")
    }

    func utilityRuntime(
        runtime: AgentRuntimeID,
        model: String,
        timeoutSeconds: TimeInterval = AgentUtilityRuntimeConfiguration.defaultTimeoutSeconds
    ) -> AgentUtilityRuntimeConfiguration {
        AgentUtilityRuntimeConfiguration(
            runtime: runtime,
            model: model,
            timeoutSeconds: timeoutSeconds,
            providerSettings: providerSnapshot.providerSettings
        )
    }
}

struct AppUIPreferencesSnapshot: Equatable, Sendable {
    var appearance: AppearancePreference
    var uiScale: Double
    var workspacesRoot: String
    var timeoutSeconds: Int
    var validationModel: String
}

enum RuntimeSettingsSnapshotStore {
    static func providerSnapshot(
        defaults: UserDefaults = .standard,
        runtimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs
    ) -> ProviderSettingsSnapshot {
        providerSnapshot(
            claudePath: defaults.string(forKey: RuntimeProviderSettingsStore.executablePathKey(for: .claudeCode)) ?? "",
            copilotPath: defaults.string(forKey: RuntimeProviderSettingsStore.executablePathKey(for: .copilotCLI)) ?? "",
            providerSettingsRevision: defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision),
            claudeProviderRaw: defaults.string(forKey: AppStorageKeys.claudeProvider) ?? ClaudeProvider.anthropic.rawValue,
            vertexProjectID: defaults.string(forKey: AppStorageKeys.claudeVertexProjectID) ?? "",
            vertexRegion: defaults.string(forKey: AppStorageKeys.claudeVertexRegion) ?? "",
            vertexOpusModel: defaults.string(forKey: AppStorageKeys.claudeVertexOpusModel) ?? "",
            vertexSonnetModel: defaults.string(forKey: AppStorageKeys.claudeVertexSonnetModel) ?? "",
            vertexHaikuModel: defaults.string(forKey: AppStorageKeys.claudeVertexHaikuModel) ?? "",
            defaults: defaults,
            runtimes: runtimes
        )
    }

    static func providerSnapshot(
        claudePath: String,
        copilotPath: String,
        providerSettingsRevision: Int,
        claudeProviderRaw: String,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String,
        defaults: UserDefaults = .standard,
        runtimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs
    ) -> ProviderSettingsSnapshot {
        var providerSettings = RuntimeProviderSettingsStore.settings(for: runtimes, defaults: defaults)
        providerSettings.setExecutablePath(claudePath.trimmingCharacters(in: .whitespacesAndNewlines), for: .claudeCode)
        providerSettings.setExecutablePath(copilotPath.trimmingCharacters(in: .whitespacesAndNewlines), for: .copilotCLI)

        return ProviderSettingsSnapshot(
            providerSettings: providerSettings,
            providerSettingsRevision: providerSettingsRevision,
            providerSettingsSignature: RuntimeProviderSettingsStore.signature(for: runtimes, defaults: defaults),
            claudeProvider: ClaudeProvider(rawValue: claudeProviderRaw) ?? .anthropic,
            vertexProjectID: vertexProjectID.trimmingCharacters(in: .whitespacesAndNewlines),
            vertexRegion: vertexRegion.trimmingCharacters(in: .whitespacesAndNewlines),
            vertexOpusModel: vertexOpusModel.trimmingCharacters(in: .whitespacesAndNewlines),
            vertexSonnetModel: vertexSonnetModel.trimmingCharacters(in: .whitespacesAndNewlines),
            vertexHaikuModel: vertexHaikuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func runtimeSnapshot(defaults: UserDefaults = .standard) -> RuntimeSettingsSnapshot {
        runtimeSnapshot(
            defaultRuntimeID: defaults.string(forKey: AppStorageKeys.defaultRuntimeID)
                ?? TaskExecutionDefaults.runtime.rawValue,
            defaultModel: defaults.string(forKey: AppStorageKeys.defaultModel) ?? TaskExecutionDefaults.model,
            defaultBudget: defaults.object(forKey: AppStorageKeys.defaultTokenBudget) == nil
                ? TaskExecutionDefaults.tokenBudget
                : defaults.integer(forKey: AppStorageKeys.defaultTokenBudget),
            skipPermissions: defaults.object(forKey: AppStorageKeys.skipPermissions) == nil
                ? false
                : defaults.bool(forKey: AppStorageKeys.skipPermissions),
            defaultPolicyLevelRaw: defaults.string(forKey: AppStorageKeys.defaultAgentPolicyLevel) ?? AgentPolicyLevel.review.rawValue,
            cachedClaudeModelsJSON: defaults.string(forKey: AppStorageKeys.claudeAvailableModels) ?? "",
            cachedCopilotModelsJSON: defaults.string(forKey: AppStorageKeys.copilotAvailableModels) ?? "",
            runtimeModelCacheRevision: defaults.integer(forKey: AppStorageKeys.runtimeModelCacheRevision),
            providerSnapshot: providerSnapshot(defaults: defaults),
            defaults: defaults
        )
    }

    static func runtimeSnapshot(
        defaultRuntimeID: String,
        defaultModel: String,
        defaultBudget: Int,
        skipPermissions: Bool,
        defaultPolicyLevelRaw: String,
        cachedClaudeModelsJSON: String,
        cachedCopilotModelsJSON: String,
        runtimeModelCacheRevision: Int,
        providerSnapshot: ProviderSettingsSnapshot,
        defaults: UserDefaults = .standard
    ) -> RuntimeSettingsSnapshot {
        RuntimeSettingsSnapshot(
            defaultRuntime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID),
            defaultModel: defaultModel,
            defaultBudget: defaultBudget,
            skipPermissions: skipPermissions,
            defaultPolicyLevelRaw: defaultPolicyLevelRaw,
            providerSnapshot: providerSnapshot,
            runtimeModelCache: RuntimeModelAvailabilityCache.appStorage(
                cachedClaudeModelsJSON: cachedClaudeModelsJSON,
                cachedCopilotModelsJSON: cachedCopilotModelsJSON,
                defaults: defaults
            ),
            runtimeModelCacheRevision: runtimeModelCacheRevision
        )
    }

    static func appUIPreferences(defaults: UserDefaults = .standard) -> AppUIPreferencesSnapshot {
        AppUIPreferencesSnapshot(
            appearance: AppearancePreference(rawValue: defaults.string(forKey: AppearancePreference.storageKey) ?? "") ?? .system,
            uiScale: defaults.object(forKey: AppStorageKeys.appUIScale) == nil
                ? 1.0
                : defaults.double(forKey: AppStorageKeys.appUIScale),
            workspacesRoot: defaults.string(forKey: AppStorageKeys.workspacesRoot) ?? "",
            timeoutSeconds: defaults.object(forKey: AppStorageKeys.timeoutSeconds) == nil
                ? 600
                : defaults.integer(forKey: AppStorageKeys.timeoutSeconds),
            validationModel: defaults.string(forKey: AppStorageKeys.validationModel) ?? "claude-haiku-4-5-20251001"
        )
    }
}

@MainActor
final class AppSettingsSnapshotStore: ObservableObject {
    @Published private(set) var runtimeSettings: RuntimeSettingsSnapshot
    @Published private(set) var providerSettings: ProviderSettingsSnapshot
    @Published private(set) var uiPreferences: AppUIPreferencesSnapshot

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var defaultsObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        observesDefaultsChanges: Bool = true
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        let runtimeSettings = RuntimeSettingsSnapshotStore.runtimeSnapshot(defaults: defaults)
        self.runtimeSettings = runtimeSettings
        self.providerSettings = runtimeSettings.providerSnapshot
        self.uiPreferences = RuntimeSettingsSnapshotStore.appUIPreferences(defaults: defaults)

        if observesDefaultsChanges {
            defaultsObserver = notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    deinit {
        if let defaultsObserver {
            notificationCenter.removeObserver(defaultsObserver)
        }
    }

    func refresh() {
        let runtimeSettings = RuntimeSettingsSnapshotStore.runtimeSnapshot(defaults: defaults)
        self.runtimeSettings = runtimeSettings
        self.providerSettings = runtimeSettings.providerSnapshot
        self.uiPreferences = RuntimeSettingsSnapshotStore.appUIPreferences(defaults: defaults)
    }
}
