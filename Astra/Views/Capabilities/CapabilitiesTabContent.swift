import SwiftUI
import ASTRACore
import ASTRAModels

struct CapabilitiesTabContent: View {
    var workspace: Workspace
    @Binding var selectedPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }

    @State private var catalog = PluginCatalog()

    var body: some View {
        PluginsSurfaceView(
            workspace: workspace,
            catalog: catalog,
            selectedPackageID: $selectedPackageID,
            onCatalogChanged: onCatalogChanged,
            onEditElement: onEditElement
        )
    }
}
