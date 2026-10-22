import Foundation
import os
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Plugins 2.0 R3 review fixes, round 10: what a withheld or off activation
/// must not run, what an earlier build left behind, and what a failed
/// rollback must not hide. Fixtures are `PluginOperationsTests`'s.
@Suite("Plugin activation review fixes")
@MainActor
struct PluginActivationReviewTests {
    typealias Fixtures = PluginOperationsTests

    @Test("An activation the automatic pass held back doesn't run until Update, here or in a queued launch")
    func withheldActivationDoesNotRun() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        let queued = WorkspaceCapabilityActivation.activations(of: env.workspace).map(PluginActivationRecord.init)
        var v2 = Fixtures.package(version: "2.0.0")
        v2.localTools = []
        try env.importUpdate(v2, mode: .automatic)
        #expect(activation.recordedVersion == "1.0.0")

        let library = env.library.installedPackages()
        func runs(_ workspace: Workspace) -> Bool {
            !PluginRuntimeProjection.project(workspace: workspace, packages: library, connectorMode: .runtimeCopies).skills.isEmpty
        }
        #expect(!runs(env.workspace))
        #expect(CapabilityRuntimeResourceMatcher.enabledPackages(for: env.workspace, in: library).allSatisfy { $0.id != v2.id })

        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: library, mode: .release, approvalRecords: PluginOperationsTests.approvals(library))
        #expect(activation.recordedVersion == "2.0.0")
        #expect(runs(env.workspace))
        #expect(CapabilityRuntimeResourceMatcher.enabledPackages(for: env.workspace, in: library).contains { $0.id == v2.id })
        // A legacy request without frozen definitions keeps its own acceptance:
        // the live Update cannot silently make its old settings runnable.
        let launch = Workspace(name: "Launch copy", primaryPath: env.workspace.primaryPath)
        launch.id = env.workspace.id
        WorkspaceCapabilityActivation.copyActivations(queued, of: env.workspace, to: launch, accountsByID: [:])
        #expect(!runs(launch))
    }

    @Test("A shared account is trimmed to its creator's installed definition while that plugin is off")
    func sharedAccountFollowsOffCreator() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.connectors[0].credentialHints.append(.init(key: "LEGACY_TOKEN", hint: "Legacy"))
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == v1.id })
        var other = Fixtures.package(version: "1.0.0")
        other.id = "ops.other"
        other.skills[0].name = "Other Agent"
        other.connectors[0].credentialHints = [.init(key: "TRACKER_TOKEN", hint: "Token"), .init(key: "LEGACY_TOKEN", hint: "Legacy")]
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(other.id) }
        let otherActivation = try #require(WorkspaceCapabilityActivation.activation(for: other.id, in: env.workspace))
        WorkspaceCapabilityActivation.bind(
            account, toComponent: CapabilityResourceOrigin.componentID(for: other.connectors[0]), of: otherActivation
        )
        try env.context.save()
        try env.importUpdate(Fixtures.package(version: "2.0.0"))
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs.removeAll { $0 == v1.id } }

        let projection = PluginRuntimeProjection.project(
            workspace: env.workspace, packages: [other], connectorMode: .runtimeCopies,
            definitions: env.library.installedPackages() + [other]
        )
        #expect(projection.connectors.map(\.id) == [account.id])
        #expect(projection.connectors.first?.credentialKeys == ["TRACKER_TOKEN"])
        #expect(account.credentialKeys == ["TRACKER_TOKEN", "LEGACY_TOKEN"])
    }

    @Test("A manifest whose payload repeats its component ID still replaces the name an earlier ASTRA keyed it by")
    func repeatedPayloadIDKeepsLegacyIdentity() throws {
        var manifest = PluginManifestConverter.manifest(from: Fixtures.package(version: "2.0.0"))
        for index in manifest.components.indices {
            switch manifest.components[index].kind {
            case .skill:
                manifest.components[index].id = "custom-agent"
                manifest.components[index].skill?.id = "custom-agent"
            case .connector:
                manifest.components[index].id = "custom-tracker"
                manifest.components[index].connector?.id = "custom-tracker"
            case .tool:
                manifest.components[index].id = "custom-cli"
                manifest.components[index].tool?.id = "custom-cli"
            default: break
            }
        }
        let package = try PluginManifestConverter.checkedPackage(from: manifest)
        #expect(package.skills[0].replaces == ["skill:report-agent"])
        #expect(package.connectors[0].replaces == ["connector:tracker:tracker-api"])
        #expect(package.localTools[0].replaces?.contains("tool:cli:report-cli:report-cli") == true)
        #expect(PluginUpdateService.replacesProblems(in: package).isEmpty)
    }

    @Test("An interrupted Remove whose library entry is unreadable moves the entry aside before finishing")
    func removeIntentSurvivesUnreadableEntry() throws {
        let env = try Fixtures.Environment()
        let journal = PluginRemoveJournal(fileURL: env.root.appendingPathComponent("PluginRemoveIntents.json"))
        try env.library.install(Fixtures.package(version: "1.0.0"), sourceMetadata: .localLibrary())
        try Data("not a package".utf8).write(to: env.library.packageURL(for: "ops.report"))
        #expect(env.library.installedPackage(id: "ops.report") == nil)
        try journal.begin("ops.report")

        // The unreadable entry is moved aside (it would block a reinstall
        // under its name), and only then is the Remove finished.
        PluginRemoveJournal.resumePending(modelContext: env.context, library: env.library, journal: journal)
        #expect(try journal.pending().isEmpty)
        #expect(!env.library.occupiedStorageNames().contains("ops-report") && !env.library.holdsUnreadableEntry(id: "ops.report"))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: env.library.quarantineDirectory.path)
        #expect(quarantined.count == 1 && quarantined[0].hasSuffix("ops-report.json"))
    }

    @Test("A secret declared again while its old value awaits deletion is cleared before the definition is taken")
    func redeclaredSecretSettlesItsPendingDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-redeclared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // An on-disk store: the cleanup outbox lives beside it.
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: root.appendingPathComponent("default.store"))]
        )
        Fixtures.Environment.retained.append(container)
        let context = container.mainContext
        let workspace = Workspace(name: "Ops", primaryPath: root.appendingPathComponent("workspace").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        context.insert(workspace)
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        let v1 = Fixtures.package(version: "1.0.0")
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .install(v1, into: workspace, modelContext: context, announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        let namespace = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:report-agent")
        // An earlier Update released API_TOKEN, and its delete failed.
        let outbox = try #require(PluginSecretCleanupOutbox(for: context))
        try outbox.writeEntries(["\(namespace.uuidString)#API_TOKEN"])

        var v2 = Fixtures.package(version: "2.0.0")
        v2.skills[0].environmentKeys.append("API_TOKEN")
        v2.skills[0].environmentValues.append("")
        try library.install(v2, sourceMetadata: .builtIn())
        let packages = library.installedPackages()
        let account = try #require(workspace.connectors.first)
        let accountVersion = account.originPackageVersion
        var checkedBeforeMutation = false
        SecretsRefusingDeletes.beforeDelete = { key, skillID in
            guard key == "API_TOKEN", skillID == namespace else { return }
            checkedBeforeMutation = true
            #expect(!context.hasChanges, "Secret cleanup admission must precede domain mutation")
            #expect(account.originPackageVersion == accountVersion)
        }
        defer { SecretsRefusingDeletes.beforeDelete = nil }
        #expect(throws: PluginUpdateService.UpdateError.secretCleanupPending(key: "API_TOKEN")) {
            try PluginUpdateService.reconcileAll(modelContext: context, packages: packages, mode: .release, secrets: SecretsRefusingDeletes.self, approvalRecords: PluginOperationsTests.approvals(packages))
        }
        SecretsRefusingDeletes.beforeDelete = nil
        #expect(checkedBeforeMutation)
        #expect(activation.recordedVersion == "1.0.0")
        #expect(!context.hasChanges)
        try PluginUpdateService.reconcileAll(modelContext: context, packages: packages, mode: .automatic, secrets: SecretsRefusingDeletes.self, approvalRecords: PluginOperationsTests.approvals(packages))
        #expect(activation.recordedVersion == "1.0.0")
        #expect(PluginRuntimeProjection.project(workspace: workspace, packages: packages).skills.isEmpty)
        #expect(try outbox.pendingKeys() == [.init(key: "API_TOKEN", skillID: namespace)])

        #expect(!context.hasChanges)
        try PluginUpdateService.reconcileAll(modelContext: context, packages: packages, mode: .release, secrets: SecretsAcceptingDeletes.self, approvalRecords: PluginOperationsTests.approvals(packages))
        #expect(activation.recordedVersion == "2.0.0")
        #expect(try outbox.pendingKeys().isEmpty)
    }

    @Test("A rename uses a fresh generation while old destination cleanup remains pending")
    func renameDestinationSettlesItsPendingCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-rename-dest-\(UUID().uuidString)", isDirectory: true)
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
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        context.insert(workspace)
        let library = CapabilityLibrary(directory: root.appendingPathComponent("Capabilities", isDirectory: true))
        let v1 = Fixtures.package(version: "1.0.0")
        try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0))
            .install(v1, into: workspace, modelContext: context, announceCatalogMutation: false)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: workspace))
        // An earlier version had a "Renamed Agent" whose Remove left its
        // namespace journaled: the delete failed.
        let destination = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:renamed-agent")
        let outbox = try #require(PluginSecretCleanupOutbox(for: context))
        try outbox.writeEntries([destination.uuidString])

        var v2 = Fixtures.package(version: "2.0.0")
        v2.skills[0].name = "Renamed Agent"
        v2.skills[0].replaces = ["skill:report-agent"]
        try library.install(v2, sourceMetadata: .builtIn())
        let packages = library.installedPackages()
        try PluginUpdateService.reconcileAll(modelContext: context, packages: packages, mode: .release,
            secrets: SecretsRefusingDeletes.self, approvalRecords: PluginOperationsTests.approvals(packages))
        #expect(activation.recordedVersion == "2.0.0")
        let current = PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:renamed-agent")
        #expect(current != destination)
        #expect(try outbox.entries().contains(destination.uuidString))
        PluginSecretCleanupOutbox.resumePending(modelContext: context, outbox: outbox, secrets: SecretsAcceptingDeletes.self)
        #expect(!(try outbox.entries()).contains(destination.uuidString))
    }

    @Test("A journaled rename destination is cleared whole, and stays journaled until that succeeds")
    func renameDestinationNamespaceIsClearedWhole() throws {
        let env = try Fixtures.Environment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-rename-whole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = PluginSecretCleanupOutbox(fileURL: root.appendingPathComponent("PluginSecretCleanup.json"))
        let destination = UUID()
        func settle(kept: Set<String> = [], cleans: Bool, deleted: inout [String], cleaned: inout [UUID]) -> Bool {
            PluginSecretCleanupOutbox.settleRenameDestination(
                destination, keys: ["DECLARED"], kept: kept, modelContext: env.context, outbox: outbox,
                clean: { cleaned.append($0); return cleans }
            ) { deleted.append($0); return true }
        }
        var deleted: [String] = [], cleaned: [UUID] = []
        // The earlier cleanup may have left keys the destination doesn't
        // declare: deleting the declared ones isn't enough to drop the intent.
        try outbox.writeEntries([destination.uuidString])
        #expect(!settle(cleans: false, deleted: &deleted, cleaned: &cleaned))
        #expect(try outbox.entries() == [destination.uuidString])
        #expect(settle(cleans: true, deleted: &deleted, cleaned: &cleaned))
        #expect(cleaned == [destination, destination] && deleted.isEmpty)
        #expect(try outbox.entries().isEmpty)
        // Secrets the activation records there keep the namespace: only
        // what isn't the person's is deleted.
        try outbox.writeEntries([destination.uuidString])
        #expect(settle(kept: ["KEPT"], cleans: false, deleted: &deleted, cleaned: &cleaned))
        #expect(deleted == ["DECLARED"] && cleaned.count == 2)
        #expect(try outbox.entries().isEmpty)
    }

    @Test("An import whose new library entry can't be read back fails and puts the previous version back")
    func importFailsWhenTheInstalledCopyIsUnreadable() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: HidingVersionFileManager(hidden: "2.0.0"))
        let update = CapabilityPackageValidator.validate(
            package: Fixtures.package(version: "2.0.0"), installedPackages: library.installedPackages(), checkPrerequisites: false
        )
        #expect(throws: CapabilityPackageInstallUnreadable(packageID: "ops.report")) {
            try CapabilityPackageImporter(library: library).importValidatedPackage(update, modelContext: env.context)
        }
        #expect(env.library.installedPackage(id: "ops.report")?.version == "1.0.0")
        #expect(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace)?.recordedVersion == "1.0.0")
    }

    @Test("An import that can't put the previous version back reports it, and keeps the copy")
    func importReportsAFailedRestore() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: RestoreBlockingFileManager(hidden: "2.0.0", library: env.library.directory))
        let update = CapabilityPackageValidator.validate(
            package: Fixtures.package(version: "2.0.0"), installedPackages: library.installedPackages(), checkPrerequisites: false
        )
        var operationID: UUID?
        do {
            _ = try CapabilityPackageImporter(library: library).importValidatedPackage(update, modelContext: env.context)
            Issue.record("The retargeted recovery root should be refused")
        } catch let problem as PluginOperationProblem {
            if case .commitUncertain(let id) = problem { operationID = id }
            else { throw problem }
        }
        let id = try #require(operationID)
        let journal = PluginFileOperationJournal(library: env.library, approvals: CapabilityApprovalStore())
        #expect(try journal.pendingIDs() == [id])
        let prepared = try journal.load(id)
        let oldBytes = try #require(prepared.manifest.entries.first { $0.name == "ops-report.json" }?.before?.files[""])
        let kept = try JSONDecoder().decode(PluginPackage.self, from: oldBytes)
        #expect(kept.version == "1.0.0")
        #expect(env.library.installedPackage(id: "ops.report") == nil)
        #expect(try PluginOperationCommit.read(id, container: env.container) == nil)
        #expect(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace)?.recordedVersion == "1.0.0")
    }

    @Test("Remove keeps a plugin template the person changed only in its models, hooks or default skills")
    func removeKeepsTemplatesEditedInOwnFields() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        package.templates = ["Models", "Hooks", "Skills", "Untouched"].map { Fixtures.template($0, goal: "Report") }
        try env.install(package)
        func row(_ name: String) throws -> TaskTemplate {
            try #require(env.workspace.templates.first { $0.name == name && !$0.isDeleted })
        }
        try row("Models").mainModel = "claude-opus"
        try row("Hooks").hooksJSON = #"{"stop":[]}"#
        try row("Skills").defaultSkillIDs = [UUID().uuidString]
        let kept = try ["Models", "Hooks", "Skills"].map(row)
        // Remove compares the person's saved template edits with the installed
        // definition; it must not commit an unrelated pending edit.
        try env.context.save()

        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)
        for template in kept {
            #expect(!template.isDeleted, "\(template.name)")
            #expect(template.originPackageID == nil, "\(template.name)")
        }
        #expect(env.workspace.templates.allSatisfy { $0.isDeleted || $0.name != "Untouched" })
    }

    @Test("A queued request an earlier build wrote, without template digests, still decodes")
    func legacyActivationRecordDecodes() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PluginActivationRecord(activation))) as? [String: Any])
        json.removeValue(forKey: "templateDigests")
        let decoded = try JSONDecoder().decode(PluginActivationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.templateDigests.isEmpty)
        #expect(decoded.id == activation.id)
        #expect(decoded.knownComponentIDs == activation.knownComponentIDs)
    }

    @Test("A failed private credential copy reports its key and preserves the saved activation")
    func updateReportsUnrestoredCopiedSecret() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.skills[0].environmentKeys = ["A_TOKEN", "B_TOKEN"]
        v1.skills[0].environmentValues = ["", ""]
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        var v2 = v1
        v2.version = "2.0.0"
        v2.skills[0].id = "summary-agent"
        v2.skills[0].replaces = ["skill:report-agent"]
        try env.library.install(v2, sourceMetadata: .builtIn())
        CopyFailingSecrets.sources.withLock { $0.insert(PluginRuntimeProjection.credentialID(of: activation, componentID: "skill:report-agent")) }
        for key in ["A_TOKEN", "B_TOKEN"] {
            WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: "skill:report-agent#\(key)", on: activation)
        }
        try env.context.save()

        // A_TOKEN stages privately; B_TOKEN fails before the saved owner changes.
        #expect(throws: PluginUpdateService.UpdateError.secretCopyFailed(component: v2.name, key: "B_TOKEN")) {
            try PluginUpdateService.reconcileAll(
                modelContext: env.context, packages: env.library.installedPackages(), mode: .release, secrets: CopyFailingSecrets.self,
                approvalRecords: PluginOperationsTests.approvals(env.library.installedPackages())
            )
        }
        #expect(activation.recordedVersion == "1.0.0")
    }

    /// Failed clears never modify the saved namespace, so no compensating
    /// Keychain write is required even when that write would be refused.
    @Test("A failed clear preserves its old namespace without attempting restoration")
    func failedClearDoesNotNeedCompensation() throws {
        let env = try Fixtures.Environment()
        var package = Fixtures.package(version: "1.0.0")
        package.skills[0].environmentKeys = ["API_TOKEN"]
        package.skills[0].environmentValues = [""]
        try env.install(package)
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.setSetting(
                "API_TOKEN", to: "", of: package.skills[0], package: package, in: env.workspace, modelContext: env.context,
                secrets: UnrestorableSecrets.self, persist: { _, _ in throw CocoaError(.fileWriteUnknown) }
            )
        }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        #expect(activation.secretSettingKeys.isEmpty)
    }

    @Test("An enabled shared skill row offers Turn off without an activation; a workspace's own skill doesn't")
    func sharedSkillRowShowsTurnOff() throws {
        let env = try Fixtures.Environment()
        let own = Skill(name: "Local Analyst", allowedTools: ["Read"])
        own.workspace = env.workspace
        let shared = Skill(name: "Shared Analyst", allowedTools: ["Read"])
        shared.isGlobal = true
        [own, shared].forEach { env.context.insert($0) }
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableGlobalSkill(shared.id.uuidString) }
        try env.context.save()
        let capabilities = WorkspaceCapabilities(workspace: env.workspace, globalSkills: [shared])
        let rows = CapabilityCatalogInventory.configuredPackages(catalogPackages: [], capabilities: capabilities, workspace: env.workspace)
        func pluginRow(_ skill: Skill, enabled: Bool = true) throws -> PluginRow {
            let package = try #require(rows.first { $0.id == "skill.\(skill.id.uuidString.lowercased())" })
            return PluginRow(package: package, activation: nil, display: PluginsSurfaceRow(
                id: package.id, name: package.name, icon: package.icon, subtitle: "",
                pendingSteps: 0, isEnabled: enabled, isRemovable: false, verb: nil
            ))
        }
        #expect(PluginsSurfacePresentation.showsTurnOff(try pluginRow(shared)))
        #expect(!PluginsSurfacePresentation.showsTurnOff(try pluginRow(shared, enabled: false)))
        #expect(!PluginsSurfacePresentation.showsTurnOff(try pluginRow(own)))
    }

    // MARK: - Round 11

    @Test("A same-version definition the automatic pass held back doesn't run until Update")
    func digestOnlyWithheldActivationDoesNotRun() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.skills[0].environmentKeys = ["PROJECT", "REGION"]
        v1.skills[0].environmentValues = ["default-project", ""]
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        WorkspaceCapabilityActivation.setConfigValue(
            "us-east", forKey: PluginActivation.settingKey(componentID: "skill:report-agent", key: "REGION"), on: activation
        )
        try env.context.save()
        // Reseeded with the same version and components, without REGION: only
        // the digest differs, and the pass can't release the setting.
        try env.importUpdate(Fixtures.package(version: "1.0.0"), mode: .automatic)
        #expect(activation.recordedVersion == "1.0.0")
        #expect(activation.knownComponentIDs == PluginRuntimeProjection.componentIDs(of: Fixtures.package(version: "1.0.0")))

        let library = env.library.installedPackages()
        func runs() -> Bool { !PluginRuntimeProjection.project(workspace: env.workspace, packages: library).skills.isEmpty }
        #expect(activation.awaitingUpdate)
        #expect(!runs())
        #expect(PluginRuntimeProjection.runnable(library, in: env.workspace).isEmpty)
        // Snapshots, queued records and the workspace mirror carry it.
        #expect(PluginActivationRecord(activation).awaitingUpdate)
        #expect(WorkspaceConfigManager.installedPluginRefs(for: env.workspace).first { $0.id == v1.id }?.awaitingUpdate == true)

        try PluginUpdateService.reconcileAll(modelContext: env.context, packages: library, mode: .release, approvalRecords: PluginOperationsTests.approvals(library))
        #expect(!activation.awaitingUpdate)
        #expect(runs())
    }

    @Test("A shared account is trimmed to its creator's declaration after the creator renamed the connector")
    func sharedAccountFollowsRenamedCreator() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.connectors[0].credentialHints.append(.init(key: "LEGACY_TOKEN", hint: "Legacy"))
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == v1.id })
        var other = Fixtures.package(version: "1.0.0")
        other.id = "ops.other"
        other.skills[0].name = "Other Agent"
        other.connectors[0].credentialHints = [.init(key: "TRACKER_TOKEN", hint: "Token"), .init(key: "LEGACY_TOKEN", hint: "Legacy")]
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(other.id) }
        let otherActivation = try #require(WorkspaceCapabilityActivation.activation(for: other.id, in: env.workspace))
        WorkspaceCapabilityActivation.bind(
            account, toComponent: CapabilityResourceOrigin.componentID(for: other.connectors[0]), of: otherActivation
        )
        var v2 = Fixtures.package(version: "2.0.0")
        let predecessor = CapabilityResourceOrigin.componentID(for: v2.connectors[0])
        v2.connectors[0].id = "issues"
        v2.connectors[0].replaces = [predecessor]
        try env.context.save()
        try env.importUpdate(v2)
        #expect(account.originComponentID == CapabilityResourceOrigin.componentID(for: v2.connectors[0]))
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs.removeAll { $0 == v1.id } }

        func projectedKeys() -> [String]? {
            PluginRuntimeProjection.project(
                workspace: env.workspace, packages: [other], connectorMode: .runtimeCopies,
                definitions: env.library.installedPackages() + [other]
            ).connectors.first { $0.id == account.id }?.credentialKeys
        }
        #expect(projectedKeys() == ["TRACKER_TOKEN"])
        // A stamp no Update moved (an earlier build's) resolves through the
        // creator's `replaces`.
        account.originComponentID = predecessor
        #expect(projectedKeys() == ["TRACKER_TOKEN"])
        #expect(account.credentialKeys == ["TRACKER_TOKEN", "LEGACY_TOKEN"])
    }

    @Test("A legacy template row customized only in the person's own settings gets no baseline digest")
    func customizedLegacyTemplateIsNotBaselined() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.templates = ["Daily", "Weekly", "Monthly"].map { Fixtures.template($0, goal: "Write it") }
        try env.install(v1)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: v1.id, in: env.workspace))
        // As a V19 store left it: stamped rows, no digests recorded.
        WorkspaceCapabilityActivation.setTemplateDigests(entries: [], on: activation)
        let rows = Dictionary(uniqueKeysWithValues: PluginTemplateSync.stamped(v1.id, in: env.workspace).map { ($0.name, $0) })
        try #require(rows["Daily"]).mainModel = "claude-opus"
        try #require(rows["Weekly"]).defaultSkillIDs = [UUID().uuidString]

        PluginTemplateSync.recordUnedited(v1, in: env.workspace, on: activation)
        func digest(_ name: String) -> String? {
            activation.templateDigest(forComponent: CapabilityResourceOrigin.componentID(for: Fixtures.template(name, goal: "")))
        }
        #expect(digest("Daily") == nil)
        #expect(digest("Weekly") == nil)
        #expect(digest("Monthly") != nil)
    }

    @Test("A setting an Update stopped declaring stays on the account but never reaches a run")
    func retiredConnectorSettingIsNotProjected() throws {
        let env = try Fixtures.Environment()
        var v1 = Fixtures.package(version: "1.0.0")
        v1.connectors[0].configHints = [.init(key: "TRACKER_REGION", hint: "Region", isList: false)]
        try env.install(v1)
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == v1.id })
        // This plugin's settings are credentials now (only a bundled plugin's
        // stay plain); an account from before that holds the value as one.
        account.setConfigValue("TRACKER_REGION", value: "eu-old")
        try env.context.save()
        try env.importUpdate(Fixtures.package(version: "2.0.0"))

        let copy = try #require(PluginRuntimeProjection.project(
            workspace: env.workspace, packages: env.library.installedPackages(), connectorMode: .runtimeCopies,
            definitions: env.library.installedPackages()
        ).connectors.first { $0.id == account.id })
        #expect(!copy.configKeys.contains("TRACKER_REGION") && copy.configKeys.count == copy.configValues.count)
        #expect(copy.credentialKeys == ["TRACKER_TOKEN"])
        #expect(account.config["TRACKER_REGION"] == "eu-old")
    }

    @Test("A shared account whose creator's definition can't be found brings no credentials to a run")
    func sharedAccountWithUnresolvableCreatorFailsClosed() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == "ops.report" })
        var other = Fixtures.package(version: "1.0.0")
        other.id = "ops.other"
        other.skills[0].name = "Other Agent"
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(other.id) }
        let otherActivation = try #require(WorkspaceCapabilityActivation.activation(for: other.id, in: env.workspace))
        WorkspaceCapabilityActivation.bind(
            account, toComponent: CapabilityResourceOrigin.componentID(for: other.connectors[0]), of: otherActivation
        )
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs.removeAll { $0 == "ops.report" } }

        // The creator's library entry is unreadable: only `other` is found.
        let copy = try #require(PluginRuntimeProjection.project(
            workspace: env.workspace, packages: [other], connectorMode: .runtimeCopies, definitions: [other]
        ).connectors.first { $0.id == account.id })
        #expect(copy.credentialKeys.isEmpty && copy.credentialValues.isEmpty)
        #expect(account.credentialKeys == ["TRACKER_TOKEN"])
    }

    /// One runtime copy serves a run scoped to either binder, so with no
    /// creator to read it keeps only the settings both declare: the skill
    /// settings an account carries plain. A binder's own connector setting
    /// is a credential of a third-party plugin, so a plain value the row
    /// still holds for it reaches no run.
    @Test("A shared account whose creator can't be found keeps only the settings every binder declares")
    func sharedAccountWithUnresolvableCreatorKeepsCommonSettings() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let account = try #require(env.workspace.connectors.first { $0.originPackageID == "ops.report" })
        account.setConfigValue("ONLY_B", value: "b-value")
        account.setConfigValue("SHARED", value: "shared-value")
        account.setConfigValue("TRACKER_REGION", value: "plain-region")
        func binder(_ id: String, settings: [String]) throws -> PluginPackage {
            var package = Fixtures.package(version: "1.0.0")
            package.id = id
            package.skills[0].name = "\(id) Agent"
            package.skills[0].environmentKeys = settings
            package.skills[0].environmentValues = settings.map { _ in "" }
            package.connectors[0].configHints = [.init(key: "TRACKER_REGION", hint: "Region", isList: false)]
            WorkspaceCapabilityActivation.mutate(env.workspace) { $0.enableCapability(id) }
            let activation = try #require(WorkspaceCapabilityActivation.activation(for: id, in: env.workspace))
            WorkspaceCapabilityActivation.bind(
                account, toComponent: CapabilityResourceOrigin.componentID(for: package.connectors[0]), of: activation
            )
            return package
        }
        let b = try binder("ops.b", settings: ["ONLY_B", "SHARED"])
        let c = try binder("ops.c", settings: ["SHARED"])
        WorkspaceCapabilityActivation.mutate(env.workspace) { $0.capabilityIDs.removeAll { $0 == "ops.report" } }

        // Either order of the binders: the first one no longer decides.
        for packages in [[b, c], [c, b]] {
            let copy = try #require(PluginRuntimeProjection.project(
                workspace: env.workspace, packages: packages, connectorMode: .runtimeCopies, definitions: packages
            ).connectors.first { $0.id == account.id })
            #expect(copy.configKeys.contains("SHARED"))
            #expect(!copy.configKeys.contains("ONLY_B") && !copy.configValues.contains("b-value"))
            #expect(!copy.configKeys.contains("TRACKER_REGION") && !copy.configValues.contains("plain-region"))
            #expect(copy.credentialKeys.isEmpty)
        }
        #expect(account.config["ONLY_B"] == "b-value" && account.config["TRACKER_REGION"] == "plain-region")
    }

    @Test("A queued launch keeps coherent frozen acceptance and rejects changed definitions when none were frozen")
    func queuedLaunchAcceptanceFollowsItsDefinitions() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let submitted = env.library.installedPackages().filter { $0.id == "ops.report" }
        let task = AgentTask(title: "Report", goal: "Write the weekly report", workspace: env.workspace)
        env.context.insert(task)
        // One request froze its definitions; an earlier build's froze none.
        let frozen = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, kind: .retry, pluginDefinitions: submitted)
        let older = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
        [frozen, older].forEach { env.context.insert($0) }
        try env.context.save()
        try env.importUpdate(Fixtures.package(version: "2.0.0"))

        func launch(_ request: TaskTurnRequest) throws -> AgentTask {
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            return TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        }
        func version(_ launch: AgentTask) -> String? {
            launch.workspace.flatMap { WorkspaceCapabilityActivation.activation(for: "ops.report", in: $0) }?.recordedVersion
        }
        // Frozen v1 definition, frozen v1 acceptance: the plugin runs as submitted.
        let frozenLaunch = try launch(frozen)
        #expect(version(frozenLaunch) == "1.0.0")
        #expect(TaskCapabilityResolver(task: frozenLaunch).allBehaviorSkills.contains { $0.name == "Report Agent" })
        #expect(!CapabilityRuntimeIntegrityService.issues(for: frozenLaunch, packages: submitted, checkExecutables: false)
            .contains { $0.message.contains("queued request") })
        // An old request has no v1 definition to execute. Keep its v1
        // contract and reject dispatch against v2, rather than certify old
        // settings as if Update had reconciled this detached request.
        let olderLaunch = try launch(older)
        #expect(version(olderLaunch) == "1.0.0")
        #expect(PluginRuntimeProjection.project(workspace: olderLaunch.workspace, packages: env.library.installedPackages()).skills.isEmpty)
        #expect(CapabilityRuntimeIntegrityService.issues(for: olderLaunch, packages: env.library.installedPackages(), checkExecutables: false)
            .contains { $0.packageID == "ops.report" && $0.resourceKind == .policy && $0.message.contains("queued request") })
    }

    @Test("The row's Update fails, changing nothing, when the installed definition can't be read back")
    func rowUpdateNeedsReadableDefinition() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        try Data("not a package".utf8).write(to: env.library.packageURL(for: "ops.report"))
        // The row still shows a definition that dropped the connector.
        var shown = Fixtures.package(version: "2.0.0")
        shown.connectors = []
        #expect(throws: PluginUpdateService.UpdateError.definitionUnreadable(plugin: shown.name)) {
            try CapabilityCatalogActionService(library: env.library).update(shown, modelContext: env.context)
        }
        #expect(activation.recordedVersion == "1.0.0")
        #expect(!activation.bindings.isEmpty)
    }
}

