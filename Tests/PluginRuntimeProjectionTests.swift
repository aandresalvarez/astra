import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Identity and ownership rules of `PluginRuntimeProjection` and the services
/// that write activations (Plugins 2.0 R1 review).
@Suite("Plugin runtime projection")
@MainActor
struct PluginRuntimeProjectionTests {
    private static var retained: [ModelContainer] = []

    @Test("Projected IDs survive Remove and Add, and differ between workspaces")
    func projectedIDsAreStableAcrossReinstall() throws {
        let context = try makeContext()
        let gcloud = try builtIn("gcloud-workflow")
        let a = Workspace(name: "A", primaryPath: "/tmp/projection-a")
        let b = Workspace(name: "B", primaryPath: "/tmp/projection-b")
        context.insert(a)
        context.insert(b)
        for workspace in [a, b] {
            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(gcloud.id) }
        }
        let before = PluginRuntimeProjection.project(workspace: a, packages: [gcloud]).skills.map(\.id)
        let other = PluginRuntimeProjection.project(workspace: b, packages: [gcloud]).skills.map(\.id)
        #expect(!before.isEmpty)
        #expect(Set(before).isDisjoint(with: other))

        WorkspaceCapabilityActivation.mutate(a) {
            $0.capabilityIDs = []
            $0.removeInstalledPlugin(id: gcloud.id)
        }
        #expect(WorkspaceCapabilityActivation.activation(for: gcloud.id, in: a) == nil)
        WorkspaceCapabilityActivation.mutate(a) { $0.enableCapability(gcloud.id) }
        #expect(PluginRuntimeProjection.project(workspace: a, packages: [gcloud]).skills.map(\.id) == before)
    }

    @Test("An authored row that replaced the first skill still owns the plugin's tools and accounts")
    func overriddenFirstSkillOwnsResources() throws {
        let context = try makeContext()
        let gcloud = try builtIn("gcloud-workflow")
        let workspace = Workspace(name: "Override", primaryPath: "/tmp/projection-override")
        context.insert(workspace)
        let authored = Skill(name: "My GCloud", allowedTools: ["Read"])
        authored.workspace = workspace
        context.insert(authored)
        let account = Connector(name: "GCP", serviceType: gcloud.connectors[0].serviceType)
        account.workspace = workspace
        context.insert(account)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(gcloud.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: gcloud.id, in: workspace))
        let skillComponent = CapabilityResourceOrigin.componentID(for: gcloud.skills[0])
        WorkspaceCapabilityActivation.setOverridden(true, componentID: skillComponent, rowID: authored.id, on: activation)
        WorkspaceCapabilityActivation.bind(
            account,
            toComponent: CapabilityResourceOrigin.componentID(for: gcloud.connectors[0]),
            of: activation
        )
        try context.save()

        let runtime = PluginRuntimeProjection.project(workspace: workspace, packages: [gcloud], connectorMode: .runtimeCopies)
        let owner = try #require(runtime.skills.first { $0.id == authored.id })
        // A detached copy, so the stored row never adopts projected models.
        #expect(owner.modelContext == nil)
        #expect(owner.name == "My GCloud")
        #expect(!runtime.tools.isEmpty)
        #expect(runtime.tools.allSatisfy { $0.skill?.id == authored.id })
        #expect(runtime.connectors.map { $0.skill?.id } == [authored.id])
        #expect(authored.localTools.isEmpty)
        #expect(authored.connectors.isEmpty)

        // The views see the stored row itself.
        let accounts = PluginRuntimeProjection.project(workspace: workspace, packages: [gcloud])
        #expect(accounts.skills.contains { $0 === authored })
    }

    @Test("Deleting the row that replaced a component gives the component back to the plugin")
    func deletedOverrideRowRestoresComponent() throws {
        let context = try makeContext()
        let gcloud = try builtIn("gcloud-workflow")
        let workspace = Workspace(name: "Gone", primaryPath: "/tmp/projection-gone")
        context.insert(workspace)
        let authored = Skill(name: "My GCloud", allowedTools: ["Read"])
        authored.workspace = workspace
        context.insert(authored)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(gcloud.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: gcloud.id, in: workspace))
        let skillComponent = CapabilityResourceOrigin.componentID(for: gcloud.skills[0])
        WorkspaceCapabilityActivation.setOverridden(true, componentID: skillComponent, rowID: authored.id, on: activation)
        try context.save()
        #expect(!PluginRuntimeProjection.project(workspace: workspace, packages: [gcloud]).skills.contains {
            $0.originComponentID == skillComponent
        })

        context.delete(authored)
        try context.save()
        let projected = PluginRuntimeProjection.project(workspace: workspace, packages: [gcloud]).skills
        #expect(projected.contains { $0.originComponentID == skillComponent && PluginRuntimeProjection.isProjected($0) })
    }

    @Test("Adding a catalog skill turns its stored row on instead of projecting a copy")
    func syntheticSkillPackageEnablesItsRow() throws {
        let context = try makeContext()
        let workspace = Workspace(name: "Synthetic", primaryPath: "/tmp/projection-synthetic")
        context.insert(workspace)
        let shared = Skill(name: "Shared Analyst", allowedTools: ["Read"])
        shared.isGlobal = true
        context.insert(shared)
        let tool = LocalTool(name: "jq", toolDescription: "", icon: "terminal", toolType: "cli", command: "jq", arguments: "")
        tool.isGlobal = true
        tool.skill = shared
        context.insert(tool)
        try context.save()
        let package = PluginPackage(
            id: "skill.\(shared.id.uuidString.lowercased())",
            name: shared.name,
            icon: shared.icon,
            description: "",
            author: "Shared Library",
            category: "Shared",
            tags: ["shared"],
            version: "1.0.0",
            skills: [PluginSkill(
                name: shared.name, icon: shared.icon, description: "", allowedTools: ["Read"],
                disallowedTools: [], customTools: [], behaviorInstructions: "", environmentKeys: [], environmentValues: []
            )],
            connectors: [],
            localTools: [],
            templates: [],
            sourceMetadata: CapabilitySourceMetadata(
                id: "shared-skills", displayName: "Shared Capability", kind: "shared", trustLevel: "shared"
            ),
            governance: .builtInApproved(riskLevel: .low)
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-synthetic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)

        let result = try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        #expect(result.skillIDs == [shared.id])
        #expect(workspace.enabledGlobalSkillIDs == [shared.id.uuidString])
        #expect(workspace.enabledGlobalToolIDs == [tool.id.uuidString])
        #expect(workspace.pluginActivations.isEmpty)
        #expect(library.installedPackages().isEmpty)
    }

    @Test("Add records the definition's components and keeps the workspace's default account")
    func addSeedsKnownComponentsAndKeepsDefault() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let workspace = Workspace(name: "Known", primaryPath: "/tmp/projection-known")
        context.insert(workspace)
        let chosen = Connector(name: "Chosen", serviceType: jira.connectors[0].serviceType)
        chosen.workspace = workspace
        context.insert(chosen)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("other-jira") }
        let other = try #require(WorkspaceCapabilityActivation.activation(for: "other-jira", in: workspace))
        WorkspaceCapabilityActivation.bind(chosen, toComponent: "connector:jira:other", of: other)
        try context.save()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-known-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try CapabilityInstaller(library: CapabilityLibrary(directory: root)).install(
            jira,
            into: workspace,
            modelContext: context,
            baseURLOverrides: [jira.connectors[0].name: "https://new.atlassian.net"]
        )

        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        #expect(activation.knownComponentIDs == PluginRuntimeProjection.componentIDs(of: jira))
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: jira.connectors[0].serviceType, in: workspace)?.id == chosen.id)
    }

    @Test("Copying setup reads only the copied plugin's own accounts")
    func setupCopyIsScopedToThePackage() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let spec = jira.connectors[0]
        let workspace = Workspace(name: "Source", primaryPath: "/tmp/projection-copy")
        context.insert(workspace)
        let unrelated = Connector(name: spec.name, serviceType: spec.serviceType, baseURL: "https://unrelated.atlassian.net")
        unrelated.workspace = workspace
        // Only the unrelated plugin's account has a project list: a copy
        // that read it would hand it to this plugin.
        unrelated.configKeys = ["JIRA_PROJECTS"]
        unrelated.configValues = ["UNRELATED"]
        let own = Connector(name: spec.name, serviceType: spec.serviceType, baseURL: "https://own.atlassian.net")
        own.workspace = workspace
        context.insert(unrelated)
        context.insert(own)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability("other-jira")
            $0.enableCapability(jira.id)
        }
        let other = try #require(WorkspaceCapabilityActivation.activation(for: "other-jira", in: workspace))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        // The unrelated plugin's account is older and the service default.
        WorkspaceCapabilityActivation.bind(unrelated, toComponent: CapabilityResourceOrigin.componentID(for: spec), of: other)
        WorkspaceCapabilityActivation.bind(own, toComponent: CapabilityResourceOrigin.componentID(for: spec), of: activation)
        try context.save()

        let inputs = CapabilitySetupCopier(secretStore: MockSecretStore()).installationInputs(for: jira, from: workspace)
        #expect(inputs.baseURLOverrides[spec.name] == "https://own.atlassian.net")
        #expect(inputs.configInputs["JIRA_PROJECTS"] == nil)
    }

    @Test("Copying setup does not turn back on a plugin the source turned off")
    func setupCopySkipsDisabledActivation() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let spec = jira.connectors[0]
        let workspace = Workspace(name: "Off", primaryPath: "/tmp/projection-copy-off")
        context.insert(workspace)
        // Turn off keeps the binding; its non-default URL is a nonempty input.
        let own = Connector(name: spec.name, serviceType: spec.serviceType, baseURL: "https://own.atlassian.net")
        own.workspace = workspace
        context.insert(own)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(jira.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        WorkspaceCapabilityActivation.bind(own, toComponent: CapabilityResourceOrigin.componentID(for: spec), of: activation)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.removeAll { $0 == jira.id } }
        try context.save()
        #expect(activation.isEnabled == false)

        let summary = CapabilitySetupCopier(secretStore: MockSecretStore()).copySetup(from: workspace, packages: [jira])
        #expect(!summary.selectedPackageIDs.contains(jira.id))
        #expect(summary.inputsByPackageID[jira.id] == nil)
    }

    @Test("Deleting a workspace cleans the namespaces its activations remember, even without the plugin")
    func deletionCleanupUsesRememberedComponents() throws {
        let context = try makeContext()
        let workspace = Workspace(name: "Forgotten", primaryPath: "/tmp/projection-forgotten")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("gone-plugin") }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gone-plugin", in: workspace))
        WorkspaceCapabilityActivation.setKnownComponents(["skill:old"], on: activation)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:older#TOKEN", on: activation)
        try context.save()

        let record = WorkspaceDeletionCleanupRecord(workspace)
        let expected = ["skill:old", "skill:older"].map {
            PluginRuntimeProjection.derivedID(workspaceID: workspace.id, pluginID: "gone-plugin", componentID: $0)
        }
        #expect(Set(expected).isSubset(of: Set(record.skills.map(\.skillID))))
    }

    @Test("An account two plugins bind is owned by both for scope pruning")
    func sharedAccountKeepsEveryOwner() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        var second = jira
        second.id = "jira-ops"
        second.skills[0].name = "Jira Ops Agent"
        let workspace = Workspace(name: "Shared", primaryPath: "/tmp/projection-shared")
        context.insert(workspace)
        let account = Connector(name: "Jira", serviceType: jira.connectors[0].serviceType)
        account.workspace = workspace
        context.insert(account)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability(jira.id)
            $0.enableCapability(second.id)
        }
        let component = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        for id in [jira.id, second.id] {
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: id, in: workspace))
            WorkspaceCapabilityActivation.bind(account, toComponent: component, of: activation)
        }
        try context.save()

        let projection = PluginRuntimeProjection.project(workspace: workspace, packages: [jira, second], connectorMode: .runtimeCopies)
        #expect(projection.connectors.map(\.id) == [account.id])
        let primaries = Set(projection.skills.filter { $0.name == jira.skills[0].name || $0.name == "Jira Ops Agent" }.map(\.id))
        #expect(primaries.count == 2)
        #expect(projection.accountOwnerSkillIDs[account.id] == primaries)
    }

    @Test("Adding a version without a connector releases its binding and keeps the account")
    func addReleasesDroppedConnectorBindings() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let workspace = Workspace(name: "Dropped", primaryPath: "/tmp/projection-dropped")
        context.insert(workspace)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-dropped-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = CapabilityInstaller(library: CapabilityLibrary(directory: root))
        try installer.install(jira, into: workspace, modelContext: context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        let account = try #require(activation.bindings.first?.account)

        var next = jira
        next.version = "9.0.0"
        next.connectors = []
        try installer.install(next, into: workspace, modelContext: context)
        #expect(activation.bindings.isEmpty)
        #expect(workspace.connectors.contains { $0.id == account.id })
    }

    @Test("Unbinding one component keeps the account's other bindings and the default")
    func unbindOneComponent() throws {
        let context = try makeContext()
        let workspace = Workspace(name: "Two components", primaryPath: "/tmp/projection-two")
        context.insert(workspace)
        let account = Connector(name: "Tracker", serviceType: "tracker")
        context.insert(account)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability("p") }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "p", in: workspace))
        WorkspaceCapabilityActivation.bind(account, toComponent: "connector:tracker:a", of: activation)
        WorkspaceCapabilityActivation.bind(account, toComponent: "connector:tracker:b", of: activation)
        WorkspaceCapabilityActivation.unbind(account, from: activation, componentID: "connector:tracker:a")
        #expect(activation.accounts(forComponent: "connector:tracker:a").isEmpty)
        #expect(activation.accounts(forComponent: "connector:tracker:b").map(\.id) == [account.id])
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "tracker", in: workspace)?.id == account.id)
    }

    @Test("A launch copy projects a component whose override row was deleted, like the live workspace")
    func detachedCopyDropsStaleOverrides() throws {
        let context = try makeContext()
        let gcloud = try builtIn("gcloud-workflow")
        let workspace = Workspace(name: "Stale", primaryPath: "/tmp/projection-stale")
        context.insert(workspace)
        let authored = Skill(name: "My GCloud", allowedTools: ["Read"])
        authored.isGlobal = true
        context.insert(authored)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(gcloud.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: gcloud.id, in: workspace))
        let component = CapabilityResourceOrigin.componentID(for: gcloud.skills[0])
        WorkspaceCapabilityActivation.setOverridden(true, componentID: component, rowID: authored.id, on: activation)
        try context.save()
        context.delete(authored)
        try context.save()

        let copy = Workspace(name: "Copy", primaryPath: "/tmp/projection-stale")
        copy.id = workspace.id
        WorkspaceCapabilityActivation.copyActivations(from: workspace, to: copy, accountsByID: [:])
        #expect(copy.pluginActivations.first?.overriddenComponentIDs.isEmpty == true)
        let detached = PluginRuntimeProjection.project(workspace: copy, packages: [gcloud], connectorMode: .runtimeCopies)
        #expect(detached.skills.contains { $0.originComponentID == component })
    }

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(container)
        return container.mainContext
    }

    private func builtIn(_ id: String) throws -> PluginPackage {
        try #require(PluginCatalog.builtInPackages.first { $0.id == id })
    }
}
