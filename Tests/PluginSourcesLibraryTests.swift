import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Plugin sources against their threat model, continued from
/// `PluginSourcesTests` (one file is over the line budget): the library
/// writes an install, a file import, Create and Remove make one at a time
/// (T5, T13), and what a recovery or a chosen file's import holds back
/// until the right copy is installed (T5). Fixtures are
/// `PluginSourcesTests`'s.
@Suite("Plugin sources: library writes and held imports")
@MainActor
struct PluginSourcesLibraryTests {
    @Test("T5, T13: installs of one plugin ID are one at a time across sources; the second meets the first's copy as a conflict")
    func installsOfOneIDAreSerializedAcrossSources() throws {
        let fixture = try PluginSourcesTests.Fixture()
        let (library, files) = fixture.journaledLibrary()
        let first = fixture.root.appendingPathComponent("first", isDirectory: true)
        let second = fixture.root.appendingPathComponent("second", isDirectory: true)
        try fixture.write(["capability.json": try PluginSourcesTests.packageJSON(id: "raced", version: "1.0.0")], in: first)
        // The other source's copy is newer: a file import of it would be an Update.
        try fixture.write(["capability.json": try PluginSourcesTests.packageJSON(id: "raced", version: "2.0.0")], in: second)
        let sourceA = try #require(PluginSource.make(from: first.path))
        let sourceB = try #require(PluginSource.make(from: second.path))
        try fixture.store.save([sourceA, sourceB])
        let coordinator = PluginSourceCoordinator(store: fixture.store, installedPackages: { library.installedPackages() })
        coordinator.reload()
        let plugins = coordinator.listings.flatMap(\.plugins)
        let fromA = try #require(plugins.first { $0.source.id == sourceA.id })
        let fromB = try #require(plugins.first { $0.source.id == sourceB.id })
        #expect(fromA.canAdd && fromB.canAdd)
        let workspace = Workspace(name: "Raced", primaryPath: fixture.root.appendingPathComponent("ws").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        fixture.context.insert(workspace)
        let service = CapabilityCatalogActionService(library: library, sourceStore: fixture.store)

        // While A's library write is under way, B's Add of the same ID (in
        // another case too), a file import and a Remove are each refused,
        // not run over it.
        var refusals: [Error] = []
        files.duringNextLibraryWrite = {
            MainActor.assumeIsolated {
                do {
                    try service.importReviewed(fromB, workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
                } catch { refusals.append(error) }
                do {
                    let file = try PluginSourcesTests.package(id: "Raced", version: "3.0.0")
                    let report = CapabilityPackageValidator.validate(package: file, installedPackages: [], checkPrerequisites: false)
                    try service.importPlugin(report, workspace: workspace, modelContext: fixture.context, traceID: AuditTrace.make("test"))
                } catch { refusals.append(error) }
                do {
                    _ = try service.remove(try PluginSourcesTests.package(id: "raced", version: "1.0.0"), modelContext: fixture.context)
                } catch { refusals.append(error) }
            }
        }
        try service.importReviewed(fromA, workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        #expect(files.duringNextLibraryWrite == nil)
        #expect(refusals.count == 3)
        #expect(refusals.allSatisfy { error in
            if case .pluginBusy? = error as? PluginSourceStoreError { return true }
            return false
        }, "\(refusals)")
        #expect(library.installedPackage(id: "raced")?.version == "1.0.0")
        #expect(fixture.store.provenance()["raced"] == PluginSourceStore.Provenance(
            sourceID: sourceA.id, digest: fromA.digest
        ))

        // Once A is done, B's Add checks again and meets A's copy: a conflict.
        let refused = try #require(coordinator.listings.flatMap(\.plugins).first { $0.source.id == sourceB.id })
        #expect(!refused.canAdd)
        #expect(throws: PluginSourceCatalogError.self) {
            try service.importReviewed(fromB, workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        }
        #expect(library.installedPackage(id: "raced")?.version == "1.0.0")
        #expect(fixture.store.provenance()["raced"]?.sourceID == sourceA.id)

