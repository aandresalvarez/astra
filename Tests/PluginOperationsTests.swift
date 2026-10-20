import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Plugins 2.0 R3: Update, accounts, settings and Remove on the activation
/// model (spec, "Operations").
@Suite("Plugin operations")
@MainActor
struct PluginOperationsTests {
    @Test("Renaming a component across an Update keeps its settings, accounts and schedule")
    func renameAcrossUpdateKeepsState() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        let workspace = env.workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: workspace, modelContext: env.context)
        let account = try #require(workspace.connectors.first)
        let oldSkillID = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:report-agent")
        let schedule = TaskSchedule(name: "Weekly", goal: "Report", workspace: workspace)
        schedule.skillIDs = [oldSkillID.uuidString]
        env.context.insert(schedule)
        try env.context.save()

        var v2 = Self.package(version: "2.0.0")
        v2.skills[0].id = "summary-agent"
        v2.skills[0].name = "Summary Agent"
        v2.skills[0].replaces = ["report-agent"]
        v2.connectors[0].id = "tracker"
        v2.connectors[0].replaces = ["connector:tracker:tracker-api"]
        try env.importUpdate(v2)

        let newSkillComponent = "skill:summary-agent"
        #expect(activation.configuration(forComponent: newSkillComponent) == ["PROJECT": "alpha"])
        #expect(activation.configuration(forComponent: "skill:report-agent").isEmpty)
        #expect(activation.accounts(forComponent: "connector:tracker:tracker").map(\.id) == [account.id])
        let newSkillID = PluginRuntimeProjection.derivedID(of: activation, componentID: newSkillComponent)
        #expect(schedule.skillIDs == [newSkillID.uuidString])
        #expect(activation.recordedVersion == "2.0.0")
        #expect(activation.knownComponentIDs.contains(newSkillComponent))

        let projected = WorkspaceCapabilities(workspace: workspace, packageDefinitions: [v2]).activeSkills
        #expect(projected.map(\.id) == [newSkillID])
        #expect(projected.first?.environmentVariables["PROJECT"] == "alpha")
    }

    @Test("A component an Update drops is gone, with its state; its account stays")
    func droppedComponentIsReleased() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        let workspace = env.workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        let account = try #require(workspace.connectors.first)
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: workspace, modelContext: env.context)

        var v2 = Self.package(version: "2.0.0")
        v2.connectors = []
        v2.localTools = []
        v2.skills[0].id = "unrelated-agent"
        v2.skills[0].name = "Unrelated Agent"
        try env.importUpdate(v2)

        #expect(activation.bindings.isEmpty)
        #expect(activation.configKeys.isEmpty)
        #expect(activation.knownComponentIDs == ["skill:unrelated-agent"])
        #expect(workspace.connectors.map(\.id) == [account.id])
        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: [v2])
        #expect(capabilities.activeTools.isEmpty)
        #expect(capabilities.activeConnectors.isEmpty)
        #expect(capabilities.activeSkills.map(\.name) == ["Unrelated Agent"])
    }

    @Test("An Update a workspace would refuse is refused for every workspace")
    func updateRefusedByAWorkspace() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        var v2 = Self.package(version: "2.0.0")
        v2.requires = ["not-installed-plugin"]

        #expect(throws: PluginUpdateService.UpdateError.self) { try env.importUpdate(v2) }
        #expect(env.library.installedPackage(id: v1.id)?.version == "1.0.0")
        #expect(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace)?.recordedVersion == "1.0.0")
    }

    @Test("Two components may not share an identity, and replaces must be unambiguous")
    func componentIdentityIsValidated() {
        var package = Self.package(version: "1.0.0")
        package.skills.append(package.skills[0])
        package.localTools[0].replaces = ["skill:report-agent"]
        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
        let identityIssues = report.issues.filter { $0.code == .invalidComponentIdentity }
        #expect(identityIssues.contains { $0.title == "Duplicate component" })
        #expect(identityIssues.contains { $0.message.contains("different kind") })
        #expect(identityIssues.contains { $0.message.contains("still declares") })
        #expect(!report.canInstall)

        #expect(PluginUpdateService.replacesProblems(in: Self.package(version: "1.0.0")).isEmpty)
    }

    @Test("Accounts: a second one gets its own alias, can become the default, and deleting one unbinds it everywhere")
    func accountOperations() throws {
        let env = try Environment()
        let package = Self.package(version: "1.0.0")
        try env.install(package)
        let workspace = env.workspace
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let component = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        let first = try #require(activation.accounts(forComponent: component).first)

        let second = try PluginOperations.addAccount(for: package.connectors[0], of: package, in: workspace, modelContext: env.context)
        #expect(second.name == "\(first.name) 2")
        #expect(second.workspace?.id == workspace.id)
        #expect(activation.accounts(forComponent: component).map(\.id) == [first.id, second.id])

        try PluginOperations.makeDefault(second, componentID: component, pluginID: package.id, in: workspace, modelContext: env.context)
        #expect(activation.accounts(forComponent: component).first?.id == second.id)
        #expect(try PluginOperations.workspacesUsing(second).map(\.id) == [workspace.id])

        try PluginOperations.deleteAccount(second, modelContext: env.context)
        #expect(activation.accounts(forComponent: component).map(\.id) == [first.id])
        #expect(activation.bindings.first?.isDefault == true)
        #expect(!workspace.connectors.contains { $0.id == second.id })
    }

    @Test("A setting is per workspace and falls back to the plugin's default")
    func settingsArePerWorkspace() throws {
        let env = try Environment()
        let package = Self.package(version: "1.0.0")
        try env.install(package)
        let other = Workspace(name: "Other", primaryPath: "/tmp/plugin-ops-other")
        env.context.insert(other)
        try env.installer.install(package, into: other, modelContext: env.context, announceCatalogMutation: false)

        try PluginOperations.setSetting("PROJECT", to: "alpha", of: package.skills[0], pluginID: package.id, in: env.workspace, modelContext: env.context)
        let here = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let there = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: other))
        #expect(PluginOperations.setting("PROJECT", of: package.skills[0], in: here) == "alpha")
        #expect(PluginOperations.setting("PROJECT", of: package.skills[0], in: there) == "default-project")
    }

    /// A Remove whose save landed but whose mirror couldn't be written: a
    /// recovery from that mirror would bring back what it deleted, so the
    /// intent stays, with the workspace, until launch rewrites it.
    @Test("A Remove's intent is cleared only once every affected mirror is rewritten")
    func removeIntentWaitsForMirrorRewrites() throws {
        let env = try Environment()
        let folder = env.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.workspace.primaryPath = folder.path
        let other = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("other").path)
        env.context.insert(other)
        let package = Self.package(version: "1.0.0")
        try env.install(package)
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        // The mirror's path is taken by a folder: it can't be written.
        let mirrorURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try? FileManager.default.removeItem(at: mirrorURL)
        try FileManager.default.createDirectory(at: mirrorURL, withIntermediateDirectories: true)

        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context, removeJournal: journal)
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace) == nil)
        #expect(try journal.intents() == [.init(pluginID: package.id, workspaceIDs: [env.workspace.id])])

        // Launch: still unwritable, still kept; only the recorded workspace
        // is rewritten.
        var rewritten: [UUID] = []
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal) {
            rewritten.append($0.id)
            return false
        }
        #expect(rewritten == [env.workspace.id])
        #expect(try journal.pending() == [package.id])

        try FileManager.default.removeItem(at: mirrorURL)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(try journal.pending().isEmpty)
        let mirror = try WorkspaceConfigManager.loadConfig(from: mirrorURL)
        #expect(!(mirror.installedPlugins ?? []).contains { $0.id == package.id })
    }

    @Test("An interrupted Remove is finished at launch; one never saved is dropped")
    func removeJournalResumes() throws {
        let env = try Environment()
        let package = Self.package(version: "1.0.0")
        try env.install(package)
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))

        // Never saved: the activation is still there, so the library stays.
        try journal.begin(package.id)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(env.library.installedPackage(id: package.id) != nil)
        #expect(try journal.pending().isEmpty)

        // Saved, then the exit came before the library entry went.
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0 = WorkspaceCapabilityActivationState() }
        try env.context.save()
        try journal.begin(package.id)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(env.library.installedPackage(id: package.id) == nil)
        #expect(try journal.pending().isEmpty)
    }

    @Test("The automatic pass moves renames but never releases; Update does")
    func automaticPassWithholdsReleases() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)

        var v2 = Self.package(version: "2.0.0")
        v2.skills[0].id = "summary-agent"
        v2.skills[0].replaces = ["report-agent"]
        v2.connectors = []
        try env.importUpdate(v2, mode: .automatic)

        // The rename moved; the dropped connector's binding is still there.
        #expect(activation.configuration(forComponent: "skill:summary-agent") == ["PROJECT": "alpha"])
        #expect(!activation.bindings.isEmpty)
        #expect(activation.recordedVersion == "1.0.0")
        #expect(PluginUpdateService.needsReconcile(activation, to: v2))
        #expect(activation.knownComponentIDs.contains("skill:summary-agent"))
        #expect(!activation.knownComponentIDs.contains("skill:report-agent"))

        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [v2], mode: .release, approvalRecords: PluginOperationsTests.approvals([v2]))
        #expect(activation.bindings.isEmpty)
        #expect(activation.recordedVersion == "2.0.0")
        #expect(!PluginUpdateService.needsReconcile(activation, to: v2))
    }

    @Test("A setting a kept skill no longer declares is released by Update")
    func removedKeyOfKeptComponentIsReleased() throws {
        let env = try Environment()
        var v1 = Self.package(version: "1.0.0")
        v1.skills[0].environmentKeys = ["PROJECT", "REGION"]
        v1.skills[0].environmentValues = ["default-project", ""]
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try PluginOperations.setSetting("REGION", to: "us", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)

        let v2 = Self.package(version: "2.0.0")
        try env.importUpdate(v2, mode: .automatic)
        #expect(activation.configuration(forComponent: "skill:report-agent") == ["REGION": "us"])
        #expect(activation.recordedVersion == "1.0.0")

        try env.importUpdate(v2)
        #expect(activation.configuration(forComponent: "skill:report-agent").isEmpty)
        #expect(activation.recordedVersion == "2.0.0")
    }

    /// Adding a version this workspace had at another one is an Update for
    /// it (`.release`): a setting the new version stopped declaring goes.
    @Test("Adding a version that stops declaring a setting releases it")
    func addReleasesADroppedSetting() throws {
        let env = try Environment()
        var v1 = Self.package(version: "1.0.0")
        v1.skills[0].environmentKeys = ["PROJECT", "REGION"]
        v1.skills[0].environmentValues = ["default-project", ""]
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try PluginOperations.setSetting("REGION", to: "us", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)
        #expect(activation.configuration(forComponent: "skill:report-agent") == ["REGION": "us"])

        try env.install(Self.package(version: "2.0.0"))
        #expect(activation.configuration(forComponent: "skill:report-agent").isEmpty)
        #expect(activation.recordedVersion == "2.0.0")
    }

    @Test("Update brings the plugin's templates to the definition and keeps dropped ones as the person's")
    func templatesFollowUpdate() throws {
        let env = try Environment()
        var v1 = Self.package(version: "1.0.0")
        v1.templates = [Self.template("Weekly", goal: "Write it"), Self.template("Daily", goal: "Note it")]
        try env.install(v1)
        let weekly = try #require(env.workspace.templates.first { $0.name == "Weekly" })
        let daily = try #require(env.workspace.templates.first { $0.name == "Daily" })

        var v2 = Self.package(version: "2.0.0")
        v2.templates = [Self.template("Weekly", goal: "Write it better"), Self.template("Monthly", goal: "Sum it")]
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try env.importUpdate(v2, mode: .automatic)
        #expect(weekly.mainGoal == "Write it")
        #expect(activation.recordedVersion == "1.0.0")

        try env.importUpdate(v2)
        #expect(weekly.mainGoal == "Write it better")
        #expect(env.workspace.templates.contains { $0.name == "Monthly" && $0.originPackageID == v2.id })
        #expect(daily.originPackageID == nil)
        #expect(env.workspace.templates.contains { $0 === daily })
        #expect(PluginTemplateSync.isInSync(v2, in: env.workspace))
    }

    @Test("A rename into a component that has its own secret keeps that secret; a failed save puts copies back")
    func renameKeepsDestinationSecret() throws {
        guard AstraSecureKeychainTestSupport.isAvailable else { return }
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: [])
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let env = try Environment()
                var v1 = Self.package(version: "1.0.0")
                var second = v1.skills[0]
                second.id = "summary-agent"
                second.name = "Summary Agent"
                v1.skills.append(second)
                for index in v1.skills.indices {
                    v1.skills[index].environmentKeys = ["API_TOKEN"]
                    v1.skills[index].environmentValues = [""]
                }
                try env.install(v1)
                let workspace = env.workspace
                try PluginOperations.setSetting("API_TOKEN", to: "old", of: v1.skills[0], pluginID: v1.id, in: workspace, modelContext: env.context)
                try PluginOperations.setSetting("API_TOKEN", to: "mine", of: v1.skills[1], pluginID: v1.id, in: workspace, modelContext: env.context)
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))

                var v2 = v1
                v2.version = "2.0.0"
                v2.skills.removeFirst()
                v2.skills[0].replaces = ["report-agent"]
                try env.importUpdate(v2)
                #expect(PluginOperations.setting("API_TOKEN", of: v2.skills[0], in: activation) == "mine")

                // `undo` restores what a copy overwrote, or clears what it added.
                let persistence = SkillSecretSeam.required
                let target = UUID()
                #expect(persistence.saveSecretValue("new", key: "API_TOKEN", skillID: target, skillName: "", allowUserInteraction: false))
                PluginUpdateService.undo([.init(key: "API_TOKEN", skillID: target, previousValue: nil)])
                #expect(!persistence.secretExists(key: "API_TOKEN", skillID: target))
            }
        }
    }

    @Test("A secret a kept skill stops declaring is journaled with the save and deleted after it")
    func droppedSecretKeyIsJournaledAndDeleted() throws {
        guard AstraSecureKeychainTestSupport.isAvailable else { return }
        let keychainPath = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap)
        defer {
            AstraSecureKeychainTestSupport.cleanup(keychainPath: keychainPath, bootstrapService: bootstrap, services: [])
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(keychainPath) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                let env = try Environment()
                var v1 = Self.package(version: "1.0.0")
                v1.skills[0].environmentKeys = ["PROJECT", "API_TOKEN"]
                v1.skills[0].environmentValues = ["default-project", ""]
                try env.install(v1)
                try PluginOperations.setSetting("API_TOKEN", to: "s3cret", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)
                let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
                let namespace = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:report-agent")
                let persistence = SkillSecretSeam.required
                #expect(persistence.secretExists(key: "API_TOKEN", skillID: namespace))
                #expect(activation.secretSettingKeys == ["skill:report-agent#API_TOKEN"])

                try env.importUpdate(Self.package(version: "2.0.0"))
                #expect(activation.secretSettingKeys.isEmpty)
                #expect(!persistence.secretExists(key: "API_TOKEN", skillID: namespace))

                // The journal: recorded before the save, spared while a live
                // activation records the key again, cleaned otherwise.
                let outbox = PluginSecretCleanupOutbox(fileURL: env.root.appendingPathComponent("PluginSecretCleanup.json"))
                let stale = PluginUpdateService.StaleSecret(key: "API_TOKEN", skillID: namespace)
                var recorded: [PluginUpdateService.StaleSecret] = []
                #expect(persistence.saveSecretValue("again", key: "API_TOKEN", skillID: namespace, skillName: "", allowUserInteraction: false))
                WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:report-agent#API_TOKEN", on: activation)
                #expect(PluginSecretCleanupOutbox.deleteThenClean([], keys: [stale], modelContext: env.context, outbox: outbox) {
                    recorded = (try? outbox.pendingKeys()) ?? []
                    return true
                })
                #expect(recorded == [stale])
                #expect(persistence.secretExists(key: "API_TOKEN", skillID: namespace))
                WorkspaceCapabilityActivation.setSecretRecorded(false, forKey: "skill:report-agent#API_TOKEN", on: activation)
                try outbox.writeEntries(["\(namespace.uuidString)#API_TOKEN"])
                PluginSecretCleanupOutbox.resumePending(modelContext: env.context, outbox: outbox)
                #expect(!persistence.secretExists(key: "API_TOKEN", skillID: namespace))
                #expect(try outbox.entries().isEmpty)
            }
        }
    }

    @Test("Update keeps a plugin template the person edited as their own and writes the definition's beside it")
    func editedTemplateSurvivesUpdate() throws {
        let env = try Environment()
        var v1 = Self.package(version: "1.0.0")
        v1.templates = [Self.template("Weekly", goal: "Write it"), Self.template("Daily", goal: "Note it")]
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        #expect(activation.templateDigests.count == 2)
        let weekly = try #require(env.workspace.templates.first { $0.name == "Weekly" })
        let daily = try #require(env.workspace.templates.first { $0.name == "Daily" })
        weekly.mainGoal = "Write it my way"

        var v2 = Self.package(version: "2.0.0")
        v2.templates = [Self.template("Weekly", goal: "Write it better"), Self.template("Daily", goal: "Note it well")]
        try env.importUpdate(v2)
        // The edited row is the person's now; the unedited one follows.
        #expect(weekly.mainGoal == "Write it my way")
        #expect(weekly.originPackageID == nil)
        #expect(daily.mainGoal == "Note it well")
        #expect(daily.originPackageID == v2.id)
        #expect(env.workspace.templates.contains { $0.name == "Weekly" && $0.mainGoal == "Write it better" && $0.originPackageID == v2.id })
        #expect(PluginTemplateSync.isInSync(v2, in: env.workspace))

        // The workspace's own mirror keeps the digests, so recovery still
        // tells an edit from the plugin's own content.
        let config = try #require(WorkspaceConfigManager.export(workspace: env.workspace, modelContext: env.context))
        #expect(config.installedPlugins?.first { $0.id == v2.id }?.templateDigests == activation.templateDigests)
    }

    @Test("Update never takes over a template the person authored under the same name")
    func authoredTemplateIsNotTakenOver() throws {
        let env = try Environment()
        let mine = TaskTemplate(name: "Weekly", mainGoal: "My own goal", workspace: env.workspace, icon: "doc", templateDescription: "mine")
        env.context.insert(mine)
        try env.context.save()
        var v1 = Self.package(version: "1.0.0")
        v1.templates = [Self.template("Weekly", goal: "Plugin goal")]
        try env.install(v1)
        #expect(mine.mainGoal == "My own goal")
        #expect(mine.originPackageID == nil)
        #expect(env.workspace.templates.filter { $0.name == "Weekly" }.count == 2)
    }

    @Test("A full replaces identity matches however it is spelled")
    func replacesIsCanonicalized() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        var v2 = Self.package(version: "2.0.0")
        v2.skills[0].id = "summary-agent"
        v2.skills[0].replaces = ["skill:Report Agent"]
        try env.importUpdate(v2)
        #expect(activation.configuration(forComponent: "skill:summary-agent") == ["PROJECT": "alpha"])
    }

    @Test("An automatic rename that releases nothing else is saved even when the pass holds back")
    func automaticRenameIsPersisted() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        let account = try #require(activation.bindings.first?.account)
        var v2 = Self.package(version: "2.0.0")
        v2.connectors[0].id = "tracker"
        v2.connectors[0].replaces = ["connector:tracker:tracker-api"]
        v2.localTools = []
        try env.importUpdate(v2, mode: .automatic)
        #expect(activation.recordedVersion == "1.0.0")
        #expect(activation.accounts(forComponent: "connector:tracker:tracker").map(\.id) == [account.id])
        #expect(!env.context.hasChanges)
    }

    @Test("Update adds the credential keys a kept connector now declares to the accounts the plugin created")
    func ownedAccountsFollowTheDefinition() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first)
        account.baseURL = "https://mine.example.com"
        try env.context.save()
        var v2 = Self.package(version: "2.0.0")
        v2.connectors[0].credentialHints.append(.init(key: "TRACKER_SECRET", hint: "Secret"))
        v2.connectors[0].description = "Tracker v2"
        try env.importUpdate(v2)
        #expect(account.credentialKeys.contains("TRACKER_SECRET"))
        #expect(account.connectorDescription == "Tracker v2")
        #expect(account.baseURL == "https://mine.example.com")
    }

    @Test("The delete confirmation names every workspace the deletion reaches")
    func deleteReachIncludesSharedListings() throws {
        let env = try Environment()
        let package = Self.package(version: "1.0.0")
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)
        let other = Workspace(name: "Listing", primaryPath: "/tmp/plugin-ops-listing")
        env.context.insert(other)
        WorkspaceCapabilityActivation.mutate(other) { $0.enableGlobalConnector(account.id.uuidString) }
        try env.context.save()
        #expect(try Set(PluginOperations.workspacesUsing(account).map(\.id)) == [env.workspace.id, other.id])
    }

    @Test("Dropping the component whose account is the service default promotes another account")
    func droppedDefaultIsPromoted() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        var other = Self.package(version: "1.0.0")
        other.id = "ops.other"
        other.skills[0].name = "Other Agent"
        other.connectors[0].name = "Other Tracker"
        other.localTools = []
        try env.install(other)
        let firstAccount = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace)?.bindings.first?.account)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "tracker", in: env.workspace)?.id == firstAccount.id)

        var v2 = Self.package(version: "2.0.0")
        v2.connectors = []
        try env.importUpdate(v2)
        let otherAccount = try #require(WorkspaceCapabilityActivation.activation(for: other.id, in: env.workspace)?.bindings.first?.account)
        #expect(WorkspaceCapabilityActivation.defaultAccount(forService: "tracker", in: env.workspace)?.id == otherAccount.id)
    }

    @Test("A component may list a chain of predecessors; two that both still hold state are refused")
    func predecessorChains() throws {
        var chained = Self.package(version: "3.0.0")
        chained.skills[0].id = "c-agent"
        chained.skills[0].replaces = ["report-agent", "b-agent"]
        #expect(PluginUpdateService.replacesProblems(in: chained).isEmpty)

        // A straight to C: A's settings move.
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        try PluginOperations.setSetting("PROJECT", to: "alpha", of: v1.skills[0], pluginID: v1.id, in: env.workspace, modelContext: env.context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        try env.importUpdate(chained)
        #expect(activation.configuration(forComponent: "skill:c-agent") == ["PROJECT": "alpha"])

        // Both A and B holding state: Update refuses and nothing changes.
        let twoLive = try Environment()
        var ab = Self.package(version: "1.0.0")
        var b = ab.skills[0]
        b.id = "b-agent"
        b.name = "B Agent"
        ab.skills.append(b)
        try twoLive.install(ab)
        for skill in ab.skills {
            try PluginOperations.setSetting("PROJECT", to: skill.name, of: skill, pluginID: ab.id, in: twoLive.workspace, modelContext: twoLive.context)
        }
        let twoActivation = try #require(WorkspaceCapabilityActivation.activation(for: ab.id, in: twoLive.workspace))
        #expect(throws: PluginUpdateService.UpdateError.ambiguousRename(component: "skill:c-agent")) {
            try PluginUpdateService.reconcileAll(modelContext: twoLive.context, packages: [chained], mode: .release, approvalRecords: PluginOperationsTests.approvals([chained]))
        }
        #expect(twoActivation.recordedVersion == "1.0.0")
        #expect(twoActivation.configuration(forComponent: "skill:report-agent") == ["PROJECT": "Report Agent"])
    }

    @Test("An account whose sign-in method the new version no longer declares needs a step")
    func droppedAuthMethodNeedsReconnect() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first)
        var v2 = Self.package(version: "2.0.0")
        v2.connectors[0].authMethod = "oauth"
        try env.importUpdate(v2)
        #expect(account.authMethod == "bearer")
        let state = CapabilityPackageState(package: v2, workspace: env.workspace, capabilities: WorkspaceCapabilities(workspace: env.workspace, packageDefinitions: [v2]))
        #expect(state.attentionMessages(for: account).contains { $0.contains("reconnect") })
        #expect(state.connectorsNeedingAttention.map(\.id) == [account.id])
        // The plugin's own state says so too, not only the component's.
        #expect(state.readiness.level == .needsAttention)
        #expect(state.readiness.messages.contains { $0.contains("reconnect") })
    }

    @Test("Update is refused, before anything changes, when a workspace with the plugin would refuse it")
    func updatePreflightsEveryActivation() throws {
        let env = try Environment()
        let v1 = Self.package(version: "1.0.0")
        try env.install(v1)
        var v2 = Self.package(version: "2.0.0")
        v2.requires = ["not-installed-plugin"]
        v2.connectors = []
        try env.library.install(v2, sourceMetadata: .builtIn())
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        #expect(throws: PluginUpdateService.UpdateError.self) {
            try CapabilityCatalogActionService(library: env.library).update(v2, modelContext: env.context)
        }
        #expect(activation.recordedVersion == "1.0.0")
        #expect(!activation.bindings.isEmpty)
    }

    @Test("A connector replaces identity is checked with the same service spelling as its component ID")
    func replacesServiceNormalization() {
        var package = Self.package(version: "2.0.0")
        package.connectors[0].serviceType = "Issue Tracker"
        package.connectors[0].id = "tracker"
        package.connectors[0].replaces = ["old"]
        #expect(PluginUpdateService.replacesProblems(in: package).isEmpty)
    }

    @Test("Two templates with one identity are refused")
    func duplicateTemplatesAreRefused() {
        var package = Self.package(version: "1.0.0")
        package.templates = [Self.template("Daily Report", goal: "a"), Self.template("daily-report", goal: "b")]
        let report = CapabilityPackageValidator.validate(package: package, installedPackages: [], checkPrerequisites: false)
        #expect(report.blockers.contains { $0.title == "Duplicate template" })
    }

    @Test("A manifest component keeps its identity through a rename that keeps its id, and a round trip changes nothing")
    func manifestComponentIDsAreTheIdentity() throws {
        let gcloud = try #require(PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" })
        let first = PluginManifestConverter.manifest(from: gcloud)
        let roundTrip = try PluginManifestConverter.checkedPackage(from: first)
        #expect(try CapabilityApprovalDigest.digest(for: roundTrip) == CapabilityApprovalDigest.digest(for: gcloud))

        // Skills, connectors and tools carry their id; a setup component's
        // comes back derived (its requirement's ID or its name's slug), so a
        // renamed CLI check is a different component and is not renamed here.
        var renamed = first
        for index in renamed.components.indices where [.skill, .connector, .tool].contains(renamed.components[index].kind) {
            renamed.components[index].name += " renamed"
            renamed.components[index].skill?.name += " renamed"
            renamed.components[index].connector?.name += " renamed"
            renamed.components[index].tool?.name += " renamed"
        }
        let next = try PluginManifestConverter.checkedPackage(from: renamed)
        #expect(next.skills.map(CapabilityResourceOrigin.componentID(for:)) == gcloud.skills.map(CapabilityResourceOrigin.componentID(for:)))
        #expect(next.connectors.map(CapabilityResourceOrigin.componentID(for:))
            == gcloud.connectors.map(CapabilityResourceOrigin.componentID(for:)))
        // A tool's name-derived identity includes its type and command; the
        // renamed one carries an id and replaces that form.
        #expect(!gcloud.localTools.isEmpty)
        for (before, after) in zip(gcloud.localTools, next.localTools) {
            #expect(after.replaces?.contains(CapabilityResourceOrigin.componentID(for: before)) == true)
        }
    }

    @Test("An Update whose installed copy can't be copied aside is refused and leaves the installed copy")
    func updateNeedsARestorableSnapshot() throws {
        let env = try Environment()
        try env.library.install(Self.package(version: "1.0.0"), sourceMetadata: .localLibrary())
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: SnapshotRefusingFileManager())
        let report = CapabilityPackageValidator.validate(
            package: Self.package(version: "2.0.0"), installedPackages: library.installedPackages(), checkPrerequisites: false
        )
        #expect(throws: CapabilityPackageSnapshotUnavailable(packageID: "ops.report")) {
            try CapabilityPackageImporter(library: library).importValidatedPackage(report, modelContext: env.context)
        }
        #expect(env.library.installedPackage(id: "ops.report")?.version == "1.0.0")
    }

    /// Fails only the copy that sets an installed package aside.
    final class SnapshotRefusingFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            if dstURL.path.contains("astra-capability-snapshot-") { throw CocoaError(.fileWriteNoPermission) }
            try super.copyItem(at: srcURL, to: dstURL)
        }
    }

    @Test("An MCP server ID another installed plugin declares is refused")
    func mcpServerIDsAreUniqueAcrossPlugins() {
        var installed = Self.package(version: "1.0.0")
        installed.mcpServers = [PluginMCPServer(id: "tracker", displayName: "Tracker", transport: .stdio, command: "tracker-mcp")]
        var incoming = Self.package(version: "1.0.0")
        incoming.id = "ops.other"
        incoming.mcpServers = installed.mcpServers
        let report = CapabilityPackageValidator.validate(package: incoming, installedPackages: [installed], checkPrerequisites: false)
        #expect(report.issues.contains { $0.code == .duplicateMCPServerID })
        #expect(!report.canInstall)
    }

    @Test("A Remove of a plugin no workspace added is finished; one the library refuses stays pending")
    func removeJournalEdgeCases() throws {
        let env = try Environment()
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        let package = Self.package(version: "1.0.0")
        try env.library.install(package, sourceMetadata: .localLibrary())
        try journal.begin(package.id)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(env.library.installedPackage(id: package.id) == nil)
        #expect(try journal.pending().isEmpty)

        // The library refuses to delete a built-in: the intent is kept.
        let builtIn = try #require(PluginCatalog.builtInPackages.first)
        try env.library.install(builtIn, sourceMetadata: .builtIn())
        try journal.begin(builtIn.id)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(try journal.pending() == [builtIn.id])

        // A journal that can't be read is never rewritten: a new Remove
        // refuses to start, and launch leaves the file as it is.
        let unreadable = Data("not json".utf8)
        try unreadable.write(to: journal.fileURL)
        #expect(throws: (any Error).self) { try journal.begin(package.id) }
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        journal.finish(builtIn.id)
        #expect(try Data(contentsOf: journal.fileURL) == unreadable)
    }

    @Test("Deleting an account refreshes the mirror of every workspace that used it")
    func deleteAccountExportsAffectedWorkspaces() async throws {
        let env = try Environment()
        let folder = env.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        env.workspace.primaryPath = folder.path
        let package = Self.package(version: "1.0.0")
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)
        let accountID = account.id.uuidString
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        func mirrorNamesAccount() -> Bool? {
            guard let config = try? WorkspaceConfigManager.loadConfig(from: mirror) else { return nil }
            let connectors: [String] = (config.connectors ?? []).compactMap(\.id)
            let bound: [String] = (config.installedPlugins ?? []).flatMap { $0.accounts ?? [] }.map(\.connectorID)
            return connectors.contains(accountID) || bound.contains(accountID)
        }
        // The mirror is written off the main actor: wait for Add's.
        for _ in 0..<500 where mirrorNamesAccount() != true { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(mirrorNamesAccount() == true)

        try PluginOperations.deleteAccount(account, modelContext: env.context)
        for _ in 0..<500 where mirrorNamesAccount() != false { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(mirrorNamesAccount() == false)
    }

    // MARK: - Fixtures

    static func template(_ name: String, goal: String) -> PluginTemplate {
        PluginTemplate(
            name: name, icon: "doc", description: name, mainGoal: goal,
            beforeGoal: "", afterGoal: "", mainBudget: 1000, beforeBudget: 0,
            afterBudget: 0, variablesJSON: "[]", passContextToMain: true,
            passContextToAfter: true
        )
    }

    /// An approval of each of `packages` as it is: a local plugin read back
    /// from the library is a draft until one covers its digest.
    static func approvals(_ packages: [PluginPackage]) -> [CapabilityApprovalRecord] {
        packages.map { package in
            CapabilityApprovalRecord(
                packageID: package.id, packageVersion: package.version, status: .approved, approvedBy: "Tests",
                approvedAt: Date(), reviewNotes: "", sourceDigest: (try? CapabilityApprovalDigest.digest(for: package)) ?? ""
            )
        }
    }

    static func package(version: String) -> PluginPackage {
        PluginPackage(
            id: "ops.report",
            name: "Reports",
            icon: "doc.text",
            description: "Weekly reports",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: version,
            skills: [PluginSkill(
                name: "Report Agent", icon: "doc.text", description: "Writes reports",
                allowedTools: ["Read"], disallowedTools: [], customTools: [],
                behaviorInstructions: "Write the weekly report.",
                environmentKeys: ["PROJECT"], environmentValues: ["default-project"]
            )],
            connectors: [PluginConnector(
                name: "Tracker API", serviceType: "tracker", icon: "network", description: "Tracker",
                baseURL: "https://tracker.example.com", authMethod: "bearer",
                credentialHints: [.init(key: "TRACKER_TOKEN", hint: "Token")],
                configHints: [], notes: ""
            )],
            localTools: [PluginLocalTool(
                name: "report-cli", description: "Report CLI", icon: "terminal",
                toolType: "cli", command: "report-cli", arguments: ""
            )],
            templates: [],
            governance: .builtInApproved(riskLevel: .low)
        )
    }

    @MainActor
    struct Environment {
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let root: URL
        let library: CapabilityLibrary
        let installer: CapabilityInstaller

        static var retained: [ModelContainer] = []

        init() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-plugin-ops-\(UUID().uuidString)", isDirectory: true)
            let workspaceURL = rootURL.appendingPathComponent("Workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            Self.retained.append(container)
            context = container.mainContext
            workspace = Workspace(name: "Ops", primaryPath: workspaceURL.path)
            context.insert(workspace)
            root = rootURL
            library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
            installer = CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
        }

        func install(_ package: PluginPackage) throws {
            try installer.install(package, into: workspace, modelContext: context, announceCatalogMutation: false)
        }

        /// What an import of a newer version does: refuse it if a workspace
        /// would, replace the library entry, reconcile every activation.
        func importUpdate(_ package: PluginPackage, mode: PluginUpdateService.Mode = .release) throws {
            if let refusal = PluginUpdateService.refusals(for: package, modelContext: context, approvalRecords: []).first {
                throw refusal
            }
            try library.install(package, sourceMetadata: .builtIn())
            try PluginUpdateService.reconcileAll(modelContext: context, packages: library.installedPackages(), mode: mode, approvalRecords: PluginOperationsTests.approvals(library.installedPackages()))
        }
    }
}
