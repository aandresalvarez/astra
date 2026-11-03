import Foundation
import ASTRACore

/// Derived from the same installed definitions as runtime projection. No
/// cached acceptance state: a different copy or version cannot prove emptiness.
enum PluginCredentialComponentInventory: PluginCredentialComponentInventoryResolving {
    static func componentIDs(pluginID: String, version: String, digest: String) -> [String]? {
        guard let package = CapabilityRuntimeResourceMatcher.packageDefinitions().first(where: { $0.id == pluginID }) else { return nil }
        return componentIDs(in: package, version: version, digest: digest)
    }

    static func componentIDs(in package: PluginPackage, version: String, digest: String) -> [String]? {
        guard !version.isEmpty, version == package.version, !digest.isEmpty else { return nil }
        if let matches = PluginDefinitionDigest.matches(digest, package) {
            guard matches else { return nil }
        } else {
            // Mirrors predating content digests recorded the approval digest.
            guard let accepted = try? CapabilityApprovalDigest.digest(for: package), accepted == digest else { return nil }
        }
        return PluginRuntimeProjection.componentIDs(of: package)
    }
}