/// Skill secrets with no values whose deletes all fail.
private enum SecretsRefusingDeletes: SkillSecretPersisting {
    nonisolated(unsafe) static var beforeDelete: ((String, UUID) -> Void)?
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        beforeDelete?(key, skillID)
        return false
    }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
    static func deleteAllSecretsReportingResult(skillID: UUID) -> Bool { false }
}

/// Skill secrets with no values whose deletes all succeed.
private enum SecretsAcceptingDeletes: SkillSecretPersisting {
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { nil }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool { true }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
}

/// Skill secrets holding a value in each `sources` namespace: A_TOKEN copies,
/// B_TOKEN can't, and nothing can be deleted.
private enum CopyFailingSecrets: SkillSecretPersisting {
    static let sources = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        sources.withLock { $0.contains(skillID) } ? "value" : nil
    }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        key == "A_TOKEN"
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { false }
    static func secretExists(key: String, skillID: UUID) -> Bool { false }
    static func deleteAllSecrets(skillID: UUID) {}
}

/// Skill secrets whose every value is "previous": it can be deleted, but
/// not written back.
private enum UnrestorableSecrets: SkillSecretPersisting {
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? { "previous" }
    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String, allowUserInteraction: Bool) -> Bool {
        value != "previous"
    }
    static func deleteSecret(key: String, skillID: UUID) -> Bool { true }
    static func secretExists(key: String, skillID: UUID) -> Bool { true }
    static func deleteAllSecrets(skillID: UUID) {}
}

/// A file manager that can't read a library entry of one version.
private final class HidingVersionFileManager: FileManager, @unchecked Sendable {
    let hidden: String
    init(hidden: String) { self.hidden = hidden }
    override func contents(atPath path: String) -> Data? {
        guard let data = super.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self).contains("\"\(hidden)\"") ? nil : data
    }
}

/// Hides the replacement and retargets the actual storage directory, so
/// recovery must retain its images instead of writing into an unrelated root.
private final class RestoreBlockingFileManager: FileManager, @unchecked Sendable {
    let hidden: String
    let library: URL
    private var blocked = false
    init(hidden: String, library: URL) { self.hidden = hidden; self.library = library }
    override func contents(atPath path: String) -> Data? {
        guard let data = super.contents(atPath: path) else { return nil }
        guard String(decoding: data, as: UTF8.self).contains("\"\(hidden)\"") else { return data }
        if !blocked {
            blocked = true
            do {
                try super.moveItem(at: library, to: library.deletingLastPathComponent().appendingPathComponent("RetainedLibrary"))
                try super.createDirectory(at: library, withIntermediateDirectories: false)
            } catch { Issue.record("Could not create the blocked-restore fixture") }
        }
        return nil
    }
}
