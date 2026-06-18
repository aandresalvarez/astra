import SwiftUI

/// A workspace app rendered inline in the sidebar, directly under its workspace and
/// alongside that workspace's chats. It deliberately reuses the chat row's chrome
/// (`SidebarThreadRowLayout` metrics, selection/hover fill, row height) but swaps the
/// thread/status glyph for the app's own icon, so apps read as durable surfaces you
/// switch to — not conversations. Extracted to its own file to keep `TaskSidebarView`
/// within its architecture-fitness line budget.
struct SidebarWorkspaceAppRow: View {
    let app: WorkspaceApp
    let isSelected: Bool
    var contentLeadingPadding: CGFloat = 0
    let onOpen: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Only non-published apps carry a subtitle; a published app is just icon + name,
    /// the same visual weight as a chat row.
    private var statusSubtitle: String? {
        switch app.lifecycleStatus {
        case .published: return nil
        case .draft:     return "Draft"
        case .disabled:  return "Disabled"
        case .blocked:   return "Needs setup"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: SidebarThreadRowLayout.statusIconTitleSpacing) {
                Image(systemName: app.icon.isEmpty ? "square.grid.2x2" : app.icon)
                    .font(Stanford.ui(13))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                    .frame(
                        width: SidebarThreadRowLayout.statusIconWidth,
                        height: SidebarThreadRowLayout.statusIconWidth
                    )
                    .padding(.leading, contentLeadingPadding)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(Stanford.ui(SidebarThreadRowLayout.titleFontSize, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                    if let statusSubtitle {
                        Text(statusSubtitle)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)
            }
            .padding(.horizontal, SidebarThreadRowLayout.rowHorizontalPadding)
            .padding(.vertical, 5)
            .frame(minHeight: Stanford.sidebarThreadRowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                    .fill(isSelected ? Stanford.selectionFill : (isHovered ? Color.primary.opacity(0.052) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                    .stroke(
                        isSelected ? Color.primary.opacity(0.10) : (isHovered ? Color.primary.opacity(0.055) : .clear),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { isHovered = hovering }
        }
        .help(app.name)
        .accessibilityIdentifier("SidebarAppRow_\(app.name)")
    }
}
