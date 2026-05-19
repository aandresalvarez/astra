import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Approval")
struct CapabilityApprovalTests {
    @Test("approval record round trips for exact package digest")
    func approvalRecordRoundTripsForExactDigest() throws {
        let (store, root) = makeApprovalStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = makeApprovalPackage()

        let record = try store.save(
            package: package,
            status: .approved,
            approvedBy: "Security",
            reviewNotes: "Reviewed"
        )

        let loaded = try #require(store.record(for: package))
        let expectedDigest = try CapabilityApprovalDigest.digest(for: package)
        #expect(loaded == record)
        #expect(loaded.sourceDigest == expectedDigest)
    }

    @Test("package content changes invalidate previous approval")
    func packageContentChangesInvalidatePreviousApproval() throws {
        let (store, root) = makeApprovalStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = makeApprovalPackage()
        try store.save(package: package, status: .approved, approvedBy: "Security")

        var changed = package
        changed.localTools[0].arguments = "issue list"

        #expect(store.record(for: changed) == nil)
        #expect(try CapabilityApprovalDigest.digest(for: package) != CapabilityApprovalDigest.digest(for: changed))
    }

    @Test("approval store default directories are channel-specific")
    func approvalStoreDirectoriesAreChannelSpecific() {
        let dev = CapabilityApprovalStore.approvalsDirectory(for: .development).path
        let prod = CapabilityApprovalStore.approvalsDirectory(for: .production).path

        #expect(dev.contains("AstraDev/CapabilityApprovals"))
        #expect(prod.contains("Astra/CapabilityApprovals"))
        #expect(dev != prod)
    }
}

private func makeApprovalStore() -> (CapabilityApprovalStore, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-capability-approvals-\(UUID().uuidString)", isDirectory: true)
    return (CapabilityApprovalStore(directory: root), root)
}

private func makeApprovalPackage() -> PluginPackage {
    PluginPackage(
        id: "approval-package",
        name: "Approval Package",
        icon: "puzzlepiece.extension",
        description: "Approval test",
        author: "Tests",
        category: "Tests",
        tags: [],
        version: "1.0.0",
        skills: [],
        connectors: [],
        localTools: [
            PluginLocalTool(
                name: "GitHub",
                description: "GitHub CLI",
                icon: "terminal",
                toolType: "cli",
                command: "gh",
                arguments: ""
            )
        ],
        templates: [],
        governance: .localDraft()
    )
}
