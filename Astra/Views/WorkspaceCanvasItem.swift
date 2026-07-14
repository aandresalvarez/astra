import SwiftUI

/// Layout value types for the docked Shelf column — which artifact is shown, its sizing, and
/// the resize-boundary metrics. Extracted from ContentView (which is at its line budget); the
/// behavior is unchanged. These were file-private to ContentView and are now module-internal.

/// Layout-level artifacts shown in the docked Shelf column.
/// Future cases can choose wider sizing for browser or file previews.
enum WorkspaceCanvasItem: String, Equatable {
    case plan
    case markdown
    case browser
    case query
    /// The live app preview shown while building an app by chatting in App Studio. Reuses
    /// the full interactive `WorkspaceAppPreviewView` (which scrolls its content), so it can
    /// dock narrower than the standalone sheet and leave the chat column room to breathe.
    case appPreview

    var minWidth: CGFloat {
        descriptor.minWidth
    }
    var idealWidth: CGFloat {
        descriptor.idealWidth
    }
    var maxWidth: CGFloat {
        descriptor.maxWidth
    }
    var title: String {
        descriptor.title
    }
    var closesWhenDraggedBelowMinimum: Bool {
        descriptor.closesWhenDraggedBelowMinimum
    }

    private var descriptor: ShelfDescriptor {
        CoreShelfRegistry.requiredDescriptor(for: shelfID)
    }
}

enum WorkspaceRightPanel: Equatable {
    case canvas(WorkspaceCanvasItem)
    case context(UUID)
    var isContext: Bool {
        if case .context = self { return true }
        return false
    }
}

/// A docked panel changes the task transcript's available width. Animating that
/// width asks every visible Markdown block to reflow on every animation frame,
/// which turns a short decorative transition into multi-second main-actor work
/// on long conversations. Docked panels therefore commit their final geometry
/// once; only a true overlay may animate because it leaves detail width stable.
enum WorkspaceRightPanelTransitionMode: Equatable {
    case immediateDocked
    case animatedOverlay

    static func resolve(usesInspectorOverlay: Bool) -> Self {
        usesInspectorOverlay ? .animatedOverlay : .immediateDocked
    }

    var animatesPanel: Bool {
        self == .animatedOverlay
    }

    var disablesLayoutAnimation: Bool {
        self == .immediateDocked
    }
}

/// Determines whether a right panel participates in the task detail's layout
/// proposal. Canvas shelves are composited over a stable, full-width detail
/// surface. Only the chat's readable inner surface receives the unobscured
/// width, avoiding a new proposal for the complete retained task hierarchy.
/// The workspace context panel keeps its existing docked/compact behavior.
enum WorkspaceRightPanelLayoutMode: Equatable {
    case detailOnly
    case dockedContext
    case compositedCanvas
    case overlayContext

    static func resolve(
        panel: WorkspaceRightPanel?,
        usesInspectorOverlay: Bool
    ) -> Self {
        guard let panel else { return .detailOnly }
        switch panel {
        case .canvas:
            return .compositedCanvas
        case .context:
            return usesInspectorOverlay ? .overlayContext : .dockedContext
        }
    }

    var preservesDetailProposalWidth: Bool {
        self != .dockedContext
    }

    func detailProposalWidth(availableWidth: CGFloat, panelWidth: CGFloat) -> CGFloat {
        preservesDetailProposalWidth ? availableWidth : max(0, availableWidth - panelWidth)
    }

    func detailUnobscuredWidth(availableWidth: CGFloat, panelWidth: CGFloat) -> CGFloat {
        self == .compositedCanvas
            ? max(0, availableWidth - panelWidth)
            : detailProposalWidth(availableWidth: availableWidth, panelWidth: panelWidth)
    }
}

struct ShelfBoundaryMetrics: Equatable {
    var width: CGFloat = 0
    var isVisible = false
    var isResizing = false
    static let hidden = ShelfBoundaryMetrics()
}

struct ShelfBoundaryMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = ShelfBoundaryMetrics.hidden

    static func reduce(value: inout ShelfBoundaryMetrics, nextValue: () -> ShelfBoundaryMetrics) {
        let next = nextValue()
        if next.isVisible {
            value = next
        }
    }
}

struct ShelfBoundaryOverlayModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ShelfBoundaryMetricsPreferenceKey.self) { metrics in
            ShelfBoundaryOverlay(metrics: metrics)
        }
    }
}

struct ShelfBoundaryOverlay: View {
    let metrics: ShelfBoundaryMetrics

    var body: some View {
        if metrics.isVisible {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: borderWidth)
                    Spacer(minLength: 0)
                }
                .frame(width: metrics.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.all, edges: .top)
            .allowsHitTesting(false)
        }
    }

    private var borderColor: Color {
        metrics.isResizing ? Stanford.lagunita.opacity(0.95) : Color.primary.opacity(0.12)
    }

    private var borderWidth: CGFloat {
        metrics.isResizing ? 3 : 1
    }
}
