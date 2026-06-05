import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Runtime Settings Snapshot")
struct RuntimeSettingsSnapshotTests {
    @Test("Central runtime snapshot keys preserve legacy raw values")
    func centralRuntimeSnapshotKeysPreserveLegacyRawValues() {
        #expect(AppStorageKeys.defaultRuntimeID == "defaultRuntimeID")
        #expect(AppStorageKeys.defaultModel == "defaultModel")
        #expect(AppStorageKeys.appUIScale == "appUIScale")
        #expect(AppStorageKeys.workspacesRoot == "workspacesRoot")
        #expect(AppStorageKeys.timeoutSeconds == "timeoutSeconds")
        #expect(AppStorageKeys.validationModel == "validationModel")
    }

    @Test("Provider snapshot preserves legacy path keys and trims values")
    func providerSnapshotPreservesLegacyPathKeysAndTrimsValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(" /usr/local/bin/claude \n", forKey: AppStorageKeys.claudePath)
        defaults.set("\t/usr/local/bin/copilot ", forKey: AppStorageKeys.copilotPath)
        defaults.set(7, forKey: AppStorageKeys.runtimeProviderSettingsRevision)
        defaults.set(ClaudeProvider.vertex.rawValue, forKey: AppStorageKeys.claudeProvider)
        defaults.set(" astra-gcp ", forKey: AppStorageKeys.claudeVertexProjectID)
        defaults.set(" us-central1 ", forKey: AppStorageKeys.claudeVertexRegion)
        defaults.set(" opus-v ", forKey: AppStorageKeys.claudeVertexOpusModel)

        let snapshot = RuntimeSettingsSnapshotStore.providerSnapshot(defaults: defaults)

