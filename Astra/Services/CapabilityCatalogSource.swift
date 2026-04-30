import Foundation
import ASTRACore

protocol CapabilityCatalogSource {
    var id: String { get }
    var displayName: String { get }
    @MainActor
    func packages() throws -> [PluginPackage]
}

struct LocalCapabilityCatalogSource: CapabilityCatalogSource {
    let id = "local"
    let displayName = "Installed Capabilities"
    let library: CapabilityLibrary

    init(library: CapabilityLibrary = CapabilityLibrary()) {
        self.library = library
    }

    func packages() throws -> [PluginPackage] {
        library.installedPackages()
    }
}

struct BuiltInCapabilityCatalogSource: CapabilityCatalogSource {
    let id = "built-in"
    let displayName = "Built-in Capabilities"

    func packages() throws -> [PluginPackage] {
        PluginCatalog.builtInPackages.map { package in
            var sourced = package
            if sourced.sourceMetadata == nil {
                sourced.sourceMetadata = .builtIn()
            }
            return sourced
        }
    }
}
