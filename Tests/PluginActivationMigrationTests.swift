import Foundation
import SwiftData
import Testing
import os
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// The V19 -> V20 move onto `PluginActivation` (spec: "Migration V19 -> V20").
/// The fixture is a real V19 store written through the frozen V19 models: two
/// Jira accounts in one workspace, a third workspace's own Jira account, a
/// shared Google Cloud account with a project ID, an unedited shared GCloud
/// skill with a setting, and an edited built-in Jira skill.
@Suite("Plugin activation migration", BuiltInCapabilityFixture())
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
        // accepting the definition it migrated against: its version (not the
        // legacy one, which would await an Update) and digest.
        #expect(Set(a.enabledCapabilityIDs) == ["jira-workflow", "gcloud-workflow"])
        #expect(Set(b.enabledCapabilityIDs) == ["jira-workflow", "gcloud-workflow"])
        #expect(c.installedPluginIDs == ["jira-workflow"])
        #expect(c.enabledCapabilityIDs.isEmpty)
        let aJira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: a))
        #expect(aJira.recordedVersion == fixture.jira.version)
        #expect(fixture.jira.version != "1.0.0")
        #expect(aJira.recordedDigest == PluginDefinitionDigest.content(of: fixture.jira))

        // 2. Connectors stay rows with the same IDs and become accounts,
        // bound by ownership; same-named accounts get distinct aliases.
        let jiraComponent = CapabilityResourceOrigin.componentID(for: fixture.jira.connectors[0])
        let aAccounts = aJira.accounts(forComponent: jiraComponent)
        #expect(Set(aAccounts.map(\.id)) == [fixture.jiraAccount1ID, fixture.jiraAccount2ID])
        #expect(Set(aAccounts.map(\.name)) == ["Jira", "Jira 2"])
        #expect(aJira.bindings.first { $0.isDefault }?.account?.id == fixture.jiraAccount1ID)
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
        let projectedID = PluginRuntimeProjection.derivedID(of: aGCloud, componentID: skillComponent)
        #expect(a.templates.first?.defaultSkillIDs == [projectedID.uuidString])
        #expect(a.schedules.first?.skillIDs == [projectedID.uuidString])
        #expect(!a.enabledGlobalSkillIDs.contains(fixture.gcloudSkillID.uuidString))
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).isEmpty)

        // 4. The edited skill survives as an authored skill; the activations
        // skip the component it replaced and alone turn it on.
        let edited = try #require(try context.fetch(FetchDescriptor<Skill>()).first)
        #expect(edited.originPackageID == nil)
        #expect(edited.behaviorInstructions == "My own Jira rules.")
        let editedComponent = CapabilityResourceOrigin.componentID(for: fixture.jira.skills[0])
        #expect(aJira.overriddenComponentIDs == [editedComponent])
        #expect(cJira.overriddenComponentIDs == [editedComponent])
        #expect(!a.enabledGlobalSkillIDs.contains(fixture.editedJiraSkillID.uuidString))
        #expect(!c.enabledGlobalSkillIDs.contains(fixture.editedJiraSkillID.uuidString))

        // Idempotent: nothing left to move.
        #expect(!PluginActivationMigration.needsMigration(modelContext: context, packages: fixture.packages))
        #expect(try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages) == .init())
    }

    @Test("After migration a task sees its own workspace's accounts and never another's")
    func migratedRuntimeIsIsolatedPerWorkspace() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        // Launch reconciles right after migrating: a plugin recorded at its
        // legacy version runs once it records the library's.
        try PluginUpdateService.reconcileAll(modelContext: context, packages: fixture.packages, mode: .automatic)
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

    @Test("A detached launch resolves the same plugin skills, accounts and settings as the live task")
    func detachedLaunchKeepsProjection() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()

        let live = TaskCapabilityResolver(task: task).resolvedScope(.fullInventory)
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let detachedScope = TaskCapabilityResolver(task: detached).resolvedScope(.fullInventory)
        #expect(detached.modelContext == nil)
        #expect(Set(detachedScope.behaviorSkills.map(\.id)) == Set(live.behaviorSkills.map(\.id)))
        #expect(Set(detachedScope.connectors.map(\.id)) == Set(live.connectors.map(\.id)))
        #expect(Set(detachedScope.localTools.map(\.id)) == Set(live.localTools.map(\.id)))
        let detachedGCloud = try #require(detachedScope.behaviorSkills.first { $0.name == fixture.gcloud.skills[0].name })
        #expect(detachedGCloud.environmentVariables["GCP_PROJECT"] == "skill-project")
        #expect(detached.workspace?.pluginActivations.first { $0.pluginID == "jira-workflow" }?.bindings.count == 2)
        // The launch copy never touched the store.
        #expect(try context.fetch(FetchDescriptor<PluginActivation>()).count == 5)
    }

    @Test("A queued request runs with the plugins it was submitted with, not ones changed while it waited")
    func queuedRequestKeepsSubmittedActivations() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()
        let submitted = TaskCapabilityResolver(task: task).resolvedScope(.fullInventory)

        // While it waits, Google Cloud's setting changes and both plugins
        // are turned off. Google Cloud's account is a shared row the live
        // workspace no longer reaches.
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let skillComponent = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        WorkspaceCapabilityActivation.updateActivation(for: "gcloud-workflow", in: a) {
            WorkspaceCapabilityActivation.setConfigValue(
                "edited-project", forKey: PluginActivation.settingKey(componentID: skillComponent, key: "GCP_PROJECT"), on: $0
            )
        }
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll() }
        try context.save()
        #expect(!gcloud.isEnabled)
        #expect(!TaskCapabilityResolver(task: task).resolvedScope(.fullInventory).connectors.contains { $0.id == fixture.sharedGCloudID })

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let scope = TaskCapabilityResolver(task: detached).resolvedScope(.fullInventory)
        #expect(Set(scope.behaviorSkills.map(\.id)) == Set(submitted.behaviorSkills.map(\.id)))
        #expect(Set(scope.connectors.map(\.id)) == Set(submitted.connectors.map(\.id)))
        #expect(Set(scope.localTools.map(\.id)) == Set(submitted.localTools.map(\.id)))
        let detachedGCloud = try #require(scope.behaviorSkills.first { $0.name == fixture.gcloud.skills[0].name })
        #expect(detachedGCloud.environmentVariables["GCP_PROJECT"] == "skill-project")
        // The request's own record survives an encode/decode round trip.
        let decoded = try JSONDecoder().decode(
            TaskExecutionPolicySnapshotV1.self, from: Data(try #require(request.executionPolicySnapshotJSON).utf8)
        )
        #expect(decoded.pluginActivations?.filter(\.isEnabled).count == 2)
    }

    @Test("The workspace mirror carries activation settings, overrides and accounts")
    func mirrorRoundTripsActivations() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let gcloudActivation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let secretKey = PluginActivation.settingKey(
            componentID: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0]),
            key: "GCP_API_TOKEN"
        )
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: secretKey, on: gcloudActivation)
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WorkspaceConfigManager.WorkspaceConfig.self, from: data)

        // Launch recovery restores the activations exactly.
        let target = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(target)
        let restored = WorkspaceConfigManager.importWorkspaceResult(
            from: decoded,
            modelContext: target.mainContext,
            capabilityTrust: .preserveRecordedState
        ).workspace
        let original = WorkspaceCapabilityActivation.activations(of: a).map(Summary.init)
        #expect(WorkspaceCapabilityActivation.activations(of: restored).map(Summary.init) == original)

        // A file the user picks keeps settings and bindings only for the
        // components the installed plugin declares.
        var forged = decoded
        forged.id = UUID().uuidString
        forged.installedPlugins = forged.installedPlugins?.map { ref in
            var ref = ref
            ref.settings = (ref.settings ?? [:]).merging(["skill:not-declared#TOKEN": "x"]) { first, _ in first }
            return ref
        }
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: ["jira-workflow", "gcloud-workflow"],
            installedPackageIDs: ["jira-workflow", "gcloud-workflow"],
            availablePackIDs: [],
            declaredComponentIDs: [
                "jira-workflow": Set(fixture.jira.connectors.map(CapabilityResourceOrigin.componentID(for:))),
                "gcloud-workflow": Set(fixture.gcloud.skills.map(CapabilityResourceOrigin.componentID(for:)))
            ],
            installedContentDigests: fixture.digests,
            connectorComponents: WorkspaceConfigManager.CapabilityImportVerifier.connectorComponents(of: fixture.packages)
        )
        let validated = WorkspaceConfigManager.importWorkspaceResult(
            from: forged,
            modelContext: target.mainContext,
            capabilityTrust: .validate(verifier)
        ).workspace
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: validated))
        #expect(jira.bindings.count == 2)
        let boundIDs = Set(jira.bindings.compactMap { $0.account?.id })
        let boundOwners = Set(jira.bindings.compactMap { $0.account?.workspace?.id })
        #expect(boundIDs.isDisjoint(with: [fixture.jiraAccount1ID, fixture.jiraAccount2ID]))
        #expect(boundOwners == [validated.id])
        #expect(jira.overriddenComponentIDs.isEmpty)
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: validated))
        #expect(gcloud.configKeys.count == 1)
        #expect(gcloud.bindings.isEmpty)
        // History survives only for declared components.
        #expect(Set(gcloud.knownComponentIDs).isSubset(of: Set(fixture.gcloud.skills.map(CapabilityResourceOrigin.componentID(for:)))))
        #expect(!gcloud.knownComponentIDs.isEmpty)
        // A chosen file gets fresh namespaces, so no secret is carried.
        #expect(gcloud.secretSettingKeys.isEmpty)
    }

    private struct Summary: Equatable {
        let id: UUID
        let pluginID: String
        let isEnabled: Bool
        let version: String
        let settings: [String: String]
        let overrides: [String]
        let known: [String]
        let secrets: [String]
        let accounts: Set<String>

        init(_ activation: PluginActivation) {
            id = activation.id
            pluginID = activation.pluginID
            isEnabled = activation.isEnabled
            version = activation.recordedVersion
            settings = activation.configuration
            overrides = activation.overriddenComponentIDs
            known = activation.knownComponentIDs
            secrets = activation.secretSettingKeys
            accounts = Set(activation.bindings.compactMap { binding in
                binding.account.map { "\(binding.componentID)|\($0.id)|\(binding.isDefault)" }
            })
        }
    }

    private static var retained: [ModelContainer] = []

    @Test("Deleting a workspace records its activations' secret namespaces for cleanup")
    func workspaceDeletionCleansActivationSecrets() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let record = WorkspaceDeletionCleanupRecord(a)
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let projectedID = PluginRuntimeProjection.derivedID(
            of: gcloud,
            componentID: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        )
        #expect(record.skills.contains { $0.skillID == projectedID })
    }

    @Test("A shared row a workspace turned on without its plugin survives there")
    func componentOnlyMembershipSurvives() throws {
        let fixture = try Fixture(componentOnlyWorkspace: true)
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let d = try fixture.workspace(fixture.dID)
        let a = try fixture.workspace(fixture.aID)

        // D listed the GCloud skill and the shared Google Cloud row directly.
        #expect(d.pluginActivations.isEmpty)
        let skill = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(skill.originPackageID == nil)
        #expect(d.enabledGlobalSkillIDs == [fixture.gcloudSkillID.uuidString])
        #expect(d.enabledGlobalConnectorIDs == [fixture.sharedGCloudID.uuidString])
        // A, which has the plugin, uses the projection instead of the row.
        #expect(!a.enabledGlobalSkillIDs.contains(fixture.gcloudSkillID.uuidString))
        let taskD = AgentTask(title: "D", goal: "Google Cloud", workspace: d)
        context.insert(taskD)
        #expect(TaskCapabilityResolver(task: taskD).allConnectors.map(\.id) == [fixture.sharedGCloudID])
        // The skill D keeps still has its tools and its account.
        #expect(skill.localTools.count == fixture.gcloud.localTools.count)
        #expect(skill.connectors.map(\.id) == [fixture.sharedGCloudID])
    }

    @Test("Secret cleanup is recorded before the save and taken back when it fails")
    func secretCleanupOutboxRecordsBeforeSave() throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-plugin-secret-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = PluginSecretCleanupOutbox(fileURL: directory.appendingPathComponent("PluginSecretCleanup.json"))
        let orphan = UUID()

        var recordedDuringSave: [UUID] = []
        let failed = PluginSecretCleanupOutbox.deleteThenClean([orphan], modelContext: fixture.context, outbox: outbox) {
            recordedDuringSave = (try? outbox.pending()) ?? []
            return false
        }
        #expect(!failed)
        #expect(recordedDuringSave == [orphan])
        #expect(try outbox.pending().isEmpty)

        // A namespace something live still names is dropped, never cleaned.
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let live = PluginRuntimeProjection.derivedID(
            of: gcloud,
            componentID: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        )
        #expect(PluginSecretCleanupOutbox.liveSkillIDs(modelContext: fixture.context)?.contains(live) == true)
        try outbox.write([live])
        PluginSecretCleanupOutbox.resumePending(modelContext: fixture.context, outbox: outbox)
        #expect(try outbox.pending().isEmpty)
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
        #expect(!PluginActivationMigration.needsMigration(modelContext: context, packages: packages))
    }

    @Test("An account whose plugin is missing from the library stays the person's, in scope")
    func missingLibraryEntryKeepsAccountsAuthored() throws {
        let fixture = try Fixture()
        let context = fixture.context
        let packages = fixture.packages.filter { $0.id != "gcloud-workflow" }
        try PluginActivationMigration.migrate(modelContext: context, packages: packages)
        let a = try fixture.workspace(fixture.aID)
        // Nothing could project a bound account without the definition.
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(gcloud.bindings.isEmpty)
        let connectors = try context.fetch(FetchDescriptor<Connector>())
        let shared = try #require(connectors.first { $0.id == fixture.sharedGCloudID })
        #expect(shared.originPackageID == nil)
        // Still on where it was turned on, as the person's own account.
        #expect(WorkspaceCapabilityActivation.state(of: a).globalConnectorIDs.contains(fixture.sharedGCloudID.uuidString))
        #expect(!WorkspaceCapabilities(workspace: a).boundAccountIDs.contains(fixture.sharedGCloudID))
    }

    @Test("Rows kept while their plugin was missing become its overrides once it is back, never a second copy")
    func missingPluginRowsBecomeOverridesWhenItIsBack() throws {
        for path in ["launch", "add", "remove then add"] {
            let fixture = try Fixture()
            let context = fixture.context
            let missing = fixture.packages.filter { $0.id != "gcloud-workflow" }
            try PluginActivationMigration.migrate(modelContext: context, packages: missing)
            let a = try fixture.workspace(fixture.aID)
            let keptToolIDs = Set(try context.fetch(FetchDescriptor<LocalTool>()).map(\.id))
            #expect(keptToolIDs.count == fixture.gcloud.localTools.count)
            func capabilities(_ packages: [PluginPackage]) throws -> WorkspaceCapabilities {
                WorkspaceCapabilities(
                    workspace: a,
                    globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })),
                    globalTools: try context.fetch(FetchDescriptor<LocalTool>()),
                    packageDefinitions: packages
                )
            }
            // Without the definition the kept rows are the person's, in scope.
            let before = try capabilities(missing)
            #expect(before.activeSkills.contains { $0.id == fixture.gcloudSkillID })
            #expect(keptToolIDs.isSubset(of: Set(before.activeTools.map(\.id))))
            #expect(try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a)).overriddenComponentIDs.isEmpty)
            if path == "remove then add" {
                // Removed while missing: the rows stay the person's, in scope.
                let removed = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
                WorkspaceCapabilityActivation.retire(removed, in: a)
                WorkspaceCapabilityActivation.mutate(a) { $0.pluginIDs.removeAll { $0 == "gcloud-workflow" } }
                #expect(try capabilities(missing).activeSkills.contains { $0.id == fixture.gcloudSkillID })
            }

            // The definition is back: found at launch, or added again.
            if path == "launch" {
                #expect(PluginActivationMigration.needsMigration(modelContext: context, packages: fixture.packages))
                try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
                #expect(!PluginActivationMigration.needsMigration(modelContext: context, packages: fixture.packages))
            } else {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("astra-missing-plugin-readd-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                try CapabilityInstaller(library: CapabilityLibrary(directory: root)).enable(
                    fixture.gcloud, in: a, modelContext: context, persist: { _, context in (try? context.save()) != nil }
                )
            }
            // Each kept row replaces its component: one copy of the skill and
            // of each tool, the person's.
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
            let after = try capabilities(fixture.packages)
            let skillSpec = fixture.gcloud.skills[0]
            #expect(after.activeSkills.filter { $0.name == skillSpec.name }.map(\.id) == [fixture.gcloudSkillID])
            #expect(activation.overridingRowID(forComponent: CapabilityResourceOrigin.componentID(for: skillSpec)) == fixture.gcloudSkillID)
            for spec in fixture.gcloud.localTools {
                let component = CapabilityResourceOrigin.componentID(for: spec)
                #expect(activation.overridingRowID(forComponent: component).map(keptToolIDs.contains) == true)
                #expect(!after.activeTools.contains { $0.originComponentID == component })
            }
            #expect(keptToolIDs.isSubset(of: Set(after.activeTools.map(\.id))))
            #expect(after.activeTools.count == Set(after.activeTools.map(\.id)).count)
            // B's activation used the same shared rows: they replace its
            // components too, in the same pass.
            let b = try fixture.workspace(fixture.bID)
            let bActivation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: b))
            #expect(bActivation.overridingRowID(forComponent: CapabilityResourceOrigin.componentID(for: skillSpec)) == fixture.gcloudSkillID)
            #expect(WorkspaceCapabilityActivation.pendingOverridePluginIDs(of: a).isEmpty)
            #expect(WorkspaceCapabilityActivation.pendingOverridePluginIDs(of: b).isEmpty)
            // Now they follow the plugin: off with it, still the person's rows.
            WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll { $0 == "gcloud-workflow" } }
            #expect(!(try capabilities(fixture.packages)).activeSkills.contains { $0.id == fixture.gcloudSkillID })
            #expect(try context.fetch(FetchDescriptor<Skill>()).contains { $0.id == fixture.gcloudSkillID })
        }
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
                try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packagesDeclaringSecret)

                let a = try fixture.workspace(fixture.aID)
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
                let projectedID = PluginRuntimeProjection.derivedID(
                    of: activation,
                    componentID: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
                )
                #expect(persistence.loadSecretValue(key: "GCP_API_TOKEN", skillID: projectedID, store: KeychainSecretStore()) == "s3cret")
                #expect(!activation.configKeys.contains { $0.hasSuffix("#GCP_API_TOKEN") })
                // A projected skill's snapshot never carries the secret value.
                let task = AgentTask(title: "A", goal: "Google Cloud", workspace: a)
                fixture.context.insert(task)
                let declared = try #require(fixture.packagesDeclaringSecret.first { $0.id == "gcloud-workflow" })
                let projected = try #require(PluginRuntimeProjection.project(workspace: a, packages: [declared]).skills.first { $0.id == projectedID })
                #expect(!SkillSnapshotConfig(skill: projected).environmentValues.contains("s3cret"))
                #expect(projected.environmentVariables["GCP_API_TOKEN"] == "s3cret")
                // The deleted row's own namespace is cleaned after the save.
                #expect(!persistence.secretExists(key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID))
            }
        }
    }

    @Test("Each activation starts from its definition's components")
    func knownComponentsAreSeeded() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(gcloud.knownComponentIDs == PluginRuntimeProjection.componentIDs(of: fixture.gcloud))
        #expect(!gcloud.knownComponentIDs.isEmpty)

        // An activation a history-less mirror restored is seeded later.
        WorkspaceCapabilityActivation.setKnownComponents([], on: gcloud)
        try fixture.context.save()
        #expect(PluginActivationMigration.needsMigration(modelContext: fixture.context, packages: fixture.packages))
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        #expect(gcloud.knownComponentIDs == PluginRuntimeProjection.componentIDs(of: fixture.gcloud))
        #expect(!PluginActivationMigration.needsMigration(modelContext: fixture.context, packages: fixture.packages))
    }

    @Test("A setting the person emptied stays empty instead of reverting to the default")
    func explicitEmptySettingIsKept() throws {
        let fixture = try Fixture(gcloudSkillProject: "")
        var gcloud = fixture.gcloud
        gcloud.skills[0].environmentValues = ["default-project"]
        let packages = fixture.packages.map { $0.id == gcloud.id ? gcloud : $0 }
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: packages)

        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let componentID = CapabilityResourceOrigin.componentID(for: gcloud.skills[0])
        #expect(activation.configuration[PluginActivation.settingKey(componentID: componentID, key: "GCP_PROJECT")] == "")
        let projected = PluginRuntimeProjection.project(workspace: a, packages: [gcloud])
        let skill = try #require(projected.skills.first { $0.originComponentID == componentID })
        #expect(skill.environmentValues == [""])
    }

    @Test("A V19 row stamped with the identity a stable ID replaced moves its settings to the renamed component")
    func stampedPredecessorRowMigrates() throws {
        let fixture = try Fixture(gcloudSkillProject: "my-project")
        var gcloud = fixture.gcloud
        let legacy = CapabilityResourceOrigin.componentID(for: gcloud.skills[0])
        gcloud.skills[0].id = "gcp-operator"
        gcloud.skills[0].replaces = [legacy]
        let packages = fixture.packages.map { $0.id == gcloud.id ? gcloud : $0 }
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: packages)

        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: gcloud.id, in: a))
        let renamed = CapabilityResourceOrigin.componentID(for: gcloud.skills[0])
        #expect(activation.configuration[PluginActivation.settingKey(componentID: renamed, key: "GCP_PROJECT")] == "my-project")
        // The row became the projection, not an authored row beside it.
        #expect(try fixture.context.fetch(FetchDescriptor<Skill>()).allSatisfy { $0.id != fixture.gcloudSkillID })
        #expect(activation.overriddenComponentIDs.isEmpty)
    }

    @Test("Unstamped legacy accounts retain every connector declaration they matched")
    func unstampedAccountPreservesAllMatches() throws {
        let fixture = try Fixture()
        var jira = fixture.jira
        jira.connectors[0].id = "first-jira"
        var second = jira.connectors[0]
        second.id = "second-jira"
        second.name = "Other Jira component"
        jira.connectors.append(second)
        for account in try fixture.context.fetch(FetchDescriptor<Connector>()) where account.originPackageID == jira.id {
            account.originComponentID = nil
        }
        try fixture.context.save()
        try PluginActivationMigration.migrate(modelContext: fixture.context,
            packages: fixture.packages.map { $0.id == jira.id ? jira : $0 })
        let workspace = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        for component in jira.connectors {
            #expect(Set(activation.accounts(forComponent: CapabilityResourceOrigin.componentID(for: component)).map(\.id))
                == [fixture.jiraAccount1ID, fixture.jiraAccount2ID])
        }
    }

    @Test("A V19 account stamped with the identity a stable ID replaced is bound to the renamed component")
    func stampedPredecessorAccountMigrates() throws {
        let fixture = try Fixture()
        var jira = fixture.jira
        let legacy = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        jira.connectors[0].id = "jira-site"
        jira.connectors[0].replaces = [legacy]
        let packages = fixture.packages.map { $0.id == jira.id ? jira : $0 }
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: packages)

        // Bound by the migration itself: the activation is seeded from the
        // current definition, so no later reconcile need move it.
        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: a))
        let renamed = CapabilityResourceOrigin.componentID(for: jira.connectors[0])
        #expect(Set(activation.accounts(forComponent: renamed).map(\.id)) == [fixture.jiraAccount1ID, fixture.jiraAccount2ID])
        #expect(activation.accounts(forComponent: legacy).isEmpty)
        try PluginUpdateService.reconcileAll(modelContext: fixture.context, packages: packages, mode: .automatic)
        let projected = PluginRuntimeProjection.project(workspace: a, packages: [jira]).connectors.map(\.id)
        #expect(Set(projected) == [fixture.jiraAccount1ID, fixture.jiraAccount2ID])
    }

    @Test("A plugin tool whose description was edited stays an authored row")
    func editedToolDescriptionIsKept() throws {
        let fixture = try Fixture(editedToolDescription: "My own words")
        let report = try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        #expect(report.toolsProjected == 0)
        #expect(report.toolsKeptAsAuthored == fixture.gcloud.localTools.count)
        let tools = try fixture.context.fetch(FetchDescriptor<LocalTool>())
        #expect(tools.filter { $0.toolDescription == "My own words" }.count == fixture.gcloud.localTools.count)
        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(Set(activation.overriddenComponentIDs).isSuperset(of: fixture.gcloud.localTools.map {
            CapabilityResourceOrigin.componentID(for: $0)
        }))
    }

    @Test("An edited plugin tool stays in scope with its plugin's skill")
    func editedToolStaysWithItsPluginSkill() throws {
        let fixture = try Fixture(editedToolDescription: "My own words")
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        fixture.context.insert(task)
        let edited = try fixture.context.fetch(FetchDescriptor<LocalTool>())
        #expect(edited.count == fixture.gcloud.localTools.count)

        // The request matches the plugin's skill but none of the edited
        // tools' own words: they come along with the skill, as projected
        // tools would.
        let scope = TaskCapabilityResolver(task: task).activationScope(contextText: "Manage GCP resources")
        #expect(scope.behaviorSkills.contains { $0.name == fixture.gcloud.skills[0].name })
        #expect(Set(edited.map(\.id)).isSubset(of: Set(scope.localTools.map(\.id))))
        // Only the runtime's copies are wired; the stored rows stay unowned.
        #expect(edited.allSatisfy { $0.skill == nil })
    }

    @Test("An edited shared plugin skill is on exactly while its plugin is")
    func editedSharedSkillFollowsItsActivation() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        // Launch reconciles right after migrating: a plugin recorded at its
        // legacy version runs once it records the library's.
        try PluginUpdateService.reconcileAll(modelContext: fixture.context, packages: fixture.packages, mode: .automatic)
        let a = try fixture.workspace(fixture.aID)
        let shared = try fixture.context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
        func activeSkillIDs() -> Set<UUID> {
            Set(WorkspaceCapabilities(workspace: a, globalSkills: shared, packageDefinitions: fixture.packages).activeSkills.map(\.id))
        }
        #expect(activeSkillIDs().contains(fixture.editedJiraSkillID))

        // Turning Jira off takes its edited skill with it: no shared-list
        // membership keeps it on for new tasks.
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll { $0 == "jira-workflow" } }
        #expect(!activeSkillIDs().contains(fixture.editedJiraSkillID))
        // The mirror still carries the row the override names.
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        #expect(config.skills.contains { $0.id == fixture.editedJiraSkillID.uuidString })
    }

    @Test("A workspace's own edited plugin skill and tool are on exactly while their plugin is")
    func editedWorkspaceRowsFollowTheirActivation() throws {
        let fixture = try Fixture(editedToolDescription: "My own words", workspaceScopedRows: true)
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        // Launch reconciles right after migrating: a plugin recorded at its
        // legacy version runs once it records the library's.
        try PluginUpdateService.reconcileAll(modelContext: fixture.context, packages: fixture.packages, mode: .automatic)
        let a = try fixture.workspace(fixture.aID)
        let tools = try fixture.context.fetch(FetchDescriptor<LocalTool>())
        let toolIDs = Set(tools.map(\.id))
        #expect(toolIDs.count == fixture.gcloud.localTools.count)
        #expect(tools.allSatisfy { $0.workspace?.id == a.id && !$0.isGlobal })
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        fixture.context.insert(task)
        func active() -> (skills: Set<UUID>, tools: Set<UUID>, runTools: Set<UUID>) {
            let capabilities = WorkspaceCapabilities(workspace: a, packageDefinitions: fixture.packages)
            return (Set(capabilities.activeSkills.map(\.id)), Set(capabilities.activeTools.map(\.id)),
                    Set(TaskCapabilityResolver(task: task).allLocalTools.map(\.id)))
        }
        let on = active()
        #expect(on.skills.contains(fixture.editedJiraSkillID))
        #expect(toolIDs.isSubset(of: on.tools))
        #expect(toolIDs.isSubset(of: on.runTools))

        // Turning the plugins off takes the workspace's own overrides with
        // them; they stay its rows, listed and mirrored.
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll { ["jira-workflow", "gcloud-workflow"].contains($0) } }
        let off = active()
        #expect(!off.skills.contains(fixture.editedJiraSkillID))
        #expect(off.tools.isDisjoint(with: toolIDs))
        #expect(off.runTools.isDisjoint(with: toolIDs))
        let capabilities = WorkspaceCapabilities(workspace: a, packageDefinitions: fixture.packages)
        #expect(capabilities.workspaceSkills.contains { $0.id == fixture.editedJiraSkillID })
        #expect(toolIDs.isSubset(of: Set(capabilities.workspaceTools.map(\.id))))
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        #expect(config.skills.contains { $0.id == fixture.editedJiraSkillID.uuidString })
    }

    @Test("A plugin skill stamped with another version is kept when edited and projected when it matches")
    func versionMismatchedSkillIsComparedToTheDefinition() throws {
        let edited = try Fixture(gcloudBehaviorSuffix: "\nAlso cite the console link.", gcloudSkillVersion: "0.0.1")
        #expect(try PluginActivationMigration.migrate(modelContext: edited.context, packages: edited.packages).skillsProjected == 0)
        let kept = try #require(try edited.context.fetch(FetchDescriptor<Skill>()).first { $0.id == edited.gcloudSkillID })
        #expect(kept.behaviorInstructions.hasSuffix("Also cite the console link."))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: try edited.workspace(edited.aID)))
        let component = CapabilityResourceOrigin.componentID(for: edited.gcloud.skills[0])
        #expect(activation.overridingRowID(forComponent: component) == edited.gcloudSkillID)

        let unedited = try Fixture(gcloudSkillVersion: "0.0.1")
        #expect(try PluginActivationMigration.migrate(modelContext: unedited.context, packages: unedited.packages).skillsProjected == 1)
        #expect(try unedited.context.fetch(FetchDescriptor<Skill>()).allSatisfy { $0.id != unedited.gcloudSkillID })
    }

    @Test("A chosen file binds an account only to a component of its service, and never a reused shared row")
    func validatedImportChecksAccountsAgainstTheirComponent() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        var forged = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        forged.id = UUID().uuidString
        // One of A's Jira accounts is relabeled as another service; the
        // shared GCloud account is in this store, so the import reuses it.
        forged.connectors = forged.connectors?.map { connector in
            var connector = connector
            if connector.id == fixture.jiraAccount2ID.uuidString { connector.serviceType = "github" }
            return connector
        }
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: ["jira-workflow", "gcloud-workflow"],
            installedPackageIDs: ["jira-workflow", "gcloud-workflow"],
            availablePackIDs: [],
            declaredComponentIDs: Dictionary(uniqueKeysWithValues: [fixture.jira, fixture.gcloud].map {
                ($0.id, Set(PluginRuntimeProjection.componentIDs(of: $0)))
            }),
            installedContentDigests: fixture.digests,
            connectorComponents: WorkspaceConfigManager.CapabilityImportVerifier.connectorComponents(of: fixture.packages)
        )
        let imported = WorkspaceConfigManager.importWorkspaceResult(
            from: forged, modelContext: fixture.context, capabilityTrust: .validate(verifier)
        ).workspace
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: imported))
        #expect(jira.bindings.count == 1)
        #expect(jira.bindings.allSatisfy { $0.account?.serviceType == fixture.jira.connectors[0].serviceType })
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: imported))
        #expect(gcloud.bindings.isEmpty)
    }

    @Test("A plugin skill whose icon the person changed stays an authored row")
    func editedSkillIconIsKept() throws {
        let fixture = try Fixture(editedSkillIcon: "star")
        let report = try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        #expect(report.skillsProjected == 0)
        let skill = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(skill.icon == "star")
        #expect(skill.originPackageID == nil)
    }

    @Test("A validated import gets its own secret namespaces; the workspace's own mirror keeps them")
    func validatedImportGetsFreshNamespaces() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let original = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let target = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(target)

        let recovered = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: target.mainContext, capabilityTrust: .preserveRecordedState
        ).workspace
        let recoveredActivation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: recovered))
        #expect(PluginRuntimeProjection.derivedID(of: recoveredActivation, componentID: component)
            == PluginRuntimeProjection.derivedID(of: original, componentID: component))

        let other = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(other)
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: ["gcloud-workflow"],
            installedPackageIDs: ["gcloud-workflow"],
            availablePackIDs: [],
            declaredComponentIDs: ["gcloud-workflow": Set(PluginRuntimeProjection.componentIDs(of: fixture.gcloud))],
            installedContentDigests: fixture.digests
        )
        let validated = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: other.mainContext, capabilityTrust: .validate(verifier)
        ).workspace
        #expect(validated.id == a.id)
        let validatedActivation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: validated))
        #expect(!validatedActivation.namespaceSeed.isEmpty)
        #expect(validatedActivation.secretSettingKeys.isEmpty)
        #expect(PluginRuntimeProjection.derivedID(of: validatedActivation, componentID: component)
            != PluginRuntimeProjection.derivedID(of: original, componentID: component))
    }

    @Test("A chosen file's activation for another copy of the plugin stays off and brings nothing")
    func importedActivationNeedsTheInstalledDigest() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let digest = try #require(config.installedPlugins?.first { $0.id == "gcloud-workflow" }?.digest)
        #expect(digest == fixture.digests["gcloud-workflow"])

        for installedDigest in ["another-copy", digest] {
            let target = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            Self.retained.append(target)
            var digests = fixture.digests
            digests["gcloud-workflow"] = installedDigest
            let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
                approvedPackageIDs: ["gcloud-workflow"],
                installedPackageIDs: ["gcloud-workflow"],
                availablePackIDs: [],
                declaredComponentIDs: ["gcloud-workflow": Set(PluginRuntimeProjection.componentIDs(of: fixture.gcloud))],
                installedContentDigests: digests
            )
            let result = WorkspaceConfigManager.importWorkspaceResult(
                from: config, modelContext: target.mainContext, capabilityTrust: .validate(verifier)
            )
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: result.workspace))
            if installedDigest == digest {
                #expect(activation.isEnabled)
                #expect(activation.recordedDigest == digest)
                #expect(!activation.configuration.isEmpty)
                #expect(result.capabilityTrust.pluginsChanged.isEmpty)
            } else {
                #expect(!activation.isEnabled)
                #expect(activation.recordedDigest.isEmpty)
                #expect(activation.configuration.isEmpty && activation.bindings.isEmpty)
                #expect(result.capabilityTrust.pluginsChanged == ["gcloud-workflow"])
            }
        }
    }

    @Test("The mirror carries a shared row an override names even when nothing else enables it")
    func mirrorCarriesOverrideRows() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let c = try fixture.workspace(fixture.cID)
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: c))
        #expect(jira.overridingRowIDs.contains(fixture.editedJiraSkillID.uuidString))
        #expect(!c.enabledGlobalSkillIDs.contains(fixture.editedJiraSkillID.uuidString))
        let config = try #require(WorkspaceConfigManager.export(workspace: c, modelContext: fixture.context))
        #expect(config.skills.contains { $0.id == fixture.editedJiraSkillID.uuidString })
    }

    @Test("The mirror carries the shared rows a removed activation named as overrides")
    func mirrorCarriesRetiredOverrideRows() throws {
        let fixture = try Fixture(editedToolDescription: "My own words")
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let b = try fixture.workspace(fixture.bID)
        let toolIDs = Set(try fixture.context.fetch(FetchDescriptor<LocalTool>()).map(\.id.uuidString))
        #expect(!toolIDs.isEmpty)
        // Remove both plugins from B: only the retired entries name the rows.
        for pluginID in ["jira-workflow", "gcloud-workflow"] {
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: pluginID, in: b))
            WorkspaceCapabilityActivation.retire(activation, in: b)
            WorkspaceCapabilityActivation.mutate(b) {
                $0.capabilityIDs.removeAll { $0 == pluginID }
                $0.pluginIDs.removeAll { $0 == pluginID }
            }
        }
        #expect(WorkspaceCapabilityActivation.activations(of: b).isEmpty)
        #expect(WorkspaceCapabilityActivation.retiredOverrideRowIDs(of: b).contains(fixture.editedJiraSkillID))
        #expect(b.enabledGlobalSkillIDs.isEmpty && b.enabledGlobalToolIDs.isEmpty)
        let config = try #require(WorkspaceConfigManager.export(workspace: b, modelContext: fixture.context))
        #expect(config.skills.contains { $0.id == fixture.editedJiraSkillID.uuidString })
        #expect(toolIDs.isSubset(of: Set((config.localTools ?? []).compactMap(\.id))))
    }

    @Test("Only the exact note the disallowed-tools migration appended counts as unedited")
    func behaviorMatchIsExact() throws {
        let note = "\nDo NOT use these tools: Write, Edit."
        // Folded: the list moved into the text.
        let generated = try Fixture(gcloudBehaviorSuffix: note, gcloudDisallowedTools: [])
        #expect(try PluginActivationMigration.migrate(modelContext: generated.context, packages: generated.packages).skillsProjected == 1)
        let extended = try Fixture(gcloudBehaviorSuffix: note + "\nAlso cite the console link.", gcloudDisallowedTools: [])
        let report = try PluginActivationMigration.migrate(modelContext: extended.context, packages: extended.packages)
        #expect(report.skillsProjected == 0)
        let kept = try #require(try extended.context.fetch(FetchDescriptor<Skill>()).first { $0.id == extended.gcloudSkillID })
        #expect(kept.behaviorInstructions.hasSuffix("Also cite the console link."))
    }

    @Test("A validated import points templates and schedules at the re-minted projected IDs")
    func validatedImportRemapsProjectedReferences() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        let oldID = PluginRuntimeProjection.derivedID(workspaceID: a.id, pluginID: "gcloud-workflow", componentID: component)
        #expect(config.schedules?.first?.skillIDs == [oldID.uuidString])

        let target = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(target)
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: ["gcloud-workflow"],
            installedPackageIDs: ["gcloud-workflow"],
            availablePackIDs: [],
            declaredComponentIDs: ["gcloud-workflow": Set(PluginRuntimeProjection.componentIDs(of: fixture.gcloud))],
            installedContentDigests: fixture.digests
        )
        let imported = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: target.mainContext, capabilityTrust: .validate(verifier)
        ).workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: imported))
        let newID = PluginRuntimeProjection.derivedID(of: activation, componentID: component)
        #expect(newID != oldID)
        #expect(imported.schedules.first?.skillIDs == [newID.uuidString])
        #expect(imported.templates.first { $0.name == "Weekly GCP report" }?.defaultSkillIDs == [newID.uuidString])
    }

    @Test("A duplicated import remaps projected references from the file's workspace, not its new ID")
    func duplicatedImportRemapsFromTheFileWorkspace() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        var config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        // What Duplicate does (`TaskLifecycleCoordinator.importFromConfig`).
        config.id = nil
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: ["gcloud-workflow"],
            installedPackageIDs: ["gcloud-workflow"],
            availablePackIDs: [],
            declaredComponentIDs: ["gcloud-workflow": Set(PluginRuntimeProjection.componentIDs(of: fixture.gcloud))],
            installedContentDigests: fixture.digests
        )

        let duplicate = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: fixture.context, capabilityTrust: .validate(verifier), sourceWorkspaceID: a.id
        ).workspace
        #expect(duplicate.id != a.id)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: duplicate))
        let newID = PluginRuntimeProjection.derivedID(of: activation, componentID: component)
        #expect(duplicate.schedules.first?.skillIDs == [newID.uuidString])
        #expect(duplicate.templates.first { $0.name == "Weekly GCP report" }?.defaultSkillIDs == [newID.uuidString])
    }

    @Test("A chosen file's rejected activation still gets its own namespaces")
    func rejectedImportedActivationIsReseeded() throws {
        let fixture = try Fixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let original = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let target = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(target)
        var digests = fixture.digests
        digests["gcloud-workflow"] = "another-copy"
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: ["gcloud-workflow"],
            installedPackageIDs: ["gcloud-workflow"],
            availablePackIDs: [],
            declaredComponentIDs: ["gcloud-workflow": Set(PluginRuntimeProjection.componentIDs(of: fixture.gcloud))],
            installedContentDigests: digests
        )

        let imported = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: target.mainContext, capabilityTrust: .validate(verifier)
        ).workspace
        // Replace keeps the workspace's ID: without a seed, a later Add would
        // derive the replaced workspace's namespaces and read its secrets.
        #expect(imported.id == a.id)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: imported))
        #expect(!activation.isEnabled)
        #expect(activation.configuration.isEmpty && activation.bindings.isEmpty)
        #expect(!activation.namespaceSeed.isEmpty)
        #expect(activation.namespaceSeed != original.namespaceSeed)
        #expect(PluginRuntimeProjection.derivedID(of: activation, componentID: component)
            != PluginRuntimeProjection.derivedID(of: original, componentID: component))
    }

    @Test("A workspace that replaced the shared account with its own binds only its own")
    func replacedSharedAccountIsNotBound() throws {
        let fixture = try Fixture(aOwnsGCloudAccount: true)
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let b = try fixture.workspace(fixture.bID)
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.connectors[0])
        let aAccounts = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a)).accounts(forComponent: component)
        #expect(aAccounts.count == 1)
        #expect(aAccounts.first?.id != fixture.sharedGCloudID)
        // B never replaced it and keeps the shared account.
        let bAccounts = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: b)).accounts(forComponent: component)
        #expect(bAccounts.map(\.id) == [fixture.sharedGCloudID])
    }

    @Test("A plugin skill whose environment keys the person changed stays an authored row")
    func editedEnvironmentKeysAreKept() throws {
        let fixture = try Fixture(gcloudSkillSecret: "x")
        let report = try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        #expect(report.skillsProjected == 0)
        let kept = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(kept.environmentKeys.contains("GCP_API_TOKEN"))
    }

    @Test("A failed migration takes back the secrets it copied")
    func failedMigrationRestoresCopiedSecrets() throws {
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
                // The cleanup record can't be written: the migration aborts
                // after copying the secret.
                try FileManager.default.createDirectory(
                    at: fixture.storeDirectory.appendingPathComponent("PluginSecretCleanup.json", isDirectory: true),
                    withIntermediateDirectories: true
                )
                #expect(throws: PluginActivationMigration.MigrationError.cleanupUnrecordable) {
                    try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packagesDeclaringSecret)
                }
                let a = try fixture.workspace(fixture.aID)
                // Nothing in memory claims the migration happened.
                #expect(a.legacyEnabledCapabilityIDs == ["jira-workflow", "gcloud-workflow"])
                #expect(WorkspaceCapabilityActivation.activations(of: a).isEmpty)
                #expect(a.enabledGlobalSkillIDs == [fixture.gcloudSkillID.uuidString])
                let projectedID = PluginRuntimeProjection.derivedID(
                    workspaceID: a.id,
                    pluginID: "gcloud-workflow",
                    componentID: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
                )
                #expect(!persistence.secretExists(key: "GCP_API_TOKEN", skillID: projectedID))
                #expect(persistence.secretExists(key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID))
            }
        }
    }

    @Test("An unwritable cleanup journal prevents every skill credential copy")
    func unwritableJournalStopsSecretCopy() throws {
        try AstraSecureKeychainTestSupport.withPrivateVault {
            let fixture = try Fixture(gcloudSkillSecret: "s3cret")
            #expect(SkillSecretSeam.required.saveSecretValue("s3cret", key: "GCP_API_TOKEN",
                skillID: fixture.gcloudSkillID, skillName: "GCloud", allowUserInteraction: false))
            try FileManager.default.createDirectory(
                at: fixture.storeDirectory.appendingPathComponent("PluginSecretCleanup.json", isDirectory: true),
                withIntermediateDirectories: true)
            UndeletableSkillSecrets.reset()
            #expect(throws: PluginActivationMigration.MigrationError.cleanupUnrecordable) {
                try PluginActivationMigration.migrate(modelContext: fixture.context,
                    packages: fixture.packagesDeclaringSecret, secrets: UndeletableSkillSecrets.self)
            }
            #expect(UndeletableSkillSecrets.savedNamespaces.isEmpty)
            #expect(SkillSecretSeam.required.loadSecretValue(key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID,
                store: KeychainSecretStore()) == "s3cret")
            #expect(WorkspaceCapabilityActivation.activations(of: try fixture.workspace(fixture.aID)).isEmpty)
        }
    }

    @Test("A failed migration keeps the legacy enablement on, with the plugins' MCP servers and browser adapters")
    func failedMigrationKeepsLegacyEnablement() throws {
        let fixture = try Fixture()
        var gcloud = fixture.gcloud
        gcloud.mcpServers = [PluginMCPServer(id: "legacy-files", displayName: "Legacy files", transport: .stdio, command: "/bin/cat")]
        gcloud.browserAdapters = [BrowserSiteAdapterID.googleDrive]
        let packages = fixture.packages.map { $0.id == gcloud.id ? gcloud : $0 }
        // The cleanup record can't be written: the migration rolls back.
        try FileManager.default.createDirectory(
            at: fixture.storeDirectory.appendingPathComponent("PluginSecretCleanup.json", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(throws: PluginActivationMigration.MigrationError.cleanupUnrecordable) {
            try PluginActivationMigration.migrate(modelContext: fixture.context, packages: packages)
        }
        let a = try fixture.workspace(fixture.aID)
        #expect(WorkspaceCapabilityActivation.activations(of: a).isEmpty)
        #expect(Set(a.enabledCapabilityIDs) == ["jira-workflow", "gcloud-workflow"])
        let adapter = try #require(BrowserSiteAdapterID.normalized(BrowserSiteAdapterID.googleDrive))
        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        fixture.context.insert(task)
        // A queued launch's copy sees them too.
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: task), from: task)
        for workspace in [a, try #require(detached.workspace)] {
            #expect(TaskCapabilityResolver.enabledMCPServerManifests(for: workspace, packages: packages).map(\.id) == ["legacy-files"])
            #expect(TaskCapabilityResolver.enabledBrowserAdapters(for: workspace, packages: packages) == [adapter])
        }
    }

    @Test("A plugin skill whose denied tools the person changed stays an authored row")
    func editedDisallowedToolsAreKept() throws {
        // Installed with Write and Edit denied; the person allowed Edit.
        let fixture = try Fixture(gcloudDisallowedTools: ["Write"])
        let report = try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        #expect(report.skillsProjected == 0)
        let kept = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(kept.disallowedTools == ["Write"])
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: try fixture.workspace(fixture.aID)))
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        #expect(activation.overridingRowID(forComponent: component) == fixture.gcloudSkillID)
    }

    @Test("An edited tool of a shared skill kept without its plugin still replaces the plugin's tool where the plugin is on")
    func editedToolOfIndependentSkillIsAlsoAnOverride() throws {
        let fixture = try Fixture(componentOnlyWorkspace: true, editedToolDescription: "My own words")
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let edited = try fixture.context.fetch(FetchDescriptor<LocalTool>())
        let editedIDs = Set(edited.map(\.id))
        #expect(editedIDs.count == fixture.gcloud.localTools.count)

        // D, which turned the skill on by itself, keeps the tools on it.
        let skill = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(Set(skill.localTools.map(\.id)) == editedIDs)
        // A, which has the plugin, runs the person's tools, not the plugin's.
        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        for spec in fixture.gcloud.localTools {
            let row = activation.overridingRowID(forComponent: CapabilityResourceOrigin.componentID(for: spec))
            #expect(row.map(editedIDs.contains) == true)
        }
        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        fixture.context.insert(task)
        let scope = TaskCapabilityResolver(task: task).activationScope(contextText: "Manage GCP resources")
        #expect(editedIDs.isSubset(of: Set(scope.localTools.map(\.id))))
    }

    @Test("A tool the person attached to an unedited plugin skill stays with the plugin, not in the workspace's ambient scope")
    func authoredAttachmentStaysWithTheActivation() throws {
        let fixture = try Fixture(authoredToolOnGCloudSkill: true)
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let toolID = try #require(fixture.authoredToolID)
        let tool = try #require(try fixture.context.fetch(FetchDescriptor<LocalTool>()).first { $0.id == toolID })
        // Its skill is kept as the person's override, the tool on it.
        #expect(tool.skill?.id == fixture.gcloudSkillID)
        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(activation.overridingRowID(forComponent: CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0]))
            == fixture.gcloudSkillID)

        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        fixture.context.insert(task)
        #expect(TaskCapabilityResolver(task: task).allLocalTools.contains { $0.id == toolID })
        // B uses the same shared skill but never reaches A's own tool.
        let taskB = AgentTask(title: "B", goal: "Manage GCP resources", workspace: try fixture.workspace(fixture.bID))
        fixture.context.insert(taskB)
        #expect(!TaskCapabilityResolver(task: taskB).allLocalTools.contains { $0.id == toolID })
        // Turning the plugin off takes the tool with it.
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll { $0 == "gcloud-workflow" } }
        #expect(!TaskCapabilityResolver(task: task).allLocalTools.contains { $0.id == toolID })
    }

    @Test("An override skill selected for a task is never pinned, and leaves the run with its plugin")
    func overrideSkillStaysOutOfTaskPins() throws {
        let fixture = try Fixture(authoredToolOnGCloudSkill: true)
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let toolID = try #require(fixture.authoredToolID)
        let a = try fixture.workspace(fixture.aID)
        let shared = try fixture.context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
        let capabilities = WorkspaceCapabilities(workspace: a, globalSkills: shared, packageDefinitions: fixture.packages)
        // The composer offers the override row itself: a stored skill.
        let skill = try #require(capabilities.activeSkills.first { $0.id == fixture.gcloudSkillID })
        #expect(skill.modelContext != nil)
        #expect(AgentTask.storableSkills([skill], in: a).isEmpty)

        // A pin kept from before the migration still never outlives the plugin.
        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        fixture.context.insert(task)
        task.skills = [skill]
        func inRun() -> (skill: Bool, tool: Bool) {
            let resolver = TaskCapabilityResolver(task: task)
            return (resolver.allBehaviorSkills.contains { $0.id == fixture.gcloudSkillID },
                    resolver.allLocalTools.contains { $0.id == toolID })
        }
        #expect(inRun() == (true, true))
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll { $0 == "gcloud-workflow" } }
        #expect(inRun() == (false, false))

        // Remove retires the activation; its override stays out of pins and runs.
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        WorkspaceCapabilityActivation.retire(activation, in: a)
        WorkspaceCapabilityActivation.mutate(a) { $0.pluginIDs.removeAll { $0 == "gcloud-workflow" } }
        #expect(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a) == nil)
        #expect(AgentTask.storableSkills([skill], in: a).isEmpty)
        #expect(inRun() == (false, false))
    }

    @Test("The rail counts an activation's override rows as its own")
    func railActivationResourcesIncludeOverrides() throws {
        let fixture = try Fixture(editedToolDescription: "My own words")
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        // Launch reconciles right after migrating; an activation still on its
        // legacy version waits for Update and doesn't run.
        try PluginUpdateService.reconcileAll(modelContext: fixture.context, packages: fixture.packages, mode: .automatic)
        let a = try fixture.workspace(fixture.aID)
        let shared = try fixture.context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
        let tools = try fixture.context.fetch(FetchDescriptor<LocalTool>())
        let capabilities = WorkspaceCapabilities(
            workspace: a, globalSkills: shared, globalTools: tools, packageDefinitions: fixture.packages
        )
        let index = CapabilityRailWorkspaceResourceIndex(workspace: a, capabilities: capabilities)
        #expect(index.activations["jira-workflow"]?.skills.contains { $0.id == fixture.editedJiraSkillID } == true)
        #expect(Set(tools.map(\.id)).isSubset(of: Set(index.activations["gcloud-workflow"]?.tools.map(\.id) ?? [])))
    }

    @Test("A queued request runs with the plugin definitions it was submitted with, not an update installed while it waited")
    func queuedRequestKeepsSubmittedDefinitions() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        context.insert(task)
        // Submitted against an earlier GCloud: other rules, another command
        // line. The library now holds the built-in, as after an Update.
        var submitted = fixture.gcloud
        submitted.skills[0].behaviorInstructions = "Submitted GCloud rules."
        submitted.localTools[0].arguments = "--submitted"
        Self.accept(submitted, in: a)
        let request = TaskTurnRequest(
            task: task, messageEventID: UUID(), sequence: 2, kind: .retry, pluginDefinitions: [fixture.jira, submitted]
        )
        context.insert(request)
        Self.accept(fixture.gcloud, in: a)
        try context.save()
        let skillName = fixture.gcloud.skills[0].name
        let liveSkill = TaskCapabilityResolver(task: task).allBehaviorSkills.first { $0.name == skillName }
        #expect(liveSkill?.behaviorInstructions == fixture.gcloud.skills[0].behaviorInstructions)

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        // The runtime re-detaches its launch task (`AgentRuntimeExecutionContext`).
        let relaunched = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: detached), from: detached)
        let toolID = CapabilityResourceOrigin.componentID(for: fixture.gcloud.localTools[0])
        for launch in [detached, relaunched] {
            let resolver = TaskCapabilityResolver(task: launch)
            #expect(resolver.allBehaviorSkills.first { $0.name == skillName }?.behaviorInstructions == "Submitted GCloud rules.")
            #expect(resolver.allLocalTools.first { $0.originComponentID == toolID }?.arguments == "--submitted")
        }
        let decoded = try JSONDecoder().decode(
            TaskExecutionPolicySnapshotV1.self, from: Data(try #require(request.executionPolicySnapshotJSON).utf8)
        )
        #expect(decoded.pluginDefinitions?.first { $0.id == "gcloud-workflow" }?.skills[0].behaviorInstructions == "Submitted GCloud rules.")
    }

    @Test("A queued request launches the MCP servers it was submitted with, not the library's")
    func queuedRequestKeepsSubmittedMCPServers() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        context.insert(task)
        // Submitted against a GCloud that shipped an MCP server; the library
        // now holds the built-in, which has none, as after an Update.
        #expect(fixture.gcloud.mcpServers.isEmpty)
        var submitted = fixture.gcloud
        submitted.mcpServers = [PluginMCPServer(
            id: "submitted-files", displayName: "Submitted files", transport: .stdio, command: "/bin/cat"
        )]
        Self.accept(submitted, in: a)
        let request = TaskTurnRequest(
            task: task, messageEventID: UUID(), sequence: 2, kind: .retry, pluginDefinitions: [fixture.jira, submitted]
        )
        context.insert(request)
        Self.accept(fixture.gcloud, in: a)
        try context.save()
        func serverIDs(_ launch: AgentTask) -> (codex: Set<String>, manifest: Set<String>) {
            let codex = CodexMCPLaunchProjection.resolve(
                task: launch, workspacePath: "/tmp/astra-frozen-mcp", runID: UUID(),
                executionEnvironment: .host, contextText: "Use Jira and Google Cloud"
            )
            return (Set(codex.servers.map(\.server.id)),
                    Set(TaskCapabilityResolver(task: launch).enabledMCPServerManifests.map(\.id)))
        }
        #expect(!serverIDs(task).codex.contains("submitted-files"))

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let relaunched = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: detached), from: detached)
        for launch in [detached, relaunched] {
            let ids = serverIDs(launch)
            #expect(ids.codex.contains("submitted-files"))
            #expect(ids.manifest.contains("submitted-files"))
            #expect(CapabilityRuntimeResourceMatcher.packageDefinitions(for: launch.workspace)
                .first { $0.id == "gcloud-workflow" }?.mcpServers.map(\.id) == ["submitted-files"])
        }
    }

    @Test("A queued request runs with its accounts as submitted, not as edited or deleted while it waited")
    func queuedRequestKeepsSubmittedAccounts() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        try PluginUpdateService.reconcileAll(modelContext: context, packages: fixture.packages, mode: .automatic)
        let a = try fixture.workspace(fixture.aID)
        let accounts = try context.fetch(FetchDescriptor<Connector>())
        let first = try #require(accounts.first { $0.id == fixture.jiraAccount1ID })
        let second = try #require(accounts.first { $0.id == fixture.jiraAccount2ID })
        first.configKeys = ["JIRA_PROJECTS"]
        first.configValues = ["CLIN"]
        first.credentialValues = ["legacy-plaintext"]
        let submittedName = first.name
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()
        // Never a credential value, not even the legacy column's.
        #expect(request.executionPolicySnapshotJSON?.contains("legacy-plaintext") == false)

        // While it waits, one account moves and is reconfigured; the other
        // is deleted.
        first.name = "Renamed"
        first.baseURL = "https://edited.atlassian.net"
        first.configValues = ["EDITED"]
        context.delete(second)
        try context.save()

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let connectors = TaskCapabilityResolver(task: detached).allConnectors
        let launchedFirst = try #require(connectors.first { $0.id == fixture.jiraAccount1ID })
        #expect(launchedFirst.name == submittedName)
        #expect(launchedFirst.baseURL == "https://one.atlassian.net")
        #expect(launchedFirst.config["JIRA_PROJECTS"] == "CLIN")
        let launchedSecond = try #require(connectors.first { $0.id == fixture.jiraAccount2ID })
        #expect(launchedSecond.baseURL == "https://two.atlassian.net")
        // The store was never touched.
        #expect(try context.fetch(FetchDescriptor<Connector>()).first { $0.id == fixture.jiraAccount1ID }?.baseURL
            == "https://edited.atlassian.net")
    }

    @Test("A queued request runs with its override rows as submitted, not as edited or deleted while it waited")
    func queuedRequestKeepsSubmittedOverrides() throws {
        let fixture = try Fixture(editedToolDescription: "My own words", workspaceScopedRows: true)
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        // Launch runs the automatic reconcile; until then a plugin migrated
        // from a legacy version awaits Update and projects nothing.
        try PluginUpdateService.reconcileAll(modelContext: context, packages: fixture.packages, mode: .automatic)
        let a = try fixture.workspace(fixture.aID)
        let edited = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.editedJiraSkillID })
        edited.environmentKeys = ["JIRA_API_TOKEN", "JIRA_SITE"]
        edited.environmentValues = ["legacy-secret", "clinical"]
        let tool = try #require(try context.fetch(FetchDescriptor<LocalTool>()).first)
        let submittedArguments = tool.arguments
        let task = AgentTask(title: "A", goal: "Use Jira and Google Cloud", workspace: a)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()
        // Never a secret value, not even one still in the row.
        let json = try #require(request.executionPolicySnapshotJSON)
        #expect(!json.contains("legacy-secret"))
        #expect(json.contains("clinical"))

        // While it waits, the tool override is edited and the skill one
        // deleted.
        tool.arguments = "--edited"
        context.delete(edited)
        try context.save()

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let relaunched = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: detached), from: detached)
        let jiraComponent = CapabilityResourceOrigin.componentID(for: fixture.jira.skills[0])
        for launch in [detached, relaunched] {
            let resolver = TaskCapabilityResolver(task: launch)
            let skill = resolver.allBehaviorSkills.first { $0.id == fixture.editedJiraSkillID }
            #expect(skill?.behaviorInstructions == "My own Jira rules.")
            #expect(skill?.environmentValues == ["", "clinical"])
            // Not the plugin's own skill in its place.
            #expect(!resolver.allBehaviorSkills.contains { $0.originComponentID == jiraComponent })
            #expect(resolver.allLocalTools.first { $0.id == tool.id }?.arguments == submittedArguments)
        }
        #expect(tool.arguments == "--edited")
    }

    @Test("A queued request runs an override skill with its attachments as submitted, not as edited or deleted while it waited")
    func queuedRequestKeepsOverrideSkillAttachments() throws {
        let fixture = try Fixture(authoredToolOnGCloudSkill: true)
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let toolID = try #require(fixture.authoredToolID)
        let tool = try #require(try context.fetch(FetchDescriptor<LocalTool>()).first { $0.id == toolID })
        let submittedArguments = tool.arguments
        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()

        // While it waits, the attached command is edited, then deleted.
        tool.arguments = "projects delete everything"
        try context.save()
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let edited = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(TaskCapabilityResolver(task: edited).allLocalTools.first { $0.id == toolID }?.arguments == submittedArguments)

        context.delete(tool)
        try context.save()
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let relaunched = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: detached), from: detached)
        for launch in [detached, relaunched] {
            let launched = TaskCapabilityResolver(task: launch).allLocalTools.first { $0.id == toolID }
            #expect(launched?.arguments == submittedArguments)
            #expect(launched?.skill?.id == fixture.gcloudSkillID)
        }
    }

    @Test("Adding a version that drops a replaced component gives its row back to the workspace")
    func addingAVersionThatDropsAReplacedComponentReleasesItsRow() throws {
        let fixture = try Fixture(editedToolDescription: "My own words")
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let dropped = CapabilityResourceOrigin.componentID(for: try #require(fixture.gcloud.localTools.first))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let rowID = try #require(activation.overridingRowID(forComponent: dropped))
        #expect(!a.enabledGlobalToolIDs.contains(rowID.uuidString))
        var newer = fixture.gcloud
        newer.version = "2.0.0"
        newer.localTools.removeAll { CapabilityResourceOrigin.componentID(for: $0) == dropped }
        try Self.add(newer, to: a, context: context)

        // Nothing projects the row any more: it is A's shared row again, on.
        #expect(activation.overridingRowID(forComponent: dropped) == nil)
        #expect(!WorkspaceCapabilityActivation.overridingRowIDs(of: a).contains(rowID))
        let capabilities = WorkspaceCapabilities(
            workspace: a,
            globalSkills: try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })),
            globalTools: try context.fetch(FetchDescriptor<LocalTool>()),
            packageDefinitions: fixture.packages.map { $0.id == newer.id ? newer : $0 }
        )
        #expect(capabilities.activeTools.contains { $0.id == rowID })
        // B never accepted the newer version: the row still replaces its component.
        let b = try fixture.workspace(fixture.bID)
        let bActivation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: b))
        #expect(bActivation.overridingRowID(forComponent: dropped) == rowID)
    }

    @Test("A recovered mirror keeps override rows off the shared lists, so they leave with their plugin")
    func recoveredMirrorKeepsOverridesOffSharedLists() throws {
        let fixture = try Fixture(editedToolDescription: "My own words")
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let toolIDs = Set(try fixture.context.fetch(FetchDescriptor<LocalTool>()).map(\.id.uuidString))
        let editedSkillID = fixture.editedJiraSkillID.uuidString
        #expect(!toolIDs.isEmpty && !a.enabledGlobalToolIDs.contains(where: toolIDs.contains))
        #expect(!a.enabledGlobalSkillIDs.contains(editedSkillID))
        let config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))

        let recovered = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let restored = WorkspaceConfigManager.importWorkspaceResult(from: config, modelContext: recovered.mainContext).workspace
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: restored))
        #expect(toolIDs.isSubset(of: Set(gcloud.overridingRowIDs)))
        #expect(!restored.enabledGlobalToolIDs.contains(where: toolIDs.contains))
        #expect(!restored.enabledGlobalSkillIDs.contains(editedSkillID))
        // Off with their plugins.
        WorkspaceCapabilityActivation.mutate(restored) { $0.capabilityIDs = [] }
        let task = AgentTask(title: "A", goal: "Use Google Cloud", workspace: restored)
        recovered.mainContext.insert(task)
        let resolver = TaskCapabilityResolver(task: task)
        #expect(!resolver.allLocalTools.contains { toolIDs.contains($0.id.uuidString) })
        #expect(!resolver.allBehaviorSkills.contains { $0.id == fixture.editedJiraSkillID })
        withExtendedLifetime(recovered) {}
    }

    @Test("A queued request keeps a removed plugin's override rows out, even when it is added back while it waits")
    func queuedRequestKeepsRetiredOverridesOut() throws {
        // A's own edited GCloud tools replace the plugin's: standalone rows,
        // in a run's ambient scope unless a record names them.
        let fixture = try Fixture(editedToolDescription: "My own words", workspaceScopedRows: true)
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let toolIDs = Set(try context.fetch(FetchDescriptor<LocalTool>()).map(\.id))
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(!toolIDs.isEmpty && toolIDs.isSubset(of: Set(gcloud.overridingRowIDs.compactMap(UUID.init(uuidString:)))))
        WorkspaceCapabilityActivation.retire(gcloud, in: a)
        WorkspaceCapabilityActivation.mutate(a) {
            $0.capabilityIDs.removeAll { $0 == "gcloud-workflow" }
            $0.pluginIDs.removeAll { $0 == "gcloud-workflow" }
        }
        let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()
        func launched(_ task: AgentTask) -> Set<UUID> {
            Set(TaskCapabilityResolver(task: task).allLocalTools.map(\.id)).intersection(toolIDs)
        }
        #expect(launched(task).isEmpty)

        // Added back while the request waits: live, the rows are its
        // overrides again and the retired record is gone.
        try Self.add(fixture.gcloud, to: a, context: context)
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: a).isEmpty)
        #expect(launched(task) == toolIDs)

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let relaunched = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: detached), from: detached)
        for launch in [detached, relaunched] {
            #expect(launched(launch).isEmpty)
        }
    }

    @Test("Adding a missing plugin back exports every other workspace whose kept rows became its overrides")
    func addingMissingPluginBackExportsOtherAdoptingWorkspaces() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages.filter { $0.id != "gcloud-workflow" })
        let a = try fixture.workspace(fixture.aID)
        let b = try fixture.workspace(fixture.bID)
        #expect(WorkspaceCapabilityActivation.pendingOverridePluginIDs(of: b).contains("gcloud-workflow"))
        var exported: [UUID] = []
        try Self.add(fixture.gcloud, to: a, context: context) { exported.append($0.id) }
        #expect(WorkspaceCapabilityActivation.pendingOverridePluginIDs(of: b).isEmpty)
        #expect(exported == [fixture.bID])
    }

    @Test("The migration has rewritten each workspace's mirror by the time it cleans the deleted rows' secrets")
    func migrationRewritesMirrorsBeforeCleanup() throws {
        let fixture = try Fixture()
        let a = try fixture.workspace(fixture.aID)
        let folder = fixture.storeDirectory.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        a.primaryPath = folder.path
        try fixture.context.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        #expect(!FileManager.default.fileExists(atPath: mirror.path))

        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        // Written synchronously, in the migrated shape: the projected skill's
        // row is gone and the activation carries its accounts.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(WorkspaceConfigManager.WorkspaceConfig.self, from: Data(contentsOf: mirror))
        #expect(!config.skills.contains { $0.id == fixture.gcloudSkillID.uuidString })
        let jira = try #require(config.installedPlugins?.first { $0.id == "jira-workflow" })
        #expect(Set((jira.accounts ?? []).map(\.connectorID)) == [fixture.jiraAccount1ID.uuidString, fixture.jiraAccount2ID.uuidString])
    }

    @Test("An activation that accepted another definition needs action, and offers Update to accept the installed one")
    func activationAwaitingUpdateOffersUpdate() throws {
        let fixture = try Fixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        var newer = fixture.gcloud
        newer.version = "2.0.0"
        func state() throws -> CapabilityPackageState {
            CapabilityPackageState(package: newer, workspace: a, capabilities: WorkspaceCapabilities(
                workspace: a, globalSkills: [], globalTools: [], packageDefinitions: [newer]
            ))
        }
        let waiting = try state()
        #expect(waiting.isEnabled && waiting.awaitsUpdate)
        #expect(waiting.readiness.level == .needsAttention)
        let input = PluginsSurfacePresentation.Input(
            package: newer, isEnabled: waiting.isEnabled, pendingSteps: 0, isVisible: true, isRemovable: true,
            awaitsUpdate: waiting.awaitsUpdate
        )
        let surface = PluginsSurfacePresentation.makeState([input], query: "")
        #expect(surface.actionNeeded.map(\.id) == [newer.id] && surface.ready.isEmpty)
        #expect(surface.actionNeeded.first?.verb == .update)

        try Self.add(newer, to: a, context: context)
        #expect(try !state().awaitsUpdate)
        let accepted = PluginsSurfacePresentation.makeState([PluginsSurfacePresentation.Input(
            package: newer, isEnabled: true, pendingSteps: 0, isVisible: true, isRemovable: true, awaitsUpdate: try state().awaitsUpdate
        )], query: "")
        #expect(accepted.ready.map(\.id) == [newer.id] && accepted.ready.first?.verb == nil)
    }

    /// The workspace's activation accepts `package`, as the Add that
    /// installed it did: a request freezes the definition and the activation
    /// that accepted it together.
    private static func accept(_ package: PluginPackage, in workspace: Workspace) {
        WorkspaceCapabilityActivation.recordAccepted(
            pluginID: package.id, version: package.version, digest: PluginDefinitionDigest.content(of: package), in: workspace
        )
    }

    /// Add, as the Plugins surface's Add does it, against a scratch library.
    private static func add(
        _ package: PluginPackage,
        to workspace: Workspace,
        context: ModelContext,
        exportMirror: (@MainActor (Workspace) -> Void)? = nil
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-plugin-add-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try CapabilityInstaller(library: CapabilityLibrary(directory: root)).enable(
            package, in: workspace, modelContext: context,
            persist: { _, context in (try? context.save()) != nil }, exportMirror: exportMirror
        )
    }
}

