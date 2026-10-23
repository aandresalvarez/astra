import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Plugin skill setting ownership")
@MainActor
struct PluginSkillSettingOwnershipTests {
    @Test("Skill settings stay activation-owned through Add, another account, editing and runtime projection",
          arguments: [false, true], ["", "default-project"])
    func activationOwnsSkillSettings(legacyDuplicate: Bool, defaultValue: String) throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.skills[0].environmentValues = [defaultValue]
        try env.install(package)
        let first = try #require(env.workspace.connectors.first)
        let second = try PluginOperations.addAccount(for: package.connectors[0], of: package,
            in: env.workspace, modelContext: env.context)
        #expect(!first.configKeys.contains("PROJECT"))
        #expect(!second.configKeys.contains("PROJECT"))
        if legacyDuplicate {
            first.configKeys = ["PROJECT"]
            first.configValues = ["stale-account-project"]
            try env.context.save()
        }
        try PluginOperations.setSetting("PROJECT", to: "current-activation-project", of: package.skills[0],
            package: package, in: env.workspace, modelContext: env.context)
        let saved = ModelContext(env.container)
        let workspace = try #require(try saved.fetch(FetchDescriptor<Workspace>()).first)
        let projection = PluginRuntimeProjection.project(workspace: workspace, packages: [package],
            connectorMode: .runtimeCopies, definitions: [package])
        let skill = try #require(projection.skills.first)
        #expect(skill.environmentVariables["PROJECT"] == "current-activation-project")
        #expect(projection.connectors.allSatisfy { !$0.configKeys.contains("PROJECT") })
        let connectorEnvironment = ConnectorRuntimeProjection(connectors: projection.connectors,
            secretStore: MockSecretStore()).environmentVariables()
        let resolver = SkillResolver(effectiveSnapshots: [], detachedSnapshots: [], standaloneToolSnapshots: [],
            liveLocalToolCommands: [], liveSkillEnvVars: skill.environmentVariables,
            connectorEnvVars: connectorEnvironment)
        #expect(resolver.resolvedEnvironmentVariables["PROJECT"] == "current-activation-project")
        #expect(!resolver.resolvedEnvironmentVariables.values.contains("stale-account-project"))
        if legacyDuplicate {
            // Derived runtime filtering must not silently erase saved legacy values.
            let account = try #require(try saved.fetch(FetchDescriptor<Connector>()).first { $0.id == first.id })
            #expect(account.config["PROJECT"] == "stale-account-project")
        }
    }
}
