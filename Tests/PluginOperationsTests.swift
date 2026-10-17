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
        #expect(PluginOperations.workspacesUsing(second).map(\.id) == [workspace.id])

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
        #expect(journal.pending().isEmpty)

        // Saved, then the exit came before the library entry went.
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0 = WorkspaceCapabilityActivationState() }
        try env.context.save()
        try journal.begin(package.id)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(env.library.installedPackage(id: package.id) == nil)
        #expect(journal.pending().isEmpty)
    }

    @Test("Import through the action service: a valid file is installed, a blocked one refused")
    func importThroughActionService() throws {
        let env = try Environment()
        let package = Self.package(version: "1.0.0")
        let data = try JSONEncoder().encode(package)
        let report = CapabilityPackageValidator.validate(data: data, installedPackages: [], checkPrerequisites: false)
        let service = CapabilityCatalogActionService(library: env.library)
        let result = try service.importPlugin(report, workspace: env.workspace, modelContext: env.context, traceID: "t")
        #expect(result.package.id == package.id)
        #expect(env.library.installedPackage(id: package.id) != nil)

        let blocked = CapabilityPackageValidator.validate(data: Data("{}".utf8), installedPackages: [], checkPrerequisites: false)
        #expect(throws: CapabilityPackageImportError.self) {
            try service.importPlugin(blocked, workspace: env.workspace, modelContext: env.context, traceID: "t")
        }
    }

    @Test("An admin's review records the status for this version's digest")
    func adminReviewRecordsStatus() throws {
        let env = try Environment()
        let store = CapabilityApprovalStore(directory: env.root.appendingPathComponent("approvals", isDirectory: true))
        let package = Self.package(version: "1.0.0")
        try CapabilityCatalogActionService(library: env.library)
            .setApprovalStatus(.blocked, for: package, workspace: env.workspace, approvalStore: store)
        let record = try #require(store.record(for: package))
        #expect(record.status == .blocked)
        #expect(record.sourceDigest == PluginUpdateService.digest(of: package))
    }

    @Test("A plugin that needs an account sign-in ASTRA can't do is listed without Add")
    func oauthPluginIsNotOffered() throws {
        let google = try #require(PluginCatalog.builtInPackages.first { $0.id == "google-workspace" })
        let reason = try #require(PluginsSurfacePresentation.unavailableReason(for: google))
        var input = PluginsSurfacePresentation.Input(
            package: google, isEnabled: false, pendingSteps: 0, isVisible: true, isRemovable: false
        )
        input.unavailableReason = reason
        let row = try #require(PluginsSurfacePresentation.makeState([input], query: "").available.first)
        #expect(row.verb == nil)
        #expect(row.subtitle == reason)
        #expect(PluginsSurfacePresentation.unavailableReason(for: Self.package(version: "1.0.0")) == nil)
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

        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: [v2], mode: .release)
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

    @Test("A component may take over one predecessor only")
    func onePredecessorPerComponent() {
        var package = Self.package(version: "2.0.0")
        package.skills[0].replaces = ["old-a", "old-b"]
        #expect(PluginUpdateService.replacesProblems(in: package).contains { $0.contains("more than one component") })
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
        #expect(journal.pending().isEmpty)

        // The library refuses to delete a built-in: the intent is kept.
        let builtIn = try #require(PluginCatalog.builtInPackages.first)
        try env.library.install(builtIn, sourceMetadata: .builtIn())
        try journal.begin(builtIn.id)
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(journal.pending() == [builtIn.id])
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
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            Self.retained.append(container)
            context = container.mainContext
            workspace = Workspace(name: "Ops", primaryPath: "/tmp/plugin-ops")
            context.insert(workspace)
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-plugin-ops-\(UUID().uuidString)", isDirectory: true)
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
            try PluginUpdateService.reconcileAll(modelContext: context, packages: library.installedPackages(), mode: mode)
        }
    }
}
