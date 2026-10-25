import Foundation
import Testing
import SwiftData
import os
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Keychain User Interaction Routing", .serialized)
struct KeychainUserInteractionRoutingTests {
    @Test("Explicit credential entry paths request promptable Keychain saves")
    func explicitCredentialEntryPathsRequestPromptableSaves() throws {
        let connectorView = try source("Astra/Views/ConnectorsManagerView.swift")
        let skillView = try source("Astra/Views/SkillsManagerView.swift")
        let chatView = try source("Astra/Views/ChatPanelView.swift")
        let outlook = try source("Astra/Services/Persistence/OutlookOAuthVaultSession.swift")
        let permissionsView = try source("Astra/Views/MacOSPermissionsSectionView.swift")
        let onboardingOrchestrator = try source("Astra/Services/Tasks/WorkspaceImportOrchestrator.swift")

        #expect(connectorView.contains("allowUserInteraction: true"))
        // The view delegates; the runtime test below checks the actual save
        // policy rather than requiring Keychain implementation in a view.
        #expect(skillView.contains("SkillCredentialEditor.save("))
        #expect(chatView.contains("allowCredentialUserInteraction: !credentials.isEmpty"))
        #expect(outlook.contains("allowUserInteraction: allowUserInteraction"))
        // The Retry-Keychain-Check action (both the row-level and header
        // retry buttons) must request a promptable probe — otherwise a
        // denied/blocked Keychain permission can never be recovered from,
        // since the retry reruns the same non-interactive check forever.
        #expect(permissionsView.contains("allowKeychainUserInteraction: true"))
        #expect(onboardingOrchestrator.contains("allowCredentialUserInteraction: inputs.credentialInputs.values.contains"))
    }

    @Test("Background Keychain paths remain non-interactive by default")
    func backgroundKeychainPathsRemainNonInteractiveByDefault() throws {
        let keychainService = try source("Astra/Services/Persistence/KeychainService.swift")
        let skill = try source("Astra/Models/Skill.swift")
        let outlook = try source("Astra/Services/Persistence/OutlookOAuthVaultSession.swift")

        #expect(keychainService.contains("allowUserInteraction: Bool = false"))
        #expect(skill.contains("allowUserInteraction: Bool = false"))
        #expect(outlook.contains("allowUserInteraction: Bool = false"))
    }

    @MainActor
    @Test("Explicit skill entry prompts only for replacement, never for retained copies")
    func skillEntryUsesTheActualParticipantPromptPolicy() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let previous = SkillSecretSeam.required
            PromptRoutingSkillSecrets.reset()
            SkillSecretSeam.register(PromptRoutingSkillSecrets.self)
            defer { SkillSecretSeam.register(previous); PromptRoutingSkillSecrets.reset() }
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let skill = Skill(name: "Prompt policy")
            skill.environmentKeys = ["RETAINED_SECRET"]
            skill.environmentValues = [""]
            skill.workspace = env.workspace
            env.context.insert(skill)
            try env.context.save()
            try SkillCredentialEditor.save("explicit-synthetic-token", forKey: "API_TOKEN", on: skill, modelContext: env.context)
            let writes = PromptRoutingSkillSecrets.writes
            #expect(writes.count == 2)
            #expect(writes.contains { $0.key == "API_TOKEN" && $0.promptable })
            #expect(writes.contains { $0.key == "RETAINED_SECRET" && !$0.promptable })
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(filePath: #filePath)
        let repoRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }
}

private enum PromptRoutingSkillSecrets: SkillSecretPersisting {
    struct Write: Sendable { let key: String; let promptable: Bool }
    private static let recorded = OSAllocatedUnfairLock<[Write]>(initialState: [])
    static var writes: [Write] { recorded.withLock { $0 } }
    static func reset() { recorded.withLock { $0 = [] } }
    static func readSecretValue(key: String, skillID: UUID, store: SecretStore) -> SecretReadOutcome {
        key == "RETAINED_SECRET" ? .value("retained-synthetic-secret") : .missing
    }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        key == "RETAINED_SECRET" ? "retained-synthetic-secret" : nil
    }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        recorded.withLock { $0.append(Write(key: key, promptable: allowUserInteraction)) }
        return true
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { key == "RETAINED_SECRET" }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { true }
}
