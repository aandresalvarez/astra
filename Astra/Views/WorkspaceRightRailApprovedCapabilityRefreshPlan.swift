import Foundation

struct WorkspaceRightRailApprovedCapabilityRefreshPlan: Equatable {
    let shouldRebuildSnapshot: Bool
    let shouldRefreshPrerequisites: Bool

    static func make(
        previousPackageIDs: [String],
        nextPackageIDs: [String],
        previousApprovalRecords: [CapabilityApprovalRecord] = [],
        nextApprovalRecords: [CapabilityApprovalRecord] = [],
        previousPolicy: PackResolvedPolicy,
        nextPolicy: PackResolvedPolicy
    ) -> WorkspaceRightRailApprovedCapabilityRefreshPlan {
        let packagesChanged = normalizedIDs(previousPackageIDs) != normalizedIDs(nextPackageIDs)
        let approvalsChanged = previousApprovalRecords != nextApprovalRecords
        let policyChanged = CapabilityRailPackPolicySignature(policy: previousPolicy)
            != CapabilityRailPackPolicySignature(policy: nextPolicy)

        return WorkspaceRightRailApprovedCapabilityRefreshPlan(
            shouldRebuildSnapshot: packagesChanged || approvalsChanged || policyChanged,
            shouldRefreshPrerequisites: packagesChanged
        )
    }

    private static func normalizedIDs(_ ids: [String]) -> [String] {
        ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
    }
}
