import Foundation
import ASTRACore

/// The approval record that lets a package be enabled now, when the catalog
/// policy would otherwise hold it for review.
///
/// On a single-user Mac the reviewer is the person adding the plugin, so the
/// separate Approve step is a confirmation they were already giving. The
/// record is still digest-bound, so a changed package is not covered.
enum CapabilityApprovalGrant {
    /// Nil when the package can already be enabled. Throws when approval alone
    /// would not unblock it (an unsafe tool, a pack rule).
    static func pendingRecord(
        for package: PluginPackage,
        context: CapabilityCatalogPolicyContext,
        approvedBy: String,
        reviewNotes: String
    ) throws -> CapabilityApprovalRecord? {
        if CapabilityCatalogPolicy.decision(for: package, context: context).canEnable {
            return nil
        }
        let record = CapabilityApprovalRecord(
            packageID: package.id,
            packageVersion: package.version,
            status: .approved,
            approvedBy: approvedBy,
            approvedAt: Date(),
            reviewNotes: reviewNotes,
            sourceDigest: try CapabilityApprovalDigest.digest(for: package)
        )
        var reviewed = context
        reviewed.approvalRecords.append(record)
        let decision = CapabilityCatalogPolicy.decision(for: package, context: reviewed)
        guard decision.canEnable else {
            throw CapabilityInstaller.InstallationError.blocked(decision.blockerMessages)
        }
        return record
    }
}
