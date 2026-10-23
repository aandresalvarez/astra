import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Stored skill Add approval", .serialized)
struct PluginSyntheticApprovalTests {
    @Test("Adding a reviewable shared skill saves its approval together with enabling the real row")
    func sharedSkillApprovalIsCommitted() throws {
        let env = try PluginAddCommitTests.Fixture(installed: false)
        defer { env.disk.removeFiles() }
        let skill = Skill(name: "Reviewed shared skill", allowedTools: ["Read"])
        skill.isGlobal = true
        env.context.insert(skill)
        try env.context.save()
        var package = env.package
        package.id = "skill." + skill.id.uuidString.lowercased()
        package.sourceMetadata = .init(id: "shared-skills", displayName: "Shared Capability", kind: "shared", trustLevel: "shared")
        package.governance = .localDraft()
        let approvals = CapabilityApprovalStore(directory: env.disk.root.appendingPathComponent("Approvals"))
        let policy = CapabilityCatalogPolicyContext.currentUser(workspace: env.workspace, approvalRecords: [])
        #expect(CapabilityCatalogPolicy.decision(for: package, context: policy).requiresApproval)
        _ = try CapabilityCatalogActionService(library: env.disk.library).add(package, workspace: env.workspace,
            modelContext: env.context, policyContext: policy, approvalStore: approvals, traceID: "synthetic-review")
        let stored = PluginInstallationTransaction.reviewedPackage(package)
        #expect(approvals.record(for: stored)?.status == .approved)
        #expect(env.workspace.enabledGlobalSkillIDs == [skill.id.uuidString])
        #expect(env.disk.library.installedPackages().isEmpty)
        let receipts = try ModelContext(env.disk.container).fetch(FetchDescriptor<PluginOperationReceipt>())
        #expect(receipts.contains { $0.pluginIDs == [package.id] && $0.manifestDigest != nil && $0.completedAt != nil })
    }
}
