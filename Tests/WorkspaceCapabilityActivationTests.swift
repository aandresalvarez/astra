import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
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
        WorkspaceCapabilityActivation.setConfigValue("PROJ", forKey: "skill:jira agent#JIRA_PROJECT", on: activation)
        WorkspaceCapabilityActivation.setOverridden(true, componentID: "skill:jira agent", on: activation)
        WorkspaceCapabilityActivation.setKnownComponents(["skill:jira agent", component, component], on: activation)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:jira agent#JIRA_API_TOKEN", on: activation)
        #expect(activation.knownComponentIDs == ["skill:jira agent", component])
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
        #expect(restored.knownComponentIDs == ["skill:jira agent", component])
        #expect(restored.secretSettingKeys == ["skill:jira agent#JIRA_API_TOKEN"])

        // Deleting an account removes its bindings with it.
        context.delete(second)
        try context.save()
        #expect(restored.accounts(forComponent: component).map(\.name) == ["Jira Stanford"])
        withExtendedLifetime(container) {}
    }

    @Test("A workspace has one default account per service across its plugins")
    @MainActor
    func oneDefaultPerServiceAcrossPlugins() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let stanford = Connector(name: "Stanford", serviceType: "jira")
        let coral = Connector(name: "Coral", serviceType: "Jira ")
        let redcap = Connector(name: "Stanford", serviceType: "redcap")
        [stanford, coral, redcap].forEach(context.insert)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("jira-workflow")
            $0.enableCapability("jira-ops")
            $0.enableCapability("redcap-workflow")
        }
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        let ops = try #require(WorkspaceCapabilityActivation.activation(for: "jira-ops", in: workspace))
        let redcapActivation = try #require(WorkspaceCapabilityActivation.activation(for: "redcap-workflow", in: workspace))

        WorkspaceCapabilityActivation.bind(stanford, toComponent: "connector:jira:jira", of: jira)
        // Another plugin's first Jira account is not a second default.
        WorkspaceCapabilityActivation.bind(coral, toComponent: "connector:jira:ops", of: ops)
        // Another service keeps its own default.
        WorkspaceCapabilityActivation.bind(redcap, toComponent: "connector:redcap:redcap", of: redcapActivation)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == stanford.id)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "redcap", in: workspace)?.id == redcap.id)
        func defaults() -> [UUID] {
            WorkspaceCapabilityActivation.activations(of: workspace).flatMap(\.bindings)
                .filter { $0.isDefault && $0.account?.serviceType.lowercased().contains("jira") == true }
                .compactMap { $0.account?.id }
        }
        #expect(defaults() == [stanford.id])

        // Making the other one default moves it across plugins.
        WorkspaceCapabilityActivation.bind(coral, toComponent: "connector:jira:ops", of: ops, isDefault: true)
        #expect(defaults() == [coral.id])

        // Unbinding the default promotes the service's remaining account.
        WorkspaceCapabilityActivation.unbind(coral, from: ops)
        #expect(defaults() == [stanford.id])
        withExtendedLifetime(container) {}
    }

    @Test("Removing the default's activation or deleting the default account elects the next one")
    @MainActor
    func cascadesElectANewDefault() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let stanford = Connector(name: "Stanford", serviceType: "jira")
        let coral = Connector(name: "Coral", serviceType: "jira")
        let site = Connector(name: "Site", serviceType: "jira")
        [stanford, coral, site].forEach(context.insert)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("jira-workflow")
            $0.enableCapability("jira-ops")
        }
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        let ops = try #require(WorkspaceCapabilityActivation.activation(for: "jira-ops", in: workspace))
        WorkspaceCapabilityActivation.bind(stanford, toComponent: "connector:jira:jira", of: jira)
        WorkspaceCapabilityActivation.bind(coral, toComponent: "connector:jira:ops", of: ops)
        WorkspaceCapabilityActivation.bind(site, toComponent: "connector:jira:ops", of: ops)
        try context.save()
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == stanford.id)

        // Removing the plugin that held the default.
        WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.removeAll { $0 == "jira-workflow" }; $0.removeInstalledPlugin(id: "jira-workflow") }
        #expect(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace) == nil)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == coral.id)

        // Deleting the default account from Configure.
        let deleted = ConnectorCredentialCleanup.deleteConnector(coral, in: workspace, modelContext: context) {
            (try? context.save()) != nil
        }
        #expect(deleted)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == site.id)
        withExtendedLifetime(container) {}
    }

    @Test("Deleting an account several workspaces bind refreshes every one of their mirrors")
    @MainActor
    func deletingASharedAccountExportsEveryAffectedWorkspace() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let other = Workspace(name: "Other", primaryPath: "/tmp/activation-owner-other")
        let unrelated = Workspace(name: "Unrelated", primaryPath: "/tmp/activation-owner-unrelated")
        [other, unrelated].forEach(context.insert)
        let shared = Connector(name: "Shared Jira", serviceType: "jira")
        shared.isGlobal = true
        context.insert(shared)
        for owner in [workspace, other, unrelated] {
            WorkspaceCapabilityActivation.mutate(owner) { $0.enableCapability("jira-workflow") }
        }
        for owner in [workspace, other] {
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: owner))
            WorkspaceCapabilityActivation.bind(shared, toComponent: "connector:jira:jira", of: activation)
        }
        try context.save()

        var exported: [UUID] = []
        let deleted = ConnectorCredentialCleanup.deleteConnector(
            shared, in: workspace, modelContext: context, exportMirror: { exported.append($0.id) }
        ) {
            (try? context.save()) != nil
        }
        #expect(deleted)
        // The clicked workspace is exported by its own save; the other one
        // that bound the account is exported here, and nothing else.
        #expect(exported == [other.id])
        withExtendedLifetime(container) {}
    }

    @Test("Accounts of one service a workspace sees get distinct names")
    @MainActor
    func aliasesAreUniquePerServiceInAWorkspace() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let first = Connector(name: "Stanford", serviceType: "jira")
        let second = Connector(name: "stanford ", serviceType: "jira")
        let otherService = Connector(name: "Stanford", serviceType: "redcap")
        [first, second, otherService].forEach(context.insert)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("jira-workflow")
            $0.enableCapability("jira-ops")
            $0.enableCapability("redcap-workflow")
        }
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        let ops = try #require(WorkspaceCapabilityActivation.activation(for: "jira-ops", in: workspace))
        let redcap = try #require(WorkspaceCapabilityActivation.activation(for: "redcap-workflow", in: workspace))
        WorkspaceCapabilityActivation.bind(first, toComponent: "connector:jira:jira", of: jira)
        WorkspaceCapabilityActivation.bind(second, toComponent: "connector:jira:ops", of: ops)
        WorkspaceCapabilityActivation.bind(otherService, toComponent: "connector:redcap:redcap", of: redcap)
        #expect(first.name == "Stanford")
        #expect(second.name == "stanford  2")
        #expect(otherService.name == "Stanford")
        #expect(WorkspaceCapabilityActivation.uniqueAlias("Stanford", serviceType: "jira", in: workspace) == "Stanford 2")
        withExtendedLifetime(container) {}
    }

    @Test("Sharing an account into a workspace with a same-named one never renames it where it already works")
    @MainActor
    func sharedAccountKeepsItsAliasWhenBoundElsewhere() throws {
        let (container, first) = try makeManagedWorkspace()
        let context = container.mainContext
        let second = Workspace(name: "Second", primaryPath: "/tmp/second-\(UUID().uuidString)")
        context.insert(second)
        let shared = Connector(name: "Stanford", serviceType: "jira")
        let local = Connector(name: "Stanford", serviceType: "jira")
        [shared, local].forEach(context.insert)
        local.workspace = second
        for workspace in [first, second] {
            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("jira-workflow") }
        }
        let inFirst = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: first))
        let inSecond = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: second))
        WorkspaceCapabilityActivation.bind(shared, toComponent: "connector:jira:jira", of: inFirst)
        WorkspaceCapabilityActivation.bind(local, toComponent: "connector:jira:jira", of: inSecond)
        WorkspaceCapabilityActivation.bind(shared, toComponent: "connector:jira:jira", of: inSecond)
        #expect(shared.name == "Stanford")
        #expect(local.name == "Stanford")
        withExtendedLifetime(container) {}
    }

    @Test("An emptied setting is kept; removing one restores the default")
    @MainActor
    func emptySettingIsKeptAndNilRemoves() throws {
        let (container, workspace) = try makeManagedWorkspace()
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("p") }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "p", in: workspace))
        let key = PluginActivation.settingKey(componentID: "skill:a.b", key: "c")
        WorkspaceCapabilityActivation.setConfigValue("", forKey: key, on: activation)
        #expect(activation.configuration(forComponent: "skill:a.b") == ["c": ""])
        // Setting keys can't collide however components are named.
        WorkspaceCapabilityActivation.setConfigValue("x", forKey: PluginActivation.settingKey(componentID: "skill:a", key: "b.c"), on: activation)
        #expect(activation.configuration(forComponent: "skill:a.b") == ["c": ""])
        #expect(activation.configuration(forComponent: "skill:a") == ["b.c": "x"])
        #expect(PluginActivation.componentID(ofSettingKey: key) == "skill:a.b")
        WorkspaceCapabilityActivation.setConfigValue("y", forKey: PluginActivation.settingKey(componentID: "skill:c# helper", key: "K"), on: activation)
        #expect(activation.configuration(forComponent: "skill:c").isEmpty)
        #expect(activation.configuration(forComponent: "skill:c# helper") == ["K": "y"])
        WorkspaceCapabilityActivation.setConfigValue(nil, forKey: key, on: activation)
        #expect(activation.configuration(forComponent: "skill:a.b").isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Binding a shared account another workspace turned on by itself never renames it there")
    @MainActor
    func sharedAccountEnabledElsewhereKeepsItsAlias() throws {
        let (container, joining) = try makeManagedWorkspace()
        let context = container.mainContext
        let other = Workspace(name: "Other", primaryPath: "/tmp/other-\(UUID().uuidString)")
        context.insert(other)
        let shared = Connector(name: "Stanford", serviceType: "jira")
        shared.isGlobal = true
        let local = Connector(name: "Stanford", serviceType: "jira")
        [shared, local].forEach(context.insert)
        local.workspace = joining
        // The other workspace uses the shared row directly: no binding.
        WorkspaceCapabilityActivation.mutate(other) { $0.enableGlobalConnector(shared.id.uuidString) }
        WorkspaceCapabilityActivation.mutate(joining) { $0.enableCapability("jira-workflow") }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: joining))
        WorkspaceCapabilityActivation.bind(shared, toComponent: "connector:jira:jira", of: activation)
        #expect(shared.name == "Stanford")
        // A shared row no other workspace uses is still told apart.
        let unused = Connector(name: "Stanford", serviceType: "jira")
        unused.isGlobal = true
        context.insert(unused)
        WorkspaceCapabilityActivation.bind(unused, toComponent: "connector:jira:ops", of: activation)
        // "Stanford 2" is the shared row's alias here (its binding's).
        #expect(WorkspaceCapabilityActivation.alias(of: shared, in: joining) == "Stanford 2")
        #expect(unused.name == "Stanford 3")
        withExtendedLifetime(container) {}
    }

    @Test("A shared account the workspace lists on its own counts when a new account's name is checked")
    @MainActor
    func listedSharedAccountTakesPartInAliasChecks() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        // Listed here directly, bound by no plugin.
        let listed = Connector(name: "Stanford", serviceType: "jira")
        listed.isGlobal = true
        let unlisted = Connector(name: "Other", serviceType: "jira")
        unlisted.isGlobal = true
        let local = Connector(name: "stanford", serviceType: "jira")
        [listed, unlisted, local].forEach(context.insert)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableGlobalConnector(listed.id.uuidString)
            $0.enableCapability("jira-workflow")
        }
        #expect(WorkspaceCapabilityActivation.uniqueAlias("Stanford", serviceType: "jira", in: workspace) == "Stanford 2")
        #expect(WorkspaceCapabilityActivation.uniqueAlias("Other", serviceType: "jira", in: workspace) == "Other")
        local.workspace = workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        WorkspaceCapabilityActivation.bind(local, toComponent: "connector:jira:jira", of: activation)
        #expect(local.name == "stanford 2")
        #expect(listed.name == "Stanford")
        withExtendedLifetime(container) {}
    }

    @Test("Sharing a bound account doesn't list it, so it still leaves with its plugin")
    @MainActor
    func promotingABoundAccountKeepsItBindingOnly() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let bound = Connector(name: "Bound", serviceType: "jira")
        let free = Connector(name: "Free", serviceType: "jira")
        [bound, free].forEach(context.insert)
        bound.workspace = workspace
        free.workspace = workspace
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("jira-workflow") }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        WorkspaceCapabilityActivation.bind(bound, toComponent: "connector:jira:jira", of: activation)
        CapabilitySharing.promoteToShared(bound, in: workspace)
        CapabilitySharing.promoteToShared(free, in: workspace)
        // The unbound account needs the list to stay in scope; the bound one
        // has its binding, and listed it would outlive its plugin.
        #expect(WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs == [free.id.uuidString])
        #expect(WorkspaceCapabilityActivation.bindingOnlyAccountIDs(of: workspace) == [bound.id])
        withExtendedLifetime(container) {}
    }

    @Test("A shared account that can't be renamed keeps its collision alias on the binding, durably")
    @MainActor
    func sharedAccountCollisionAliasIsDurable() throws {
        let (container, joining) = try makeManagedWorkspace()
        let context = container.mainContext
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let component = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        let other = Workspace(name: "Other", primaryPath: "/tmp/other-\(UUID().uuidString)")
        context.insert(other)
        let shared = Connector(name: "Stanford", serviceType: jira.connectors[0].serviceType)
        shared.isGlobal = true
        let local = Connector(name: "Stanford", serviceType: jira.connectors[0].serviceType)
        [shared, local].forEach(context.insert)
        local.workspace = joining
        WorkspaceCapabilityActivation.mutate(other) { $0.enableGlobalConnector(shared.id.uuidString) }
        WorkspaceCapabilityActivation.mutate(joining) { $0.enableCapability(jira.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: joining))
        WorkspaceCapabilityActivation.bind(shared, toComponent: component, of: activation)

        // The row keeps its name where it already works; here it is "Stanford 2".
        #expect(shared.name == "Stanford")
        #expect(WorkspaceCapabilityActivation.alias(of: shared, in: joining) == "Stanford 2")
        #expect(WorkspaceCapabilityActivation.alias(of: shared, in: other) == "Stanford")
        func runtimeName() -> String? {
            PluginRuntimeProjection.project(workspace: joining, packages: [jira], connectorMode: .runtimeCopies)
                .connectors.first { $0.id == shared.id }?.name
        }
        #expect(runtimeName() == "Stanford 2")
        // So does one another workspace's plugin binds.
        let boundElsewhere = Connector(name: "Stanford", serviceType: jira.connectors[0].serviceType)
        boundElsewhere.isGlobal = true
        context.insert(boundElsewhere)
        WorkspaceCapabilityActivation.mutate(other) { $0.enableCapability(jira.id) }
        let otherActivation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: other))
        WorkspaceCapabilityActivation.bind(boundElsewhere, toComponent: component, of: otherActivation)
        // Joining the other workspace, it met the shared row that one lists
        // by itself under the same name.
        #expect(boundElsewhere.name == "Stanford 2")
        WorkspaceCapabilityActivation.bind(boundElsewhere, toComponent: "connector:jira:ops", of: activation)
        #expect(boundElsewhere.name == "Stanford 2")
        #expect(WorkspaceCapabilityActivation.alias(of: boundElsewhere, in: joining) == "Stanford 2 2")
        WorkspaceCapabilityActivation.unbind(boundElsewhere, from: activation)
        // The other account going away doesn't flip it back.
        context.delete(local)
        try context.save()
        #expect(WorkspaceCapabilityActivation.alias(of: shared, in: joining) == "Stanford 2")
        #expect(runtimeName() == "Stanford 2")
        // A launch record and the mirror carry it.
        #expect(PluginActivationRecord(activation).bindings.first?.alias == "Stanford 2")
        let config = try #require(WorkspaceConfigManager.export(workspace: joining, modelContext: context))
        #expect(config.installedPlugins?.first?.accounts?.first?.alias == "Stanford 2")
        // Mirror recovery restores it with the binding.
        let target = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let recovered = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: target.mainContext, capabilityTrust: .preserveRecordedState
        ).workspace
        let recoveredShared = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: recovered)?
            .bindings.first?.account)
        #expect(WorkspaceCapabilityActivation.alias(of: recoveredShared, in: recovered) == "Stanford 2")
        withExtendedLifetime((container, target)) {}
    }

    @Test("A recovered mirror keeps each binding's age, so the same account succeeds a deleted default")
    @MainActor
    func mirrorKeepsBindingAgeForDefaultElection() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let accounts = ["Default", "Older", "Newer"].map { name -> Connector in
            let account = Connector(name: name, serviceType: "jira")
            account.workspace = workspace
            context.insert(account)
            return account
        }
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("first-plugin")
            $0.enableCapability("second-plugin")
        }
        let first = try #require(WorkspaceCapabilityActivation.activation(for: "first-plugin", in: workspace))
        let second = try #require(WorkspaceCapabilityActivation.activation(for: "second-plugin", in: workspace))
        let start = Date()
        // The later plugin's account was bound first: it is next in line.
        WorkspaceCapabilityActivation.bind(accounts[0], toComponent: "connector:jira:a", of: first, createdAt: start)
        WorkspaceCapabilityActivation.bind(accounts[1], toComponent: "connector:jira:b", of: second, createdAt: start.addingTimeInterval(0.1))
        WorkspaceCapabilityActivation.bind(accounts[2], toComponent: "connector:jira:c", of: first, createdAt: start.addingTimeInterval(0.2))
        try context.save()
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let data = try { () throws -> Data in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(config)
        }()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: data)

        let recovered = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let restored = WorkspaceConfigManager.importWorkspaceResult(from: decoded, modelContext: recovered.mainContext).workspace
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: restored)?.name == "Default")
        let deleted = try #require(restored.connectors.first { $0.name == "Default" })
        WorkspaceCapabilityActivation.releaseAccount(deleted)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: restored)?.name == "Older")
        withExtendedLifetime((container, recovered)) {}
    }

    @Test("An account moved to another service leaves one default on each side")
    @MainActor
    func serviceChangeReelectsDefaults() throws {
        let (container, workspace) = try makeManagedWorkspace()
        let context = container.mainContext
        let jiraDefault = Connector(name: "Jira main", serviceType: "jira")
        let jiraOther = Connector(name: "Jira other", serviceType: "jira")
        let github = Connector(name: "GitHub", serviceType: "github")
        [jiraDefault, jiraOther, github].forEach(context.insert)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("jira-workflow")
            $0.enableCapability("github-workflow")
        }
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: workspace))
        let githubActivation = try #require(WorkspaceCapabilityActivation.activation(for: "github-workflow", in: workspace))
        WorkspaceCapabilityActivation.bind(jiraDefault, toComponent: "connector:jira:a", of: jira)
        WorkspaceCapabilityActivation.bind(jiraOther, toComponent: "connector:jira:b", of: jira)
        WorkspaceCapabilityActivation.bind(github, toComponent: "connector:github:a", of: githubActivation)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == jiraDefault.id)

        // The person changes the Jira default's Type to GitHub.
        jiraDefault.serviceType = "github"
        WorkspaceCapabilityActivation.serviceChanged(of: jiraDefault, from: "jira")
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "jira", in: workspace)?.id == jiraOther.id)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "github", in: workspace)?.id == github.id)
        let githubDefaults = WorkspaceCapabilityActivation.activations(of: workspace).flatMap(\.bindings)
            .filter { $0.isDefault && $0.account?.serviceType == "github" }
        #expect(githubDefaults.map { $0.account?.id } == [github.id])
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
