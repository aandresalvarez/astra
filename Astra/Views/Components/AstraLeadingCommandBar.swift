import SwiftUI

/// Sidebar-toggle + search commands rendered as a plain view so they can live in
/// an AppKit *titlebar accessory* (see `WindowChromeConfigurator`) pinned to the
/// window's leading edge, right after the traffic lights.
///
/// SwiftUI toolbar placement can't keep these next to the window controls: in a
/// `NavigationSplitView`, `.navigation` items resolve to the *detail* column's
/// leading edge, so they drift to the sidebar/detail boundary whenever the column
/// is open. A leading titlebar accessory is column-agnostic — it sits beside the
/// traffic lights in every layout (column open, collapsed, or compact). The
/// built-in NavigationSplitView toggle is suppressed with
/// `.toolbar(removing: .sidebarToggle)` so this is the only such control.
struct AstraLeadingCommandBar: View {
    @Binding var isSearchActive: Bool
    @Binding var isSidebarToggleHovered: Bool
    let isSidebarHidden: Bool
    let onToggleSidebar: () -> Void
    /// Height of the title bar the hosting accessory occupies, measured at runtime
    /// by `WindowChromeConfigurator`. The bar fills it and centers its content, so
    /// the icons sit on the traffic-light row at *any* title bar height (windowed,
    /// zoomed, or full screen). `nil` before the window is laid out → intrinsic
    /// height; the coordinator re-centers on the next layout pass.
    var titleBarHeight: CGFloat? = nil

    private var sidebarToggleHelp: String {
        isSidebarHidden ? "Show sidebar" : "Hide sidebar"
    }

    var body: some View {
        AstraToolbarCommandCluster {
            Button(action: onToggleSidebar) {
                AstraToolbarCommandIcon(systemImage: "sidebar.left", isActive: false)
            }
            .buttonStyle(.plain)
            .help(sidebarToggleHelp)
            .accessibilityIdentifier("SidebarToggleButton")
            .accessibilityLabel(sidebarToggleHelp)
            // Hovering the toggle peeks the collapsed sidebar (the click still
            // fully shows/hides it). SidebarPeekContainer reads this hover state
            // but only opens the peek while the column is actually hidden.
            .onHover { isSidebarToggleHovered = $0 }
            // SwiftUI may skip onHover(false) if the button is removed while
            // hovered; reset defensively so the peek can't strand open.
            .onDisappear { isSidebarToggleHovered = false }

            Button { isSearchActive.toggle() } label: {
                AstraToolbarCommandIcon(systemImage: "magnifyingglass", isActive: isSearchActive)
            }
            .buttonStyle(.plain)
            .help("Search (⌘F)")
            // ⌘F is owned by ContentView (`searchHotkey`): this bar is hosted in an
            // AppKit titlebar accessory, outside the window's key responder chain,
            // so a `.keyboardShortcut` here would never fire.
            .accessibilityLabel("Search")
        }
        // Small breathing room from the traffic lights; AppKit positions the
        // accessory immediately after them, so no large leading inset is needed.
        .padding(.leading, 6)
        .padding(.trailing, 2)
        // Fill the measured title bar height and center: the icons land on the
        // traffic-light row by construction, with no fixed pixel offset to drift
        // when the title bar height changes. `nil` height = intrinsic, until the
        // coordinator supplies the measurement.
        .frame(height: titleBarHeight, alignment: .center)
    }
}
