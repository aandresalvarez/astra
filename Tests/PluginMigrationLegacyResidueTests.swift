import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin migration legacy residue", .serialized)
struct PluginMigrationLegacyResidueTests {
    @Test("A plugin skill's provenance takes precedence over a reserved display name", arguments: ["Read-Only", "Safe Bash"])
    func reservedNameDoesNotPreventMigration(name: String) throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.id = env.package.id
        package.connectors = []; package.localTools = []
        package.skills[0].name = name
        package.skills[0].environmentKeys = []; package.skills[0].environmentValues = []
        let library = CapabilityLibrary()
        try library.install(package)
        defer { _ = try? library.removePackage(id: package.id) }
        let spec = package.skills[0]
        let skill = Skill(name: spec.name, icon: spec.icon, skillDescription: spec.description,
            allowedTools: spec.allowedTools, disallowedTools: spec.disallowedTools,
            customTools: spec.customTools, behaviorInstructions: spec.behaviorInstructions)
        skill.workspace = env.workspace
        env.context.insert(skill)
        CapabilityResourceOrigin.stamp(skill, package: package, componentID: CapabilityResourceOrigin.componentID(for: spec))
        env.workspace.legacyEnabledCapabilityIDs = [package.id]
        env.workspace.legacyInstalledPluginIDs = [package.id]
        try env.context.save()
        try #require(PluginActivationMigration.needsMigration(modelContext: env.context, packages: [package]))
        let report = try PluginActivationMigration.migrate(modelContext: env.context, packages: [package])
        #expect(report.skillsProjected == 1)
        #expect(try env.context.fetch(FetchDescriptor<Skill>()).isEmpty)
        let needsAnotherPass = PluginActivationMigration.needsMigration(modelContext: env.context, packages: [package])
        #expect(!needsAnotherPass)
        let projected = PluginRuntimeProjection.project(workspace: env.workspace, packages: [package])
        #expect(projected.skills.map(\.name) == [name])
        let task = AgentTask(title: "Use migrated named skill", goal: "Use the plugin", workspace: env.workspace)
        env.context.insert(task)
        #expect(TaskCapabilityResolver(task: task).resourceInventory.behaviorSkills.contains { $0.name == name })
    }

    @Test("Connector-only legacy residue is released once and retains its opaque credentials", arguments: [false, true])
    func orphanAccountIsNotAnEndlessMigration(definitionPresent: Bool) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let package = PluginOperationsTests.package(version: "1.0.0")
            let account = Connector(name: "Legacy account", serviceType: "custom", baseURL: "https://legacy.example")
            account.workspace = env.workspace
            account.credentialKeys = ["TOKEN"]
            account.credentialValues = [""]
            CapabilityResourceOrigin.stamp(account, package: package,
                componentID: CapabilityResourceOrigin.componentID(for: package.connectors[0]))
            env.context.insert(account)
            try env.context.save()
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: account))
            try #require(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "accepted-legacy-alias", label: nil))
            try #require(KeychainService.load(key: "TOKEN", connectorID: account.id) == nil)
            let packages = definitionPresent ? [package] : []
            let needsMigration = PluginActivationMigration.needsMigration(modelContext: env.context, packages: packages)
            #expect(needsMigration)
            _ = try PluginActivationMigration.migrate(modelContext: env.context, packages: packages)
            #expect(account.originPackageID == nil)
            #expect(account.credentialNamespaceID != nil)
            #expect(account.currentCredentialValue(forKey: "TOKEN") == "accepted-legacy-alias")
            let needsAnotherPass = PluginActivationMigration.needsMigration(modelContext: env.context, packages: packages)
            #expect(!needsAnotherPass)
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.currentCredentialValue(forKey: "TOKEN") == "accepted-legacy-alias")
            #expect(saved.originPackageID == nil)
        }
    }

    @Test("Releasing provenance cannot publish into the accepted legacy slot before a proved save")
    func rejectedOrphanMigrationDoesNotBackfillLegacySlot() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let package = PluginOperationsTests.package(version: "1.0.0")
            let account = Connector(name: "Legacy account", serviceType: "custom", baseURL: "https://legacy.example")
            account.workspace = env.workspace
            account.credentialKeys = ["TOKEN"]; account.credentialValues = [""]
            CapabilityResourceOrigin.stamp(account, package: package,
                componentID: CapabilityResourceOrigin.componentID(for: package.connectors[0]))
            env.context.insert(account)
            try env.context.save()
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: account))
            try #require(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "accepted-legacy-alias", label: nil))
            #expect(throws: (any Error).self) {
                _ = try PluginActivationMigration.migrate(modelContext: env.context, packages: [], persist: { _ in
                    #expect(KeychainService.load(key: "TOKEN", connectorID: account.id) == nil)
                })
            }
            #expect(KeychainService.load(key: "TOKEN", connectorID: account.id) == nil)
            #expect(account.originPackageID == package.id)
            #expect(account.currentCredentialValue(forKey: "TOKEN") == "accepted-legacy-alias")
        }
    }

    @Test("A saved orphan migration recovers its account generation after reopening", arguments: [false, true])
    func savedAccountRecoversForward(reportedSaveFailure: Bool) throws {
        try withOrphanAccount { env, account in
            let persist: ((ModelContext) throws -> Void)? = reportedSaveFailure ? { context in
                try context.save()
                throw NSError(domain: "synthetic.orphan-migration.saved", code: 1)
            } : nil
            var operationID: UUID?
            do {
                try PluginActivationMigration.migrate(modelContext: env.context, packages: [], persist: persist,
                    rewriteMirror: reportedSaveFailure ? nil : { _ in false })
                Issue.record("A saved migration must report its pending recovery")
            } catch let problem as PluginOperationProblem { operationID = problem.operationID }
            let id = try #require(operationID)
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            let namespace = try #require(saved.credentialNamespaceID)
            #expect(saved.originPackageID == nil)
            #expect(saved.currentCredentialValue(forKey: "TOKEN") == "accepted-legacy-alias")
            let journal = try #require(try ConnectorCredentialGenerationJournal(modelContext: reopened.mainContext))
            #expect(try journal.pending().contains { $0.credentialNamespaceID == namespace })
            #expect(journal.resumePending(modelContext: reopened.mainContext) == 0)
            #expect(PluginOperationRecovery.resumePending(modelContext: reopened.mainContext, only: id).completed == 1)
            _ = journal.resumePending(modelContext: reopened.mainContext)
            #expect(saved.credentialNamespaceID == namespace)
            #expect(saved.currentCredentialValue(forKey: "TOKEN") == "accepted-legacy-alias")
            #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
        }
    }

    @Test("Releasing an orphan keeps unadmitted raw credentials as review debt")
    func rawFieldsAreNotAdmittedOrDiscarded() throws {
        try withOrphanAccount { env, account in
            account.credentialKeys.append("SECOND_TOKEN")
            account.credentialValues.append("your-token-here")
            try env.context.save()
            try PluginActivationMigration.migrate(modelContext: env.context, packages: [])
            #expect(account.currentCredentialValue(forKey: "TOKEN") == "accepted-legacy-alias")
            #expect(account.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
            #expect(account.credentialValues == ["", "your-token-here"])
            let reopened = try env.disk.reopen()
            let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<Connector>()).first)
            #expect(saved.credentialValues == ["", "your-token-here"])
            #expect(saved.currentCredentialValue(forKey: "SECOND_TOKEN") == nil)
        }
    }

    private func withOrphanAccount(_ body: (PluginAddCommitTests.Fixture, Connector) throws -> Void) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            let package = PluginOperationsTests.package(version: "1.0.0")
            let account = Connector(name: "Legacy account", serviceType: "custom", baseURL: "https://legacy.example")
            account.workspace = env.workspace
            account.credentialKeys = ["TOKEN"]; account.credentialValues = [""]
            CapabilityResourceOrigin.stamp(account, package: package,
                componentID: CapabilityResourceOrigin.componentID(for: package.connectors[0]))
            env.context.insert(account)
            try env.context.save()
            let stable = try #require(KeychainSecretStore.stableConnectorEntityID(for: account))
            try #require(AstraSecureKeychainStore.save(service: stable, account: "TOKEN", value: "accepted-legacy-alias", label: nil))
            try body(env, account)
        }
    }
}