        // Another process holding the ID's lock refuses it here as well.
        let lockURL = fixture.store.pluginLockURL(forKey: "raced")
        let held = open(lockURL.path, O_RDWR | O_CLOEXEC)
        #expect(held >= 0)
        defer { close(held) }
        #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: PluginSourceStoreError.pluginBusy("RACED")) {
            try fixture.store.exclusively(pluginID: "RACED") {}
        }
        flock(held, LOCK_UN)
        #expect(try fixture.store.exclusively(pluginID: "RACED") { true })
    }

    @Test("T13: library writes are one at a time across plugin IDs, so two plugins sharing an MCP server ID can't both pass the uniqueness check before either writes")
    func libraryWritesAreSerializedAcrossPluginIDs() throws {
        let fixture = try PluginSourcesTests.Fixture()
        let (library, files) = fixture.journaledLibrary()
        func plugin(_ id: String, server: String?) throws -> Data {
            var package = try PluginSourcesTests.package(id: id, version: "1.0.0")
            if let server {
                package.mcpServers = [PluginMCPServer(id: server, displayName: "Shared", transport: .http, url: URL(string: "https://mcp.example.test/")!)]
            }
            return try JSONEncoder().encode(package)
        }
        var sources: [PluginSource] = []
        for (name, id, server) in [("a", "mcp-a", "shared-mcp"), ("b", "mcp-b", "shared-mcp"), ("c", "unrelated", nil)] as [(String, String, String?)] {
            let folder = fixture.root.appendingPathComponent(name, isDirectory: true)
            try fixture.write(["capability.json": try plugin(id, server: server)], in: folder)
            sources.append(try #require(PluginSource.make(from: folder.path)))
        }
        try fixture.store.save(sources)
        let coordinator = PluginSourceCoordinator(store: fixture.store, installedPackages: { library.installedPackages() })
        coordinator.reload()
        func offered(_ index: Int) throws -> SourcedPlugin {
            try #require(coordinator.listings.flatMap(\.plugins).first { $0.source.id == sources[index].id })
        }
        #expect(try offered(0).canAdd && offered(1).canAdd && offered(2).canAdd)
        let workspace = Workspace(name: "Library", primaryPath: fixture.root.appendingPathComponent("ws").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        fixture.context.insert(workspace)
        let service = CapabilityCatalogActionService(library: library, sourceStore: fixture.store)

        // While A's library write is under way, B (another plugin ID, the
        // same server ID) and C (unrelated) each meet the library lock.
        var refusals: [Error] = []
        files.duringNextLibraryWrite = {
            MainActor.assumeIsolated {
                for index in [1, 2] {
                    do {
                        try service.importReviewed(try offered(index), workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
                    } catch { refusals.append(error) }
                }
            }
        }
        try service.importReviewed(try offered(0), workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        #expect(refusals.count == 2)
        #expect(refusals.allSatisfy { ($0 as? PluginSourceStoreError) == .libraryBusy }, "\(refusals)")
        #expect(library.installedPackages().map(\.id) == ["mcp-a"])

        // Once A is written, B's check sees A's server: a conflict, no Add.
        let b = try offered(1)
        #expect(!b.canAdd && b.problem?.contains("MCP server ID in use") == true)
        #expect(throws: PluginSourceCatalogError.self) {
            try service.importReviewed(b, workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        }
        #expect(library.installedPackage(id: "mcp-b") == nil)

        // Another process must not freeze the main actor while holding
        // this descriptor. Refuse promptly and recheck on an explicit retry.
        let held = open(fixture.store.libraryLockURL.path, O_RDWR | O_CLOEXEC)
        #expect(held >= 0)
        defer { close(held) }
        #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
        let start = ContinuousClock.now
        #expect(throws: PluginSourceStoreError.libraryBusy) {
            try service.importReviewed(try offered(2), workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        }
        #expect(start.duration(to: .now) < .milliseconds(250))
        #expect(library.installedPackage(id: "unrelated") == nil)
        flock(held, LOCK_UN)
        try service.importReviewed(try offered(2), workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        #expect(library.installedPackage(id: "unrelated") != nil)
        #expect(try fixture.store.exclusively(pluginID: "someone-else") { true })
        // The staged approval takes the same locks.
        let source = try String(contentsOf: PluginSourcesTests.repositoryRoot().appendingPathComponent("Astra/Services/Capabilities/CapabilityCatalogActionService.swift"), encoding: .utf8)
        #expect(source.contains("try sourceStore.exclusively(pluginID: review.id) {\n            try PluginSourceDefinitionOperation(library: library, store: sourceStore).approve("))
    }

    @Test("T5: recovering the workspace's own mirror holds an activation whose plugin is now installed from another source; its own source's Update is awaited as before")
    func recoveryHoldsAnActivationFromAnotherSource() throws {
        let fixture = try PluginSourcesTests.Fixture()
        let folder = fixture.root.appendingPathComponent("recovered", isDirectory: true)
        var definition = try PluginSourcesTests.package(id: "recovered-plugin", version: "1.0.0")
        definition.skills[0].environmentKeys = ["REGION"]
        definition.connectors = [PluginConnector(
            name: "Acme", serviceType: "acme", icon: "key", description: "", baseURL: "https://api.acme.test",
            authMethod: "api_key", credentialHints: [.init(key: "ACME_TOKEN", hint: "Token")], configHints: [], notes: ""
        )]
        try fixture.write(["capability.json": try JSONEncoder().encode(definition)], in: folder)
        let source = try #require(PluginSource.make(from: folder.path))
        try fixture.store.save([source])
        let coordinator = PluginSourceCoordinator(store: fixture.store, installedPackages: { fixture.library.installedPackages() })
        coordinator.reload()
        let workspace = Workspace(name: "Recovered", primaryPath: fixture.root.appendingPathComponent("ws").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        fixture.context.insert(workspace)
        let service = CapabilityCatalogActionService(library: fixture.library, sourceStore: fixture.store)
        try service.importReviewed(try #require(coordinator.listings.first?.plugins.first), workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        let installed = try #require(fixture.library.installedPackage(id: definition.id))
        _ = try service.add(
            installed, workspace: workspace, modelContext: fixture.context,
            policyContext: .workspaceUser(workspace: workspace, isAdmin: true, currentAppVersion: SemanticVersion(1, 0, 0), approvalRecords: []),
            approvalStore: CapabilityApprovalStore(directory: fixture.root.appendingPathComponent("approvals")), traceID: "test"
        )
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: installed.id, in: workspace))
        let components = PluginRuntimeProjection.componentIDs(of: installed)
        let skillComponent = try #require(components.first { $0.hasPrefix("skill") })
        WorkspaceCapabilityActivation.setConfigValue("eu", forKey: "\(skillComponent)#REGION", on: activation)
        let account = try #require(activation.bindings.first { $0.account != nil }?.account)
        try fixture.context.save()
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: fixture.context))
        config.installedPlugins = WorkspaceConfigManager.installedPluginRefs(for: workspace) { id, recorded in
            fixture.library.installedPackage(id: id).flatMap {
                PluginSourceStore.mirrorIdentity(recordedDigest: recorded, installed: $0, provenance: fixture.store.provenance())
            }
        }
        let identity = "plugin-source:\(source.id)"
        #expect(config.installedPlugins?.first?.source == identity)

        /// Launch recovery of this mirror on a Mac whose library copy is
        /// `copy` (nil: nothing, or nothing to tell).
        func recovered(_ copy: PluginInstalledCopy?) throws -> (Workspace, WorkspaceConfigManager.WorkspaceConfigImportResult) {
            let target = try ModelContainer(
                for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            PluginSourcesTests.Fixture.retained.append(target)
            let result = WorkspaceConfigManager.importWorkspaceResult(
                from: config, modelContext: target.mainContext, capabilityTrust: .preserveRecordedState, installedCopy: { _ in copy }
            )
            return (result.workspace, result)
        }
        // The same source's copy, this or a later version: restored as recorded.
        for same in [PluginInstalledCopy.installed(source: identity), nil] {
            let (back, result) = try recovered(same)
            let restored = try #require(WorkspaceCapabilityActivation.activation(for: installed.id, in: back))
            #expect(restored.isEnabled && restored.configuration["\(skillComponent)#REGION"] == "eu")
            #expect(restored.bindings.contains { $0.account?.id == account.id })
            #expect(result.capabilityTrust.pluginsHeldOnRecovery.isEmpty)
            #expect(WorkspaceCapabilityActivation.pendingImport(pluginID: installed.id, in: back) == nil)
        }
        // Installed from another source, or locally: nothing of it is
        // activated or bound; its payload waits as a held import.
        for other in [PluginInstalledCopy.installed(source: "plugin-source:acme-other-123abc"), .installed(source: nil)] {
            let (back, result) = try recovered(other)
            #expect(WorkspaceCapabilityActivation.activation(for: installed.id, in: back) == nil, "\(other)")
            #expect(!back.enabledCapabilityIDs.contains(installed.id))
            #expect(result.capabilityTrust.pluginsHeldOnRecovery == [installed.id])
            #expect(result.capabilityTrust.auditFields["plugins_held_on_recovery"] == installed.id)
            let held = try #require(WorkspaceCapabilityActivation.pendingImport(pluginID: installed.id, in: back))
            #expect(held.recovered == true && held.source == identity)
            #expect(held.settings?["\(skillComponent)#REGION"] == "eu")
            #expect(held.accounts?.map(\.connectorID) == [account.id.uuidString])
            #expect(!(back.retiredPluginActivationsJSON ?? "").contains("ACME_TOKEN"))
            // It comes back once the same source's copy is installed, at any
            // version (its Update); never for another source's or a local one.
            var newer = installed
            newer.version = "2.0.0"
            let here = PluginSourceStore(root: fixture.root.appendingPathComponent("here-\(UUID().uuidString)", isDirectory: true))
            #expect(!PluginPendingImport.matches(held, installed: newer, provenance: here.provenance()))
            try here.recordProvenance(pluginID: newer.id, sourceID: "acme-other-123abc", digest: PluginSourceCatalog.contentDigest(newer))
            #expect(!PluginPendingImport.matches(held, installed: newer, provenance: here.provenance()))
            try here.recordProvenance(pluginID: newer.id, sourceID: source.id, digest: PluginSourceCatalog.contentDigest(newer))
            #expect(PluginPendingImport.matches(held, installed: newer, provenance: here.provenance()))
            // A chosen file's held import still needs the same digest.
            var chosen = held
            chosen.recovered = nil
            #expect(!PluginPendingImport.matches(chosen, installed: newer, provenance: here.provenance()))
        }
        // The plugin not installed at all: restored as recorded, as before.
        let (absent, _) = try recovered(.notInstalled)
        #expect(WorkspaceCapabilityActivation.activation(for: installed.id, in: absent)?.isEnabled == true)

        // An activation held back from its source's Update records a digest
        // the installed copy no longer has; the mirror still names its
        // source, so a recovery meanwhile doesn't read it as local.
        WorkspaceCapabilityActivation.setAwaitingUpdate(true, on: activation)
        let awaiting = WorkspaceConfigManager.installedPluginRefs(for: workspace, sourceIdentity: { _, _ in nil }, awaitedSource: { _ in identity })
        #expect(awaiting.first?.source == identity)
        WorkspaceCapabilityActivation.setAwaitingUpdate(false, on: activation)
        #expect(WorkspaceConfigManager.installedPluginRefs(for: workspace, sourceIdentity: { _, _ in nil }, awaitedSource: { _ in identity }).first?.source == nil)
        // The launched app's resolver answers from the plugin source store.
        #expect(fixture.store.installedCopy(of: nil) == .notInstalled)
        #expect(fixture.store.installedCopy(of: installed) == .installed(source: identity))
        #expect(LocalPluginSourceIdentity.installedCopy(pluginID: installed.id) == nil)
    }

    @Test("T5: a held import is listed under Action needed with why it waits, and Discard drops it through a journaled save")
    func heldImportsAreListedAndDiscardable() throws {
        let fixture = try PluginSourcesTests.Fixture()
        let workspace = Workspace(name: "Held", primaryPath: fixture.root.appendingPathComponent("ws").path)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        fixture.context.insert(workspace)
        let folder = fixture.root.appendingPathComponent("held", isDirectory: true)
        try fixture.write(["capability.json": try PluginSourcesTests.packageJSON(id: "held-plugin", version: "1.0.0")], in: folder)
        let source = try #require(PluginSource.make(from: folder.path))
        try fixture.store.save([source])
        let coordinator = PluginSourceCoordinator(store: fixture.store, installedPackages: { fixture.library.installedPackages() })
        coordinator.reload()
        let service = CapabilityCatalogActionService(library: fixture.library, sourceStore: fixture.store)
        let identity = "plugin-source:\(source.id)"
        func hold(_ pluginID: String, digest: String, source: String?, recovered: Bool? = nil) {
            var pending = RetiredPluginActivation.PendingImport(
                digest: digest, source: source, settings: ["skill.x#REGION": "eu"], overriddenComponentIDs: nil,
                overridingRowIDs: nil, accounts: nil, knownComponentIDs: nil
            )
            pending.recovered = recovered
            WorkspaceCapabilityActivation.recordPendingImport(pending, pluginID: pluginID, in: workspace)
        }

        // Not installed: named by its ID, waiting for its source.
        hold("held-plugin", digest: "d1", source: identity)
        hold("zz-other", digest: "d2", source: nil)
        var rows = service.heldImports(in: workspace, coordinator: coordinator)
        #expect(rows.map(\.pluginID) == ["held-plugin", "zz-other"])
        #expect(rows[0].name == "held-plugin" && !rows[0].canAdd)
        #expect(rows[0].subtitle.contains("waiting for it from \(source.displayName)"))
        #expect(rows[1].subtitle.contains("waiting for it from a local file"))
        #expect(rows.allSatisfy { $0.subtitle.hasPrefix("Settings from an imported workspace file") })
        #expect(rows[0].id == "held-import:held-plugin")

        // Installed from the same source with the digest it waits for: Add brings it back.
        try service.importReviewed(try #require(coordinator.listings.first?.plugins.first), workspace: workspace, modelContext: fixture.context, coordinator: coordinator)
        let installed = try #require(fixture.library.installedPackage(id: "held-plugin"))
        hold("held-plugin", digest: PluginDefinitionDigest.content(of: installed), source: identity, recovered: true)
        rows = service.heldImports(in: workspace, coordinator: coordinator)
        #expect(rows[0].name == installed.name && rows[0].canAdd)
        #expect(rows[0].subtitle == "Settings this workspace had. Add it to bring them back, or discard them.")
        // Another version of it: no Add.
        hold("held-plugin", digest: "d-other", source: identity)
        rows = service.heldImports(in: workspace, coordinator: coordinator)
        #expect(!rows[0].canAdd && rows[0].subtitle.contains("another version"))
        // Recorded for a local copy, installed from the source: names both.
        hold("held-plugin", digest: PluginDefinitionDigest.content(of: installed), source: nil)
        rows = service.heldImports(in: workspace, coordinator: coordinator)
        #expect(!rows[0].canAdd)
        #expect(rows[0].subtitle.contains("copy from a local file") && rows[0].subtitle.contains("installed is from \(source.displayName)"))

        // Discard drops it and saves; a failed save puts it back.
        #expect(throws: PluginOperations.OperationError.saveFailed) {
            try PluginOperations.discardPendingImport(pluginID: "held-plugin", in: workspace, modelContext: fixture.context) { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(WorkspaceCapabilityActivation.pendingImport(pluginID: "held-plugin", in: workspace) != nil)
        try service.discardPendingImport(pluginID: "held-plugin", workspace: workspace, modelContext: fixture.context)
        #expect(WorkspaceCapabilityActivation.pendingImport(pluginID: "held-plugin", in: workspace) == nil)
        #expect(WorkspaceCapabilityActivation.pendingImport(pluginID: "zz-other", in: workspace) != nil)
        #expect(service.heldImports(in: workspace, coordinator: coordinator).map(\.pluginID) == ["zz-other"])
        // Discarding what isn't held changes nothing.
        try service.discardPendingImport(pluginID: "held-plugin", workspace: workspace, modelContext: fixture.context)
        // The screen lists them through the service, with Discard and Add.
        let view = try String(contentsOf: PluginSourcesTests.repositoryRoot().appendingPathComponent("Astra/Views/Capabilities/PluginsSurfaceView.swift"), encoding: .utf8)
        #expect(view.contains(".heldImports(in: workspace)") && view.contains(".discardPendingImport(pluginID:"))
    }
}
