import Foundation
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Only ASTRA's bundled plugins keep plain connector settings: any other
/// plugin's setting is a credential, in the Keychain, masked and never
/// exported (`PluginConnectorFieldTrust`). Fixtures are
/// `PluginOperationsTests`'s.
@Suite("Plugin connector field trust")
@MainActor
struct PluginConnectorFieldTrustTests {
    typealias Fixtures = PluginOperationsTests

    /// The fixture plugin (not bundled) with a setting its author named
    /// like a harmless project field.
    static func importedPackage() -> PluginPackage {
        var package = Fixtures.package(version: "1.0.0")
        package.connectors[0].configHints = [.init(key: "TRACKER_PROJECT", hint: "Paste your project here", isList: false)]
        return package
    }

    static func jira() throws -> PluginPackage {
        try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
    }

    @Test("An imported plugin's setting is stored as a credential: Keychain, masked, not exported, still projected")
    func importedSettingIsACredential() throws {
        guard AstraSecureKeychainTestSupport.isAvailable else { return }
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer { AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: []) }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let env = try Fixtures.Environment()
                let package = Self.importedPackage()
                // The value arrives as a setting input, as every earlier caller sent it.
                try env.installer.install(
                    package, into: env.workspace, modelContext: env.context,
                    credentialInputs: ["TRACKER_TOKEN": "tracker-token-value"],
                    configInputs: ["TRACKER_PROJECT": "ENG-4242"],
                    announceCatalogMutation: false
                )
                let account = try #require(env.workspace.connectors.first)
                // A credential key, so the editor shows it masked
                // (`SecretEntryField`), never in its plain Configuration list.
                #expect(account.credentialKeys == ["TRACKER_TOKEN", "TRACKER_PROJECT"])
                #expect(!account.configKeys.contains("TRACKER_PROJECT"))
                #expect(!account.configValues.contains("ENG-4242"))
                #expect(KeychainService.load(key: "TRACKER_PROJECT", connector: account) == "ENG-4242")

                // Not in the workspace mirror.
                let mirror = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
                let exported = try #require(mirror.connectors?.first { $0.id == account.id.uuidString })
                #expect(!exported.configKeys.contains("TRACKER_PROJECT"))
                let json = try #require(String(data: JSONEncoder().encode(mirror), encoding: .utf8))
                #expect(!json.contains("ENG-4242"))

