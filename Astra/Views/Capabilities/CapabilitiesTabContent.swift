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
        PluginCatalogView(
            workspace: workspace,
            catalog: catalog,
            focus: .all,
            presentation: .embedded,
            selectedPackageID: $selectedPackageID,
            onCatalogChanged: onCatalogChanged,
            onEditElement: onEditElement
        )
    }
}
