import SwiftUI
import ASTRACore
import ASTRAModels

struct CapabilitiesTabContent: View {
    var workspace: Workspace
    var focusPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onPackageFocusChanged: (String?) -> Void = { _ in }
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }

    @State private var catalog = PluginCatalog()

    var body: some View {
        PluginCatalogView(
            workspace: workspace,
            catalog: catalog,
            focus: .all,
            presentation: .embedded,
            focusedPackageID: focusPackageID,
            onCatalogChanged: onCatalogChanged,
            onPackageFocusChanged: onPackageFocusChanged,
            onEditElement: onEditElement
        )
    }
}
