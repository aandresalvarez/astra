import Foundation
import ASTRACore

/// Shared clamp for self-declared package governance. Package JSON is not a
/// trust boundary: approval is granted only through digest-bound
/// `CapabilityApprovalStore` records (re-applied at policy time) or by being
/// one of the app's bundled built-in definitions. Both the import path and
/// the library load path run untrusted packages through this normalizer so
/// the two can't drift.
enum CapabilityGovernanceNormalizer {
    /// Forces a package's self-declared source and governance back to the
    /// local-draft baseline. Returns `true` when any field was changed, so
    /// callers can surface a warning or audit entry.
    @discardableResult
    static func clampToLocalDraft(_ package: inout PluginPackage) -> Bool {
        var changed = false

        if package.sourceMetadata != .localLibrary() {
            package.sourceMetadata = .localLibrary()
            changed = true
        }

        if package.governance.approvalStatus != .draft ||
            package.governance.visibility != .adminOnly ||
            !package.governance.requiresAdminApproval ||
            !package.governance.requiresExplicitUserConsent ||
            package.governance.approvedBy != nil ||
            package.governance.approvedAt != nil {
            changed = true
        }

        package.governance.approvalStatus = .draft
        package.governance.visibility = .adminOnly
        package.governance.requiresAdminApproval = true
        package.governance.requiresExplicitUserConsent = true
        package.governance.approvedBy = nil
        package.governance.approvedAt = nil
        if package.governance.policyNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            package.governance.policyNotes = "Local capability package pending review."
        }
        return changed
    }
}
