import Foundation
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Template IDs survive Remove and Add again, and every plugin-state save
/// writes the mirrors it changed. Fixtures are `PluginOperationsTests`'s.
@Suite("Plugin template IDs and post-save mirrors")
@MainActor
struct PluginTemplateIDsAndMirrorsTests {
    typealias Fixtures = PluginOperationsTests

    static func packageWithTemplate() -> PluginPackage {
        var package = Fixtures.package(version: "1.0.0")
        package.templates = [PluginTemplate(
            name: "Weekly", icon: "doc.text", description: "Weekly report", mainGoal: "Write the weekly report",
            beforeGoal: "", afterGoal: "", mainBudget: 1000, beforeBudget: 0, afterBudget: 0, variablesJSON: "[]",
            passContextToMain: true, passContextToAfter: false
        )]
        return package
    }

    @Test("A schedule on a plugin template resolves again after Remove and Add; an authored template stays untouched")
    func templateIDSurvivesReinstall() throws {
        let env = try Fixtures.Environment()
        let package = Self.packageWithTemplate()
        // The person's own template, named like the plugin's.
        let authored = TaskTemplate(name: "Weekly", mainGoal: "My own goal", workspace: env.workspace, icon: "star", templateDescription: "")
        env.context.insert(authored)
        try env.context.save()
        try env.install(package)
        let stamped = try #require(env.workspace.templates.first { $0.originPackageID == package.id })
        let templateID = stamped.id
        let schedule = TaskSchedule(name: "Weekly run", goal: "Report", workspace: env.workspace)
        schedule.templateID = templateID
        env.context.insert(schedule)
        try env.context.save()

        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)
        #expect(!env.workspace.templates.contains { $0.id == templateID })
        #expect(WorkspaceCapabilityActivation.retainedTemplateIDs(of: package.id, in: env.workspace) == [
            CapabilityResourceOrigin.componentID(for: package.templates[0]): templateID
        ])

        try env.install(package)
        let back = try #require(env.workspace.templates.first { $0.id == schedule.templateID })
        #expect(back.originPackageID == package.id && back.mainGoal == "Write the weekly report")
        #expect(authored.mainGoal == "My own goal" && authored.originPackageID == nil)
        #expect(env.workspace.templates.filter { !$0.isDeleted }.count == 2)
    }

    /// Two workspaces, each with a mirror folder: the plugin's own, and one
    /// whose other plugin binds the account the first one created.
    @Test("Every plugin-state save writes the mirrors it changed: setting, Add account, Make default, account edit")
    func everyPluginStateSaveWritesItsMirrors() throws {
        let env = try Fixtures.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        func folder(_ name: String) throws -> String {
            let url = env.root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        env.workspace.primaryPath = try folder("own")
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)
        let other = Workspace(name: "Other", primaryPath: try folder("other"))
        env.context.insert(other)
        var otherPlugin = Fixtures.package(version: "1.0.0")
        otherPlugin.id = "ops.other"
        try env.installer.install(otherPlugin, into: other, modelContext: env.context, announceCatalogMutation: false)
        let otherActivation = try #require(WorkspaceCapabilityActivation.activation(for: otherPlugin.id, in: other))
        WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: otherPlugin.connectors[0]), of: otherActivation)
        try env.context.save()
        func mirror(_ workspace: Workspace) throws -> String {
            try String(contentsOfFile: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath), encoding: .utf8)
        }
        func plugin(in workspace: Workspace, _ id: String) throws -> WorkspaceConfigManager.InstalledPluginRef? {
            try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath)))
                .installedPlugins?.first { $0.id == id }
        }
        let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])

        // A setting.
        try PluginOperations.setSetting("PROJECT", to: "mirrored-project", of: package.skills[0], package: package, in: env.workspace, modelContext: env.context)
        #expect(try mirror(env.workspace).contains("mirrored-project"))
        // Add account, then Make default.
        let second = try PluginOperations.addAccount(for: package.connectors[0], of: package, in: env.workspace, modelContext: env.context)
        #expect(try plugin(in: env.workspace, package.id)?.accounts?.contains { $0.connectorID == second.id.uuidString } == true)
        try PluginOperations.makeDefault(second, componentID: componentID, package: package, in: env.workspace, modelContext: env.context)
        #expect(try plugin(in: env.workspace, package.id)?.accounts?.first { $0.connectorID == second.id.uuidString }?.isDefault == true)
        // An edit of the account itself reaches the other workspace's mirror too.
        account.name = "Renamed Tracker"
        try env.context.save()
        #expect(PluginStateMirrors.exportAfterSave(workspace: env.workspace, accounts: [account], modelContext: env.context))
        #expect(try mirror(other).contains("Renamed Tracker"))
        #expect(try mirror(env.workspace).contains("Renamed Tracker"))
    }

    @Test("Remove keeps a template the person edited as theirs, under its ID; Add again doesn't replace it")
    func editedTemplateSurvivesRemove() throws {
        let env = try Fixtures.Environment()
        var package = Self.packageWithTemplate()
        var second = package.templates[0]
        second.name = "Monthly"
        second.mainGoal = "Write the monthly report"
        package.templates.append(second)
        try env.install(package)
        let weekly = try #require(env.workspace.templates.first { $0.name == "Weekly" })
        let monthly = try #require(env.workspace.templates.first { $0.name == "Monthly" })
        let monthlyID = monthly.id
        // Edited before any Update looked at it.
        weekly.mainGoal = "Write it my way"
        try env.context.save()

        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)
        #expect(env.workspace.templates.contains { $0 === weekly })
        #expect(weekly.originPackageID == nil && weekly.mainGoal == "Write it my way")
        #expect(!env.workspace.templates.contains { $0.id == monthlyID && !$0.isDeleted })

        try env.install(package)
        // The person's row keeps its ID and content; the plugin's Weekly is a
        // new row beside it, and Monthly is back under its old ID.
        #expect(weekly.originPackageID == nil && weekly.mainGoal == "Write it my way")
        let pluginWeekly = try #require(env.workspace.templates.first { $0.name == "Weekly" && $0.originPackageID == package.id })
        #expect(pluginWeekly.id != weekly.id)
        #expect(env.workspace.templates.contains { $0.id == monthlyID && $0.originPackageID == package.id })
    }

    @Test("Remove deletes a draft staged beside the plugin, and so does an interrupted Remove at launch")
    func removeDeletesStagedDraft() throws {
        let env = try Fixtures.Environment()
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals", isDirectory: true))
        func installAndStage() throws {
            try env.install(Fixtures.package(version: "1.0.0"))
            _ = try approvals.save(package: try #require(env.library.installedPackage(id: "ops.report")), status: .approved, approvedBy: "Tests")
            let report = CapabilityPackageValidator.validate(
                package: Fixtures.package(version: "2.0.0"), installedPackages: env.library.installedPackages(), checkPrerequisites: false
            )
            #expect(try CapabilityPackageImporter(library: env.library)
                .importValidatedPackage(report, modelContext: env.context, approvalRecords: approvals.records()).staged)
            #expect(env.library.stagedPackage(id: "ops.report") != nil)
        }
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        try installAndStage()
        try CapabilityUninstaller(library: env.library).remove(Fixtures.package(version: "1.0.0"), modelContext: env.context, removeJournal: journal)
        #expect(env.library.stagedPackage(id: "ops.report") == nil)
        #expect(try journal.pending().isEmpty)

        // Saved, then the quit came before the library and the staged draft went.
        try installAndStage()
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0 = WorkspaceCapabilityActivationState() }
        try env.context.save()
        try journal.begin("ops.report")
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(env.library.stagedPackage(id: "ops.report") == nil)
        #expect(env.library.installedPackage(id: "ops.report") == nil)
        #expect(try journal.pending().isEmpty)
    }
}
