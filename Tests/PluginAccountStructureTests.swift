import Foundation
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// An external plugin's endpoint and account name are the account's
/// structure, not settings: they land on the account, validated, while its
/// other fields are still stored as credentials. Fixtures are
/// `PluginOperationsTests`'s.
@Suite("Plugin account structure fields")
@MainActor
struct PluginAccountStructureTests {
    typealias Fixtures = PluginOperationsTests

    /// A multi-tenant tracker (no default URL) imported from a file: a site
    /// field stored as the account's endpoint, a name field as its alias,
    /// and a project setting.
    static func multiTenant() -> PluginPackage {
        var package = Fixtures.package(version: "1.0.0")
        package.connectors[0].baseURL = ""
        package.connectors[0].configHints = [
            .init(key: "TRACKER_SITE", hint: "Your site", isList: false, storage: PluginConnector.ConfigHint.accountBaseURL),
            .init(key: "TRACKER_ACCOUNT_NAME", hint: "Name", isList: false, storage: PluginConnector.ConfigHint.accountAlias),
            .init(key: "TRACKER_PROJECT", hint: "Project", isList: false)
        ]
        return package
    }

    @Test("An external plugin's endpoint field lands on the account, validated; its other fields are still credentials")
    func endpointFieldLandsOnTheAccount() throws {
        let package = Self.multiTenant()
        let connector = package.connectors[0]
        #expect(!PluginConnectorFieldTrust.isBundled(package.id))
        let stored = PluginConnectorFieldTrust.asStored(connector, in: package)
        #expect(stored.credentialHints.map(\.key) == ["TRACKER_TOKEN", "TRACKER_PROJECT"])
        #expect(stored.configHints.map(\.key) == ["TRACKER_SITE", "TRACKER_ACCOUNT_NAME"])
        #expect(PluginConnectorFieldTrust.settingsStoredAsCredentials(of: connector, in: package) == ["TRACKER_PROJECT"])

        let env = try Fixtures.Environment()
        let component = connector.setupComponentID
        try env.installer.install(
            package, into: env.workspace, modelContext: env.context,
            configInputs: [
                PluginSetupInputs.key("TRACKER_SITE", component: component): "https://acme.tracker.example.com",
                PluginSetupInputs.key("TRACKER_ACCOUNT_NAME", component: component): "Acme"
            ],
            announceCatalogMutation: false
        )
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: component).first)
        #expect(account.baseURL == "https://acme.tracker.example.com")
        #expect(account.name == "Acme")
        #expect(!account.configKeys.contains("TRACKER_SITE") && !account.credentialKeys.contains("TRACKER_SITE"))
        #expect(account.credentialKeys.contains("TRACKER_PROJECT"))
        // The mirror can rebuild the endpoint.
        let mirror = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        #expect(mirror.connectors?.first { $0.id == account.id.uuidString }?.baseURL == "https://acme.tracker.example.com")
    }

    @Test("Update never adds endpoint or account-name fields to configuration", arguments: [false, true])
    func updateKeepsOneStructureOwner(legacyDuplicates: Bool) throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: package.connectors[0].setupComponentID).first)
        account.name = "Configured account"
        account.baseURL = "https://configured.example.com"
        if legacyDuplicates {
            account.configKeys += ["TRACKER_SITE", "TRACKER_ACCOUNT_NAME"]
            account.configValues += ["https://stale.example.com", "Stale duplicate"]
        }
        package.version = "2.0.0"
        package.connectors[0].configHints = Self.multiTenant().connectors[0].configHints
        var copied: [PluginUpdateService.CopiedSecret] = []
        _ = try PluginUpdateService.syncOwnedAccounts(of: activation, to: package, store: MockSecretStore(), copied: &copied)
        #expect(!account.configKeys.contains("TRACKER_SITE"))
        #expect(!account.configKeys.contains("TRACKER_ACCOUNT_NAME"))
        #expect(account.baseURL == "https://configured.example.com")
        #expect(account.name == "Configured account")
        #expect(account.configKeys == ["PROJECT"])
    }

    @Test("Update moves legacy structure values into empty account fields without dropping other settings")
    func updateRecoversLegacyStructure() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: package.connectors[0].setupComponentID).first)
        account.name = ""
        account.baseURL = ""
        account.configKeys += ["TRACKER_SITE", "TRACKER_ACCOUNT_NAME"]
        account.configValues += ["https://saved.example.com", "Saved name"]
        package.connectors[0].configHints = Self.multiTenant().connectors[0].configHints
        var copied: [PluginUpdateService.CopiedSecret] = []
        _ = try PluginUpdateService.syncOwnedAccounts(of: activation, to: package, store: MockSecretStore(), copied: &copied)
        #expect(account.baseURL == "https://saved.example.com")
        #expect(account.name == "Saved name")
        #expect(account.configKeys == ["PROJECT"])
        #expect(account.configValues == ["default-project"])
    }

    @Test("Invalid legacy endpoint values are retained and refuse Update", arguments: [
        "http://unsafe.example.com", "https://name:password@unsafe.example.com"
    ])
    func invalidLegacyStructureIsNotLost(endpoint: String) throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: package.connectors[0].setupComponentID).first)
        account.baseURL = ""
        account.configKeys += ["TRACKER_SITE"]
        account.configValues += [endpoint]
        package.connectors[0].configHints = Self.multiTenant().connectors[0].configHints
        var copied: [PluginUpdateService.CopiedSecret] = []
        #expect(throws: CapabilityInstaller.InstallationError.self) {
            try PluginUpdateService.syncOwnedAccounts(of: activation, to: package, store: MockSecretStore(), copied: &copied)
        }
        #expect(account.baseURL.isEmpty)
        #expect(account.configKeys.contains("TRACKER_SITE"))
        #expect(account.configValues.contains(endpoint))
        #expect(copied.isEmpty)
    }

    @Test("An endpoint that isn't HTTPS, or carries a password, is refused with the reason")
    func badEndpointIsRefused() throws {
        let package = Self.multiTenant()
        let component = package.connectors[0].setupComponentID
        for (url, reason) in [("http://acme.tracker.example.com", "HTTPS"), ("https://me:secret@acme.tracker.example.com", "password")] {
            let env = try Fixtures.Environment()
            #expect {
                try env.installer.install(
                    package, into: env.workspace, modelContext: env.context,
                    configInputs: [PluginSetupInputs.key("TRACKER_SITE", component: component): url],
                    announceCatalogMutation: false
                )
            } throws: { error in
                guard case CapabilityInstaller.InstallationError.blocked(let messages) = error else { return false }
                return messages.contains { $0.contains(reason) }
            }
            #expect(env.workspace.connectors.isEmpty)
        }
        // Two endpoint fields on one connector are refused by the validator.
        var twice = package
        twice.connectors[0].configHints.append(.init(key: "OTHER_SITE", hint: "", isList: false, storage: PluginConnector.ConfigHint.accountBaseURL))
        #expect(CapabilityPackageValidator.validate(package: twice, checkPrerequisites: false)
            .issues.contains { $0.title == "Two fields for one account value" })
    }
}
