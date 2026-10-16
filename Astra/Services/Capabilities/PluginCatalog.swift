import Foundation
import ASTRACore

/// Read-side catalog of capability packages. All mutations (enable, disable,
/// remove, import, create) go through `CapabilityCatalogActionService` →
/// `CapabilityInstaller`/`CapabilityUninstaller`; this type only loads the
/// approved/built-in package set and exposes the curated definitions.
@Observable @MainActor
final class PluginCatalog {
    /// Scalar change token for presentation consumers. Catalog packages are
    /// value types, so observing the array through a cached projection does not
    /// reliably register later replacements with Observation.
    private(set) var revision = 0
    var packages: [PluginPackage] = [] {
        didSet { revision &+= 1 }
    }
    private var isLoadingApprovedCapabilities = false

    func loadApprovedCapabilities(
        library: CapabilityLibrary = CapabilityLibrary(),
        announceLibraryMutations: Bool = true
    ) {
        // A repair can publish a synchronous global persistence event. The
        // event handler is the sole reload owner, but it may be invoked before
        // this load returns; ignore that nested request because this load has
        // already read the repaired library and assigned the current snapshot.
        guard !isLoadingApprovedCapabilities else { return }
        isLoadingApprovedCapabilities = true
        defer { isLoadingApprovedCapabilities = false }
        let libraryChanged = (try? library.syncApprovedPackages(Self.builtInPackages)) == true
        packages = library.installedPackages()
        if libraryChanged, announceLibraryMutations {
            CapabilityCatalogPersistenceEvents.post(.global)
        }
    }

    // MARK: - Built-in Package Definitions (Curated)

    /// The built-ins are the bundled manifests and nothing else. There used
    /// to be a compiled copy for an unreadable bundle; it drifted from the
    /// JSON more than once (a pre-broker REDCap workflow shipped for releases),
    /// so an empty bundle is now a logged packaging error, not a quiet switch
    /// to stale definitions.
    nonisolated static let builtInPackages: [PluginPackage] = {
        let bundledPackages = ApprovedCapabilityBundle.packages()
        if bundledPackages.isEmpty {
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                "source": "built_in_bundle_empty"
            ], level: .error)
        }
        return bundledPackages
    }()
}
