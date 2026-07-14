import SwiftUI

enum NewWorkspaceCommandPresentation {
    static let title = "New Workspace"
    static let hoverFillOpacity: CGFloat = 0.12
    static let hoverLabelLeadingPadding: CGFloat = 8
    static let hoverLabelWidth: CGFloat = 96

    static let hoveredControlWidth = hoverLabelLeadingPadding
        + hoverLabelWidth
        + AstraToolbarCommandMetrics.labelSpacing
        + AstraToolbarCommandMetrics.iconWidth
}

/// The shared workspace-creation affordance used by the expanded sidebar and
/// the collapsed titlebar command bar.
struct NewWorkspaceCommandButton: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: isHovered ? AstraToolbarCommandMetrics.labelSpacing : 0) {
                if isHovered {
                    Text(NewWorkspaceCommandPresentation.title)
                        .font(Stanford.ui(AstraToolbarCommandMetrics.labelFontSize, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: NewWorkspaceCommandPresentation.hoverLabelWidth, alignment: .trailing)
                        .transition(.opacity)
                }

                Image(systemName: "folder.badge.plus")
                    .font(Stanford.ui(AstraToolbarCommandMetrics.iconFontSize, weight: .medium))
                    .frame(
                        width: AstraToolbarCommandMetrics.iconWidth,
                        height: AstraToolbarCommandMetrics.controlHeight
                    )
            }
            .foregroundStyle(isHovered ? Stanford.lagunita : Color.primary)
            .padding(.leading, isHovered ? NewWorkspaceCommandPresentation.hoverLabelLeadingPadding : 0)
            .background {
                Capsule()
                    .fill(
                        Stanford.lagunita.opacity(
                            isHovered ? NewWorkspaceCommandPresentation.hoverFillOpacity : 0
                        )
                    )
            }
            .contentShape(Rectangle())
            .animation(hoverAnimation, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(NewWorkspaceCommandPresentation.title)
        .accessibilityIdentifier("NewWorkspaceButton")
        .accessibilityLabel(NewWorkspaceCommandPresentation.title)
        .accessibilityHint("Creates a new workspace")
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}
