import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Workspace capability activation owner")
struct WorkspaceCapabilityActivationTests {
    @Test("Enabling is idempotent and keeps the stored order")
    func enablingIsIdempotentAndOrdered() {
        var state = WorkspaceCapabilityActivationState()
        state.enableCapability("b")
        state.enableCapability("a")
        state.enableCapability("b")
        state.enableGlobalSkill("s1")
        state.enableGlobalSkill("s1")
        state.enableGlobalConnector("c1")
        state.enableGlobalTool("t1")
        state.enableGlobalTool("t1")

        #expect(state.capabilityIDs == ["b", "a"])
        #expect(state.globalSkillIDs == ["s1"])
        #expect(state.globalConnectorIDs == ["c1"])
        #expect(state.globalToolIDs == ["t1"])
    }

    @Test("Toggling a shared skill turns it off when on and on when off")
    func togglingSharedSkill() {
        var state = WorkspaceCapabilityActivationState(globalSkillIDs: ["x", "y"])
        state.toggleGlobalSkill("x")
        #expect(state.globalSkillIDs == ["y"])
        state.toggleGlobalSkill("x")
        #expect(state.globalSkillIDs == ["y", "x"])
    }

    @Test("Recording a plugin pads a versions array that fell behind instead of dropping the write")
    func recordingPadsDesyncedVersions() {
        var state = WorkspaceCapabilityActivationState(pluginIDs: ["a", "b"], pluginVersions: [])
        state.recordInstalledPlugin(id: "b", version: "2.0.0")
        #expect(state.pluginIDs == ["a", "b"])
        #expect(state.pluginVersions == ["", "2.0.0"])

        state.recordInstalledPlugin(id: "c", version: "3.0.0")
        #expect(state.pluginIDs == ["a", "b", "c"])
        #expect(state.pluginVersions == ["", "2.0.0", "3.0.0"])
    }

    @Test("Removing a plugin drops every duplicate and keeps the remaining pairs aligned")
    func removingKeepsPairsAligned() {
        var state = WorkspaceCapabilityActivationState(
            pluginIDs: ["a", "x", "b", "x", "c"],
            pluginVersions: ["1", "x1", "2", "x2"]
        )
        state.removeInstalledPlugin(id: "x")
        #expect(state.pluginIDs == ["a", "b", "c"])
        #expect(state.pluginVersions == ["1", "2"])
    }

    @Test("Mutate writes back through the owner and leaves updatedAt alone")
    @MainActor
    func mutateWritesBackWithoutTouchingUpdatedAt() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let stamp = Date(timeIntervalSince1970: 1_000)
        workspace.updatedAt = stamp

        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("pkg")
            $0.packIDs = ["pack"]
            $0.enableGlobalConnector("c1")
            $0.recordInstalledPlugin(id: "pkg", version: "1.2.3")
        }

        #expect(workspace.enabledCapabilityIDs == ["pkg"])
        #expect(workspace.enabledPackIDs == ["pack"])
        #expect(workspace.enabledGlobalConnectorIDs == ["c1"])
        #expect(workspace.installedPluginIDs == ["pkg"])
        #expect(workspace.installedPluginVersions == ["1.2.3"])
        #expect(workspace.updatedAt == stamp)
        withExtendedLifetime(container) {}
    }

    @Test("A snapshot restores all seven arrays and updatedAt, packs included")
    @MainActor
    func snapshotRestoresAllSevenFields() throws {
        let (container, workspace) = try makeManagedWorkspace()
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0 = WorkspaceCapabilityActivationState(
                capabilityIDs: ["cap"],
                packIDs: ["pack"],
                globalSkillIDs: ["s"],
                globalConnectorIDs: ["c"],
                globalToolIDs: ["t"],
                pluginIDs: ["cap"],
                pluginVersions: ["1.0.0"]
            )
        }
        let before = WorkspaceCapabilityActivation.state(of: workspace)
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)

        WorkspaceCapabilityActivation.mutate(workspace) { $0 = WorkspaceCapabilityActivationState() }
        workspace.updatedAt = Date(timeIntervalSince1970: 42)
        WorkspaceCapabilityActivation.restore(snapshot, to: workspace)

        #expect(WorkspaceCapabilityActivation.state(of: workspace) == before)
        #expect(workspace.enabledPackIDs == ["pack"])
        #expect(workspace.updatedAt == snapshot.updatedAt)
        withExtendedLifetime(container) {}
    }

    @Test("Apply copies a desynced plugin pairing exactly")
    @MainActor
    func applyCopiesDesyncedPairingExactly() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let source = WorkspaceCapabilityActivationState(pluginIDs: ["a", "b", "c"], pluginVersions: ["1"])
        WorkspaceCapabilityActivation.apply(source, to: workspace)
        #expect(workspace.installedPluginIDs == ["a", "b", "c"])
        #expect(workspace.installedPluginVersions == ["1"])
        #expect(WorkspaceCapabilityActivation.state(of: workspace) == source)
        withExtendedLifetime(container) {}
    }

    @Test("A default account per service round-trips through the workspace and ignores case")
    @MainActor
    func defaultAccountRoundTrips() throws {
        let (container, workspace) = try makeManagedWorkspace()
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.setDefaultAccount("jira-stanford", forService: "Jira")
            $0.setDefaultAccount("redcap-a", forService: "redcap")
        }
        #expect(workspace.defaultAccountServiceTypes == ["jira", "redcap"])
        #expect(workspace.defaultAccountConnectorIDs == ["jira-stanford", "redcap-a"])

        let state = WorkspaceCapabilityActivation.state(of: workspace)
        #expect(state.defaultAccountID(forService: "JIRA") == "jira-stanford")
        #expect(state.defaultAccountID(forService: "github") == nil)

        WorkspaceCapabilityActivation.mutate(workspace) { $0.setDefaultAccount(nil, forService: "jira") }
        #expect(workspace.defaultAccountServiceTypes == ["redcap"])
        #expect(workspace.defaultAccountConnectorIDs == ["redcap-a"])
        withExtendedLifetime(container) {}
    }

    @Test("Installed plugin reads pair versions by index and report a missing slot as nil")
    func installedPluginReads() {
        let state = WorkspaceCapabilityActivationState(pluginIDs: ["a", "b"], pluginVersions: ["1.0"])
        #expect(state.pluginIDSet == ["a", "b"])
        #expect(state.installedVersion(of: "a") == "1.0")
        #expect(state.installedVersion(of: "b") == nil)
        #expect(state.installedPlugins.map(\.version) == ["1.0", nil])
    }

    @MainActor
    private func makeManagedWorkspace() throws -> (ModelContainer, Workspace) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspace = Workspace(name: "Activation", primaryPath: "/tmp/activation-owner")
        container.mainContext.insert(workspace)
        try container.mainContext.save()
        return (container, workspace)
    }
}
