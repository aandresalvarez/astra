import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@MainActor
@Suite("Staged review identity", .serialized)
struct PluginStagedReviewTests {
    @Test("A stale review never approves or discards a replacement draft", arguments: [false, true])
    func staleReviewIsRejected(discard: Bool) throws {
        let env = try PluginFileOperationRecoveryTests.Fixture()
        defer { env.removeFiles() }
        let original = PluginOperationsTests.package(version: "1.0.0")
        try env.library.install(original, sourceMetadata: .localLibrary())
        let approvals = CapabilityApprovalStore(directory: env.root.appendingPathComponent("Approvals"))
        _ = try approvals.save(package: #require(env.library.installedPackage(id: original.id)), status: .approved, approvedBy: "Test")
        let service = CapabilityCatalogActionService(library: env.library)
        var draft = PluginOperationsTests.package(version: "2.0.0")
        try env.library.stage(.init(package: draft, manifestURL: nil, assetRootURL: nil))
        let review = try service.reviewStaged(id: draft.id)
        // Same ID/version; changed executable content still needs a new review.
        draft.skills[0].behaviorInstructions = "Different instructions"
        try env.library.stage(.init(package: draft, manifestURL: nil, assetRootURL: nil))
        let before = approvals.records()
        do {
            if discard { try service.discardStaged(review, modelContext: env.context) }
            else { _ = try service.approveStaged(review, modelContext: env.context, approvalStore: approvals) }
            Issue.record("A stale review was accepted")
        } catch PluginDefinitionChange.Failure.reviewedBytesChanged { }
        #expect(env.library.installedPackage(id: original.id)?.version == "1.0.0")
        #expect(env.library.stagedPackage(id: original.id)?.skills[0].behaviorInstructions == "Different instructions")
        #expect(approvals.records() == before)
        let refreshed = try service.reviewStaged(id: draft.id)
        if discard {
            try service.discardStaged(refreshed, modelContext: env.context)
            #expect(env.library.stagedPackage(id: original.id) == nil)
            #expect(env.library.installedPackage(id: original.id)?.version == "1.0.0")
        } else {
            let accepted = try service.approveStaged(refreshed, modelContext: env.context, approvalStore: approvals)
            #expect(accepted.skills[0].behaviorInstructions == "Different instructions")
        }
    }
}
