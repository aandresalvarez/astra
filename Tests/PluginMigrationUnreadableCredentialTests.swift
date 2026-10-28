import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// A rebuilt ad-hoc ASTRA can't read Keychain items an earlier build wrote:
/// the item trusts only the old binary, so the read fails silently with UI
/// disabled (`.unavailable`). On 2026-10-26 four such accounts kept
/// `plugin_activations_v21` deferred on every launch, for every workspace, and
/// the account editor couldn't replace one value without copying the other.
@MainActor
@Suite("Plugin migration with unreadable account credentials", .serialized)
struct PluginMigrationUnreadableCredentialTests {
    @Test("An unreadable account is bound as it is while the rest migrates, and re-entering its values finishes it")
    func unreadableAccountDefersAlone() throws {
        try withLegacyAccounts { legacy in
            let env = legacy.env
            #expect(PluginActivationMigration.needsMigration(modelContext: env.context, packages: [legacy.package]))
            let report = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: legacy.vault)
            #expect(report.accountsBound == 2)
            #expect(report.accountsAwaitingReentry == [legacy.unreadable.id: "TRACKER_EMAIL"])
            #expect(env.workspace.legacyInstalledPluginIDs.isEmpty && env.workspace.legacyEnabledCapabilityIDs.isEmpty)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: legacy.package.id, in: env.workspace))
            #expect(Set(activation.accounts(forComponent: legacy.component).map(\.id)) == [legacy.readable.id, legacy.unreadable.id])

            // The readable account has its generation; the other one is
            // exactly as it was, its values still where they were.
            #expect(legacy.readable.credentialNamespaceID != nil)
            #expect(legacy.readable.currentCredentialValue(forKey: "TRACKER_TOKEN") == "one-TRACKER_TOKEN")
            #expect(legacy.unreadable.credentialNamespaceID == nil)
            #expect(legacy.unreadable.originPackageID == legacy.package.id)
            legacy.expectLegacyValuesIntact()

            // Later launches retry it; nothing about it changes until its
            // values are re-entered.
            #expect(PluginActivationMigration.needsMigration(modelContext: env.context, packages: [legacy.package]))
            let again = try PluginActivationMigration.migrate(modelContext: env.context, packages: [legacy.package],
                vault: legacy.vault)
            #expect(again.accountsAwaitingReentry == report.accountsAwaitingReentry)
            #expect(again.accountsBound == 0 && again.activations == 0)
            #expect(legacy.unreadable.credentialNamespaceID == nil)
            legacy.expectLegacyValuesIntact()

            // The editor names what to re-enter, and won't replace one value
            // without the other: that generation would drop it.
            #expect(ConnectorCredentialEditor.unreadableKeys(of: legacy.readable, vault: legacy.vault).isEmpty)
            #expect(ConnectorCredentialEditor.unreadableKeys(of: legacy.unreadable, vault: legacy.vault)
                == ["TRACKER_EMAIL", "TRACKER_TOKEN"])
            #expect(throws: ConnectorCredentialGenerationTransaction.Failure.self) {
                _ = try ConnectorCredentialEditor.save(["TRACKER_TOKEN": "reentered-token"], on: legacy.unreadable,
                    modelContext: env.context, vault: legacy.vault)
            }
            #expect(legacy.unreadable.credentialNamespaceID == nil)
            legacy.expectLegacyValuesIntact()

            let failure = try ConnectorCredentialEditor.save(
                ["TRACKER_EMAIL": "reentered@example.com", "TRACKER_TOKEN": "reentered-token"],
                on: legacy.unreadable, modelContext: env.context, vault: legacy.vault)
            #expect(failure?.key == nil)
            let namespace = try #require(legacy.unreadable.credentialNamespaceID)
            #expect(legacy.unreadable.currentCredentialValue(forKey: "TRACKER_EMAIL") == "reentered@example.com")
            #expect(legacy.unreadable.currentCredentialValue(forKey: "TRACKER_TOKEN") == "reentered-token")
            #expect(ConnectorCredentialEditor.unreadableKeys(of: legacy.unreadable, vault: legacy.vault).isEmpty)
            #expect(!PluginActivationMigration.needsMigration(modelContext: env.context, packages: [legacy.package]))

            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first { $0.id == legacy.unreadable.id })
            #expect(saved.credentialNamespaceID == namespace)
            #expect(saved.currentCredentialValue(forKey: "TRACKER_TOKEN") == "reentered-token")
            #expect(saved.accountBindings.contains { !$0.isDeleted && $0.componentID == legacy.component })
        }
    }

    @Test("An unreadable account whose plugin is gone keeps the provenance its legacy slot is named by")
    func unreadableOrphanKeepsItsSlot() throws {
        try withLegacyAccounts { legacy in
            let env = legacy.env
            let report = try PluginActivationMigration.migrate(modelContext: env.context, packages: [], vault: legacy.vault)
            #expect(report.accountsAwaitingReentry.keys.sorted() == [legacy.unreadable.id])
            #expect(legacy.readable.originPackageID == nil)
            #expect(legacy.readable.currentCredentialValue(forKey: "TRACKER_TOKEN") == "one-TRACKER_TOKEN")
            // Released, its stable slot would be named by other fields and
            // the saved values would belong to no account.
            #expect(legacy.unreadable.originPackageID == legacy.package.id)
            #expect(legacy.unreadable.originComponentID == legacy.component)
            #expect(legacy.unreadable.credentialNamespaceID == nil)
            legacy.expectLegacyValuesIntact()
            #expect(PluginActivationMigration.needsMigration(modelContext: env.context, packages: []))

            let failure = try ConnectorCredentialEditor.save(
                ["TRACKER_EMAIL": "reentered@example.com", "TRACKER_TOKEN": "reentered-token"],
                on: legacy.unreadable, modelContext: env.context, vault: legacy.vault)
            #expect(failure?.key == nil)
            let finished = try PluginActivationMigration.migrate(modelContext: env.context, packages: [], vault: legacy.vault)
            #expect(finished.accountsAwaitingReentry.isEmpty)
            #expect(legacy.unreadable.originPackageID == nil)
            #expect(legacy.unreadable.currentCredentialValue(forKey: "TRACKER_TOKEN") == "reentered-token")
            #expect(!PluginActivationMigration.needsMigration(modelContext: env.context, packages: []))
        }
    }

    /// The real vault, except that the named namespaces refuse reads the way
    /// items an earlier ad-hoc build wrote refuse this one. Shared with
    /// `PluginMigrationUnreadableSkillSecretTests`.
    struct RefusingVault: SecretStore {
        let refused: Set<String>
        private let real = KeychainSecretStore()
        init(refused: Set<String>) { self.refused = refused }
        func read(key: String, entityID: String) -> SecretReadOutcome {
            refused.contains(entityID) ? .unavailable : real.read(key: key, entityID: entityID)
        }
        func load(key: String, entityID: String) -> String? {
            refused.contains(entityID) ? nil : real.load(key: key, entityID: entityID)
        }
        func save(key: String, value: String, entityID: String, label: String?) -> Bool {
            real.save(key: key, value: value, entityID: entityID, label: label)
        }
        func delete(key: String, entityID: String) -> Bool { real.delete(key: key, entityID: entityID) }
        func deleteAll(entityID: String) { real.deleteAll(entityID: entityID) }
        func exists(key: String, entityID: String) -> Bool {
            !refused.contains(entityID) && real.exists(key: key, entityID: entityID)
        }
    }

    private struct Legacy {
        let env: PluginAddCommitTests.Fixture
        let package: PluginPackage
        let component: String
        let readable: Connector
        let unreadable: Connector
        let vault: RefusingVault

        /// Read past the refusal: nothing was moved, overwritten or deleted.
        func expectLegacyValuesIntact() {
            let slot = KeychainSecretStore.connectorEntityID(for: unreadable.id)
            for key in ["TRACKER_EMAIL", "TRACKER_TOKEN"] {
                #expect(AstraSecureKeychainStore.read(service: slot, account: key) == .value("two-\(key)"))
            }
        }
    }

    private func withLegacyAccounts(_ body: (Legacy) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.skills = []; package.localTools = []
            package.connectors[0].credentialHints = [.init(key: "TRACKER_EMAIL", hint: "Email"),
                                                     .init(key: "TRACKER_TOKEN", hint: "Token")]
            let component = CapabilityResourceOrigin.componentID(for: package.connectors[0])
            @MainActor func account(_ name: String, host: String) throws -> Connector {
                let account = Connector(name: name, serviceType: "tracker", baseURL: "https://\(host).tracker.example.com")
                account.workspace = env.workspace
                account.credentialKeys = ["TRACKER_EMAIL", "TRACKER_TOKEN"]
                account.credentialValues = ["", ""]
                CapabilityResourceOrigin.stamp(account, package: package, componentID: component)
                env.context.insert(account)
                for key in account.credentialKeys {
                    try #require(AstraSecureKeychainStore.save(service: KeychainSecretStore.connectorEntityID(for: account.id),
                        account: key, value: "\(host)-\(key)", label: nil))
                }
                return account
            }
            let readable = try account("Readable", host: "one")
            let unreadable = try account("Unreadable", host: "two")
            env.workspace.legacyEnabledCapabilityIDs = [package.id]
            env.workspace.legacyInstalledPluginIDs = [package.id]
            env.workspace.legacyInstalledPluginVersions = [package.version]
            try env.context.save()
            let vault = RefusingVault(refused: Set(KeychainSecretStore.connectorEntityIDs(for: unreadable)))
            try body(Legacy(env: env, package: package, component: component,
                readable: readable, unreadable: unreadable, vault: vault))
        }
    }
}
