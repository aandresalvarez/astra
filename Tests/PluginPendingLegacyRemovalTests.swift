import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Pending legacy plugin removal")
struct PluginPendingLegacyRemovalTests {
    @Test("Remove clears pending legacy state, preserves other pairs, and restores it on save failure",
          arguments: [false, true], [false, true])
    func pendingLegacyRemoval(missing: Bool, enabled: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        let package = PluginOperationsTests.package(version: "1.0.0")
        if !missing { try env.library.install(package, sourceMetadata: .localLibrary()) }
        env.workspace.legacyEnabledCapabilityIDs = enabled ? ["before", package.id, package.id] : ["before"]
        env.workspace.legacyInstalledPluginIDs = ["before", package.id, "after", package.id]
        env.workspace.legacyInstalledPluginVersions = ["v-before", "v-gone", "v-after"]
        try env.context.save()
        let before = WorkspaceCapabilityActivation.pendingLegacyState(of: env.workspace)
        let uninstaller = CapabilityUninstaller(library: env.library)
        #expect(throws: CapabilityUninstaller.UninstallError.saveFailed(packageID: package.id)) {
            if missing {
                try uninstaller.forgetMissing(pluginID: package.id, modelContext: env.context, persist: { _, _ in false })
            } else {
                try uninstaller.remove(package, modelContext: env.context, persist: { _, _ in false })
            }
        }
        #expect(WorkspaceCapabilityActivation.pendingLegacyState(of: env.workspace) == before)
        let savedBefore = try #require(try ModelContext(env.container).fetch(FetchDescriptor<Workspace>()).first)
        #expect(WorkspaceCapabilityActivation.pendingLegacyState(of: savedBefore) == before)
        let result: CapabilityUninstaller.RemovalResult
        if missing { result = try uninstaller.forgetMissing(pluginID: package.id, modelContext: env.context) }
        else { result = try uninstaller.remove(package, modelContext: env.context) }
        #expect(result.disabledWorkspaceIDs.contains(env.workspace.id))
        #expect(!env.workspace.enabledCapabilityIDs.contains(package.id))
        #expect(env.workspace.legacyInstalledPluginIDs == ["before", "after"])
        #expect(env.workspace.legacyInstalledPluginVersions == ["v-before", "v-after"])
        let saved = try #require(try ModelContext(env.container).fetch(FetchDescriptor<Workspace>()).first)
        #expect(!saved.enabledCapabilityIDs.contains(package.id))
        #expect(WorkspaceCapabilityActivation.pendingLegacyInstallations(in: saved).map(\.id) == ["before", "after"])
        let mirror = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath:
            WorkspaceFileLayout.workspaceConfigFile(for: env.workspace.primaryPath)))
        #expect(!(mirror.installedPlugins ?? []).contains { $0.id == package.id })
    }
}
