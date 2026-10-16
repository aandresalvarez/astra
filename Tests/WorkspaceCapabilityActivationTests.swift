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

    @Test("Apply gives every plugin one activation, pairing a missing version with empty")
    @MainActor
    func applyPairsEveryPluginWithAVersion() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let source = WorkspaceCapabilityActivationState(
            capabilityIDs: ["b", "d"],
            pluginIDs: ["a", "b", "c", "a"],
            pluginVersions: ["1"]
        )
        WorkspaceCapabilityActivation.apply(source, to: workspace)
        #expect(workspace.installedPluginIDs == ["a", "b", "c", "d"])
        #expect(workspace.installedPluginVersions == ["1", "", "", ""])
        #expect(workspace.enabledCapabilityIDs == ["b", "d"])
        #expect(workspace.pluginActivations.count == 4)

        // Dropping a plugin from both lists deletes its activation; dropping it
        // only from the enabled list turns it off and keeps it.
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.capabilityIDs = ["d"]
            $0.pluginIDs = ["b", "c"]
        }
        #expect(workspace.installedPluginIDs == ["b", "c", "d"])
        #expect(workspace.enabledCapabilityIDs == ["d"])
        #expect(WorkspaceCapabilityActivation.activation(for: "b", in: workspace)?.isEnabled == false)
        withExtendedLifetime(container) {}
    }

    @Test("Bindings, settings and overrides bump the revision and survive a snapshot restore")
    @MainActor
    func activationRecordRoundTrips() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let first = Connector(name: "Jira Stanford", serviceType: "jira")
        let second = Connector(name: "Jira Coral", serviceType: "jira")
        context.insert(first)
        context.insert(second)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("jira-workflow") }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        let component = "connector:jira:jira"
        let startRevision = activation.revision

        WorkspaceCapabilityActivation.bind(first, toComponent: component, of: activation)
        WorkspaceCapabilityActivation.bind(second, toComponent: component, of: activation, isDefault: true)
        WorkspaceCapabilityActivation.setConfigValue("PROJ", forKey: "skill:jira agent.JIRA_PROJECT", on: activation)
        WorkspaceCapabilityActivation.setOverridden(true, componentID: "skill:jira agent", on: activation)
        #expect(activation.revision > startRevision)
        #expect(activation.accounts(forComponent: component).map(\.name) == ["Jira Coral", "Jira Stanford"])
        #expect(activation.configuration(forComponent: "skill:jira agent") == ["JIRA_PROJECT": "PROJ"])
        try context.save()

        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        WorkspaceCapabilityActivation.unbind(second, from: activation)
        #expect(activation.accounts(forComponent: component).map(\.name) == ["Jira Stanford"])
        #expect(activation.bindings.first?.isDefault == true)
        WorkspaceCapabilityActivation.mutate(workspace) { $0 = WorkspaceCapabilityActivationState() }
        #expect(workspace.pluginActivations.isEmpty)

        WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
        let restored = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        #expect(PluginActivationRecord(restored) == snapshot.activations.first)
        #expect(restored.accounts(forComponent: component).map(\.name) == ["Jira Coral", "Jira Stanford"])
        #expect(restored.overriddenComponentIDs == ["skill:jira agent"])

        // Deleting an account removes its bindings with it.
        context.delete(second)
        try context.save()
        #expect(restored.accounts(forComponent: component).map(\.name) == ["Jira Stanford"])
        withExtendedLifetime(container) {}
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
