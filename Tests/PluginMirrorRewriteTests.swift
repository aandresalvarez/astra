import Foundation
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// An Update or a Remove that clears Keychain data or provenance rewrites
/// every mirror it changed, synchronously, before that cleanup settles; a
/// definition awaiting its review is reconciled but not accepted. Fixtures
/// are `PluginOperationsTests`'s.
@Suite("Plugin mirror rewrites and review")
@MainActor
struct PluginMirrorRewriteTests {
    typealias Fixtures = PluginOperationsTests

    /// A second workspace whose own plugin binds the account `ops.report`
    /// created in the fixture's workspace: its mirror carries that account.
    static func sharedAccount(in env: Fixtures.Environment) throws -> (other: Workspace, account: Connector) {
        try env.install(Fixtures.package(version: "1.0.0"))
        let account = try #require(env.workspace.connectors.first)
        let other = Workspace(name: "Other", primaryPath: env.root.appendingPathComponent("other").path)
        env.context.insert(other)
        var otherPlugin = Fixtures.package(version: "1.0.0")
        otherPlugin.id = "ops.other"
        otherPlugin.name = "Other"
        try env.installer.install(otherPlugin, into: other, modelContext: env.context, announceCatalogMutation: false)
        let otherActivation = try #require(WorkspaceCapabilityActivation.activation(for: otherPlugin.id, in: other))
        WorkspaceCapabilityActivation.bind(
            account, toComponent: CapabilityResourceOrigin.componentID(for: otherPlugin.connectors[0]), of: otherActivation
        )
        try env.context.save()
        #expect(try WorkspaceConfigManager.workspacesMirroring(
            accountIDs: [account.id], among: [env.workspace, other], modelContext: env.context
        ).map(\.id) == [env.workspace.id, other.id])
        return (other, account)
    }

    @Test("An Update rewrites the mirror of every workspace carrying an account it changed")
    func updateRewritesEveryMirrorOfAChangedAccount() throws {
        let env = try Fixtures.Environment()
        let (other, account) = try Self.sharedAccount(in: env)
        var v2 = Fixtures.package(version: "2.0.0")
        v2.connectors[0].description = "Tracker, version 2"
        try env.library.install(v2, sourceMetadata: .builtIn())
        // Only ops.report is reconciled: the other workspace isn't one it changes.
        let packages = env.library.installedPackages().filter { $0.id == v2.id }

        var rewritten: [UUID] = []
        try PluginUpdateService.reconcileAll(
            modelContext: env.context, packages: packages, mode: .release,
            approvalRecords: Fixtures.approvals(packages), rewriteMirror: { rewritten.append($0.id); return true }
        )
        #expect(account.connectorDescription == "Tracker, version 2")
        #expect(Set(rewritten) == [env.workspace.id, other.id])
    }

    @Test("A Remove journals and rewrites every workspace carrying an account whose provenance it releases")
    func removeJournalsEveryMirrorOfAReleasedAccount() throws {
        let env = try Fixtures.Environment()
        let (other, account) = try Self.sharedAccount(in: env)
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        // The mirror of the fixture's workspace can't be written, so the
        // intent stays to be read.
        let folder = env.root.appendingPathComponent("blocked-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.workspace.primaryPath = folder.path
        let mirrorURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirrorURL, withIntermediateDirectories: true)

        try CapabilityUninstaller(library: env.library).remove(
            Fixtures.package(version: "1.0.0"), modelContext: env.context, removeJournal: journal
        )
        #expect(account.originPackageID == nil)
        let intent = try #require(try journal.intents().first)
        #expect(Set(intent.workspaceIDs ?? []) == [env.workspace.id, other.id])
    }

    /// An Update that releases a skill's secret namespace, on a store with a
    /// cleanup outbox.
    @Test("An Update cleans released secrets only after every mirror is rewritten, and launch rewrites them first")
    func releasedSecretsWaitForMirrorRewrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
        )
        Fixtures.Environment.retained.append(container)
        let context = container.mainContext
        let workspace = Workspace(name: "Ops", primaryPath: root.appendingPathComponent("workspace").path)
        context.insert(workspace)
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        var v1 = Fixtures.package(version: "1.0.0")
        var second = v1.skills[0]
        second.id = "summary-agent"
        second.name = "Summary Agent"
        v1.skills.append(second)
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .install(v1, into: workspace, modelContext: context, announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        let released = PluginRuntimeProjection.derivedID(of: activation, componentID: "skill:summary-agent")
        let outbox = try #require(PluginSecretCleanupOutbox(for: context))

        var v2 = v1
        v2.version = "2.0.0"
        v2.skills.removeLast()
        try library.install(v2, sourceMetadata: .builtIn())
        let packages = library.installedPackages()
        // The cleanup is still owed while the mirrors are rewritten; one
        // that can't be written keeps it.
        var owedDuringRewrite = false
        var pendingOperation: UUID?
        do {
            try PluginUpdateService.reconcileAll(
                modelContext: context, packages: packages, mode: .release, secrets: AcceptingSkillDeletes.self,
                approvalRecords: Fixtures.approvals(packages),
                rewriteMirror: { _ in
                    owedDuringRewrite = (try? outbox.pending())?.contains(released) ?? false
                    return false
                }
            )
        } catch let problem as PluginOperationProblem {
            if case .savedRecoveryPending(let id) = problem { pendingOperation = id }
            else { throw problem }
        }
        #expect(pendingOperation != nil)
        #expect(owedDuringRewrite)
        #expect(activation.recordedVersion == "2.0.0")
        #expect(try outbox.pending() == [released])

        // Launch rewrites every mirror before it cleans, and waits while one fails.
        PluginSecretCleanupOutbox.resumePending(
            modelContext: context, outbox: outbox, secrets: AcceptingSkillDeletes.self, rewriteMirror: { _ in false }
        )
        #expect(try outbox.pending() == [released])
        let resumed = PluginOperationRecovery.resumePending(modelContext: context, only: try #require(pendingOperation), export: { _, _ in true })
        #expect(resumed.completed == 1 && resumed.deferred == 0)
        var rewritten: [UUID] = []
        PluginSecretCleanupOutbox.resumePending(modelContext: context, outbox: outbox, secrets: AcceptingSkillDeletes.self, rewriteMirror: {
            rewritten.append($0.id)
            return true
        })
        #expect(rewritten == [workspace.id])
        #expect(try outbox.pending().isEmpty)
    }

    /// An imported local version is a draft until approved: the person's
    /// import reconciles it, but the activation keeps running nothing new
    /// and offers Update until an approval covers that digest.
    @Test("A definition awaiting its review is reconciled but stays awaiting until approved")
    func draftDefinitionStaysAwaitingUntilApproved() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        try env.library.install(Fixtures.package(version: "2.0.0"), sourceMetadata: .builtIn())
        let packages = env.library.installedPackages()
        let v2 = try #require(packages.first { $0.id == "ops.report" })
        #expect(v2.governance.approvalStatus == .draft)
        #expect(PluginUpdateService.awaitsReview(v2, in: env.workspace, records: []))

        for mode in [PluginUpdateService.Mode.release, .automatic] {
            try PluginUpdateService.reconcileAll(modelContext: env.context, packages: packages, mode: mode, approvalRecords: [])
            #expect(activation.recordedVersion == "1.0.0")
            #expect(activation.awaitingUpdate)
        }
        // An approval of another digest doesn't cover it.
        var stale = Fixtures.approvals([v2])
        stale[0].sourceDigest = "another"
        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: packages, mode: .release, approvalRecords: stale)
        #expect(activation.awaitingUpdate)

        try PluginUpdateService.reconcileAll(
            modelContext: env.context, packages: packages, mode: .release, approvalRecords: Fixtures.approvals([v2])
        )
        #expect(activation.recordedVersion == "2.0.0")
        #expect(!activation.awaitingUpdate)
    }

    /// The automatic pass never takes other content under the version the
    /// activation accepted, even when it would release nothing: that is the
    /// person's to take, with Update.
    @Test("The automatic pass holds a definition changed under the same version as awaiting Update")
    func sameVersionContentChangeAwaitsUpdate() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        let accepted = activation.recordedDigest
        #expect(PluginDefinitionDigest.isContentDigest(accepted))
        var changed = Fixtures.package(version: "1.0.0")
        changed.skills[0].behaviorInstructions = "Write the weekly report, briefly."
        try env.library.install(changed, sourceMetadata: .builtIn())
        let packages = env.library.installedPackages()

        try PluginUpdateService.reconcileAll(
            modelContext: env.context, packages: packages, mode: .automatic, approvalRecords: Fixtures.approvals(packages)
        )
        #expect(activation.awaitingUpdate)
        #expect(activation.recordedDigest == accepted)
        #expect(PluginRuntimeProjection.runnable(packages, in: env.workspace).isEmpty)

        try PluginUpdateService.reconcileAll(
            modelContext: env.context, packages: packages, mode: .release, approvalRecords: Fixtures.approvals(packages)
        )
        #expect(!activation.awaitingUpdate)
        #expect(activation.recordedDigest == PluginDefinitionDigest.content(of: changed))
    }

    /// A shared account attached to a shared skill another workspace turned
    /// on is in that workspace's mirror (through the skill), with no plugin
    /// binding and no shared-list entry of its own.
    @Test("Deleting an account names and rewrites a workspace whose shared skill carries it")
    func deleteScopeIncludesSkillLinkedWorkspaces() throws {
        let env = try Fixtures.Environment()
        let account = Connector(name: "Shared Tracker", serviceType: "tracker", baseURL: "https://tracker.example.com", authMethod: "bearer")
        account.isGlobal = true
        let skill = Skill(name: "Shared Analyst", allowedTools: ["Read"])
        skill.isGlobal = true
        env.context.insert(account)
        env.context.insert(skill)
        account.skill = skill
        let linked = Workspace(name: "Linked", primaryPath: env.root.appendingPathComponent("linked").path)
        env.context.insert(linked)
        WorkspaceCapabilityActivation.mutate(linked) { $0.enableGlobalSkill(skill.id.uuidString) }
        try env.context.save()

        #expect(try PluginOperations.workspacesUsing(account).map(\.id) == [linked.id])
        var rewritten: [UUID] = []
        try PluginOperations.deleteAccount(account, modelContext: env.context) { rewritten.append($0.id); return true }
        #expect(rewritten == [linked.id])
    }

    /// A legacy account holds a promoted setting as plain text while the
    /// Keychain already has a newer value for it: Add again with another
    /// change keeps the Keychain's, and leaves the row's visible.
    @Test("Add again keeps a newer Keychain value over a legacy row's plain setting")
    func addKeepsANewerKeychainValue() throws {
        let env = try Fixtures.Environment()
        let package = PluginConnectorFieldTrustTests.importedPackage()
        try env.install(package)
        let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        let account = try #require(activation.accounts(forComponent: componentID).first)
        // The legacy shape: the setting is plain on the row.
        account.credentialKeys = ["TRACKER_TOKEN"]
        account.credentialValues = [""]
        account.configKeys = ["TRACKER_PROJECT"]
        account.configValues = ["ENG-1"]
        try env.context.save()

        var asked: [String] = []
        let installer = CapabilityInstaller(library: env.library, appVersion: SemanticVersion(1, 0, 0)) { connector, key in
            asked.append(key)
            return connector.id == account.id && key == "TRACKER_PROJECT" ? "ENG-2" : nil
        }
        try installer.install(
            package, into: env.workspace, modelContext: env.context,
            baseURLOverrides: [componentID: "https://tracker2.example.com"], announceCatalogMutation: false
        )
        let after = try #require(activation.accounts(forComponent: componentID).first)
        #expect(after.id == account.id && after.baseURL == "https://tracker2.example.com")
        #expect(asked == ["TRACKER_PROJECT"])
        // Not moved over the Keychain's value: still the row's, to settle.
        #expect(after.configValue("TRACKER_PROJECT") == "ENG-1")
        #expect(!after.credentialKeys.contains("TRACKER_PROJECT"))
        #expect(after.credentialKeys.count == after.credentialValues.count)
    }

    /// R1's binding alias (`AccountBinding.alias`) is the name a workspace
    /// knows an account by: a rename that merges two bindings of one
    /// account keeps it.
    @Test("A rename that merges an account's bindings keeps the alias it had")
    func renameMergeKeepsBindingAlias() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        let account = try #require(env.workspace.connectors.first)
        let old = "connector:tracker:tracker-api", new = "connector:tracker:tracker"
        WorkspaceCapabilityActivation.bind(account, toComponent: new, of: activation)
        for binding in activation.bindings { binding.alias = binding.componentID == old ? "Tracker 2" : "" }
        WorkspaceCapabilityActivation.moveComponentState(from: old, to: new, on: activation)
        let merged = activation.bindings.filter { !$0.isDeleted }
        #expect(merged.map(\.componentID) == [new])
        #expect(merged.first?.alias == "Tracker 2")
        #expect(WorkspaceCapabilityActivation.alias(of: account, in: env.workspace) == "Tracker 2")
    }

    @Test("Two MCP servers of one package can't share an ID")
    func duplicateMCPServerIDsInOnePackageAreBlocked() {
        var package = Fixtures.package(version: "1.0.0")
        package.mcpServers = [
            PluginMCPServer(id: "tracker", displayName: "Tracker", transport: .stdio, command: "tracker-mcp"),
            PluginMCPServer(id: " Tracker", displayName: "Tracker 2", transport: .stdio, command: "tracker-mcp-2")
        ]
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
        #expect(report.issues.contains { $0.code == .duplicateMCPServerID && $0.component == "tracker" })
        #expect(!report.canInstall)
        package.mcpServers.removeLast()
        #expect(!CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)
            .issues.contains { $0.code == .duplicateMCPServerID })
    }
}

/// Skill secrets with no values whose deletes all succeed.
private enum AcceptingSkillDeletes: SkillSecretPersisting {
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { true }
}
