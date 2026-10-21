import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Plugin stale credential owners", .serialized)
struct PluginStaleCredentialOwnerTests {
    @Test("A stale model reader cannot restore an older credential generation", arguments: ["setting", "add", "update"])
    func staleReaderCannotReplaceNewerOwner(operation: String) throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let env = try PluginAddCommitTests.Fixture(installed: false)
            defer { env.disk.removeFiles() }
            var package = PluginOperationsTests.package(version: "1.0.0")
            package.id = env.package.id
            package.connectors = []; package.localTools = []
            package.skills[0].environmentKeys = ["API_TOKEN", "SECOND_TOKEN"]
            package.skills[0].environmentValues = ["", ""]
            let library = CapabilityLibrary()
            try library.install(package)
            defer { _ = try? library.removePackage(id: package.id) }
            try env.installer.enable(package, in: env.workspace, modelContext: env.context,
                configInputs: ["API_TOKEN": "first-token", "SECOND_TOKEN": "older-second-token"])
            let task = AgentTask(title: "Hold accepted older generation", goal: "Use the plugin", workspace: env.workspace)
            env.context.insert(task)
            try env.context.save()
            _ = try ExecutionRequestSubmissionService.submitInitial(for: task, into: env.context).get()
            let stale = ModelContext(env.context.container)
            stale.autosaveEnabled = false
            let staleWorkspace = try #require(try stale.fetch(FetchDescriptor<Workspace>()).first)
            let staleActivation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: staleWorkspace))
            let originalGeneration = staleActivation.credentialNamespaceSeed
            try #require(try PluginOperations.setting("SECOND_TOKEN", of: package.skills[0], in: staleActivation) == "older-second-token")
            try PluginOperations.setSetting("SECOND_TOKEN", to: "newest-second-token", of: package.skills[0],
                pluginID: package.id, in: env.workspace, modelContext: env.context)
            let savedBefore = ModelContext(env.context.container)
            let before = try #require(try savedBefore.fetch(FetchDescriptor<PluginActivation>()).first)
            let latestGeneration = before.credentialNamespaceSeed
            try #require(latestGeneration != originalGeneration)
            try #require(staleActivation.credentialNamespaceSeed == originalGeneration)
            try #require(!stale.hasChanges)
            let count = try savedBefore.fetchCount(FetchDescriptor<PluginOperationReceipt>())
            let attempt: () throws -> Void = {
                switch operation {
                case "setting":
                    try PluginOperations.setSetting("API_TOKEN", to: "replacement-first-token", of: package.skills[0],
                        pluginID: package.id, in: staleWorkspace, modelContext: stale)
                case "add":
                    _ = try env.installer.enable(package, in: staleWorkspace, modelContext: stale,
                        configInputs: ["API_TOKEN": "replacement-first-token"])
                default:
                    var next = package
                    next.version = "2.0.0"
                    next.skills[0].id = "renamed-agent"
                    next.skills[0].replaces = [CapabilityResourceOrigin.componentID(for: package.skills[0])]
                    try library.install(next)
                    _ = try PluginUpdateService.reconcileAll(modelContext: stale, packages: [next], mode: .release)
                }
            }
            if operation == "update" {
                // Reconciliation refetches the activation before preparing a
                // renamed component. It may proceed from that current owner.
                try attempt()
            } else { #expect(throws: PluginOperations.OperationError.workspaceChanged) { try attempt() } }
            let savedAfter = ModelContext(env.context.container)
            let after = try #require(try savedAfter.fetch(FetchDescriptor<PluginActivation>()).first)
            if operation == "update" {
                var renamed = package.skills[0]
                renamed.id = "renamed-agent"
                #expect(try PluginOperations.setting("SECOND_TOKEN", of: renamed, in: after) == "newest-second-token")
                #expect(after.recordedVersion == "2.0.0")
            } else {
                #expect(after.credentialNamespaceSeed == latestGeneration)
                #expect(try PluginOperations.setting("SECOND_TOKEN", of: package.skills[0], in: after) == "newest-second-token")
                #expect(try savedAfter.fetchCount(FetchDescriptor<PluginOperationReceipt>()) == count)
            }
        }
    }
}
