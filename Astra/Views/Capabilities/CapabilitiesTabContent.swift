import SwiftUI
import ASTRACore
import ASTRAModels

struct CapabilitiesTabContent: View {
    var workspace: Workspace
    @Binding var selectedPackageID: String?
    var onCatalogChanged: () -> Void = {}
    var onEditElement: (ConfigureTab, UUID) -> Void = { _, _ in }

    @State private var catalog = PluginCatalog()
    /// Re-read when Settings changes the preference, so an open Configure
    /// switches surfaces without being recreated.
    @State private var showsPluginsSurface = PluginsSurfacePreferences.isEnabled()

    var body: some View {
        Group {
            if showsPluginsSurface {
                pluginsSurface
            } else {
                catalogView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PluginsSurfacePreferences.didChange)) { _ in
            showsPluginsSurface = PluginsSurfacePreferences.isEnabled()
        }
    }

    private var pluginsSurface: some View {
        PluginsSurfaceView(
            workspace: workspace,
            catalog: catalog,
            selectedPackageID: $selectedPackageID,
            onCatalogChanged: onCatalogChanged,
            onEditElement: onEditElement
        )
    }

    private var catalogView: some View {
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
