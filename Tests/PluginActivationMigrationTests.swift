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
            installedDigests: fixture.digests,
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

    @Test("Adding a plugin again first clears what its Remove left pending, and waits while it can't")
    func reAddSettlesPendingSecrets() throws {
        let fixture = try Fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-plugin-secret-readd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = PluginSecretCleanupOutbox(fileURL: directory.appendingPathComponent("PluginSecretCleanup.json"))
        let workspace = try fixture.workspace(fixture.cID)
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        let reused = PluginActivation.projectedID(workspaceID: workspace.id, pluginID: "gcloud-workflow", componentID: component)
        let unrelated = UUID()
        try outbox.write([reused, unrelated])
        #expect(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: workspace) == nil)

        // A delete that fails keeps the record and holds the Add back.
        #expect(!PluginSecretCleanupOutbox.settleBeforeAdding(
            fixture.gcloud, to: workspace, modelContext: fixture.context, outbox: outbox, clean: { _ in false }
        ))
        #expect(Set(try outbox.pending()) == [reused, unrelated])
        var cleaned: [UUID] = []
        #expect(PluginSecretCleanupOutbox.settleBeforeAdding(
            fixture.gcloud, to: workspace, modelContext: fixture.context, outbox: outbox, clean: { cleaned.append($0); return true }
        ))
        // Only the namespaces the new activation would reuse are settled.
        #expect(cleaned == [reused])
        #expect(try outbox.pending() == [unrelated])

        // A record that can't be read never lets the Add through.
        try Data("not json".utf8).write(to: outbox.fileURL)
        #expect(!PluginSecretCleanupOutbox.settleBeforeAdding(fixture.gcloud, to: workspace, modelContext: fixture.context, outbox: outbox))
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
            installedDigests: fixture.digests,
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
            installedDigests: fixture.digests
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
                installedDigests: digests
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

    @Test("Only the exact note the disallowed-tools migration appended counts as unedited")
    func behaviorMatchIsExact() throws {
        let note = "\nDo NOT use these tools: Write, Edit."
        let generated = try Fixture(gcloudBehaviorSuffix: note)
        #expect(try PluginActivationMigration.migrate(modelContext: generated.context, packages: generated.packages).skillsProjected == 1)
        let extended = try Fixture(gcloudBehaviorSuffix: note + "\nAlso cite the console link.")
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
            installedDigests: fixture.digests
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
            installedDigests: fixture.digests
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
            installedDigests: digests
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
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let packages: [PluginPackage]
    /// Each fixture package's approval digest, as the live verifier reads it.
    var digests: [String: String] {
        Dictionary(uniqueKeysWithValues: packages.compactMap { package in
            (try? CapabilityApprovalDigest.digest(for: package)).map { (package.id, $0) }
        })
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
    let storeDirectory: URL

    private static var retained: [ModelContainer] = []

    init(
        gcloudSkillSecret: String? = nil,
        componentOnlyWorkspace: Bool = false,
        gcloudSkillProject: String = "skill-project",
        editedToolDescription: String? = nil,
        editedSkillIcon: String? = nil,
        gcloudBehaviorSuffix: String? = nil,
        aOwnsGCloudAccount: Bool = false,
        gcloudSkillVersion: String? = nil,
        workspaceScopedRows: Bool = false
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
