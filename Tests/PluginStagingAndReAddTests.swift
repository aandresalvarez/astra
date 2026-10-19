import Foundation
import SwiftData
import Testing
@testable import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Staged drafts over an approved plugin, retained accounts on re-Add, and
/// dependency-aware Remove. Fixtures are `PluginOperationsTests`'s.
@Suite("Plugin staging, re-Add and dependents")
@MainActor
struct PluginStagingAndReAddTests {
    typealias Fixtures = PluginOperationsTests

    @Test("A draft imported over an approved plugin is staged; the approved copy runs until approval commits it")
    func draftOverApprovedPluginIsStaged() throws {
        let env = try Fixtures.Environment()
        try env.install(Fixtures.package(version: "1.0.0"))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: "ops.report", in: env.workspace))
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals", isDirectory: true))
        let installedV1 = try #require(env.library.installedPackage(id: "ops.report"))
        _ = try approvals.save(package: installedV1, status: .approved, approvedBy: "Tests")

        var v2 = Fixtures.package(version: "2.0.0")
        v2.skills[0].behaviorInstructions = "Write the report, version 2."
        let report = CapabilityPackageValidator.validate(package: v2, installedPackages: env.library.installedPackages(), checkPrerequisites: false)
        let result = try CapabilityPackageImporter(library: env.library)
            .importValidatedPackage(report, modelContext: env.context, approvalRecords: approvals.records())
        #expect(result.staged)
        // Durable, beside the approved copy, which is still what resolves.
        let reopened = CapabilityLibrary(directory: env.library.directory)
        #expect(reopened.installedPackage(id: "ops.report")?.version == "1.0.0")
        #expect(reopened.stagedPackage(id: "ops.report")?.version == "2.0.0")
        #expect(!reopened.installedPackages().contains { $0.version == "2.0.0" })
        #expect(activation.recordedVersion == "1.0.0" && !activation.awaitingUpdate)
        #expect(!PluginRuntimeProjection.runnable(reopened.installedPackages(), in: env.workspace).isEmpty)

        // Approval commits it: installed, reconciled, no longer staged.
        let service = CapabilityCatalogActionService(library: env.library, appVersion: SemanticVersion(1, 0, 0))
        let committed = try service.approveStaged(id: "ops.report", modelContext: env.context, approvalStore: approvals)
        #expect(committed.version == "2.0.0")
        #expect(env.library.installedPackage(id: "ops.report")?.version == "2.0.0")
        #expect(env.library.stagedPackage(id: "ops.report") == nil)
        #expect(activation.recordedVersion == "2.0.0" && !activation.awaitingUpdate)

        // Over a copy no approval covers, an import installs as it always did.
        let v3 = Fixtures.package(version: "3.0.0")
        let direct = try CapabilityPackageImporter(library: env.library).importValidatedPackage(
            CapabilityPackageValidator.validate(package: v3, installedPackages: env.library.installedPackages(), checkPrerequisites: false),
            modelContext: env.context, approvalRecords: []
        )
        #expect(!direct.staged)
        #expect(env.library.installedPackage(id: "ops.report")?.version == "3.0.0")
    }

    @Test("Adding a plugin again binds back the account its component created here, stamped, with no duplicate")
    func reAddAdoptsTheRetainedAccount() throws {
        let env = try Fixtures.Environment()
        let package = Fixtures.package(version: "1.0.0")
        try env.install(package)
        let account = try #require(env.workspace.connectors.first)
        let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        // The person's own row of the same service is never taken.
        let authored = Connector(name: "Tracker API", serviceType: "tracker", baseURL: "https://mine.example.com", authMethod: "bearer")
        env.context.insert(authored)
        authored.workspace = env.workspace
        try env.context.save()

        try CapabilityUninstaller(library: env.library).remove(package, modelContext: env.context)
        #expect(account.originPackageID == nil)
        try env.install(package)

        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        #expect(activation.accounts(forComponent: componentID).map(\.id) == [account.id])
        #expect(account.originPackageID == package.id && account.originComponentID == componentID)
        #expect(env.workspace.connectors.count == 2)
        #expect(authored.originPackageID == nil)
    }

    @Test("A retained account is bound back only to a copy from the source the removed one came from (T5)")
    func retainedAccountsStayWithTheirSource() throws {
        let env = try Fixtures.Environment()
        let store = PluginSourceStore(root: env.root.appendingPathComponent("PluginSources", isDirectory: true))
        let installer = CapabilityInstaller(library: env.library, appVersion: SemanticVersion(1, 0, 0), sourceStore: store)
        let uninstaller = CapabilityUninstaller(library: env.library, sourceStore: store)
        let package = Fixtures.package(version: "1.0.0")
        let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        func install() throws -> PluginActivation {
            try installer.install(package, into: env.workspace, modelContext: env.context, announceCatalogMutation: false)
            return try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: env.workspace))
        }
        /// Makes the installed copy source `id`'s own, or local.
        func installedFrom(_ id: String?) throws {
            let installed = try #require(env.library.installedPackage(id: package.id))
            if let id {
                try store.recordProvenance(pluginID: package.id, sourceID: id, digest: PluginSourceCatalog.contentDigest(installed))
            } else {
                try store.forgetProvenance(pluginID: package.id)
            }
        }
        _ = try install()
        try installedFrom("acme-a")
        let account = try #require(env.workspace.connectors.first)

        // Removed as source A's copy, added back as a local file's: the
        // account stays the person's, unbound and unstamped; Add makes its own.
        try uninstaller.remove(package, modelContext: env.context)
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).first?.source == "plugin-source:acme-a")
        try store.forgetProvenance(pluginID: package.id)
        var activation = try install()
        #expect(!activation.accounts(forComponent: componentID).map(\.id).contains(account.id))
        #expect(account.originPackageID == nil && !account.isDeleted)
        #expect(env.workspace.connectors.filter { !$0.isDeleted }.count == 2)
        let second = try #require(activation.accounts(forComponent: componentID).first)

        // Removed as a local copy, added back from a source: the same.
        try uninstaller.remove(package, modelContext: env.context)
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).first?.source == nil)
        // The library write of a source import precedes its provenance only
        // in order, never across an Add: the record names the copy first.
        try store.recordProvenance(pluginID: package.id, sourceID: "acme-b", digest: PluginSourceCatalog.contentDigest(package))
        activation = try install()
        #expect(!activation.accounts(forComponent: componentID).map(\.id).contains(second.id))
        #expect(env.workspace.connectors.filter { !$0.isDeleted }.count == 3)

        // Removed and added back as the same source's copy: bound back, stamped.
        let third = try #require(activation.accounts(forComponent: componentID).first)
        try uninstaller.remove(package, modelContext: env.context)
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: env.workspace).first?.source == "plugin-source:acme-b")
        activation = try install()
        #expect(activation.accounts(forComponent: componentID).map(\.id) == [third.id])
        #expect(third.originPackageID == package.id)
        #expect(env.workspace.connectors.filter { !$0.isDeleted }.count == 3)
        // Nothing else of the record depends on the source: the seed comes back.
        #expect(WorkspaceCapabilityActivation.retainedAccounts(of: package.id, in: env.workspace, addingFrom: "local").isEmpty)
    }

    @Test("Remove is refused while another installed plugin requires it, naming the dependents")
    func removeRefusesWhileRequired() throws {
        let env = try Fixtures.Environment()
        let base = Fixtures.package(version: "1.0.0")
        try env.install(base)
        var dependent = Fixtures.package(version: "1.0.0")
        dependent.id = "ops.dependent"
        dependent.name = "Dependent Reports"
        dependent.requires = [base.id]
        try env.library.install(dependent, sourceMetadata: .localLibrary())

        #expect(throws: CapabilityUninstaller.UninstallError.requiredBy(packageID: base.name, dependents: ["Dependent Reports"])) {
            try CapabilityUninstaller(library: env.library).remove(base, modelContext: env.context)
        }
        #expect(env.library.installedPackage(id: base.id) != nil)
        #expect(WorkspaceCapabilityActivation.activation(for: base.id, in: env.workspace) != nil)

        _ = try env.library.removePackage(id: dependent.id)
        try CapabilityUninstaller(library: env.library).remove(base, modelContext: env.context)
        #expect(env.library.installedPackage(id: base.id) == nil)
    }
}
