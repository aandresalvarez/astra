import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Who owns a plugin's rows, accounts and accepted definition after the
/// V20 migration: the activation, through its projection, and nothing that
/// lists a row beside it. Pinned against the V19 fixture store
/// (`PluginMigrationFixture`).
@Suite("Plugin activation ownership")
@MainActor
struct PluginActivationOwnershipTests {
    private static var retained: [ModelContainer] = []

    // MARK: - Migration

    @Test("A shared plugin row a workspace turned on beside its plugin's off activation stays on there")
    func rowListedBesideAnOffActivationSurvives() throws {
        let fixture = try PluginMigrationFixture(componentOnlyWorkspace: true, componentWorkspaceHasGCloudOff: true)
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let d = try fixture.workspace(fixture.dID)
        let a = try fixture.workspace(fixture.aID)

        let off = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: d))
        #expect(!off.isEnabled)
        // The row is D's own now, still listed and on, with its tools; the
        // shared account stays D's shared row, not bound to the off plugin.
        let skill = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
        #expect(skill.originPackageID == nil)
        #expect(d.enabledGlobalSkillIDs == [fixture.gcloudSkillID.uuidString])
        #expect(d.enabledGlobalConnectorIDs == [fixture.sharedGCloudID.uuidString])
        #expect(!off.bindings.contains { $0.account?.id == fixture.sharedGCloudID })
        let globalSkills = try context.fetch(FetchDescriptor<Skill>()).filter(\.isGlobal)
        let globalTools = try context.fetch(FetchDescriptor<LocalTool>()).filter(\.isGlobal)
        let capabilities = WorkspaceCapabilities(workspace: d, globalSkills: globalSkills, globalTools: globalTools)
        #expect(capabilities.activeSkills.contains { $0.id == fixture.gcloudSkillID })
        #expect(Set(capabilities.activeTools.map(\.name)) == Set(fixture.gcloud.localTools.map(\.name)))
        let taskD = AgentTask(title: "D", goal: "Google Cloud", workspace: d)
        context.insert(taskD)
        #expect(TaskCapabilityResolver(task: taskD).allConnectors.map(\.id) == [fixture.sharedGCloudID])
        // A, where the plugin is on, still gets the projection.
        #expect(!a.enabledGlobalSkillIDs.contains(fixture.gcloudSkillID.uuidString))
        let aGCloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(aGCloud.bindings.contains { $0.account?.id == fixture.sharedGCloudID })
    }

    @Test("A migrated mirror that can't be rewritten keeps the deleted rows' secret cleanup pending")
    func unwrittenMirrorHoldsTheCleanup() throws {
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: [])
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let fixture = try PluginMigrationFixture(gcloudSkillSecret: "s3cret")
                let context = fixture.context
                let persistence = SkillSecretSeam.required
                #expect(persistence.saveSecretValue(
                    "s3cret", key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID, skillName: "GCloud", allowUserInteraction: false
                ))
                // A's folder exists, but its mirror can't be written: a
                // folder sits where the file goes.
                let folder = fixture.storeDirectory.appendingPathComponent("workspace-a", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let a = try fixture.workspace(fixture.aID)
                a.primaryPath = folder.path
                try context.save()
                let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
                try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

                try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packagesDeclaringSecret)
                // The row is deleted, but its namespace waits for the mirror.
                #expect(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID } == nil)
                let outbox = try #require(PluginSecretCleanupOutbox(for: context))
                #expect(try outbox.pending().contains(fixture.gcloudSkillID))
                #expect(persistence.secretExists(key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID))

                // A later launch finds the V19 mirror still naming the row:
                // it writes the mirror again first, then cleans.
                try FileManager.default.removeItem(at: mirror)
                try Data(#"{"skills":[{"id":"\#(fixture.gcloudSkillID.uuidString)"}]}"#.utf8).write(to: mirror)
                PluginSecretCleanupOutbox.resumePending(modelContext: context)
                #expect(try outbox.pending().isEmpty)
                #expect(!persistence.secretExists(key: "GCP_API_TOKEN", skillID: fixture.gcloudSkillID))
                let rewritten = try String(contentsOf: mirror, encoding: .utf8)
                #expect(!rewritten.contains(fixture.gcloudSkillID.uuidString))
            }
        }
    }

    // MARK: - Accepted definition

    @Test("A definition replaced under the same version and components awaits Add again")
    func sameVersionContentChangeAwaitsAdd() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        #expect(!PluginRuntimeProjection.awaitsUpdate(activation, to: fixture.gcloud))

        // Another copy of the same definition (its source and governance
        // differ) is the definition the activation accepted.
        var copy = fixture.gcloud
        copy.sourceMetadata = CapabilitySourceMetadata(id: "elsewhere", displayName: "Elsewhere", kind: "custom", trustLevel: "local")
        copy.governance = CapabilityGovernance.defaultGovernance(for: copy.sourceMetadata)
        #expect(!PluginRuntimeProjection.awaitsUpdate(activation, to: copy))

        // Changed commands under the same version and component IDs: not
        // what this workspace accepted, so nothing of it runs here.
        var changed = fixture.gcloud
        changed.localTools[0].arguments = "--changed"
        #expect(PluginRuntimeProjection.componentIDs(of: changed) == PluginRuntimeProjection.componentIDs(of: fixture.gcloud))
        #expect(PluginRuntimeProjection.awaitsUpdate(activation, to: changed))
        let projected = PluginRuntimeProjection.project(workspace: a, packages: [changed])
        #expect(!projected.tools.contains { $0.originPackageID == "gcloud-workflow" })
        #expect(PluginRuntimeProjection.runnable([changed], in: a).isEmpty)

        // Add again accepts it.
        try Self.add(changed, to: a, context: fixture.context)
        #expect(!PluginRuntimeProjection.awaitsUpdate(activation, to: changed))
        #expect(PluginRuntimeProjection.project(workspace: a, packages: [changed]).tools.contains { $0.arguments == "--changed" })

        // A digest recorded before content digests can't be judged: the
        // version and components alone decide.
        WorkspaceCapabilityActivation.recordAccepted(
            pluginID: "gcloud-workflow", version: fixture.gcloud.version,
            digest: try CapabilityApprovalDigest.digest(for: fixture.gcloud), in: a
        )
        #expect(!PluginRuntimeProjection.awaitsUpdate(activation, to: fixture.gcloud))
    }

    @Test("The rail shows an activation awaiting Add again as needing attention")
    func railShowsAwaitingActivation() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        // A skill-and-tool plugin: no connector message could flag it.
        var accepted = fixture.gcloud
        accepted.connectors = []
        WorkspaceCapabilityActivation.recordAccepted(
            pluginID: accepted.id, version: accepted.version, digest: PluginDefinitionDigest.content(of: accepted), in: a
        )
        // Accepted as Update records it: the components it declares (an
        // Update releases a dropped one's state).
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: accepted.id, in: a))
        WorkspaceCapabilityActivation.setKnownComponents(PluginRuntimeProjection.componentIDs(of: accepted), on: activation)
        var changed = accepted
        changed.localTools[0].arguments = "--changed"
        let index = CapabilityRailWorkspaceResourceIndex(
            workspace: a,
            capabilities: WorkspaceCapabilities(workspace: a, packageDefinitions: [accepted])
        )
        #expect(CapabilityRailPackageSnapshotState(package: accepted, index: index).readiness == .ready)
        let awaiting = CapabilityRailPackageSnapshotState(package: changed, index: index).readiness
        #expect(awaiting.level == .needsAttention)
        #expect(awaiting.messages == [PluginsSurfacePresentation.awaitsUpdateMessage])
        // The rail's cache refreshes on such a replacement.
        #expect(CapabilityRailPackageSignature(package: changed) != CapabilityRailPackageSignature(package: accepted))
    }

    // MARK: - Override rows

    @Test("An activation's override row is locked in the composer menu, checked while its plugin is on")
    func composerLocksOverrideRows() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let c = try fixture.workspace(fixture.cID)
        let edited = try #require(try fixture.context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.editedJiraSkillID })
        #expect(WorkspaceCapabilityActivation.overridingRowIDs(of: a).contains(edited.id))

        // A has Jira on: the row is the plugin's, on, and not the task's to toggle.
        #expect(ComposerToolbarPresentation.skillMenuItem(edited, selected: [], workspace: a)
            == .init(isEnabled: true, isPluginOwned: true))
        // C has Jira off: still the plugin's, and off.
        #expect(ComposerToolbarPresentation.skillMenuItem(edited, selected: [edited], workspace: c)
            == .init(isEnabled: false, isPluginOwned: true))
        // A row of the workspace's own follows the task's selection.
        let own = Skill(name: "Mine", icon: "star", skillDescription: "", behaviorInstructions: "")
        own.workspace = a
        fixture.context.insert(own)
        #expect(ComposerToolbarPresentation.skillMenuItem(own, selected: [], workspace: a)
            == .init(isEnabled: false, isPluginOwned: false))
        #expect(ComposerToolbarPresentation.skillMenuItem(own, selected: [own], workspace: a)
            == .init(isEnabled: true, isPluginOwned: false))
    }

    @Test("An override row turned on in the Shared Library goes with its plugin")
    func sharedListNeverKeepsAnOverrideOn() throws {
        let fixture = try PluginMigrationFixture(editedToolDescription: "My own words")
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let tools = try context.fetch(FetchDescriptor<LocalTool>())
        let tool = try #require(tools.first { gcloud.overridingRowIDs.contains($0.id.uuidString) })
        #expect(tool.isGlobal)
        let edited = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.editedJiraSkillID })

        // The person turns both on from the Shared Library, with a shared
        // account of their own attached to the skill, then turns the
        // plugins off.
        CapabilitySharing.enableShared(tool, in: a)
        WorkspaceCapabilityActivation.mutate(a) { $0.enableGlobalSkill(edited.id.uuidString) }
        let attached = Connector(name: "My API", serviceType: "custom", baseURL: "https://api.example.invalid")
        attached.authMethod = "none"
        attached.isGlobal = true
        attached.skill = edited
        context.insert(attached)
        CapabilitySharing.enableShared(attached, in: a)
        #expect(a.enabledGlobalToolIDs.contains(tool.id.uuidString))
        WorkspaceCapabilityActivation.mutate(a) { $0.capabilityIDs.removeAll() }
        try context.save()

        let task = AgentTask(title: "A", goal: "Google Cloud", workspace: a)
        context.insert(task)
        let resolver = TaskCapabilityResolver(task: task)
        #expect(!resolver.allLocalTools.contains { $0.id == tool.id })
        #expect(resolver.allConnectors.contains { $0.id == attached.id })
        #expect(!resolver.allBehaviorSkills.contains { $0.id == edited.id })
        let capabilities = WorkspaceCapabilities(
            workspace: a,
            globalSkills: try context.fetch(FetchDescriptor<Skill>()).filter(\.isGlobal),
            globalTools: tools.filter(\.isGlobal)
        )
        #expect(!capabilities.activeTools.contains { $0.id == tool.id })
        #expect(!capabilities.activeSkills.contains { $0.id == edited.id })
    }

    // MARK: - Queued requests

    @Test("A plugin added while a request waited lends none of its accounts to the run")
    func postSubmissionAccountsStayOutOfTheLaunch() throws {
        let fixture = try PluginMigrationFixture()
        let context = fixture.context
        try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
        // C has Jira installed, off, with no account.
        let c = try fixture.workspace(fixture.cID)
        let jira = try #require(WorkspaceCapabilityActivation.activation(for: "jira-workflow", in: c))
        #expect(!jira.isEnabled && jira.bindings.isEmpty)
        let task = AgentTask(title: "C", goal: "Use Jira", workspace: c)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        context.insert(request)
        try context.save()

        // While it waits, Jira is added: C gets its own Jira account.
        try Self.add(fixture.jira, to: c, context: context)
        let account = try #require(jira.bindings.first?.account)
        #expect(account.workspace?.id == c.id)
        #expect(TaskCapabilityResolver(task: task).allConnectors.contains { $0.id == account.id })

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(!TaskCapabilityResolver(task: detached).allConnectors.contains { $0.id == account.id })
        #expect(!(detached.workspace?.connectors.contains { $0.id == account.id } ?? true))
    }

    // MARK: - Import

    @Test("A chosen file's activation for another copy still maps its skill IDs onto the ones an Add here projects")
    func rejectedCopyRemapsProjectedIDs() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let original = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: a))
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.skills[0])
        let originalID = PluginRuntimeProjection.derivedID(of: original, componentID: component).uuidString
        // The migration pointed the template at the projected skill.
        #expect(a.templates.first?.defaultSkillIDs == [originalID])
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
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: imported))
        #expect(!activation.isEnabled && activation.configuration.isEmpty)
        let fresh = PluginRuntimeProjection.derivedID(of: activation, componentID: component).uuidString
        #expect(fresh != originalID)
        // What an Add of the installed copy here projects.
        #expect(imported.templates.first?.defaultSkillIDs == [fresh])
        #expect(imported.schedules.first?.skillIDs == [fresh])
    }

    @Test("A file whose activation recorded an approval digest is still judged by it")
    func legacyFileDigestIsStillAccepted() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        var config = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let legacy = try CapabilityApprovalDigest.digest(for: fixture.gcloud)
        config.installedPlugins = config.installedPlugins?.map { ref in
            var ref = ref
            if ref.id == "gcloud-workflow" { ref.digest = legacy }
            return ref
        }
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
            installedDigests: ["gcloud-workflow": legacy],
            installedContentDigests: fixture.digests
        )
        let imported = WorkspaceConfigManager.importWorkspaceResult(
            from: config, modelContext: target.mainContext, capabilityTrust: .validate(verifier)
        ).workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: imported))
        #expect(activation.isEnabled)
        #expect(!activation.configuration.isEmpty)
    }

    @Test("Workspaces imported together keep the shared account they had in common, under a fresh ID")
    func batchImportKeepsSharedAccountsShared() throws {
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: [])
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let fixture = try PluginMigrationFixture()
                try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
                let shared = try #require(try fixture.context.fetch(FetchDescriptor<Connector>()).first { $0.id == fixture.sharedGCloudID })
                shared.credentialKeys = ["GCP_TOKEN"]
                shared.credentialValues = [""]
                #expect(shared.saveCredential(key: "GCP_TOKEN", value: "original-secret"))
                try fixture.context.save()
                // A and B both bind the shared Google Cloud account.
                let configs = try [fixture.aID, fixture.bID].map { id in
                    try #require(WorkspaceConfigManager.export(workspace: try fixture.workspace(id), modelContext: fixture.context))
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
                @MainActor func importAll(
                    session: WorkspaceConfigManager.ImportSession?, configs: [WorkspaceConfigManager.WorkspaceConfig] = configs
                ) throws -> (ModelContext, [Workspace]) {
                    let target = try ModelContainer(
                        for: ASTRASchema.current,
                        migrationPlan: ASTRAMigrationPlan.self,
                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
                    )
                    Self.retained.append(target)
                    let workspaces = configs.map { config in
                        WorkspaceConfigManager.importWorkspaceResult(
                            from: config, modelContext: target.mainContext, capabilityTrust: .validate(verifier), importSession: session
                        ).workspace
                    }
                    return (target.mainContext, workspaces)
                }
                let serviceType = fixture.gcloud.connectors[0].serviceType

                // One import action: one row, shared, bound in both.
                let (context, imported) = try importAll(session: WorkspaceConfigManager.ImportSession())
                let rows = try context.fetch(FetchDescriptor<Connector>()).filter { $0.serviceType == serviceType }
                let row = try #require(rows.first)
                #expect(rows.count == 1)
                #expect(row.isGlobal && row.workspace == nil)
                #expect(row.id != fixture.sharedGCloudID)
                for workspace in imported {
                    let gcloud = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: workspace))
                    #expect(gcloud.bindings.compactMap { $0.account?.id } == [row.id])
                    // Neither mirror listed it: it is shared only through the bindings.
                    #expect(!workspace.enabledGlobalConnectorIDs.contains(row.id.uuidString))
                }
                // The fresh ID resolves none of this machine's credentials.
                #expect(row.missingCredentialKeys() == ["GCP_TOKEN"])
                #expect(shared.credentials["GCP_TOKEN"] == "original-secret")

                // Imported one at a time, each workspace gets its own, as before.
                let (separate, _) = try importAll(session: nil)
                #expect(try separate.fetch(FetchDescriptor<Connector>()).filter { $0.serviceType == serviceType }.count == 2)

                // Two files that give the ID to different accounts aren't
                // merged: each workspace binds its own row.
                var conflicting = configs
                conflicting[1].connectors = conflicting[1].connectors?.map { cc in
                    var cc = cc
                    if cc.id == fixture.sharedGCloudID.uuidString { cc.configValues = cc.configValues.map { _ in "other-tenant" } }
                    return cc
                }
                #expect(conflicting[1].connectors?.first { $0.id == fixture.sharedGCloudID.uuidString }?.configValues.isEmpty == false)
                let (split, splitWorkspaces) = try importAll(session: WorkspaceConfigManager.ImportSession(), configs: conflicting)
                let splitRows = try split.fetch(FetchDescriptor<Connector>()).filter { $0.serviceType == serviceType }
                #expect(splitRows.count == 2)
                let boundIDs = try splitWorkspaces.map { workspace in
                    try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: workspace))
                        .bindings.compactMap { $0.account?.id }
                }
                #expect(boundIDs.count == 2 && boundIDs.allSatisfy { $0.count == 1 } && Set(boundIDs.flatMap { $0 }).count == 2)
            }
        }
    }

    @Test("Mirror recovery keeps a shared account it carries only for a binding off the shared list")
    func recoveryKeepsBindingOnlyAccountsUnlisted() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let a = try fixture.workspace(fixture.aID)
        let b = try fixture.workspace(fixture.bID)
        let shared = try #require(try fixture.context.fetch(FetchDescriptor<Connector>()).first { $0.id == fixture.sharedGCloudID })
        // A also turned the account on by itself; B only binds it.
        CapabilitySharing.enableShared(shared, in: a)
        try fixture.context.save()
        var legacyA = try #require(WorkspaceConfigManager.export(workspace: a, modelContext: fixture.context))
        let configB = try #require(WorkspaceConfigManager.export(workspace: b, modelContext: fixture.context))
        #expect(configB.connectors?.contains { $0.id == fixture.sharedGCloudID.uuidString } == true)
        #expect(configB.enabledGlobalConnectorIDs?.contains(fixture.sharedGCloudID.uuidString) != true)
        let configA = legacyA
        // A mirror written before shared lists were exported names none.
        legacyA.enabledGlobalConnectorIDs = nil

        func recover(_ config: WorkspaceConfigManager.WorkspaceConfig) throws -> (ModelContext, Workspace) {
            let target = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            Self.retained.append(target)
            let workspace = WorkspaceConfigManager.importWorkspaceResult(
                from: config, modelContext: target.mainContext, capabilityTrust: .preserveRecordedState
            ).workspace
            return (target.mainContext, workspace)
        }
        func inScope(_ workspace: Workspace, _ context: ModelContext) -> Bool {
            let task = AgentTask(title: "T", goal: "Google Cloud", workspace: workspace)
            context.insert(task)
            return TaskCapabilityResolver(task: task).allConnectors.contains { $0.id == fixture.sharedGCloudID }
        }
        let component = CapabilityResourceOrigin.componentID(for: fixture.gcloud.connectors[0])
        for (config, listed) in [(configB, false), (legacyA, false), (configA, true)] {
            let (context, recovered) = try recover(config)
            #expect(recovered.enabledGlobalConnectorIDs.contains(fixture.sharedGCloudID.uuidString) == listed)
            // An Update releasing the account leaves it in scope only where
            // the person turned it on.
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: "gcloud-workflow", in: recovered))
            let account = try #require(activation.accounts(forComponent: component).first { $0.id == fixture.sharedGCloudID })
            WorkspaceCapabilityActivation.unbind(account, from: activation, componentID: component)
            #expect(inScope(recovered, context) == listed)
        }
    }

    @Test("The rail's cache key follows the approval decision, not only the record list")
    func railKeyFollowsEffectiveApproval() throws {
        let approved = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        let record = CapabilityApprovalRecord(
            packageID: approved.id, packageVersion: approved.version, status: .approved, approvedBy: "admin",
            approvedAt: Date(timeIntervalSinceReferenceDate: 1_000), reviewNotes: "",
            sourceDigest: try CapabilityApprovalDigest.digest(for: approved)
        )
        // Another copy of the same version and content: the record no
        // longer matches it, so policy blocks it, with the same records.
        var replaced = approved
        replaced.description += " (another copy)"
        #expect(PluginDefinitionDigest.content(of: replaced) == PluginDefinitionDigest.content(of: approved))
        #expect(CapabilityCatalogPolicy.approvalMatch(for: approved, records: [record]) == .record(record))
        #expect(CapabilityCatalogPolicy.approvalMatch(for: replaced, records: [record]) == .mismatch)
        #expect(CapabilityRailPackageSignature(package: approved, approvalRecords: [record])
            != CapabilityRailPackageSignature(package: replaced, approvalRecords: [record]))
        // A copy its version's records don't cover isn't one with none.
        #expect(CapabilityRailPackageSignature(package: replaced, approvalRecords: [record])
            != CapabilityRailPackageSignature(package: replaced, approvalRecords: []))
        // The rail's whole key, with the same record list.
        let workspace = Workspace(name: "Rail", primaryPath: "/tmp/rail-approval")
        func key(_ package: PluginPackage) -> CapabilityRailSnapshotSignature {
            CapabilityRailSnapshotSignature(
                workspace: workspace, globalSkills: [], globalConnectors: [], globalTools: [],
                packages: [package], approvalRecords: [record], prerequisiteStatuses: [:]
            )
        }
        #expect(key(approved) != key(replaced))
        // A block under the same digest changes it too.
        var blocked = record
        blocked.status = .blocked
        #expect(CapabilityRailPackageSignature(package: approved, approvalRecords: [record])
            != CapabilityRailPackageSignature(package: approved, approvalRecords: [blocked]))
    }

    @Test("A chosen file's binding alias isn't taken: the import's own account gets its name here")
    func validatedImportRederivesBindingAlias() throws {
        let fixture = try PluginMigrationFixture()
        try PluginActivationMigration.migrate(modelContext: fixture.context, packages: fixture.packages)
        let b = try fixture.workspace(fixture.bID)
        var config = try #require(WorkspaceConfigManager.export(workspace: b, modelContext: fixture.context))
        config.installedPlugins = config.installedPlugins?.map { ref in
            var ref = ref
            ref.accounts = ref.accounts?.map { account in
                var account = account
                account.alias = "Someone else's tenant"
                return account
            }
            return ref
        }
        let target = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        Self.retained.append(target)
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
            from: config, modelContext: target.mainContext, capabilityTrust: .validate(verifier)
        ).workspace
        let bindings = WorkspaceCapabilityActivation.activations(of: imported).flatMap(\.bindings)
        #expect(!bindings.isEmpty)
        #expect(bindings.allSatisfy { $0.alias.isEmpty })
        for binding in bindings {
            let account = try #require(binding.account)
            #expect(WorkspaceCapabilityActivation.alias(of: account, in: imported) == account.name)
        }
    }

    /// Add, as the Plugins surface's Add does it, against a scratch library.
    private static func add(_ package: PluginPackage, to workspace: Workspace, context: ModelContext) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-plugin-add-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try CapabilityInstaller(library: CapabilityLibrary(directory: root)).enable(
            package, in: workspace, modelContext: context,
            persist: { _, context in (try? context.save()) != nil }
        )
    }
}
