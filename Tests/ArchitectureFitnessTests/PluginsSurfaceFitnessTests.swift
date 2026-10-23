import Foundation
import Testing

/// The Plugins 2.0 surface changes capabilities only through
/// `CapabilityCatalogActionService`, like the catalog it replaces: no
/// installer, uninstaller, disabler or approval-store write of its own.
@Suite("Plugins surface fitness")
struct PluginsSurfaceFitnessTests {
    private let viewFiles = [
        "Astra/Views/Capabilities/PluginsSurfaceView.swift",
        "Astra/Views/Capabilities/PluginRowDetailsView.swift",
        "Astra/Views/Capabilities/PluginSourcesSection.swift",
        "Astra/Views/Capabilities/PluginAccountsSection.swift",
        "Astra/Views/Capabilities/PluginStateRecoverySection.swift"
    ]

    @Test("Plugins surface delegates capability side effects to the action service")
    func surfaceDelegatesSideEffects() throws {
        for viewFile in viewFiles {
            let source = try String(contentsOf: repositoryRoot().appendingPathComponent(viewFile), encoding: .utf8)
            #expect(source.contains("CapabilityCatalogActionService()"))
            for forbidden in [
                "CapabilityInstaller(", "CapabilityUninstaller(", "CapabilityPackageCreationService(",
                "CapabilityActivationDisabler(", ".save(package:", "WorkspaceCapabilityActivation.mutate",
                "WorkspaceCapabilityActivation.apply", "WorkspaceCapabilityActivation.bind",
                "WorkspaceCapabilityActivation.unbind", "WorkspaceCapabilityActivation.setConfigValue",
                "WorkspaceCapabilityActivation.updateActivation", "WorkspaceCapabilityActivation.restore",
                "PluginOperations.setSetting", "PluginOperations.addAccount", "PluginOperations.deleteAccount",
                "PluginOperations.makeDefault", "PluginUpdateService.reconcile",
                "PluginSourceStore(", "PluginSourceFetcher(", ".importValidatedPackage(", "coordinator.add(",
                "coordinator.remove(", "coordinator.refresh("
            ] {
                #expect(!source.contains(forbidden), "\(viewFile) calls \(forbidden) directly; go through CapabilityCatalogActionService")
            }
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
