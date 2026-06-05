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
                guard let data = try? Data(contentsOf: url),
                      var package = try? decoder.decode(PluginPackage.self, from: data) else {
                    return nil
                }
                if package.sourceMetadata == nil {
                    package.sourceMetadata = .builtIn()
                }
                return package
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
