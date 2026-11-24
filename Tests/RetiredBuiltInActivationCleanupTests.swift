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

    @Test("A leftover activation is retired at launch with no manual Remove, and never blocks a queued launch meanwhile")
    func launchContractClearsAfterUpgrade() throws {
        let env = try upgradedWorkspace(id: "stanford-apple-mail")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "stanford-apple-mail", in: env.workspace))
        #expect(activation.isEnabled)
        // A request-time copy of the workspace, as a launch reads it: a
        // launch that lands before the cleanup is not refused for it.
        activation.launchWorkspaceID = env.workspace.id
        #expect(PluginQueuedContractValidation.issues(in: env.workspace, packages: env.library.installedPackages(), library: env.library).isEmpty)
        activation.launchWorkspaceID = nil

        let outcome = cleanup(env)

        #expect(outcome == .init(retired: ["stanford-apple-mail"], failed: []))
        #expect(WorkspaceCapabilityActivation.activation(for: "stanford-apple-mail", in: env.workspace) == nil)
        #expect(!env.workspace.enabledCapabilityIDs.contains("stanford-apple-mail"))
        #expect(PluginQueuedContractValidation.issues(in: env.workspace, packages: env.library.installedPackages(), library: env.library).isEmpty)
        // Kept for a later Add, as a person's Remove keeps it.
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).map(\.pluginID) == ["stanford-apple-mail"])
    }

    @Test("A plugin that is merely missing still fails the launch contract")
    func unlistedMissingPluginStillBlocks() throws {
        let env = try upgradedWorkspace(id: "local.gone")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "local.gone", in: env.workspace))
        activation.launchWorkspaceID = env.workspace.id
        #expect(PluginQueuedContractValidation.issues(in: env.workspace, packages: env.library.installedPackages(), library: env.library)
            .map(\.packageID) == ["local.gone"])
    }

    /// A V20 store's migration keeps a missing plugin's old rows as authored
    /// rows still in scope (`pendingOverrides`); retiring the plugin takes them
    /// out with it, and an Add brings them back as its components' overrides.
    @Test("Rows kept as a retired built-in's pending overrides leave the workspace's scope")
    func pendingOverridesLeaveScope() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let row = Skill(name: "Security Auditor", allowedTools: ["Read"], behaviorInstructions: "Audit.")
        row.workspace = env.workspace
        env.context.insert(row)
        WorkspaceCapabilityActivation.recordPendingOverride(
            componentID: "skill:security-auditor", rowID: row.id, pluginID: "security-auditor", in: env.workspace)
        try env.context.save()
        #expect(!WorkspaceCapabilityActivation.overridingRowIDs(of: env.workspace).contains(row.id))
        #expect(RetiredBuiltInActivationCleanup.pendingIDs(modelContext: env.context, library: env.library, builtInIDs: [])
            == ["security-auditor"])

        var forgotten: [String] = []
        let outcome = cleanup(env) { id, _ in forgotten.append(id) }

        #expect(outcome.retired == ["security-auditor"])
        #expect(forgotten.isEmpty, "no activation, so nothing for Remove to do")
        #expect(WorkspaceCapabilityActivation.overridingRowIDs(of: env.workspace).contains(row.id))
        let record = try #require(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).first)
        #expect(record.pendingOverrides == nil)
        #expect(record.overridingRowIDs == [row.id.uuidString])
        #expect(record.overriddenComponentIDs == ["skill:security-auditor"])
        #expect(RetiredBuiltInActivationCleanup.pendingIDs(modelContext: env.context, library: env.library, builtInIDs: []).isEmpty)
        // Saved, not only staged.
        let saved = try #require(try ModelContext(env.container).fetch(FetchDescriptor<Workspace>()).first)
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: saved).first?.pendingOverrides == nil)
    }

    @Test("A local package stored under a retired ID that can't be read still fails the launch contract")
    func storedUnreadablePackageStillBlocks() throws {
        let env = try upgradedWorkspace(id: "security-auditor")
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(at: env.library.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: env.library.packageURL(for: "security-auditor"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "security-auditor", in: env.workspace))
        activation.launchWorkspaceID = env.workspace.id
        #expect(PluginQueuedContractValidation.issues(in: env.workspace, packages: env.library.installedPackages(), library: env.library)
            .map(\.packageID) == ["security-auditor"])
    }

    /// Until the pass retires them, a V20 migration's pending rows are still
    /// in scope; a launch must not run them, so the contract keeps failing.
    @Test("A retired built-in with pending V20 rows still fails the launch contract until they are retired")
    func pendingRowsKeepTheLaunchBlocked() throws {
        let env = try upgradedWorkspace(id: "stanford-healthcare-graph-mail")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let tool = LocalTool(name: "stanford-graph-mail", toolDescription: "Mail", toolType: "cli", command: "stanford-graph-mail")
        tool.workspace = env.workspace
        env.context.insert(tool)
        WorkspaceCapabilityActivation.recordPendingOverride(
            componentID: "tool:stanford-graph-mail", rowID: tool.id, pluginID: "stanford-healthcare-graph-mail", in: env.workspace)
        try env.context.save()
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "stanford-healthcare-graph-mail", in: env.workspace))
        activation.launchWorkspaceID = env.workspace.id
        let issues = { PluginQueuedContractValidation.issues(in: env.workspace, packages: [], library: env.library).map(\.packageID) }
        #expect(issues() == ["stanford-healthcare-graph-mail"])
        activation.launchWorkspaceID = nil

        #expect(cleanup(env).retired == ["stanford-healthcare-graph-mail"])
        #expect(WorkspaceCapabilityActivation.overridingRowIDs(of: env.workspace).contains(tool.id))
    }

    @Test("Unsaved edits in the shared context defer the pass instead of being committed with it")
    func unsavedEditsDefer() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let row = Skill(name: "Security Auditor", allowedTools: ["Read"], behaviorInstructions: "Audit.")
        row.workspace = env.workspace
        env.context.insert(row)
        WorkspaceCapabilityActivation.recordPendingOverride(
            componentID: "skill:security-auditor", rowID: row.id, pluginID: "security-auditor", in: env.workspace)
        try env.context.save()
        env.workspace.name = "Unsaved edit"

        let outcome = cleanup(env) { id, _ in Issue.record("\(id) ran with unsaved edits") }

        #expect(outcome == .init(retired: [], failed: [], deferred: ["security-auditor"]))
        #expect(env.context.hasChanges)
        let saved = try #require(try ModelContext(env.container).fetch(FetchDescriptor<Workspace>()).first)
        #expect(saved.name == "Ops")
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: saved).first?.pendingOverrides?.count == 1)
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

    /// Startup asks for a recovery scan while this is non-empty: the cleanup
    /// chain only runs after a trusted recovery, and a clean launch that
    /// vouches without a scan would otherwise skip the retirement forever.
    @Test("A leftover activation keeps a retirement pending until it is retired, and only then")
    func pendingUntilRetired() throws {
        let env = try upgradedWorkspace(id: "stanford-apple-mail")
        defer { try? FileManager.default.removeItem(at: env.root) }
        let pending = { RetiredBuiltInActivationCleanup.pendingIDs(modelContext: env.context, library: env.library, builtInIDs: []) }
        #expect(pending() == ["stanford-apple-mail"])
        // Unsaved edits elsewhere don't make it look pending (or not).
        env.workspace.name = "Edited"
        #expect(pending() == ["stanford-apple-mail"])
        try env.context.save()
        #expect(cleanup(env).retired == ["stanford-apple-mail"])
        #expect(pending().isEmpty)
    }

    @Test("Nothing is pending on a store with no former built-in left")
    func nothingPendingOnACleanStore() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.install(PluginOperationsTests.package(version: "1.0.0"))
        try env.context.save()
        #expect(RetiredBuiltInActivationCleanup.pendingIDs(modelContext: env.context, library: env.library, builtInIDs: []).isEmpty)
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

    @Test("A stored package under the ID that can't be read counts as present")
    func unreadableStoredPackageIsPresent() throws {
        let env = try upgradedWorkspace(id: "security-auditor")
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(at: env.library.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: env.library.packageURL(for: "security-auditor"))
        #expect(!env.library.installedPackages().contains { $0.id == "security-auditor" })
        #expect(cleanup(env) { id, _ in Issue.record("\(id) has a stored definition") } == .init())
        #expect(WorkspaceCapabilityActivation.activation(for: "security-auditor", in: env.workspace) != nil)
    }

    @Test("A package folder stored under the ID without its manifest counts as present")
    func manifestlessPackageFolderIsPresent() throws {
        let env = try upgradedWorkspace(id: "google-drive-browser")
        defer { try? FileManager.default.removeItem(at: env.root) }
        try FileManager.default.createDirectory(
            at: env.library.packageManifestURL(for: "google-drive-browser").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        #expect(cleanup(env) { id, _ in Issue.record("\(id) has stored package storage") } == .init())
        #expect(!RetiredBuiltInActivationCleanup.awaitsRetirement("google-drive-browser", in: env.workspace, library: env.library))
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
