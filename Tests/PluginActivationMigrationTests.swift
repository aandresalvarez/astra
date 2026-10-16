import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// The V19 -> V20 move onto `PluginActivation` (spec: "Migration V19 -> V20").
/// The fixture is a real V19 store written through the frozen V19 models: two
/// Jira accounts in one workspace, a third workspace's own Jira account, a
/// shared Google Cloud account with a project ID, an unedited shared GCloud
/// skill with a setting, and an edited built-in Jira skill.
@Suite("Plugin activation migration")
@MainActor
struct PluginActivationMigrationTests {
    @Test("A V19 store migrates to activations, accounts and authored overrides")
    func v19FixtureMigrates() throws {
        let fixture = try Fixture()
        let context = fixture.context
        #expect(PluginActivationMigration.needsMigration(modelContext: context))

        let report = try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        #expect(report.activations == 5)
        #expect(report.skillsProjected == 1)
        #expect(report.skillsKeptAsAuthored == 1)
        #expect(report.toolsProjected == fixture.gcloud.localTools.count)

        let a = try fixture.workspace(fixture.aID)
        let b = try fixture.workspace(fixture.bID)
        let c = try fixture.workspace(fixture.cID)
        for workspace in [a, b, c] {
            #expect(workspace.legacyEnabledCapabilityIDs.isEmpty)
            #expect(workspace.legacyInstalledPluginIDs.isEmpty)
        }

        // 1. One activation per installed-or-enabled plugin, on when enabled,
        // with the recorded version and the library digest.
        #expect(Set(a.enabledCapabilityIDs) == ["jira-workflow", "gcloud-workflow"])
        #expect(Set(b.enabledCapabilityIDs) == ["jira-workflow", "gcloud-workflow"])
        #expect(c.installedPluginIDs == ["jira-workflow"])
        #expect(c.enabledCapabilityIDs.isEmpty)
        let aJira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: a))
        #expect(aJira.recordedVersion == "1.0.0")
        #expect(aJira.recordedDigest == (try CapabilityApprovalDigest.digest(for: fixture.jira)))

        // 2. Connectors stay rows with the same IDs and become accounts,
        // bound by ownership; same-named accounts get distinct aliases.
        let jiraComponent = CapabilityResourceOrigin.componentID(for: fixture.jira.connectors[0])
        let aAccounts = aJira.accounts(forComponent: jiraComponent)
        #expect(Set(aAccounts.map(\.id)) == [fixture.jiraAccount1ID, fixture.jiraAccount2ID])
        #expect(Set(aAccounts.map(\.name)) == ["Jira", "Jira 2"])
        let bJira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: b))
        #expect(bJira.accounts(forComponent: jiraComponent).map(\.id) == [fixture.jiraAccountBID])
        let cJira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: c))
        #expect(cJira.bindings.isEmpty)

        let gcloudComponent = CapabilityResourceOrigin.componentID(for: fixture.gcloud.connectors[0])
        for workspace in [a, b] {
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: workspace))
            let shared = try #require(activation.accounts(forComponent: gcloudComponent).first)
            #expect(shared.id == fixture.sharedGCloudID)
            #expect(shared.config["GCP_PROJECT"] == "shared-project")
            #expect(shared.skill == nil)
        }
        #expect(!a.enabledGlobalConnectorIDs.contains(fixture.sharedGCloudID.uuidString))

        // 3. The unedited shared skill is gone; its setting moved to each
        // activation, and the template and schedule name its projection.
        #expect(try context.fetch(FetchDescriptor<Skill>()).map(\.id) == [fixture.editedJiraSkillID])
        let gcloudSkill = fixture.gcloud.skills[0]
        let skillComponent = CapabilityResourceOrigin.componentID(for: gcloudSkill)
        let aGCloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(aGCloud.configuration(forComponent: skillComponent)["GCP_PROJECT"] == "skill-project")
        let projectedID = PluginRuntimeProjection.derivedID(activationID: aGCloud.id, componentID: skillComponent)
        #expect(a.templates.first?.defaultSkillIDs == [projectedID.uuidString])
        #expect(a.schedules.first?.skillIDs == [projectedID.uuidString])
        #expect(!a.enabledGlobalSkillIDs.contains(fixture.gcloudSkillID.uuidString))
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).isEmpty)

        // 4. The edited skill survives as an authored skill; the activations
        // skip the component it replaced, and it stays on where Jira is on.
        let edited = try #require(try context.fetch(FetchDescriptor<Skill>()).first)
        #expect(edited.originPackageID == nil)
        #expect(edited.behaviorInstructions == "My own Jira rules.")
        let editedComponent = CapabilityResourceOrigin.componentID(for: fixture.jira.skills[0])
        #expect(aJira.overriddenComponentIDs == [editedComponent])
        #expect(cJira.overriddenComponentIDs == [editedComponent])
        #expect(a.enabledGlobalSkillIDs.contains(fixture.editedJiraSkillID.uuidString))
        #expect(!c.enabledGlobalSkillIDs.contains(fixture.editedJiraSkillID.uuidString))

        // Idempotent: nothing left to move.
        #expect(!PluginActivationMigration.needsMigration(modelContext: context))
        #expect(try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages) == .init())
    }

    @Test("After migration a task sees its own workspace's accounts and never another's")
    func migratedRuntimeIsIsolatedPerWorkspace() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let b = try fixture.workspace(fixture.bID)

        let taskA = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        let taskB = AgentTask(title: "B", goal: "Use Jira and Google Cloud", workspace: b)
        context.insert(taskA)
        context.insert(taskB)
        let connectorsA = Set(TaskCapabilityResolver(task: taskA).allConnectors.map(\.id))
        let connectorsB = Set(TaskCapabilityResolver(task: taskB).allConnectors.map(\.id))
        #expect(connectorsA == [fixture.jiraAccount1ID, fixture.jiraAccount2ID, fixture.sharedGCloudID])
        #expect(connectorsB == [fixture.jiraAccountBID, fixture.sharedGCloudID])

        // The projected GCloud skill carries A's own setting, and the edited
        // authored Jira skill replaces the plugin's.
        let skillsA = TaskCapabilityResolver(task: taskA).allBehaviorSkills
        let gcloudSkill = try #require(skillsA.first { $0.name == fixture.gcloud.skills[0].name })
        #expect(gcloudSkill.modelContext == nil)
        #expect(gcloudSkill.environmentVariables["GCP_PROJECT"] == "skill-project")
        #expect(skillsA.filter { $0.name == fixture.jira.skills[0].name }.map(\.id) == [fixture.editedJiraSkillID])

        // Turning Jira off in A takes its accounts out of scope without
        // deleting them.
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll { $0 == "jira-workflow" } }
        let afterOff = Set(TaskCapabilityResolver(task: taskA).allConnectors.map(\.id))
        #expect(afterOff == [fixture.sharedGCloudID])
        #expect(try context.fetch(FetchDescriptor<Connector>()).count == 4)
    }

    @Test("A plugin missing from the library keeps its activation and its rows")
    func missingLibraryEntryKeepsActivationAndRows() throws {
        let fixture = try Fixture()
        let context = fixture.context
        let packages = fixture.packages.filter { $0.id != "gcloud-workflow" }
        let report = try PluginActivationMigration.migrate(modelContext: context, packages: packages)
        #expect(report.skillsProjected == 0)
        let a = try fixture.workspace(fixture.aID)
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(gcloud.recordedDigest.isEmpty)
        #expect(gcloud.recordedVersion == "1.0.0")
        // The skill row is kept as authored instead of being lost.
        let skillIDs = Set(try context.fetch(FetchDescriptor<Skill>()).map(\.id))
        #expect(skillIDs.contains(fixture.gcloudSkillID))
        #expect(!PluginActivationMigration.needsMigration(modelContext: context))
    }

    @Test("A skill's secret setting moves to the projected skill's Keychain namespace")
    func secretSettingMovesToProjectedNamespace() throws {
        guard AstraSecureKeychainTestSupport.isAvailable else { return }
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: [])
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let fixture = try Fixture(gcloudSkillSecret: "s3cret")
                let persistence = SkillSecretSeam.required
                #expect(persistence.saveSecretValue(
                    "s3cret", key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID, skillName: "GCloud", allowUserInteraction: false
                ))
                try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)

                let a = try fixture.workspace(fixture.aID)
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
                let projectedID = PluginRuntimeProjection.derivedID(
                    activationID: activation.id,
                    componentID: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
                )
                #expect(persistence.loadSecretValue(key: "GCP_API_TOKEN", skillID: projectedID, store: KeychainSecretStore()) == "s3cret")
                #expect(!activation.configKeys.contains { $0.hasSuffix(".GCP_API_TOKEN") })
                // The deleted row's own namespace is cleaned after the save.
                #expect(!persistence.secretExists(key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID))
            }
        }
    }
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let packages: [PluginPackage]
    let jira: PluginPackage
    let gcloud: PluginPackage
    let aID = UUID()
    let bID = UUID()
    let cID = UUID()
    let jiraAccount1ID: UUID
    let jiraAccount2ID: UUID
    let jiraAccountBID: UUID
    let sharedGCloudID: UUID
    let gcloudSkillID: UUID
    let editedJiraSkillID: UUID

    private static var retained: [ModelContainer] = []

    init(gcloudSkillSecret: String? = nil) throws {
        jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        gcloud = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        packages = PluginCatalog.builtInPackages
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-plugin-activation-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("store.store")

        typealias V19 = ASTRASchemaV19Models
        var ids: [String: UUID] = [:]
        do {
            let old = try ModelContainer(
                for: Schema(versionedSchema: ASTRASchemaV19.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = old.mainContext
            func workspace(_ id: UUID, _ name: String) -> V19.Workspace {
                let workspace = V19.Workspace()
                workspace.id = id
                workspace.name = name
                context.insert(workspace)
                return workspace
            }
            let a = workspace(aID, "A")
            let b = workspace(bID, "B")
            let c = workspace(cID, "C")
            a.installedPluginIDs = ["jira-workflow", "gcloud-workflow"]
            a.installedPluginVersions = ["1.0.0", "1.0.0"]
            a.enabledCapabilityIDs = ["jira-workflow", "gcloud-workflow"]
            b.installedPluginIDs = ["gcloud-workflow"]
            b.installedPluginVersions = ["1.0.0"]
            b.enabledCapabilityIDs = ["gcloud-workflow", "jira-workflow"]
            c.installedPluginIDs = ["jira-workflow"]
            c.installedPluginVersions = ["1.0.0"]

            let jiraSpec = jira.connectors[0]
            func jiraAccount(_ workspace: V19.Workspace, baseURL: String) -> V19.Connector {
                let connector = V19.Connector()
                connector.name = "Jira"
                connector.serviceType = jiraSpec.serviceType
                connector.baseURL = baseURL
                connector.originPackageID = "jira-workflow"
                connector.originComponentID = CapabilityResourceOrigin.componentID(for: jiraSpec)
                connector.workspace = workspace
                context.insert(connector)
                return connector
            }
            ids["jira1"] = jiraAccount(a, baseURL: "https://one.atlassian.net").id
            ids["jira2"] = jiraAccount(a, baseURL: "https://two.atlassian.net").id
            ids["jiraB"] = jiraAccount(b, baseURL: "https://b.atlassian.net").id

            let gcloudSpec = gcloud.connectors[0]
            let shared = V19.Connector()
            shared.name = gcloudSpec.name
            shared.serviceType = gcloudSpec.serviceType
            shared.isGlobal = true
            shared.configKeys = ["GCP_PROJECT"]
            shared.configValues = ["shared-project"]
            shared.originPackageID = "gcloud-workflow"
            shared.originComponentID = CapabilityResourceOrigin.componentID(for: gcloudSpec)
            context.insert(shared)
            ids["shared"] = shared.id
            a.enabledGlobalConnectorIDs = [shared.id.uuidString]

            let gcloudSkillSpec = gcloud.skills[0]
            let skill = V19.Skill()
            skill.name = gcloudSkillSpec.name
            skill.icon = gcloudSkillSpec.icon
            skill.skillDescription = gcloudSkillSpec.description
            skill.allowedTools = gcloudSkillSpec.allowedTools
            skill.customTools = gcloudSkillSpec.customTools
            skill.behaviorInstructions = gcloudSkillSpec.behaviorInstructions
            skill.environmentKeys = ["GCP_PROJECT"] + (gcloudSkillSecret == nil ? [] : ["GCP_API_TOKEN"])
            skill.environmentValues = ["skill-project"] + (gcloudSkillSecret == nil ? [] : [""])
            skill.isGlobal = true
            skill.originPackageID = "gcloud-workflow"
            skill.originPackageVersion = gcloud.version
            skill.originComponentID = CapabilityResourceOrigin.componentID(for: gcloudSkillSpec)
            context.insert(skill)
            shared.skill = skill
            ids["gcloudSkill"] = skill.id
            a.enabledGlobalSkillIDs = [skill.id.uuidString]

            for toolSpec in gcloud.localTools {
                let tool = V19.LocalTool()
                tool.name = toolSpec.name
                tool.toolType = toolSpec.toolType
                tool.command = toolSpec.command
                tool.arguments = toolSpec.arguments
                tool.isGlobal = true
                tool.originPackageID = "gcloud-workflow"
                tool.originComponentID = CapabilityResourceOrigin.componentID(for: toolSpec)
                tool.skill = skill
                context.insert(tool)
            }

            let jiraSkillSpec = jira.skills[0]
            let edited = V19.Skill()
            edited.name = jiraSkillSpec.name
            edited.skillDescription = jiraSkillSpec.description
            edited.allowedTools = jiraSkillSpec.allowedTools
            edited.customTools = jiraSkillSpec.customTools
            edited.behaviorInstructions = "My own Jira rules."
            edited.isGlobal = true
            edited.originPackageID = "jira-workflow"
            edited.originPackageVersion = jira.version
            edited.originComponentID = CapabilityResourceOrigin.componentID(for: jiraSkillSpec)
            context.insert(edited)
            ids["edited"] = edited.id

            let template = V19.TaskTemplate()
            template.name = "Weekly GCP report"
            template.defaultSkillIDs = [skill.id.uuidString]
            template.workspace = a
            context.insert(template)
            let schedule = V19.TaskSchedule()
            schedule.name = "Weekly"
            schedule.skillIDs = [skill.id.uuidString]
            schedule.workspace = a
            context.insert(schedule)
            try context.save()
        }

        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        Self.retained.append(container)
        context = container.mainContext
        jiraAccount1ID = try #require(ids["jira1"])
        jiraAccount2ID = try #require(ids["jira2"])
        jiraAccountBID = try #require(ids["jiraB"])
        sharedGCloudID = try #require(ids["shared"])
        gcloudSkillID = try #require(ids["gcloudSkill"])
        editedJiraSkillID = try #require(ids["edited"])
    }

    func workspace(_ id: UUID) throws -> Workspace {
        try #require(try context.fetch(FetchDescriptor<Workspace>()).first { $0.id == id })
    }
}
