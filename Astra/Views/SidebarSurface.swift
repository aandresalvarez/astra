import AppKit
import SwiftUI

/// The single sidebar surface. Both the docked `NavigationSplitView` column and
/// the floating overlay drawer render their content through this, so the two can
/// never drift back into "two panel styles."
///
/// - `.docked`: the `NavigationSplitView` column already supplies the system
///   source-list vibrancy, so the surface only carries the content.
/// - `.floating`: an explicit `NSVisualEffectView(.sidebar, .behindWindow)`
///   reproduces that *same* source-list material — instead of the old
///   `.ultraThickMaterial`, which read as a denser, different slab over the
///   opaque detail area — plus a trailing hairline and a soft elevation shadow
///   appropriate for a surface that floats. Width comes from the shared model
///   width so a resized docked column and its drawer stay in sync.
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
        case .floating:
            content
                .frame(width: width)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(SidebarVibrancyBackground())
                .overlay(alignment: .trailing) {
                    // Hairline so the drawer reads as a distinct edge over the
                    // detail content, complementing the elevation shadow.
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 14, x: 5, y: 0)
        }
    }
}

/// `NSVisualEffectView` configured as a source-list sidebar, matching the
/// material the docked `NavigationSplitView` column draws for itself — so the
/// floating drawer and the docked column read as the same surface.
private struct SidebarVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
