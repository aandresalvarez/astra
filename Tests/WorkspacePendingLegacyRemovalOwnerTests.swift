import Foundation
import Testing
import ASTRAModels

@MainActor
@Suite("Pending legacy removal owner")
struct WorkspacePendingLegacyRemovalOwnerTests {
    @Test("Forgetting one plugin preserves unrelated pairs and asymmetric version arrays", arguments: [false, true])
    func preservesPairs(extraVersion: Bool) {
        let workspace = Workspace(name: "Legacy", primaryPath: "/tmp/legacy-owner")
        workspace.legacyEnabledCapabilityIDs = ["keep", "gone", "gone"]
        workspace.legacyInstalledPluginIDs = ["keep", "gone", "other", "gone"]
        workspace.legacyInstalledPluginVersions = extraVersion
            ? ["v-keep", "v-gone", "v-other", "v-gone2", "orphan"]
            : ["v-keep", "v-gone", "v-other"]
        let original = WorkspaceCapabilityActivation.pendingLegacyState(of: workspace)
        #expect(WorkspaceCapabilityActivation.forgetPendingLegacyPlugin("gone", in: workspace))
        #expect(workspace.legacyEnabledCapabilityIDs == ["keep"])
        #expect(workspace.legacyInstalledPluginIDs == ["keep", "other"])
        #expect(workspace.legacyInstalledPluginVersions == (extraVersion ? ["v-keep", "v-other", "orphan"] : ["v-keep", "v-other"]))
        #expect(!WorkspaceCapabilityActivation.forgetPendingLegacyPlugin("gone", in: workspace))
        WorkspaceCapabilityActivation.applyFrozenPendingLegacy(original, to: workspace)
        #expect(WorkspaceCapabilityActivation.pendingLegacyState(of: workspace) == original)
    }
}
