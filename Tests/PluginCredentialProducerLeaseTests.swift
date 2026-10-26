import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Unpublished plugin generations remain owned by their producer", .serialized)
struct PluginCredentialProducerLeaseTests {
    @Test("The actual collector cannot delete a staged plugin generation before publication")
    func collectorCannotDeleteLivePreparation() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            package.skills[0].environmentKeys = ["API_TOKEN"]
            package.skills[0].environmentValues = [""]
            try env.disk.library.install(package)
            try env.installer.enable(package, in: env.workspace, modelContext: env.context,
                configInputs: ["API_TOKEN": "accepted-producer-token"])
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
            let component = CapabilityResourceOrigin.componentID(for: package.skills[0])
            let original = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
            var prepared: PluginCredentialGenerationTransaction? = try .prepareCopy(activation: activation,
                workspaceID: env.workspace.id, modelContext: env.context, skillName: package.name,
                persistence: SkillSecretSeam.required, additionalComponents: [component])
            let generation = try #require(prepared?.generation)
            let lockURL = try #require(prepared?.producerLease?.lockURL)
            #expect(try lockResultFromChild(lockURL) == 23)
            let staged = PluginActivation.credentialID(workspaceID: env.workspace.id, pluginID: package.id,
                componentID: component, runtimeSeed: activation.namespaceSeed, generation: generation)
            func value(_ id: UUID) -> String? {
                SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: id, store: KeychainSecretStore())
            }
            try #require(value(staged) == "accepted-producer-token")
            let outbox = try #require(PluginSecretCleanupOutbox(for: env.context))
            PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container), outbox: outbox)
            #expect(value(staged) == "accepted-producer-token")
            #expect(try outbox.pending().contains(staged))
            withExtendedLifetime(prepared) {}
            prepared = nil // A producer exit before publication leaves a recorded orphan.
            #expect(try lockResultFromChild(lockURL) == 0)
            PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container), outbox: outbox)
            #expect(value(staged) == nil)
            #expect(value(original) == "accepted-producer-token")
        }
    }
    @Test("First Add protects its actual secret write from a concurrent collector")
    func initialAddKeepsItsProducerOwnership() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            package.skills[0].environmentKeys = ["API_TOKEN"]
            package.skills[0].environmentValues = [""]
            try env.disk.library.install(package)
            var observed = 0
            try InstallerProducerWriteProbe.$afterSave.withValue({ namespace in
                MainActor.assumeIsolated {
                    observed += 1
                    PluginSecretCleanupOutbox.resumePending(modelContext: ModelContext(env.context.container))
                    #expect(SkillSecretSeam.required.loadSecretValue(key: "API_TOKEN", skillID: namespace,
                        store: KeychainSecretStore()) == "first-add-producer-token")
                }
            }) {
                try CapabilityInstaller(library: env.disk.library, appVersion: SemanticVersion(1, 0, 0),
                    skillSecrets: InstallerProducerWriteProbe.self).enable(package, in: env.workspace,
                        modelContext: env.context, configInputs: ["API_TOKEN": "first-add-producer-token"])
            }
            #expect(observed == 1)
            let live = try #require(PluginRuntimeProjection.project(workspace: env.workspace, packages: [package]).skills.first)
            #expect(live.environmentVariables["API_TOKEN"] == "first-add-producer-token")
        }
    }

    private func lockResultFromChild(_ file: URL) throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-I", "-c", """
        import fcntl, sys
        with open(sys.argv[1], 'r+') as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(23)
            sys.exit(0)
        """, file.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }

}

private enum InstallerProducerWriteProbe: SkillSecretPersisting {
    @TaskLocal static var afterSave: (@Sendable (UUID) -> Void)?
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        SkillSecretSeam.required.loadSecretValue(key: key, skillID: skillID, store: store)
    }
    static func readSecretValue(key: String, skillID: UUID, store: SecretStore) -> SecretReadOutcome {
        SkillSecretSeam.required.readSecretValue(key: key, skillID: skillID, store: store)
    }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        let saved = SkillSecretSeam.required.saveSecretValue(value, key: key, skillID: skillID,
            skillName: skillName, allowUserInteraction: allowUserInteraction)
        if saved { afterSave?(skillID) }
        return saved
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { SkillSecretSeam.required.deleteSecret(key: key, skillID: skillID) }
    static func secretExists(key: String, skillID: UUID) -> Bool { SkillSecretSeam.required.secretExists(key: key, skillID: skillID) }
    static func deleteAllSecrets(skillID: UUID) { SkillSecretSeam.required.deleteAllSecrets(skillID: skillID) }
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { SkillSecretSeam.required.deleteAllSecretsReportingResult(skillID: skillID) }
}
