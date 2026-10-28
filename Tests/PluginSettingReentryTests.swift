import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin setting re-entry", .serialized)
struct PluginSettingReentryTests {
    @Test("Re-entry replaces two refused components together and preserves readable settings and old values")
    func replacesAllUnreadableValuesInOneGeneration() throws {
        try withFixture { env, package, activation, vault, changes, original in
            let before = PluginActivationRecord(activation)
            #expect(throws: PluginOperations.OperationError.secretReadFailed(key: "API_TOKEN")) {
                try PluginOperations.setSettings([changes[0]], package: package, in: env.workspace,
                    modelContext: env.context, vault: vault)
            }
            #expect(PluginActivationRecord(activation) == before)
            try PluginOperations.setSettings(changes, package: package, in: env.workspace,
                modelContext: env.context, vault: vault)
            #expect(activation.credentialNamespaceSeed != before.credentialNamespaceSeed)
            for (index, skill) in package.skills.enumerated() {
                #expect(try PluginOperations.setting("API_TOKEN", of: skill, in: activation) == (index < 2 ? "new-\(index)" : "old-\(index)"))
                #expect(AstraSecureKeychainStore.read(service: KeychainSecretStore.skillEntityID(for: original[index]),
                    account: "API_TOKEN") == .value("old-\(index)"))
            }
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
            #expect(saved.credentialNamespaceSeed == activation.credentialNamespaceSeed)
            #expect(try reopened.mainContext.fetchCount(FetchDescriptor<Workspace>()) == 1)
            #expect(try PluginOperations.setting("API_TOKEN", of: package.skills[0], in: saved) == "new-0")
        }
    }

    @Test("A failed batch domain save preserves the old generation and every saved value")
    func failedSavePreservesAllValues() throws {
        try withFixture { env, package, activation, vault, changes, original in
            let before = PluginActivationRecord(activation)
            #expect(throws: PluginOperations.OperationError.saveFailed) {
                try PluginOperations.setSettings(changes, package: package, in: env.workspace,
                    modelContext: env.context, persist: { _, _ in throw CocoaError(.fileWriteUnknown) }, vault: vault)
            }
            #expect(PluginActivationRecord(activation) == before)
            for (index, namespace) in original.enumerated() {
                #expect(AstraSecureKeychainStore.read(service: KeychainSecretStore.skillEntityID(for: namespace),
                    account: "API_TOKEN") == .value("old-\(index)"))
            }
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).first)
            #expect(PluginActivationRecord(saved) == before)
        }
    }

    @Test("Duplicate fields and an obsolete definition cannot rotate a credential generation")
    func rejectsInvalidBatches() throws {
        try withFixture { env, package, activation, vault, changes, _ in
            let before = PluginActivationRecord(activation)
            #expect(throws: PluginOperations.OperationError.invalidSettings) {
                try PluginOperations.setSettings([changes[0], changes[0]], package: package, in: env.workspace,
                    modelContext: env.context, vault: vault)
            }
            var obsolete = package
            obsolete.version = "0.0.1"
            #expect(throws: PluginOperations.OperationError.updateRequired) {
                try PluginOperations.setSettings(changes, package: obsolete, in: env.workspace,
                    modelContext: env.context, vault: vault)
            }
            #expect(PluginActivationRecord(activation) == before)
        }
    }

    private func withFixture(_ body: (PluginAddCommitTests.Fixture, PluginPackage, PluginActivation,
        PluginMigrationUnreadableCredentialTests.RefusingVault, [PluginOperations.SettingChange], [UUID]) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []; package.templates = []
            let template = package.skills[0]
            package.skills = (0..<3).map { index in
                var skill = template
                skill.id = "component-\(index)"; skill.name = "Component \(index)"
                skill.environmentKeys = ["API_TOKEN"]; skill.environmentValues = [""]
                return skill
            }
            _ = try env.installer.enable(package, in: env.workspace, modelContext: env.context)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
            var original: [UUID] = []
            for (index, skill) in package.skills.enumerated() {
                let component = CapabilityResourceOrigin.componentID(for: skill)
                let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
                original.append(namespace)
                try #require(AstraSecureKeychainStore.save(service: KeychainSecretStore.skillEntityID(for: namespace),
                    account: "API_TOKEN", value: "old-\(index)", label: nil))
                WorkspaceCapabilityActivation.setSecretRecorded(true,
                    forKey: PluginActivation.settingKey(componentID: component, key: "API_TOKEN"), on: activation)
            }
            try env.context.save()
            let vault = PluginMigrationUnreadableCredentialTests.RefusingVault(
                refused: Set(original.prefix(2).map(KeychainSecretStore.skillEntityID(for:))))
            let changes = (0..<2).map { PluginOperations.SettingChange(skill: package.skills[$0], key: "API_TOKEN", value: "new-\($0)") }
            try body(env, package, activation, vault, changes, original)
        }
    }
}