                // Still reaches the run, from the Keychain.
                let projection = PluginRuntimeProjection.project(
                    workspace: env.workspace, packages: [package], connectorMode: .runtimeCopies, definitions: [package]
                )
                let copy = try #require(projection.connectors.first)
                #expect(copy.credentialKeys.contains("TRACKER_PROJECT"))
                let environment = ConnectorRuntimeProjection(
                    connectors: [copy], secretStore: KeychainSecretStore(), credentialExposurePolicy: .allowAllCredentials
                ).environmentVariables()
                #expect(environment.values.contains("ENG-4242"))
            }
        }
    }

    @Test("A new account of an imported plugin lists its settings as credential fields")
    func addAccountListsImportedSettingsAsCredentials() throws {
        let env = try Fixtures.Environment()
        let package = Self.importedPackage()
        try env.install(package)
        let account = try PluginOperations.addAccount(
            for: package.connectors[0], of: package, in: env.workspace, modelContext: env.context
        )
        #expect(account.credentialKeys == ["TRACKER_TOKEN", "TRACKER_PROJECT"])
        #expect(account.configKeys.isEmpty)
        // Its value reaches the run from the secret store, through the
        // runtime copy's declared keys.
        let store = MockSecretStore()
        #expect(account.saveCredential(key: "TRACKER_PROJECT", value: "ENG-4242", store: store))
        let projection = PluginRuntimeProjection.project(
            workspace: env.workspace, packages: [package], connectorMode: .runtimeCopies, definitions: [package]
        )
        let copy = try #require(projection.connectors.first { $0.id == account.id })
        #expect(copy.credentialKeys.contains("TRACKER_PROJECT"))
        let environment = ConnectorRuntimeProjection(
            connectors: [copy], secretStore: store, credentialExposurePolicy: .allowAllCredentials
        ).environmentVariables()
        #expect(environment.values.contains("ENG-4242"))
        // Update keeps it there; a row that still holds it as plain text
        // keeps that value rather than gaining an empty credential beside it.
        let legacy = Connector(name: "Legacy", serviceType: "tracker")
        legacy.originPackageID = package.id
        legacy.configKeys = ["TRACKER_PROJECT"]
        legacy.configValues = ["ENG-1"]
        env.context.insert(legacy)
        legacy.workspace = env.workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        WorkspaceCapabilityActivation.bind(legacy, toComponent: componentID, of: activation)
        PluginUpdateService.syncOwnedAccounts(of: activation, to: package)
        #expect(account.credentialKeys == ["TRACKER_TOKEN", "TRACKER_PROJECT"])
        #expect(legacy.credentialKeys == ["TRACKER_TOKEN"])
        #expect(legacy.configValues == ["ENG-1"])
    }

    @Test("A bundled plugin's declared setting stays plain and is exported")
    func bundledSettingStaysPlain() throws {
        let jira = try Self.jira()
        let connector = try #require(jira.connectors.first { !$0.configHints.isEmpty })
        let stored = PluginConnectorFieldTrust.asStored(connector, in: jira)
        #expect(stored == connector)
        #expect(PluginConnectorFieldTrust.trustedPlainSettingKeys(of: connector, in: jira) == ["JIRA_PROJECTS"])

        let env = try Fixtures.Environment()
        let account = Connector(name: "Jira", serviceType: "jira", baseURL: "https://example.atlassian.net", authMethod: "basic")
        account.originPackageID = jira.id
        account.originComponentID = CapabilityResourceOrigin.componentID(for: connector)
        account.credentialKeys = connector.credentialHints.map(\.key)
        account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
        account.configKeys = ["JIRA_PROJECTS"]
        account.configValues = ["ENG, OPS"]
        env.context.insert(account)
        account.workspace = env.workspace
        let mirror = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        let exported = try #require(mirror.connectors?.first { $0.id == account.id.uuidString })
        #expect(exported.configKeys == ["JIRA_PROJECTS"])
        #expect(exported.configValues == ["ENG, OPS"])
    }

    @Test("An imported copy of a bundled plugin under another ID gets credentials, not plain settings")
    func importedCopyOfBundledPluginGetsCredentials() throws {
        var copy = try Self.jira()
        copy.id = "imported.jira-copy"
        let connector = try #require(copy.connectors.first { !$0.configHints.isEmpty })
        #expect(PluginConnectorFieldTrust.trustedPlainSettingKeys(of: connector, in: copy).isEmpty)
        let stored = PluginConnectorFieldTrust.asStored(connector, in: copy)
        #expect(stored.configHints.isEmpty)
        #expect(stored.credentialHints.map(\.key) == connector.credentialHints.map(\.key) + ["JIRA_PROJECTS"])
        // The same goes for a setting a bundled ID's definition doesn't declare.
        var extended = try Self.jira()
        let index = try #require(extended.connectors.firstIndex { !$0.configHints.isEmpty })
        extended.connectors[index].configHints.append(.init(key: "JIRA_SITE", hint: "Your site", isList: false))
        let extendedStored = PluginConnectorFieldTrust.asStored(extended.connectors[index], in: extended)
        #expect(extendedStored.configHints.map(\.key) == ["JIRA_PROJECTS"])
        #expect(extendedStored.credentialHints.map(\.key).contains("JIRA_SITE"))
    }

    /// Stands in for the installed definitions an account's creator is found in.
    enum StubCreator: ConnectorSettingStorageResolving {
        static func settingKeysStoredAsCredentials(
            originPackageID: String, originComponentID: String?, accountKeys: [String]
        ) -> Set<String> {
            originPackageID == "imported.tracker" ? ["TRACKER_PROJECT"] : []
        }
        static func declaredSettingKeysStoredAsCredentials(originPackageID: String, originComponentID: String?) -> Set<String>? {
            originPackageID == "imported.tracker" ? ["TRACKER_PROJECT"] : nil
        }
    }

    /// An older row of a third-party plugin holding a setting the mirror now
    /// withholds: the value moves to the Keychain before the mirror is its
    /// only other copy, and only once the Keychain has it.
    @Test("A withheld plain setting moves to the Keychain, and stays on the row when the move fails")
    func withheldPlainSettingMovesToTheKeychain() {
        func legacyRow(_ origin: String = "imported.tracker") -> Connector {
            let row = Connector(name: "Tracker", serviceType: "tracker", baseURL: "https://tracker.example.com", authMethod: "bearer")
            row.originPackageID = origin
            row.originComponentID = "connector:tracker:tracker-api"
            row.configKeys = ["TRACKER_PROJECT", "TRACKER_BASE_URL"]
            row.configValues = ["ENG-1", "https://tracker.example.com"]
            return row
        }
        // The Keychain refuses the write: nothing leaves the row.
        let refusing = MockSecretStore()
        refusing.failsWrites = true
        let kept = legacyRow()
        #expect(kept.moveSettingsStoredAsCredentials(resolver: StubCreator.self, store: refusing).isEmpty)
        #expect(kept.configValue("TRACKER_PROJECT") == "ENG-1" && kept.credentialKeys.isEmpty)
        // A creator that can't be found moves nothing either.
        let unknown = legacyRow("gone.tracker")
        #expect(unknown.moveSettingsStoredAsCredentials(resolver: StubCreator.self, store: MockSecretStore()).isEmpty)
        #expect(unknown.configKeys.count == 2)

        let store = MockSecretStore()
        let row = legacyRow()
        #expect(row.moveSettingsStoredAsCredentials(resolver: StubCreator.self, store: store) == ["TRACKER_PROJECT"])
        #expect(row.configKeys == ["TRACKER_BASE_URL"] && row.credentialKeys == ["TRACKER_PROJECT"])
        #expect(row.credentials(store: store)["TRACKER_PROJECT"] == "ENG-1")
        // The mirror now names it as a credential, and the Keychain holds it.
        let mirrored = ConnectorSettingStorageSeam.exportableConfig(
            keys: row.configKeys, values: row.configValues, originPackageID: row.originPackageID,
            originComponentID: row.originComponentID, resolver: StubCreator.self
        )
        #expect(mirrored.keys == ["TRACKER_BASE_URL"])
        // Idempotent: a second pass has nothing to move.
        #expect(row.moveSettingsStoredAsCredentials(resolver: StubCreator.self, store: store).isEmpty)
    }

    @Test("The mirror withholds a plain value an older row holds for a setting stored as a credential")
    func mirrorWithholdsLegacyPlainValues() {
        let keys = ["TRACKER_PROJECT", "TRACKER_BASE_URL"]
        let values = ["ENG-1", "https://tracker.example.com"]
        let withheld = ConnectorSettingStorageSeam.exportableConfig(
            keys: keys, values: values, originPackageID: "imported.tracker", originComponentID: "connector:tracker:tracker-api",
            resolver: StubCreator.self
        )
        #expect(withheld.keys == ["TRACKER_BASE_URL"])
        #expect(withheld.values == ["https://tracker.example.com"])
        // A row no plugin created is unchanged.
        let own = ConnectorSettingStorageSeam.exportableConfig(
            keys: keys, values: values, originPackageID: nil, originComponentID: nil, resolver: StubCreator.self
        )
        #expect(own.keys == keys && own.values == values)
    }

    @Test("The mirror withholds every setting of an account whose third-party creator can't be read")
    func mirrorFailsClosedForUnreadableCreator() throws {
        let keys = ["TRACKER_PROJECT", "TRACKER_BASE_URL"]
        let values = ["ENG-1", "https://tracker.example.com"]
        // Its library entry is unreadable, or a Remove kept the stamp.
        for stamp in ["connector:tracker:tracker-api", nil] {
            let unknown = ConnectorSettingStorageSeam.exportableConfig(
                keys: keys, values: values, originPackageID: "gone.\(UUID().uuidString)", originComponentID: stamp,
                resolver: PluginConnectorFieldTrust.self
            )
            #expect(unknown.keys.isEmpty && unknown.values.isEmpty)
        }
        // A bundled plugin's account still exports what ASTRA's own
        // definition declares plain, and nothing else.
        let jira = try #require(Self.jira().connectors.first { !$0.configHints.isEmpty })
        let bundled = ConnectorSettingStorageSeam.exportableConfig(
            keys: ["JIRA_PROJECTS", "JIRA_SITE"], values: ["ENG", "secret"], originPackageID: "jira-workflow",
            originComponentID: "connector:jira:unknown-\(UUID().uuidString)", resolver: PluginConnectorFieldTrust.self
        )
        #expect(jira.configHints.map(\.key).contains("JIRA_PROJECTS"))
        #expect(bundled.keys == ["JIRA_PROJECTS"] && bundled.values == ["ENG"])
    }
}
