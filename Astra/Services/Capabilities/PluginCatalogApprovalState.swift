import Foundation
import ASTRACore
import ASTRAModels

struct PluginCatalogApprovalReviewState: Equatable {
    var decision: CapabilityCatalogDecision
    var record: CapabilityApprovalRecord?
    var digestLabel: String
    var hasVersionRecord: Bool
    var shouldShow: Bool
}

enum PluginCatalogApprovalState {
    static func policyContext(
        workspace: Workspace,
        approvalRecords: [CapabilityApprovalRecord]
    ) -> CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext.currentUser(
            workspace: workspace,
            approvalRecords: approvalRecords
        )
    }

    static func adminReviewState(
        for package: PluginPackage,
        policyContext: CapabilityCatalogPolicyContext,
        approvalRecords: [CapabilityApprovalRecord]
    ) -> PluginCatalogApprovalReviewState? {
        let decision = CapabilityCatalogPolicy.decision(for: package, context: policyContext)
        let digest = try? CapabilityApprovalDigest.digest(for: package)
        let record = digest.flatMap { digest in
            approvalRecords.last {
                $0.packageID == package.id &&
                $0.packageVersion == package.version &&
                $0.sourceDigest == digest
            }
        }
        let hasVersionRecord = approvalRecords.contains {
            $0.packageID == package.id && $0.packageVersion == package.version
        }
        let digestLabel = record != nil ? "Digest current" : (hasVersionRecord ? "Changed since approval" : "No local record")
        let shouldShow = policyContext.isAdmin
            && (record != nil || decision.requiresApproval || decision.governance.approvalStatus != .approved)
        guard shouldShow else { return nil }

        return PluginCatalogApprovalReviewState(
            decision: decision,
            record: record,
            digestLabel: digestLabel,
            hasVersionRecord: hasVersionRecord,
            shouldShow: shouldShow
        )
    }
}
