import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Retired built-in activation cleanup", .serialized)
struct RetiredBuiltInActivationCleanupTests {
    /// A workspace that enabled a former built-in before the upgrade: its
    /// activation outlives the definition the new build no longer ships.
    private func upgradedWorkspace(id: String) throws -> PluginOperationsTests.Environment {
        let env = try PluginOperationsTests.Environment()
        var package = PluginOperationsTests.package(version: "1.0.0")
        package.id = id
        try env.install(package)
        try env.context.save()
        _ = try env.library.removePackage(id: id, trustedBuiltInIDs: [])
        return env
    }

    private func cleanup(_ env: PluginOperationsTests.Environment, ids: [String]? = nil,
                         forget: (@MainActor (String, ModelContext) throws -> Void)? = nil) -> RetiredBuiltInActivationCleanup.Outcome {
        RetiredBuiltInActivationCleanup.retireActivations(
            modelContext: env.context,
            library: env.library,
            builtInIDs: [],
            ids: ids ?? RetiredBuiltInActivationCleanup.retiredBuiltInIDs,
            forget: forget ?? { id, context in
                try CapabilityCatalogActionService(library: env.library).forgetMissing(pluginID: id, modelContext: context)
            }
        )
    }

    @Test("A queued launch stops at preflight until the leftover activation is retired, with no manual Remove")
    func launchContractClearsAfterUpgrade() throws {
        let env = try upgradedWorkspace(id: "stanford-apple-mail")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "stanford-apple-mail", in: env.workspace))
        #expect(activation.isEnabled)
        // A request-time copy of the workspace, as a launch reads it.
        activation.launchWorkspaceID = env.workspace.id
        #expect(!PluginQueuedContractValidation.issues(in: env.workspace, packages: env.library.installedPackages()).isEmpty)
        activation.launchWorkspaceID = nil

        let outcome = cleanup(env)

        #expect(outcome == .init(retired: ["stanford-apple-mail"], failed: []))
        #expect(WorkspaceCapabilityActivation.activation(for: "stanford-apple-mail", in: env.workspace) == nil)
        #expect(!env.workspace.enabledCapabilityIDs.contains("stanford-apple-mail"))
        #expect(PluginQueuedContractValidation.issues(in: env.workspace, packages: env.library.installedPackages()).isEmpty)
        // Kept for a later Add, as a person's Remove keeps it.
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).map(\.pluginID) == ["stanford-apple-mail"])
    }

    @Test("A former built-in held only in legacy state after a deferred migration is retired too")
    func pendingLegacyStateIsRetired() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.workspace.legacyEnabledCapabilityIDs = ["stanford-healthcare-graph-mail"]
        env.workspace.legacyInstalledPluginIDs = ["stanford-healthcare-graph-mail"]
        env.workspace.legacyInstalledPluginVersions = ["1.0.0"]
        try env.context.save()
        #expect(WorkspaceCapabilityActivation.activation(for: "stanford-healthcare-graph-mail", in: env.workspace) == nil)
        #expect(env.workspace.enabledCapabilityIDs.contains("stanford-healthcare-graph-mail"))

        #expect(cleanup(env).retired == ["stanford-healthcare-graph-mail"])
        #expect(!env.workspace.enabledCapabilityIDs.contains("stanford-healthcare-graph-mail"))
        #expect(env.workspace.legacyInstalledPluginIDs.isEmpty)
    }

    @Test("The default Remove acts on the library that found the definition missing")
    func defaultRemoveUsesTheGivenLibrary() throws {
        let env = try upgradedWorkspace(id: "security-auditor")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let outcome = RetiredBuiltInActivationCleanup.retireActivations(
            modelContext: env.context, library: env.library, builtInIDs: []
        )
        #expect(outcome == .init(retired: ["security-auditor"], failed: []))
        #expect(WorkspaceCapabilityActivation.activation(for: "security-auditor", in: env.workspace) == nil)
    }

    @Test("A second pass has nothing left to do")
    func idempotent() throws {
        let env = try upgradedWorkspace(id: "google-drive-browser")
        defer { try? FileManager.default.removeItem(at: env.root) }
        #expect(cleanup(env).retired == ["google-drive-browser"])
        var calls = 0
        let again = cleanup(env) { _, _ in calls += 1 }
        #expect(again == .init())
        #expect(calls == 0)
    }

    @Test("A plugin that still has a definition, or is not a former built-in, is left alone")
    func onlyMissingFormerBuiltIns() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        var listed = PluginOperationsTests.package(version: "1.0.0")
        listed.id = "security-auditor"
        try env.install(listed)
        try env.context.save()
        var forgotten: [String] = []
        // Installed in the library: a definition exists, nothing to retire.
        #expect(cleanup(env) { id, _ in forgotten.append(id) } == .init())
        // Missing, but not on the list: a local plugin's file may only be unreadable.
        _ = try env.library.removePackage(id: listed.id, trustedBuiltInIDs: [])
        #expect(cleanup(env, ids: ["code-reviewer"]) { id, _ in forgotten.append(id) } == .init())
        #expect(forgotten.isEmpty)
        #expect(WorkspaceCapabilityActivation.activation(for: listed.id, in: env.workspace) != nil)
    }

    @Test("A bundled definition counts as present")
    func bundledDefinitionIsPresent() throws {
        let env = try upgradedWorkspace(id: "google-workspace")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let outcome = RetiredBuiltInActivationCleanup.retireActivations(
            modelContext: env.context, library: env.library, builtInIDs: ["google-workspace"],
            forget: { id, _ in Issue.record("\(id) is still bundled") }
        )
        #expect(outcome == .init())
    }

    @Test("A refused Remove is reported and the others still run")
    func failureIsReported() throws {
        let env = try upgradedWorkspace(id: "code-reviewer")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let other = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("other").path)
        env.context.insert(other)
        WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability("security-auditor") }
        try env.context.save()
        struct Refused: Error {}
        var attempted: [String] = []
        let outcome = cleanup(env) { id, _ in
            attempted.append(id)
            if id == "code-reviewer" { throw Refused() }
        }
        #expect(attempted == ["code-reviewer", "security-auditor"])
        #expect(outcome == .init(retired: ["security-auditor"], failed: ["code-reviewer"]))
    }
}