/// The real skill-secret persistence, except that a delete never lands.
private enum UndeletableSkillSecrets: SkillSecretPersisting {
    private static let writes = OSAllocatedUnfairLock<[UUID]>(initialState: [])
    static var savedNamespaces: [UUID] { writes.withLock { $0 } }
    static func reset() { writes.withLock { $0 = [] } }
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        SkillSecretSeam.required.loadSecretValue(key: key, skillID: skillID, store: store)
    }

    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        writes.withLock { $0.append(skillID) }
        return SkillSecretSeam.required.saveSecretValue(
            value, key: key, skillID: skillID, skillName: skillName, allowUserInteraction: allowUserInteraction
        )
    }

    static func deleteSecret(key: String, skillID: UUID) -> Bool { false }

    static func secretExists(key: String, skillID: UUID) -> Bool {
        SkillSecretSeam.required.secretExists(key: key, skillID: skillID)
    }

    static func deleteAllSecrets(skillID: UUID) {
        SkillSecretSeam.required.deleteAllSecrets(skillID: skillID)
    }
}

// MARK: - Fixture

private typealias Fixture = PluginMigrationFixture

/// A real V19 store written through the frozen V19 models (see the suite).
/// Shared with the suites that pin later review fixes to the same store.
@MainActor
struct PluginMigrationFixture {
    let container: ModelContainer
    let context: ModelContext
    let packages: [PluginPackage]
    /// Each fixture package's content digest, as activations record it and
    /// the live verifier reads it.
    var digests: [String: String] {
        Dictionary(uniqueKeysWithValues: packages.map { ($0.id, PluginDefinitionDigest.content(of: $0)) })
    }
    let jira: PluginPackage
    let gcloud: PluginPackage
    let aID = UUID()
    let bID = UUID()
    let cID = UUID()
    let dID = UUID()
    let jiraAccount1ID: UUID
    let jiraAccount2ID: UUID
    let jiraAccountBID: UUID
    let sharedGCloudID: UUID
    let gcloudSkillID: UUID
    let editedJiraSkillID: UUID
    /// A's own tool the person attached to the GCloud skill, when asked for.
    let authoredToolID: UUID?
    let storeDirectory: URL

