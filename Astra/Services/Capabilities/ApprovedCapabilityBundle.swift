import Foundation
import ASTRACore

enum ApprovedCapabilityBundle {
    static func packages(bundle: Bundle = AstraResourceBundle.current) -> [PluginPackage] {
        guard let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Capabilities") else {
            return []
        }

        let decoder = JSONDecoder()
        return urls
            .compactMap { url -> PluginPackage? in
                guard let data = try? HostFileAccessBroker().readData(
                    at: url,
                    intent: .astraManagedStorage(root: url.deletingLastPathComponent())
                ) else { return nil }
                // Built-ins ship as Plugins 2.0 manifests; packages still read.
                // A file that decodes as neither is a broken build, not an empty
                // catalog, so it is logged rather than skipped in silence.
                let package: PluginPackage
                do {
                    package = try PluginManifestConverter.decodePackage(from: data, decoder: decoder)
                } catch {
                    AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                        "source": "built_in_bundle_decode",
                        "file": url.lastPathComponent,
                        "error_type": String(describing: type(of: error))
                    ], level: .error)
                    return nil
                }
                var builtIn = package
                if builtIn.sourceMetadata == nil {
                    builtIn.sourceMetadata = .builtIn()
                }
                if builtIn.iconDescriptor.kind == .asset {
                    builtIn.sourceMetadata?.url = url
                }
                return builtIn
            }
            .sorted { lhs, rhs in
                lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending ||
                (lhs.category == rhs.category &&
                 lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending)
            }
    }

    static func bundledDirectory(bundle: Bundle = AstraResourceBundle.current) -> URL? {
        bundle.url(forResource: "Capabilities", withExtension: nil)
    }
}
