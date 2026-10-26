import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Prepared installation source ownership", .serialized)
struct PluginSourceInstallationTests {
    @Test("Create publishes its local origin only after the matching file commit", arguments: [false, true])
    func createOwnershipWaitsForReplay(enable: Bool) throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let original = try PluginSourcesTests.package(id: env.id, version: "1.0.0")
        try env.store.recordProvenance(pluginID: env.id, sourceID: "removed-source", digest: PluginSourceCatalog.contentDigest(original))
        let before = env.store.provenance()[env.id]
        let files = RefusedCreateReplayFiles(root: env.library.directory)
        let library = CapabilityLibrary(directory: env.library.directory, fileManager: files)
        let service = CapabilityCatalogActionService(library: library, sourceStore: env.store)
        var operationID: UUID?
        do {
            _ = try service.create(original, enableHere: enable, sourceURL: nil, workspace: env.workspace,
                modelContext: env.context, policyContext: .currentUser(workspace: env.workspace, approvalRecords: env.approvals.records()), traceID: "source-create-replay")
            Issue.record("A refused replay must retain file and source recovery")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        #expect(env.store.provenance()[env.id] == before)
        #expect(try PluginSourceOperationJournal(store: env.store).pendingIDs() == [id])
        let receipt = try #require(try PluginOperationCommit.read(id, container: env.disk.container))
        #expect(receipt.manifestDigest != nil && receipt.completedAt == nil)
        try env.store.recordProvenance(pluginID: "unrelated", sourceID: "separate", digest: "untouched")
        files.refusesReplay = false
        let reopened = try env.disk.reopen()
        #expect(PluginSourceOperationRecovery(library: library, store: env.store).resumePending(modelContext: reopened.mainContext) == 0)
        #expect(env.store.provenance()[env.id] == nil)
        #expect(env.store.provenance()["unrelated"]?.sourceID == "separate")
        #expect(library.installedPackage(id: env.id) != nil)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<PluginActivation>()).count == (enable ? 1 : 0))
        #expect(try PluginOperationCommit.read(id, container: reopened)?.completedAt != nil)
    }

    @Test("Create cannot consume a held source import just because the old owner is still on disk before commit")
    func plannedLocalOriginDoesNotAdoptSourceState() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let package = try PluginSourcesTests.package(id: env.id, version: "1.0.0")
        try env.store.recordProvenance(pluginID: env.id, sourceID: "old-source", digest: PluginSourceCatalog.contentDigest(package))
        let component = CapabilityResourceOrigin.componentID(for: package.skills[0])
        let pending = RetiredPluginActivation.PendingImport(digest: PluginDefinitionDigest.content(of: package),
            source: "plugin-source:old-source", settings: [component + "#REGION": "held-by-source"],
            overriddenComponentIDs: nil, overridingRowIDs: nil, accounts: nil, knownComponentIDs: nil)
        WorkspaceCapabilityActivation.recordPendingImport(pending, pluginID: package.id, in: env.workspace)
        try env.context.save()
        _ = try env.service.create(package, enableHere: true, sourceURL: nil, workspace: env.workspace,
            modelContext: env.context, policyContext: .currentUser(workspace: env.workspace, approvalRecords: []), traceID: "local-held-source")
        #expect(env.store.provenance()[env.id] == nil)
        #expect(WorkspaceCapabilityActivation.pendingImport(pluginID: env.id, in: env.workspace) == pending)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: env.id, in: env.workspace))
        #expect(activation.configuration(forComponent: component)["REGION"] != "held-by-source")
    }

    @Test("A direct install retries its prepared approval files using the selected approval store")
    func coreInstallerRetryUsesSelectedApprovals() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        let package = PluginInstallationTransaction.reviewedPackage(try PluginSourcesTests.package(id: env.id, version: "1.0.0"))
        let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("SelectedApprovals"))
        var policy = CapabilityCatalogPolicyContext.currentUser(workspace: env.workspace, approvalRecords: [])
        let record = try #require(try CapabilityApprovalGrant.pendingRecord(for: package, context: policy,
            approvedBy: "Direct install", reviewNotes: "Exact prepared approval"))
        policy.approvalRecords.append(record)
        let installer = CapabilityInstaller(library: env.library, sourceStore: env.store)
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        try Data("Blocked mirror".utf8).write(to: support)
        var operationID: UUID?
        do {
            _ = try installer.install(package, into: env.workspace, modelContext: env.context,
                policyContext: policy, approvalStore: approvals, pendingApproval: record)
            Issue.record("The first save must retain its selected approval root")
        } catch let problem as PluginOperationProblem { operationID = problem.operationID }
        let id = try #require(operationID)
        try FileManager.default.removeItem(at: support)
        _ = try installer.install(package, into: env.workspace, modelContext: env.context,
            policyContext: policy, approvalStore: approvals)
        #expect(try PluginOperationCommit.read(id, container: env.disk.container)?.completedAt != nil)
        #expect(approvals.record(for: package)?.status == .approved)
    }

    @Test("Adding the active copy keeps the independently reviewed update and its source")
    func addPreservesPendingReview() throws {
        let env = try PluginSourceDefinitionOperationTests.Fixture()
        defer { env.disk.removeFiles() }
        _ = try env.installApprovedSource()
        let (offered, coordinator) = try env.offered(version: "2.0.0")
        _ = try env.service.importReviewed(offered, workspace: env.workspace, modelContext: env.context, coordinator: coordinator)
        let review = try env.service.reviewStaged(id: env.id)
        let provenance = env.store.provenance()[env.id]
        let active = try #require(env.library.installedPackage(id: env.id))
        _ = try env.service.add(active, workspace: env.workspace, modelContext: env.context,
            policyContext: .currentUser(workspace: env.workspace, approvalRecords: env.approvals.records()), traceID: "add-keeps-review")
        #expect(env.library.stagedPackage(id: env.id)?.version == "2.0.0")
        #expect(env.store.provenance()[env.id] == provenance)
        #expect(try env.service.reviewStaged(id: env.id).digest == review.digest)
    }
}

private final class RefusedCreateReplayFiles: FileManager {
    let root: URL
    var refusesReplay = true
    init(root: URL) { self.root = root; super.init() }
    override func removeItem(at url: URL) throws {
        if refusesReplay, url.deletingLastPathComponent().path == root.path,
           !url.lastPathComponent.hasPrefix(".astra-operation-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