        #expect(snapshot.providerSettings.executablePath(for: .claudeCode) == "/usr/local/bin/claude")
        #expect(snapshot.providerSettings.executablePath(for: .copilotCLI) == "/usr/local/bin/copilot")
        #expect(snapshot.providerSettingsRevision == 7)
        #expect(snapshot.claudeProvider == .vertex)
        #expect(snapshot.vertexProjectID == "astra-gcp")
        #expect(snapshot.vertexRegion == "us-central1")
        #expect(snapshot.vertexOpusModel == "opus-v")
        #expect(snapshot.signature.contains("/usr/local/bin/claude"))
    }

    @Test("Provider snapshot creates availability and readiness configuration")
    func providerSnapshotCreatesAvailabilityAndReadinessConfiguration() {
        let snapshot = RuntimeSettingsSnapshotStore.providerSnapshot(
            claudePath: "/bin/claude",
            copilotPath: "/bin/copilot",
            providerSettingsRevision: 1,
            claudeProviderRaw: ClaudeProvider.vertex.rawValue,
            vertexProjectID: "project",
            vertexRegion: "region",
            vertexOpusModel: "opus",
            vertexSonnetModel: "sonnet",
            vertexHaikuModel: "haiku",
            defaults: makeDefaults().0
        )

        let availability = snapshot.availabilityConfiguration
        #expect(availability.providerSettings.executablePath(for: .claudeCode) == "/bin/claude")
        #expect(availability.claudeProvider == .vertex)
        #expect(availability.vertexProjectID == "project")

        let readiness = snapshot.readinessConfiguration(for: .claudeCode)
        #expect(readiness.runtime == .claudeCode)
        #expect(readiness.scope == .availability)
        #expect(readiness.providerSettings.executablePath(for: .copilotCLI) == "/bin/copilot")
    }

    @Test("Runtime snapshot centralizes defaults and model cache")
    func runtimeSnapshotCentralizesDefaultsAndModelCache() {
        let provider = RuntimeSettingsSnapshotStore.providerSnapshot(
            claudePath: "/bin/claude",
            copilotPath: "/bin/copilot",
            providerSettingsRevision: 3,
            claudeProviderRaw: ClaudeProvider.anthropic.rawValue,
            vertexProjectID: "",
            vertexRegion: "",
            vertexOpusModel: "",
            vertexSonnetModel: "",
            vertexHaikuModel: ""
        )
        let cacheJSON = #"{"runtimeID":"copilot_cli","models":["gpt-5.1"],"checkedAt":0,"authority":"authoritative"}"#

        let snapshot = RuntimeSettingsSnapshotStore.runtimeSnapshot(
            defaultRuntimeID: AgentRuntimeID.copilotCLI.rawValue,
            defaultModel: "gpt-5.1",
            defaultBudget: 25_000,
            skipPermissions: true,
            defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue,
            cachedClaudeModelsJSON: "",
            cachedCopilotModelsJSON: cacheJSON,
            runtimeModelCacheRevision: 9,
            providerSnapshot: provider
        )

        #expect(snapshot.defaultRuntime == .copilotCLI)
        #expect(snapshot.normalizedDefaultModel == "gpt-5.1")
        #expect(snapshot.defaultBudget == 25_000)
        #expect(snapshot.skipPermissions)
        #expect(snapshot.defaultPolicyLevelRaw == AgentPolicyLevel.autonomous.rawValue)
        #expect(snapshot.runtimeModelCache.rawSnapshot(for: .copilotCLI) == cacheJSON)
        #expect(snapshot.modelCacheSignature.contains("9|"))
    }

    @Test("Runtime snapshot reads legacy default runtime and model keys")
    func runtimeSnapshotReadsLegacyDefaultRuntimeAndModelKeys() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AgentRuntimeID.copilotCLI.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        defaults.set("gpt-5.1", forKey: AppStorageKeys.defaultModel)

        let snapshot = RuntimeSettingsSnapshotStore.runtimeSnapshot(defaults: defaults)

        #expect(snapshot.defaultRuntime == .copilotCLI)
        #expect(snapshot.defaultModel == "gpt-5.1")
    }

    @MainActor
    @Test("App settings store refreshes runtime, provider, and UI snapshots")
    func appSettingsStoreRefreshesRuntimeProviderAndUISnapshots() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsSnapshotStore(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            observesDefaultsChanges: false
        )

        defaults.set(AgentRuntimeID.copilotCLI.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        defaults.set("gpt-5.1", forKey: AppStorageKeys.defaultModel)
        defaults.set(42_000, forKey: AppStorageKeys.defaultTokenBudget)
        defaults.set("/bin/copilot", forKey: AppStorageKeys.copilotPath)
        defaults.set("/tmp/astra-workspaces", forKey: AppStorageKeys.workspacesRoot)
        defaults.set(900, forKey: AppStorageKeys.timeoutSeconds)

        store.refresh()

        #expect(store.runtimeSettings.defaultRuntime == .copilotCLI)
        #expect(store.runtimeSettings.defaultModel == "gpt-5.1")
        #expect(store.runtimeSettings.defaultBudget == 42_000)
        #expect(store.providerSettings.providerSettings.executablePath(for: .copilotCLI) == "/bin/copilot")
        #expect(store.uiPreferences.workspacesRoot == "/tmp/astra-workspaces")
        #expect(store.uiPreferences.timeoutSeconds == 900)
    }

    @MainActor
    @Test("App settings store normalizes default model after runtime cache changes")
    func appSettingsStoreNormalizesDefaultModelAfterRuntimeCacheChanges() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppSettingsSnapshotStore(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            observesDefaultsChanges: false
        )
        let cacheJSON = #"{"runtimeID":"copilot_cli","models":["gpt-5.1"],"checkedAt":0,"authority":"authoritative"}"#

        defaults.set(AgentRuntimeID.copilotCLI.rawValue, forKey: AppStorageKeys.defaultRuntimeID)
        defaults.set("claude-sonnet-4-6", forKey: AppStorageKeys.defaultModel)
        defaults.set(cacheJSON, forKey: AppStorageKeys.copilotAvailableModels)
        defaults.set(12, forKey: AppStorageKeys.runtimeModelCacheRevision)

        store.refresh()

        #expect(store.runtimeSettings.defaultRuntime == .copilotCLI)
        #expect(store.runtimeSettings.normalizedDefaultModel == "gpt-5.1")
        #expect(store.runtimeSettings.modelCacheSignature.contains("12|"))
    }

    @Test("UI preference snapshot applies stable defaults")
    func uiPreferenceSnapshotAppliesStableDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RuntimeSettingsSnapshotStore.appUIPreferences(defaults: defaults) == AppUIPreferencesSnapshot(
            appearance: .system,
            uiScale: 1.0,
            workspacesRoot: "",
            timeoutSeconds: 600,
            validationModel: "claude-haiku-4-5-20251001"
        ))

        defaults.set(AppearancePreference.dark.rawValue, forKey: AppearancePreference.storageKey)
        defaults.set(1.2, forKey: AppStorageKeys.appUIScale)
        defaults.set("/tmp/workspaces", forKey: AppStorageKeys.workspacesRoot)
        defaults.set(900, forKey: AppStorageKeys.timeoutSeconds)
        defaults.set("validator", forKey: AppStorageKeys.validationModel)

        #expect(RuntimeSettingsSnapshotStore.appUIPreferences(defaults: defaults) == AppUIPreferencesSnapshot(
            appearance: .dark,
            uiScale: 1.2,
            workspacesRoot: "/tmp/workspaces",
            timeoutSeconds: 900,
            validationModel: "validator"
        ))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RuntimeSettingsSnapshotTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
