import SwiftUI
import ASTRACore

struct CapabilitiesTabContent: View {
    var workspace: Workspace
    var focusPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onPackageFocusChanged: (String?) -> Void = { _ in }
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }
    var googleWorkspaceSetupState: GoogleWorkspaceSetupState = .setupUnavailable
    @State private var catalog = PluginCatalog()

    var body: some View {
        VStack(spacing: 0) {
            GoogleWorkspaceSetupPanel(state: googleWorkspaceSetupState)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

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
}
