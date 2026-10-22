import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore
import HostControlToolSupport

/// Identity and ownership rules of `PluginRuntimeProjection` and the services
/// that write activations (Plugins 2.0 R1 review).
@Suite("Plugin runtime projection")
@MainActor
struct PluginRuntimeProjectionTests {
    @Test("One resolution shares projected identities; a fresh resolver observes the next activation state")
    func resolverMemoPreservesProjectionAndRefreshBoundary() throws {
        let context = try makeContext()
        let package = try builtIn("jira-workflow")
        let workspace = Workspace(name: "Resolver projection", primaryPath: "/tmp/projection-resolver-memo")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(package.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let spec = try #require(package.connectors.first)
        let account = Connector(name: "Resolver account", serviceType: spec.serviceType, baseURL: spec.baseURL, authMethod: spec.authMethod)
        account.workspace = workspace
        context.insert(account)
        CapabilityResourceOrigin.stamp(account, package: package, componentID: CapabilityResourceOrigin.componentID(for: spec))
        WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: spec), of: activation)
        let task = AgentTask(title: "Resolve", goal: "Resolve plugin inventory", workspace: workspace, runtime: .claudeCode)
        context.insert(task)
        try context.save()
        let resolver = TaskCapabilityResolver(task: task, secretStore: MockSecretStore())
        let first = resolver.resourceInventory
        let second = resolver.resourceInventory
        let skill = try #require(first.behaviorSkills.first { $0.originPackageID == package.id })
        let sameSkill = try #require(second.behaviorSkills.first { $0.id == skill.id })
        #expect(skill === sameSkill)
        let projectedAccount = try #require(first.connectors.first { $0.id == account.id })
        #expect(second.connectors.contains { $0 === projectedAccount })
        #expect(skill.connectors.contains { $0 === projectedAccount })
        WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.removeAll { $0 == package.id } }
        try context.save()
        let next = TaskCapabilityResolver(task: task, secretStore: MockSecretStore()).resourceInventory
        #expect(!next.behaviorSkills.contains { $0.originPackageID == package.id })
    }

    @Test("A withdrawn default account cannot prevent election among usable accounts")
    func withdrawnDefaultElectsUsableAccount() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let workspace = Workspace(name: "Withdrawn default", primaryPath: "/tmp/projection-withdrawn-default")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(jira.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        let component = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        var accounts: [Connector] = []
        for i in 0..<3 {
            let row = Connector(name: "Account \(i)", serviceType: "jira", baseURL: "https://site\(i).atlassian.net", authMethod: i == 0 ? "withdrawn-auth" : jira.connectors[0].authMethod)
            row.workspace = workspace
            context.insert(row)
            CapabilityResourceOrigin.stamp(row, package: jira, componentID: component)
            WorkspaceCapabilityActivation.bind(row, toComponent: component, of: activation, isDefault: i == 0)
            let binding = try #require(activation.bindings.first { $0.account?.id == row.id })
            binding.createdAt = Date(timeIntervalSince1970: Double(1000 + i))
            accounts.append(row)
        }
        try context.save()
        let projection = PluginRuntimeProjection.project(workspace: workspace, packages: [jira], connectorMode: .runtimeCopies, definitions: [jira])
        #expect(Set(projection.connectors.map(\.id)) == Set(accounts.dropFirst().map(\.id)))
        #expect(projection.defaultAccountIDs.contains(accounts[1].id))
        #expect(!projection.defaultAccountIDs.contains(accounts[0].id))
    }

    @Test("A shared creator account retains all declarations even when an override emits it first", arguments: [false, true])
    func sharedCreatorAccountRetainsAllDeclarations(attachedToOverride: Bool) throws {
        let context = try makeContext()
        var package = try builtIn("jira-workflow")
        var second = package.connectors[0]
        package.connectors[0].id = "first"
        package.connectors[0].credentialHints = [.init(key: "FIRST_TOKEN", hint: "First")]
        package.connectors[0].configHints = []
        second.credentialHints = [.init(key: "SECOND_TOKEN", hint: "Second")]
        // This original bundled component owns the trusted plain setting;
        // the first binding alone cannot declare it.
        second.configHints = [.init(key: "JIRA_PROJECTS", hint: "Projects", isList: false)]
        package.connectors.append(second)
        let workspace = Workspace(name: "Shared fields", primaryPath: "/tmp/projection-shared-fields")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(package.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let account = Connector(name: "Shared", serviceType: "jira", baseURL: package.connectors[0].baseURL, authMethod: package.connectors[0].authMethod)
        account.workspace = workspace
        context.insert(account)
        CapabilityResourceOrigin.stamp(account, package: package, componentID: "first")
        account.credentialKeys = ["FIRST_TOKEN", "SECOND_TOKEN", "STALE_TOKEN"]
        account.credentialValues = ["", "", ""]
        account.configKeys = ["JIRA_PROJECTS", "STALE_SETTING"]
        account.configValues = ["CLIN", "stale"]
        var authored: Skill?
        if attachedToOverride {
            let row = Skill(name: "Authored Jira", allowedTools: ["Read"])
            row.workspace = workspace
            context.insert(row)
            account.skill = row
            WorkspaceCapabilityActivation.setOverridden(
                true, componentID: CapabilityResourceOrigin.componentID(for: package.skills[0]),
                rowID: row.id, on: activation
            )
            authored = row
        }
        for spec in package.connectors { WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: spec), of: activation) }
        try context.save()
        let projection = PluginRuntimeProjection.project(workspace: workspace, packages: [package], connectorMode: .runtimeCopies, definitions: [package])
        let copy = try #require(projection.connectors.first { $0.id == account.id })
        #expect(Set(copy.credentialKeys) == ["FIRST_TOKEN", "SECOND_TOKEN"])
        #expect(Set(copy.configKeys) == ["JIRA_PROJECTS"])
        #expect(projection.connectors.filter { $0.id == account.id }.count == 1)
        if let authored {
            let skill = try #require(projection.skills.first { $0.id == authored.id })
            #expect(skill.connectors.contains { $0 === copy })
            #expect(copy.skill === skill)
            #expect(projection.accountOwnerSkillIDs[account.id] == [skill.id])
        }
        // Runtime filtering must never remove saved configuration or markers.
        #expect(account.credentialKeys == ["FIRST_TOKEN", "SECOND_TOKEN", "STALE_TOKEN"])
        #expect(account.configKeys == ["JIRA_PROJECTS", "STALE_SETTING"])
        let editable = PluginRuntimeProjection.project(workspace: workspace, packages: [package], definitions: [package])
        #expect(editable.connectors.first { $0.id == account.id } === account)
        #expect(!context.hasChanges)
    }

    @Test("Plugin-owned override attachments are filtered even when their creator has no active bindings", arguments: [false, true])
    func inactiveCreatorAttachmentIsFiltered(creatorAvailable: Bool) throws {
        let context = try makeContext()
        var creator = try builtIn("jira-workflow")
        creator.connectors[0].credentialHints = [.init(key: "VISIBLE_TOKEN", hint: "Declared")]
        creator.connectors[0].configHints = [.init(key: "JIRA_PROJECTS", hint: "Projects", isList: false)]
        var consumer = creator
        consumer.id = "authored-consumer"
        consumer.connectors = []
        let workspace = Workspace(name: "Inactive creator attachment", primaryPath: "/tmp/projection-inactive-creator")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) { state in
            state.enableCapability(creator.id)
            state.enableCapability(consumer.id)
        }
        let creatorActivation = try #require(WorkspaceCapabilityActivation.activation(for: creator.id, in: workspace))
        let consumerActivation = try #require(WorkspaceCapabilityActivation.activation(for: consumer.id, in: workspace))
        let spec = creator.connectors[0]
        let account = Connector(name: "Attached account", serviceType: spec.serviceType, baseURL: spec.baseURL, authMethod: spec.authMethod)
        account.workspace = workspace
        context.insert(account)
        CapabilityResourceOrigin.stamp(account, package: creator, componentID: CapabilityResourceOrigin.componentID(for: spec))
        account.credentialKeys = ["VISIBLE_TOKEN", "RETIRED_TOKEN"]
        account.credentialValues = ["", ""]
        account.configKeys = ["JIRA_PROJECTS", "RETIRED_SETTING"]
        account.configValues = ["CLIN", "retired"]
        WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: spec), of: creatorActivation)
        let authored = Skill(name: "Authored consumer", allowedTools: ["Read"])
        authored.workspace = workspace
        context.insert(authored)
        account.skill = authored
        WorkspaceCapabilityActivation.setOverridden(true,
            componentID: CapabilityResourceOrigin.componentID(for: consumer.skills[0]), rowID: authored.id, on: consumerActivation)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.removeAll { $0 == creator.id } }
        try context.save()
        #expect(!creatorActivation.isEnabled)
        #expect(creatorActivation.bindings.contains { $0.account?.id == account.id })
        let projection = PluginRuntimeProjection.project(workspace: workspace, packages: [consumer], connectorMode: .runtimeCopies,
            definitions: creatorAvailable ? [creator, consumer] : [consumer])
        let copy = try #require(projection.connectors.first { $0.id == account.id })
        #expect(Set(copy.credentialKeys) == (creatorAvailable ? ["VISIBLE_TOKEN"] : []))
        #expect(Set(copy.configKeys) == (creatorAvailable ? ["JIRA_PROJECTS"] : []))
        #expect(projection.skills.first { $0.id == authored.id }?.connectors.contains { $0 === copy } == true)
        #expect(account.credentialKeys == ["VISIBLE_TOKEN", "RETIRED_TOKEN"])
        #expect(account.configKeys == ["JIRA_PROJECTS", "RETIRED_SETTING"])
        #expect(!context.hasChanges)
    }

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

    @Test("A shared row that replaced a later skill brings only this workspace's tools")
    func secondaryOverrideSkillIsScopedToItsWorkspace() throws {
        let context = try makeContext()
        var jira = try builtIn("jira-workflow")
        jira.skills.append(PluginSkill(
            name: "Jira Triage", icon: "ticket", description: "", allowedTools: ["Read"],
            disallowedTools: [], customTools: [], behaviorInstructions: "", environmentKeys: [], environmentValues: []
        ))
        let a = Workspace(name: "A", primaryPath: "/tmp/projection-second-a")
        let b = Workspace(name: "B", primaryPath: "/tmp/projection-second-b")
        context.insert(a)
        context.insert(b)
        let shared = Skill(name: "My Triage", allowedTools: ["Read"])
        shared.isGlobal = true
        context.insert(shared)
        // A attached its own command to the shared replacement.
        let aTool = LocalTool(name: "a-only", toolDescription: "", icon: "terminal", toolType: "cli", command: "a-only", arguments: "")
        aTool.workspace = a
        aTool.skill = shared
        context.insert(aTool)
        let component = CapabilityResourceOrigin.componentID(for: jira.skills[1])
        for workspace in [a, b] {
            WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(jira.id) }
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
            WorkspaceCapabilityActivation.setOverridden(true, componentID: component, rowID: shared.id, on: activation)
        }
        try context.save()

        let inB = PluginRuntimeProjection.project(workspace: b, packages: [jira], connectorMode: .runtimeCopies)
        let replacement = try #require(inB.skills.first { $0.id == shared.id })
        #expect(replacement.modelContext == nil)
        #expect(!inB.skills.flatMap(\.localTools).contains { $0.id == aTool.id })
        #expect(!inB.tools.contains { $0.id == aTool.id })
        let inA = PluginRuntimeProjection.project(workspace: a, packages: [jira], connectorMode: .runtimeCopies)
        #expect(inA.tools.contains { $0.id == aTool.id && $0.skill?.id == shared.id })
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Synthetic", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Known", primaryPath: workspaceFolder.path)
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
        #expect(inputs.baseURLOverrides[spec.setupComponentID] == "https://own.atlassian.net")
        #expect(inputs.configInputs[PluginSetupInputs.key("JIRA_PROJECTS", component: spec.setupComponentID)] == nil)
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

    @Test("A request that matches an account two plugins bind brings in both plugins")
    func matchedSharedAccountIncludesEveryOwner() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let gcloud = try builtIn("gcloud-workflow")
        let workspace = Workspace(name: "Owners", primaryPath: "/tmp/projection-owners")
        context.insert(workspace)
        let account = Connector(name: "Tracker", serviceType: jira.connectors[0].serviceType)
        account.authMethod = "none"
        account.workspace = workspace
        context.insert(account)
        // Jira first: the account's one runtime copy is wired to its skill.
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(jira.id) }
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(gcloud.id) }
        for package in [jira, gcloud] {
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
            WorkspaceCapabilityActivation.bind(
                account, toComponent: CapabilityResourceOrigin.componentID(for: package.connectors[0]), of: activation
            )
        }
        let task = AgentTask(title: "Owners", goal: "Ask the Tracker", workspace: workspace)
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).resolvedScope(.providerLaunch(contextText: "Ask the Tracker"))
        #expect(scope.connectors.contains { $0.id == account.id })
        let names = Set(scope.behaviorSkills.map(\.name))
        #expect(names.contains(jira.skills[0].name))
        #expect(names.contains(gcloud.skills[0].name))
    }

    @Test("A recorded version is compared even with no recorded digest")
    func versionIsComparedWithoutADigest() throws {
        let context = try makeContext()
        let gcloud = try builtIn("gcloud-workflow")
        let workspace = Workspace(name: "Pre-V20", primaryPath: "/tmp/projection-pre-v20")
        context.insert(workspace)
        // As recovered from a mirror written before V20: a version, no digest.
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability(gcloud.id)
            $0.recordInstalledPlugin(id: gcloud.id, version: gcloud.version)
        }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: gcloud.id, in: workspace))
        #expect(activation.recordedDigest.isEmpty)
        #expect(!PluginRuntimeProjection.awaitsUpdate(activation, to: gcloud))
        var newer = gcloud
        newer.version = "99.0.0"
        #expect(PluginRuntimeProjection.awaitsUpdate(activation, to: newer))
        // And components it never recorded.
        WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: gcloud), on: activation)
        var more = gcloud
        more.skills.append(PluginSkill(
            name: "Extra", icon: "", description: "", allowedTools: [], disallowedTools: [], customTools: [],
            behaviorInstructions: "", environmentKeys: [], environmentValues: []
        ))
        #expect(PluginRuntimeProjection.awaitsUpdate(activation, to: more))
    }

    @Test("Adding a version without a connector releases its binding and keeps the account")
    func addReleasesDroppedConnectorBindings() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Dropped", primaryPath: workspaceFolder.path)
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

    @Test("A definition another workspace added doesn't run here until this workspace accepts it")
    func activationRunsOnlyTheDefinitionItAccepted() throws {
        let context = try makeContext()
        let gcloud = try builtIn("gcloud-workflow")
        let aFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: aFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: aFolder) }
        let a = Workspace(name: "A", primaryPath: aFolder.path)
        let bFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: bFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bFolder) }
        let b = Workspace(name: "B", primaryPath: bFolder.path)
        context.insert(a)
        context.insert(b)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-accepted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CapabilityLibrary(directory: root)
        let installer = CapabilityInstaller(library: library)
        try context.save()
        try installer.install(gcloud, into: a, modelContext: context)
        try installer.install(gcloud, into: b, modelContext: context)
        func instructions(_ workspace: Workspace) -> [String] {
            PluginRuntimeProjection.project(workspace: workspace, packages: library.installedPackages()).skills.map(\.behaviorInstructions)
        }
        #expect(instructions(a) == gcloud.skills.map(\.behaviorInstructions))

        // B adds a newer version: the library's one definition changes for A too.
        var next = gcloud
        next.version = "9.0.0"
        next.skills[0].behaviorInstructions = "Version nine rules."
        try installer.install(next, into: b, modelContext: context)
        #expect(instructions(b).first == "Version nine rules.")
        #expect(instructions(a).isEmpty)
        #expect(PluginRuntimeProjection.runnable(library.installedPackages(), in: a).allSatisfy { $0.id != gcloud.id })
        #expect(CapabilityRuntimeResourceMatcher.enabledPackages(for: a, in: library.installedPackages()).allSatisfy { $0.id != gcloud.id })

        // Adding it in A accepts it there.
        try installer.install(next, into: a, modelContext: context)
        #expect(instructions(a).first == "Version nine rules.")
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

    /// Make default on the second of two accounts: a broker call that names
    /// no account reaches it, and naming the other still reaches that one.
    @Test("An aliasless broker call reaches the account made default, and a named one still wins")
    func aliaslessBrokerCallUsesTheWorkspaceDefault() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        let workspace = Workspace(name: "Defaults", primaryPath: "/tmp/projection-defaults")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(jira.id) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        let component = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        let accounts = ["Ops", "Research"].map { name in
            let account = Connector(name: name, serviceType: "jira", baseURL: "https://\(name.lowercased()).atlassian.net", authMethod: "basic")
            account.workspace = workspace
            context.insert(account)
            WorkspaceCapabilityActivation.bind(account, toComponent: component, of: activation)
            return account
        }
        WorkspaceCapabilityActivation.bind(accounts[1], toComponent: component, of: activation, isDefault: true)
        let task = AgentTask(title: "Issues", goal: "list the open issues", workspace: workspace, runtime: .claudeCode)
        context.insert(task)
        try context.save()

        let configuration = Self.brokerConfiguration(for: task)
        #expect(configuration.connectorManifest.connectors.count == 2)
        #expect(configuration.connectorManifest.connectors.filter { $0.isDefault == true }.map(\.id) == [accounts[1].id.uuidString])
        let resolve = { HostControlBrokeredServices.resolveConnector(forServiceType: "jira", alias: $0, in: configuration).connector?.id }
        #expect(resolve(nil) == accounts[1].id.uuidString)
        let other = try #require(configuration.connectorManifest.connectors.first { $0.id == accounts[0].id.uuidString })
        #expect(resolve(other.alias) == accounts[0].id.uuidString)
    }

    /// Turn off keeps plugin A's bindings, its default included. While A is
    /// off, B's oldest account stands in; turning A on gives the default back.
    @Test("With the default's plugin off, an aliasless call reaches the oldest enabled account, and A's again once it's back")
    func projectedDefaultFallsBackToTheOldestEnabledAccount() throws {
        let context = try makeContext()
        let jira = try builtIn("jira-workflow")
        var other = jira
        other.id = "jira-ops"
        other.skills[0].name = "Jira Ops Agent"
        let workspace = Workspace(name: "Fallback", primaryPath: "/tmp/projection-fallback")
        context.insert(workspace)
        WorkspaceCapabilityActivation.mutate(workspace) {
            $0.enableCapability(jira.id)
            $0.enableCapability(other.id)
        }
        let component = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        func account(_ name: String, boundTo pluginID: String, at offset: TimeInterval) throws -> Connector {
            let row = Connector(name: name, serviceType: "jira", baseURL: "https://\(name.lowercased()).atlassian.net", authMethod: "basic")
            row.workspace = workspace
            context.insert(row)
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace))
            WorkspaceCapabilityActivation.bind(row, toComponent: component, of: activation)
            let binding = try #require(activation.bindings.first { $0.account?.id == row.id })
            binding.createdAt = Date(timeIntervalSince1970: 1_000 + offset)
            return row
        }
        let primary = try account("Primary", boundTo: jira.id, at: 0)
        let older = try account("Older", boundTo: other.id, at: 10)
        _ = try account("Newer", boundTo: other.id, at: 20)
        try context.save()

        func aliaslessCall() -> String? {
            let projection = PluginRuntimeProjection.project(workspace: workspace, packages: [jira, other], connectorMode: .runtimeCopies)
            let manifest = ConnectorRuntimeProjection(
                connectors: projection.connectors, secretStore: MockSecretStore(), defaultConnectorIDs: projection.defaultAccountIDs
            ).manifestJSON()
            return HostControlBrokeredServices.resolveConnector(
                forServiceType: "jira", alias: nil, in: HostControlToolConfiguration(connectorsJSON: manifest)
            ).connector?.id
        }
        #expect(aliaslessCall() == primary.id.uuidString)

        WorkspaceCapabilityActivation.mutate(workspace) { $0.capabilityIDs.removeAll { $0 == jira.id } }
        let kept = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        #expect(!kept.isEnabled && kept.bindings.contains { $0.isDefault && $0.account?.id == primary.id })
        #expect(aliaslessCall() == older.id.uuidString)

        WorkspaceCapabilityActivation.mutate(workspace) { $0.enableCapability(jira.id) }
        #expect(aliaslessCall() == primary.id.uuidString)
    }

    @Test("Accounts enabled outside a plugin carry no default, so an aliasless call is still refused")
    func directAccountsKeepTheRefusal() throws {
        let context = try makeContext()
        let workspace = Workspace(name: "Direct", primaryPath: "/tmp/projection-direct")
        context.insert(workspace)
        for name in ["Ops", "Research"] {
            let account = Connector(name: name, serviceType: "jira", baseURL: "https://\(name.lowercased()).atlassian.net", authMethod: "basic")
            account.workspace = workspace
            context.insert(account)
        }
        let task = AgentTask(title: "Issues", goal: "list the open issues", workspace: workspace, runtime: .claudeCode)
        context.insert(task)
        try context.save()

        let configuration = Self.brokerConfiguration(for: task)
        #expect(configuration.connectorManifest.connectors.count == 2)
        #expect(configuration.connectorManifest.connectors.allSatisfy { $0.isDefault == nil })
        let resolution = HostControlBrokeredServices.resolveConnector(forServiceType: "jira", alias: nil, in: configuration)
        guard case .ambiguous(alias: nil, _) = resolution else {
            Issue.record("Expected the aliasless call to be refused, got \(resolution)")
            return
        }
    }

    // MARK: - Helpers

    /// The broker's configuration as a launch of `task` builds it.
    private static func brokerConfiguration(for task: AgentTask) -> HostControlToolConfiguration {
        let store = MockSecretStore()
        let scope = TaskCapabilityResolver(task: task, runtime: .claudeCode, secretStore: store).resolvedScope(.fullInventory)
        let environment = HostControlBrokerSessionRegistry.brokeredConnectorEnvironment(
            task: task,
            runtime: .claudeCode,
            capabilityScope: scope,
            requiredTools: ["jira"],
            secretStore: store
        )
        return HostControlToolConfiguration(connectorsJSON: environment["ASTRA_CONNECTORS"] ?? #"{"connectors":[]}"#)
    }

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
