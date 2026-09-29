import SwiftUI

/// The single sidebar surface. Both the docked `NavigationSplitView` column and
/// the floating overlay drawer render their content through this, so the two can
/// never drift back into "two panel styles."
///
/// Both styles paint `Stanford.sidebarBackground`, an opaque fixed color. The
/// system source-list vibrancy this used to rely on samples whatever sits behind
/// the window, so the sidebar came out warm or cool, light or dark, depending on
/// the wallpaper, Reduce Transparency, and full screen vs windowed.
///
/// - `.docked`: the `NavigationSplitView` column, plus the `Stanford.separator`
///   hairline that replaces the system divider (see `SidebarSplitDivider`).
/// - `.floating`: the overlay drawer, plus a trailing hairline and a soft
///   elevation shadow appropriate for a surface that floats. Width comes from the
///   shared model width so a resized docked column and its drawer stay in sync.
struct SidebarSurface<Content: View>: View {
    enum Style { case docked, floating }

    let style: Style
    let width: CGFloat
    let content: Content

    init(
        style: Style,
        width: CGFloat = SidebarColumnLayout.expandedIdealWidth,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.width = width
        self.content = content()
    }

    var body: some View {
        switch style {
        case .docked:
            content
                .background(Stanford.sidebarBackground, ignoresSafeAreaEdges: .all)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Stanford.separator)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
        case .floating:
            content
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Stanford.sidebarBackground, ignoresSafeAreaEdges: .all)
                .overlay(alignment: .trailing) {
                    // Hairline so the drawer reads as a distinct edge over the
                    // detail content, complementing the elevation shadow.
                    Rectangle()
                        .fill(Stanford.separator)
                        .frame(width: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, x: 5, y: 0)
        }
    }
}
