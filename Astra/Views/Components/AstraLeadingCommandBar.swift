import SwiftUI

enum AstraLeadingCommandBarMetrics {
    /// Flush against the traffic lights: no outer inset and no reserved slot —
    /// the cluster's own horizontal padding is the only breathing room. An inert
    /// icon-width spacer used to occupy the first slot on a hunch that clicks
    /// there routed into titlebar chrome, but the toggle bug it accompanied was
    /// actually command delivery + reveal settling (PR #36), and click routing
    /// is owned by `FullScreenSafeHostingView.mouseDownCanMoveWindow` — clicks
    /// on the accessory can never start a window drag, whichever slot is first.
    static let leadingPadding: CGFloat = 0
    static let trailingPadding: CGFloat = 2
}

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
    let sidebarCommands: SidebarTitlebarCommandBridge
    @Binding var isSidebarToggleHovered: Bool
    let isSidebarHidden: Bool
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
            Button {
                sidebarCommands.requestSidebarToggle()
            } label: {
                AstraToolbarCommandIcon(systemImage: "sidebar.left", isActive: false)
            }
            .buttonStyle(.plain)
            .help(sidebarToggleHelp)
            .onHover { isSidebarToggleHovered = $0 }
            .onDisappear { isSidebarToggleHovered = false }
            .accessibilityIdentifier("SidebarToggleButton")
            .accessibilityLabel(sidebarToggleHelp)

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
        .padding(.leading, AstraLeadingCommandBarMetrics.leadingPadding)
        .padding(.trailing, AstraLeadingCommandBarMetrics.trailingPadding)
        // Fill the measured title bar height and center: the icons land on the
        // traffic-light row by construction, with no fixed pixel offset to drift
        // when the title bar height changes. `nil` height = intrinsic, until the
        // coordinator supplies the measurement.
        .frame(height: titleBarHeight, alignment: .center)
    }
}
