import Foundation
import ASTRACore

/// Immutable presentation state: approval is bound to what this window showed,
/// even if another window legitimately replaces the pending draft meanwhile.
struct PluginStagedReview: Identifiable {
    let package: PluginPackage
    let digest: String
    var id: String { package.id }

    static func capture(id: String, library: CapabilityLibrary) throws -> Self {
        guard let package = library.stagedPackage(id: id) else { throw CapabilityLibrary.RemovalError.notInstalled(id) }
        return try Self(package: package, digest: CapabilityApprovalDigest.digest(for: package))
    }
}
