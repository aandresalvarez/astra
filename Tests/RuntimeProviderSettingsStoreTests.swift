import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Runtime Provider Settings Store")
struct RuntimeProviderSettingsStoreTests {
    @Test("Built-in provider path keys stay backward compatible")
    func builtInProviderPathKeysStayBackwardCompatible() {
        #expect(RuntimeProviderSettingsStore.executablePathKey(for: .claudeCode) == "claudePath")
        #expect(RuntimeProviderSettingsStore.executablePathKey(for: .copilotCLI) == "copilotPath")
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
        #expect(defaults.string(forKey: "claudePath") == nil)
        #expect(defaults.string(forKey: "copilotPath") == nil)
        #expect(defaults.string(forKey: RuntimeProviderSettingsStore.executablePathKey(for: futureRuntime)) == "/opt/future/bin/future")

        let settings = RuntimeProviderSettingsStore.settings(for: [futureRuntime], defaults: defaults)
        #expect(settings.executablePath(for: futureRuntime) == "/opt/future/bin/future")
        #expect(settings.homeDirectory(for: futureRuntime) == "/tmp/future-home")
        #expect(RuntimeProviderSettingsStore.signature(for: [futureRuntime], defaults: defaults).contains("future_cli"))
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

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RuntimeProviderSettingsStoreTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