    private static var retained: [ModelContainer] = []

    init(
        gcloudSkillSecret: String? = nil,
        componentOnlyWorkspace: Bool = false,
        componentWorkspaceHasGCloudOff: Bool = false,
        gcloudSkillProject: String = "skill-project",
        editedToolDescription: String? = nil,
        editedSkillIcon: String? = nil,
        gcloudBehaviorSuffix: String? = nil,
        aOwnsGCloudAccount: Bool = false,
        gcloudSkillVersion: String? = nil,
        workspaceScopedRows: Bool = false,
        gcloudDisallowedTools: [String]? = nil,
        authoredToolOnGCloudSkill: Bool = false
    ) throws {
        jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        gcloud = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        packages = PluginCatalog.builtInPackages
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-plugin-activation-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("store.store")
        storeDirectory = root

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
                // As Add made it: signed in with the method the plugin declares.
                connector.authMethod = jiraSpec.authMethod
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
            if aOwnsGCloudAccount {
                // A gave the component its own account (scoped inputs) and
                // stopped listing the shared one.
                a.enabledGlobalConnectorIDs = []
                let own = V19.Connector()
                own.name = gcloudSpec.name
                own.serviceType = gcloudSpec.serviceType
                own.configKeys = ["GCP_PROJECT"]
                own.configValues = ["a-project"]
                own.originPackageID = "gcloud-workflow"
                own.originComponentID = CapabilityResourceOrigin.componentID(for: gcloudSpec)
                own.workspace = a
                context.insert(own)
                ids["aOwn"] = own.id
            }

            let gcloudSkillSpec = gcloud.skills[0]
            let skill = V19.Skill()
            skill.name = gcloudSkillSpec.name
            skill.icon = editedSkillIcon ?? gcloudSkillSpec.icon
            skill.skillDescription = gcloudSkillSpec.description
            skill.allowedTools = gcloudSkillSpec.allowedTools
            skill.customTools = gcloudSkillSpec.customTools
            // As installed: the spec's denied tools, not yet folded into the
            // behavior text by the startup pass.
            skill.disallowedTools = gcloudDisallowedTools ?? gcloudSkillSpec.disallowedTools
            skill.behaviorInstructions = gcloudSkillSpec.behaviorInstructions + (gcloudBehaviorSuffix ?? "")
            skill.environmentKeys = ["GCP_PROJECT"] + (gcloudSkillSecret == nil ? [] : ["GCP_API_TOKEN"])
            skill.environmentValues = [gcloudSkillProject] + (gcloudSkillSecret == nil ? [] : [""])
            skill.isGlobal = true
            skill.originPackageID = "gcloud-workflow"
            skill.originPackageVersion = gcloudSkillVersion ?? gcloud.version
            skill.originComponentID = CapabilityResourceOrigin.componentID(for: gcloudSkillSpec)
            context.insert(skill)
            shared.skill = skill
            ids["gcloudSkill"] = skill.id
            a.enabledGlobalSkillIDs = [skill.id.uuidString]
            if workspaceScopedRows {
                // A's own copies of the GCloud skill and tools, and its own
                // edited Jira skill.
                skill.isGlobal = false
                skill.workspace = a
                a.enabledGlobalSkillIDs = []
            }
            if componentOnlyWorkspace {
                let d = workspace(dID, "D")
                d.enabledGlobalSkillIDs = [skill.id.uuidString]
                d.enabledGlobalConnectorIDs = [shared.id.uuidString]
                if componentWorkspaceHasGCloudOff {
                    // D has the plugin, off: Disable took its rows off D's
                    // lists, and D turned them on again by themselves.
                    d.installedPluginIDs = ["gcloud-workflow"]
                    d.installedPluginVersions = ["1.0.0"]
                }
            }

            for toolSpec in gcloud.localTools {
                let tool = V19.LocalTool()
                tool.name = toolSpec.name
                tool.toolDescription = editedToolDescription ?? toolSpec.description
                tool.icon = toolSpec.icon
                tool.toolType = toolSpec.toolType
                tool.command = toolSpec.command
                tool.arguments = toolSpec.arguments
                tool.isGlobal = !workspaceScopedRows
                tool.workspace = workspaceScopedRows ? a : nil
                tool.originPackageID = "gcloud-workflow"
                tool.originComponentID = CapabilityResourceOrigin.componentID(for: toolSpec)
                tool.skill = skill
                context.insert(tool)
            }

            if authoredToolOnGCloudSkill {
                let tool = V19.LocalTool()
                tool.name = "My GCP report"
                tool.toolDescription = "A's own report command"
                tool.toolType = "cli"
                tool.command = "gcloud"
                tool.arguments = "projects list"
                tool.workspace = a
                tool.skill = skill
                context.insert(tool)
                ids["authoredTool"] = tool.id
            }

            let jiraSkillSpec = jira.skills[0]
            let edited = V19.Skill()
            edited.name = jiraSkillSpec.name
            edited.skillDescription = jiraSkillSpec.description
            edited.allowedTools = jiraSkillSpec.allowedTools
            edited.customTools = jiraSkillSpec.customTools
            edited.behaviorInstructions = "My own Jira rules."
            edited.isGlobal = !workspaceScopedRows
            edited.workspace = workspaceScopedRows ? a : nil
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
        authoredToolID = ids["authoredTool"]
    }

    /// The built-ins, with the GCloud skill declaring the secret the
    /// `gcloudSkillSecret` fixture row carries (an unedited row).
    var packagesDeclaringSecret: [PluginPackage] {
        packages.map { package in
            guard package.id == gcloud.id else { return package }
            var declared = package
            declared.skills[0].environmentKeys = ["GCP_PROJECT", "GCP_API_TOKEN"]
            declared.skills[0].environmentValues = ["", ""]
            return declared
        }
    }

    func workspace(_ id: UUID) throws -> Workspace {
        try #require(try context.fetch(FetchDescriptor<Workspace>()).first { $0.id == id })
    }
}
