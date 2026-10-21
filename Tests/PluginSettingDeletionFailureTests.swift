import Foundation
import os
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@MainActor
@Suite("Plugin setting credential deletion")
struct PluginSettingDeletionFailureTests {
    @Test("An unsaved plain replacement leaves the old secret untouched")
    func unsavedReplacementPreservesOriginalSecret() throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        try env.install(package)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        WorkspaceCapabilityActivation.setConfigValue("previous", forKey: "skill:report-agent#PROJECT", on: activation)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:report-agent#PROJECT", on: activation)
        try env.context.save()
        let before = PluginActivationRecord(activation)
        var saves = 0
        RefusingSettingDeletion.deletes.withLock { $0 = 0 }
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting("PROJECT", to: "replacement", of: package.skills[0],
                package: package, in: env.workspace, modelContext: env.context,
                secrets: RefusingSettingDeletion.self, persist: { _, _ in saves += 1 })
        }
        #expect(saves == 1)
        #expect(RefusingSettingDeletion.deletes.withLock { $0 } == 0)
        #expect(PluginActivationRecord(activation) == before)
        #expect(try PluginOperations.setting("PROJECT", of: package.skills[0], in: activation) == "previous")
    }
}

private enum RefusingSettingDeletion: SkillSecretPersisting {
    static let deletes = OSAllocatedUnfairLock(initialState: 0)
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { "old-secret" }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { deletes.withLock { $0 += 1 }; return false }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { false }
}
