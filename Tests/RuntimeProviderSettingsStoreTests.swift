import Foundation
import Testing
import ASTRAPersistence
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Runtime Provider Settings Store")
struct RuntimeProviderSettingsStoreTests {
    @Test("Built-in provider path keys stay backward compatible")
    func builtInProviderPathKeysStayBackwardCompatible() {
        #expect(AppStorageKeys.claudePath == "claudePath")
        #expect(AppStorageKeys.copilotPath == "copilotPath")
        #expect(RuntimeProviderSettingsStore.executablePathKey(for: .claudeCode) == AppStorageKeys.claudePath)
        #expect(RuntimeProviderSettingsStore.executablePathKey(for: .copilotCLI) == AppStorageKeys.copilotPath)
        #expect(
            RuntimeProviderSettingsStore.homeDirectoryKey(for: .copilotCLI)
                == "astra.copilot.homeDirectory.v1"
        )
    }

    @Test("Future provider settings use provider-keyed storage and revision")
    func futureProviderSettingsUseProviderKeyedStorageAndRevision() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))

        RuntimeProviderSettingsStore.setExecutablePath(
            "/opt/future/bin/future",
            for: futureRuntime,
            defaults: defaults
        )
        RuntimeProviderSettingsStore.setHomeDirectory(
            "/tmp/future-home",
            for: futureRuntime,
            defaults: defaults
        )

        #expect(defaults.integer(forKey: AppStorageKeys.runtimeProviderSettingsRevision) == 2)
        #expect(defaults.string(forKey: AppStorageKeys.claudePath) == nil)
        #expect(defaults.string(forKey: AppStorageKeys.copilotPath) == nil)
        #expect(
            defaults.string(forKey: RuntimeProviderSettingsStore.executablePathKey(for: futureRuntime))
                == "/opt/future/bin/future"
        )

        let settings = RuntimeProviderSettingsStore.settings(for: [futureRuntime], defaults: defaults)
        #expect(settings.executablePath(for: futureRuntime) == "/opt/future/bin/future")
        #expect(settings.homeDirectory(for: futureRuntime) == "/tmp/future-home")
        #expect(RuntimeProviderSettingsStore.signature(for: [futureRuntime], defaults: defaults).contains("future_cli"))
    }

    @Test("Future provider storage keys stay runtime namespaced")
    func futureProviderStorageKeysStayRuntimeNamespaced() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "Future CLI/Preview"))

        #expect(
            RuntimeProviderSettingsStore.executablePathKey(for: futureRuntime)
                == "astra.runtime.future_cli_preview.executablePath.v1"
        )
        #expect(
            RuntimeProviderSettingsStore.homeDirectoryKey(for: futureRuntime)
                == "astra.runtime.future_cli_preview.homeDirectory.v1"
        )
    }

    @Test("Runtime configuration preserves arbitrary provider settings")
    func runtimeConfigurationPreservesArbitraryProviderSettings() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/opt/future/bin/future", for: futureRuntime)
        settings.setHomeDirectory("/tmp/future-home", for: futureRuntime)

        var configuration = AgentRuntimeConfiguration(providerSettings: settings)
        #expect(configuration.executablePath(for: futureRuntime) == "/opt/future/bin/future")
        #expect(configuration.homeDirectory(for: futureRuntime) == "/tmp/future-home")

        configuration.setExecutablePath("/opt/future/bin/future2", for: futureRuntime)
        #expect(configuration.executablePath(for: futureRuntime) == "/opt/future/bin/future2")
    }

    @Test("Model refresh signature ignores unrelated provider settings")
    func modelRefreshSignatureIgnoresUnrelatedProviderSettings() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        var settings = AgentRuntimeProviderSettings()
        settings.setHomeDirectory("/tmp/copilot-home", for: .copilotCLI)

        let before = RuntimeModelRefreshSignature.make(
            runtime: .copilotCLI,
            executablePath: "/opt/copilot/bin/copilot",
            providerSettings: settings,
            claudeProviderRaw: "anthropic",
            claudeVertexOpusModel: "opus-a",
            claudeVertexSonnetModel: "sonnet-a",
            claudeVertexHaikuModel: "haiku-a"
        )

        settings.setExecutablePath("/opt/future/bin/future", for: futureRuntime)
        settings.setHomeDirectory("/tmp/future-home", for: futureRuntime)

        let after = RuntimeModelRefreshSignature.make(
            runtime: .copilotCLI,
            executablePath: "/opt/copilot/bin/copilot",
            providerSettings: settings,
            claudeProviderRaw: "vertex",
            claudeVertexOpusModel: "opus-b",
            claudeVertexSonnetModel: "sonnet-b",
            claudeVertexHaikuModel: "haiku-b"
        )

        #expect(before == after)
    }

    /// The availability check refuses a Vertex route whose project ID cannot
    /// name a project. That only helps if correcting the field re-runs the
    /// check — the refresh is suppressed whenever the signature is unchanged,
    /// so a signature blind to the project ID would leave the user fixing the
    /// field and watching nothing happen.
    @Test("Model refresh signature tracks the Vertex project and region")
    func modelRefreshSignatureTracksVertexRoute() {
        func signature(projectID: String, region: String) -> String {
            RuntimeModelRefreshSignature.make(
                runtime: .claudeCode,
                executablePath: "/opt/claude/bin/claude",
                providerSettings: AgentRuntimeProviderSettings(),
                claudeProviderRaw: "vertex",
                claudeVertexProjectID: projectID,
                claudeVertexRegion: region,
                claudeVertexOpusModel: "opus",
                claudeVertexSonnetModel: "sonnet",
                claudeVertexHaikuModel: "haiku"
            )
        }

        let malformed = signature(projectID: "upo-nero-phi-su-deid-jsl  upo-nero-phi-su-deid-jsl", region: "global")
        let corrected = signature(projectID: "upo-nero-phi-su-deid-jsl", region: "global")
        #expect(malformed != corrected)
        #expect(corrected != signature(projectID: "upo-nero-phi-su-deid-jsl", region: "us-east5"))
    }

    /// Vertex settings belong to the Claude runtime alone, matching how the
    /// existing provider and model fields are gated.
    @Test("Vertex project and region stay out of other runtimes' signatures")
    func vertexRouteIsScopedToClaudeCode() {
        func signature(projectID: String) -> String {
            RuntimeModelRefreshSignature.make(
                runtime: .copilotCLI,
                executablePath: "/opt/copilot/bin/copilot",
                providerSettings: AgentRuntimeProviderSettings(),
                claudeProviderRaw: "vertex",
                claudeVertexProjectID: projectID,
                claudeVertexRegion: "global",
                claudeVertexOpusModel: "opus",
                claudeVertexSonnetModel: "sonnet",
                claudeVertexHaikuModel: "haiku"
            )
        }

        #expect(signature(projectID: "one-project") == signature(projectID: "another-project"))
    }

    @Test("Provider path status uses persisted path instead of unsaved draft")
    func providerPathStatusUsesPersistedPathInsteadOfUnsavedDraft() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))

        let statusPath = ProviderPathPersistenceState.persistedPath(
            for: futureRuntime,
            claudePath: "/custom/bin/claude",
            copilotPath: "/custom/bin/copilot",
            providerPath: ""
        )

        #expect(statusPath.isEmpty)
        #expect(ProviderPathPersistenceState.hasUnsavedDraft(draft: "/draft/bin/future", persisted: ""))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RuntimeProviderSettingsStoreTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
