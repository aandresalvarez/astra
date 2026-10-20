import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Staged approval recovery", .serialized)
struct PluginStagedApprovalRecoveryTests {
    enum SaveFailure: Error { case failed }

    @Test("An imported definition remains installed when its saved state awaits a recovery copy")
    func pendingImportedDefinitionIsNotRolledBack() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.install(PluginOperationsTests.package(version: "1.0.0"))
        let support = URL(fileURLWithPath: WorkspaceFileLayout.supportDirectory(for: env.workspace.primaryPath))
        if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
        try Data("Blocked mirror".utf8).write(to: support)
        let draft = PluginOperationsTests.package(version: "2.0.0")
        let report = CapabilityPackageValidator.validate(package: draft, installedPackages: env.library.installedPackages(), checkPrerequisites: false)
        var operationID: UUID?
        do {
            _ = try CapabilityPackageImporter(library: env.library).importValidatedPackage(report,
                modelContext: env.context, approvalRecords: [])
            Issue.record("The blocked mirror should be reported as pending")
        } catch let problem as PluginOperationProblem {
            if case .savedRecoveryPending(let id) = problem { operationID = id }
            else { throw problem }
        }
        let id = try #require(operationID)
        #expect(env.library.installedPackage(id: draft.id)?.version == "2.0.0")
        let stored = try #require(try PluginOperationCommit.read(id, container: env.container))
        #expect(stored.completedAt == nil)
        #expect(stored.manifestDigest != nil)
    }

    @Test("A failed save restores files; an exception after save retains the committed update", arguments: [false, true])
    func saveProofDecidesRecovery(saveLands: Bool) throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try env.install(PluginOperationsTests.package(version: "1.0.0"))
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals"))
        let original = try #require(env.library.installedPackage(id: "ops.report"))
        _ = try approvals.save(package: original, status: .approved, approvedBy: "Tests")
        let before = approvals.records()
        let draft = PluginOperationsTests.package(version: "2.0.0")
        try env.library.stage(CapabilityPackageSource(package: draft, manifestURL: nil, assetRootURL: nil))
        var savedID: UUID?
        do {
            _ = try PluginStagedApproval.approve(try PluginStagedReview.capture(id: draft.id, library: env.library), library: env.library, modelContext: env.context,
                approvalStore: approvals, approvedBy: "Tests", persist: { context in
                    if saveLands { try context.save() }
                    throw SaveFailure.failed
                })
            Issue.record("An injected save exception should be reported")
        } catch let problem as PluginOperationProblem {
            #expect(saveLands)
            guard case .savedRecoveryPending(let id) = problem else { Issue.record("Committed operation was classified incorrectly"); return }
            savedID = id
        } catch { #expect(!saveLands) }
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: draft.id, in: env.workspace))
        #expect(activation.recordedVersion == (saveLands ? "2.0.0" : "1.0.0"))
        #expect(env.library.installedPackage(id: draft.id)?.version == activation.recordedVersion)
        #expect((env.library.stagedPackage(id: draft.id) == nil) == saveLands)
        let journal = PluginFileOperationJournal(library: env.library, approvals: approvals)
        if saveLands {
            let id = try #require(savedID)
            #expect(try journal.pendingIDs() == [id])
            #expect(try PluginOperationCommit.read(id, container: env.container)?.completedAt == nil)
            let result = PluginFileOperationRecovery(journal: journal).resumePending(modelContext: env.context)
            #expect(result.completed == 1 && result.deferred == 0)
            #expect(try journal.pendingIDs().isEmpty)
        } else {
            #expect(approvals.records() == before)
            #expect(try journal.pendingIDs().isEmpty)
        }
    }

    @Test("Approval with no activations still commits recovery proof and exact reviewed icon bytes")
    func zeroActivationsAndAssetIdentity() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let root = env.root.appendingPathComponent("Source")
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let bytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
        try bytes.write(to: assets.appendingPathComponent("icon.svg"))
        var draft = PluginOperationsTests.package(version: "2.0.0")
        draft.iconDescriptor = .asset("assets/icon.svg", fallbackSystemName: draft.icon)
        try env.context.save()
        try env.library.stage(CapabilityPackageSource(package: draft, manifestURL: nil, assetRootURL: root))
        let reviewed = try #require(env.library.stagedPackage(id: draft.id))
        let digest = try CapabilityApprovalDigest.digest(for: reviewed)
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals"))
        let installed = try CapabilityCatalogActionService(library: env.library)
            .approveStaged(try PluginStagedReview.capture(id: draft.id, library: env.library), modelContext: env.context, approvalStore: approvals)
        #expect(try CapabilityApprovalDigest.digest(for: installed) == digest)
        #expect(approvals.record(for: installed)?.sourceDigest == digest)
        #expect(try Data(contentsOf: env.library.packageManifestURL(for: draft.id).deletingLastPathComponent().appendingPathComponent("assets/icon.svg")) == bytes)
        let receipts = try ModelContext(env.container).fetch(FetchDescriptor<PluginOperationReceipt>())
        let receipt = try #require(receipts.first { $0.kindRawValue == PluginOperationReceipt.Kind.approval.rawValue })
        #expect(receipt.workspaceIDStrings.isEmpty && receipt.completedAt != nil && receipt.manifestDigest != nil)
        #expect(env.library.stagedPackage(id: draft.id) == nil)
    }

    @Test("A refused reconciliation preserves the approved library, draft and approval records")
    func failedReconciliationRestoresFiles() throws {
        let env = try PluginOperationsTests.Environment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        var original = PluginOperationsTests.package(version: "1.0.0")
        var second = original.skills[0]
        second.id = "b-agent"
        second.name = "B Agent"
        original.skills.append(second)
        try env.install(original)
        for skill in original.skills {
            try PluginOperations.setSetting("PROJECT", to: skill.name, of: skill, pluginID: original.id,
                in: env.workspace, modelContext: env.context)
        }
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals"))
        _ = try approvals.save(package: #require(env.library.installedPackage(id: original.id)),
            status: .approved, approvedBy: "Tests")
        let before = approvals.records()
        var draft = PluginOperationsTests.package(version: "2.0.0")
        draft.skills[0].id = "c-agent"
        draft.skills[0].replaces = ["report-agent", "b-agent"]
        try env.library.stage(CapabilityPackageSource(package: draft, manifestURL: nil, assetRootURL: nil))
        let service = CapabilityCatalogActionService(library: env.library)
        #expect(throws: PluginUpdateService.UpdateError.ambiguousRename(component: "skill:c-agent")) {
            try service.approveStaged(try service.reviewStaged(id: original.id), modelContext: env.context, approvalStore: approvals)
        }
        #expect(env.library.installedPackage(id: original.id)?.version == "1.0.0")
        #expect(env.library.stagedPackage(id: original.id)?.version == "2.0.0")
        #expect(approvals.records() == before)
        #expect(WorkspaceCapabilityActivation.activation(for: original.id, in: env.workspace)?.recordedVersion == "1.0.0")
    }
}
