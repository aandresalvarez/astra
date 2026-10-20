import Foundation
import os
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Round 23 review: a cleared secret comes back when its save fails, and a
/// setting the plugin stores as a credential never reaches a run as plain
/// text. Fixtures are `PluginOperationsTests`'s.
@Suite("Round 23 review: cleared secrets and withheld plain settings")
@MainActor
struct PluginRound23ReviewTests {
    typealias Fixtures = PluginOperationsTests

    @Test("Entering a now plain setting whose save fails puts the cleared secret back, or reports it")
    func clearedSecretIsRestoredWhenSaveFails() throws {
        let env = try Fixtures.Environment()
        let v1 = Fixtures.package(version: "1.0.0")
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        let skillID = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:report-agent")
        let projectKey = PluginActivation.settingKey(componentID: "skill:report-agent", key: "PROJECT")
        // An earlier definition kept PROJECT secret: recorded, with a value.
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: projectKey, on: activation)
        try env.context.save()
        HeldSecrets.reset()
        HeldSecrets.set("old-secret", key: "PROJECT", skillID: skillID)

        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting(
                "PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context,
                secrets: HeldSecrets.self, persist: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )
        }
        // The record is back, and so is the value it names.
        #expect(activation.secretSettingKeys.contains(projectKey))
        #expect(HeldSecrets.value(key: "PROJECT", skillID: skillID) == "old-secret")
        #expect(activation.configuration(forComponent: "skill:report-agent")["PROJECT"] == nil)

        // One the Keychain won't take back is reported, not reported gone.
        HeldSecrets.refusesWrites = true
        #expect(throws: PluginOperations.OperationError.secretRestoreFailed(key: "PROJECT")) {
            try PluginOperations.setSetting(
                "PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context,
                secrets: HeldSecrets.self, persist: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )
        }
        #expect(HeldSecrets.value(key: "PROJECT", skillID: skillID) == nil)

        // A save that lands clears it for good.
        HeldSecrets.refusesWrites = false
        HeldSecrets.set("old-secret", key: "PROJECT", skillID: skillID)
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context, secrets: HeldSecrets.self)
        #expect(!activation.secretSettingKeys.contains(projectKey))
        #expect(HeldSecrets.value(key: "PROJECT", skillID: skillID) == nil)
        #expect(activation.configuration(forComponent: "skill:report-agent")["PROJECT"] == "alpha")
    }

    @Test("A setting the plugin stores as a credential, still plain on the row, reaches no run as a setting")
    func promotedSettingStillPlainIsWithheld() throws {
        let env = try Fixtures.Environment()
        var package = PluginConnectorFieldTrustTests.importedPackage()
        // The skill declares the same key as a setting: an account carries
        // skill settings plain, except one a connector stores as a credential.
        package.skills[0].environmentKeys.append("TRACKER_PROJECT")
        package.skills[0].environmentValues.append("")
        try env.install(package)
        let account = try PluginOperations.addAccount(for: package.connectors[0], of: package, in: env.workspace, modelContext: env.context)
        // The promotion of TRACKER_PROJECT never landed: the row still holds
        // it plain, and not as a credential key.
        account.credentialKeys = ["TRACKER_TOKEN"]
        account.credentialValues = [""]
        account.configKeys = ["TRACKER_PROJECT"]
        account.configValues = ["ENG-4242"]
        try env.context.save()

        let store = MockSecretStore()
        #expect(account.saveCredential(key: "TRACKER_TOKEN", value: "tok", store: store))
        let projection = PluginRuntimeProjection.project(
            workspace: env.workspace, packages: [package], connectorMode: .runtimeCopies, definitions: [package]
        )
        let copy = try #require(projection.connectors.first { $0.id == account.id })
        #expect(!copy.configKeys.contains("TRACKER_PROJECT"))
        #expect(!copy.configValues.contains("ENG-4242"))
        let environment = ConnectorRuntimeProjection(
            connectors: [copy], secretStore: store, credentialExposurePolicy: .allowAllCredentials
        ).environmentVariables()
        #expect(!environment.values.contains("ENG-4242"))
        #expect(environment.values.contains("tok"))

        // Promoted for real, the value reaches the run from the Keychain.
        #expect(account.saveCredential(key: "TRACKER_PROJECT", value: "ENG-4242", store: store))
        account.configKeys = []
        account.configValues = []
        let promoted = try #require(PluginRuntimeProjection.project(
            workspace: env.workspace, packages: [package], connectorMode: .runtimeCopies, definitions: [package]
        ).connectors.first { $0.id == account.id })
        #expect(promoted.credentialKeys.contains("TRACKER_PROJECT"))
        #expect(ConnectorRuntimeProjection(
            connectors: [promoted], secretStore: store, credentialExposurePolicy: .allowAllCredentials
        ).environmentVariables().values.contains("ENG-4242"))
    }
}

/// Skill secrets held in memory, by key and namespace; writes can be refused.
private enum HeldSecrets: SkillSecretPersisting {
    private static let state = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    nonisolated(unsafe) static var refusesWrites = false

    private static func id(_ key: String, _ skillID: UUID) -> String { "\(key)@\(skillID.uuidString)" }
    static func reset() { state.withLock { $0 = [:] }; refusesWrites = false }
    static func set(_ value: String, key: String, skillID: UUID) { state.withLock { $0[id(key, skillID)] = value } }
    static func value(key: String, skillID: UUID) -> String? { state.withLock { $0[id(key, skillID)] } }

    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { value(key: key, skillID: skillID) }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        guard !refusesWrites else { return false }
        set(value, key: key, skillID: skillID)
        return true
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        state.withLock { $0[id(key, skillID)] = nil }
        return true
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { value(key: key, skillID: skillID) != nil }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { true }
}
