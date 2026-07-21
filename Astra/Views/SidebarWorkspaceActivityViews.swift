import SwiftUI
import ASTRAModels

/// Trailing workspace metadata and controls. Its active-work summary remains
/// visible until hover swaps this slot for the available workspace actions.
struct WorkspaceRowActions: View {
    let workspace: Workspace
    let isRowHovered: Bool
    let activityCounts: SidebarWorkspaceActivityCounts
    let onNewTask: () -> Void
    let onToggleStarred: () -> Void
    let onEdit: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isEllipsisHovered = false
    @State private var isNewTaskHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoverAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.10) }

    var body: some View {
        ZStack(alignment: .trailing) {
            metadata.opacity(isRowHovered ? 0 : 1).accessibilityHidden(isRowHovered)
            actions.opacity(isRowHovered ? 1 : 0).allowsHitTesting(isRowHovered)
        }
        .frame(width: SidebarLeanPresentation.workspaceRowTrailingSlotWidth, alignment: .trailing)
        .animation(hoverAnimation, value: isRowHovered)
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            if !activityCounts.isEmpty { WorkspaceActivityIndicator(counts: activityCounts) }
            if workspace.isStarred {
                SidebarWorkspaceStarIcon(role: .workspaceStatus).accessibilityLabel("Starred")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Menu {
                Button(action: onToggleStarred) {
                    Label(workspace.isStarred ? "Unstar Workspace" : "Star Workspace", systemImage: workspace.isStarred ? "star.slash" : "star")
                }
                Divider()
                Button(action: onEdit) { Label("Workspace Details", systemImage: "info.circle") }
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                Divider()
                Button(role: .destructive, action: onDelete) { Label("Remove", systemImage: "trash") }
            } label: {
                accessoryGlyph("ellipsis", size: 14, weight: .semibold, isHovered: isEllipsisHovered)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Stanford.lagunita).fixedSize()
            .onHover { isEllipsisHovered = $0 }.help("Workspace options")
            .accessibilityLabel("Options for \(workspace.name)")

            Button(action: onNewTask) {
                accessoryGlyph("square.and.pencil", size: 13, weight: .medium, isHovered: isNewTaskHovered)
            }
            .buttonStyle(.plain).onHover { isNewTaskHovered = $0 }
            .help("Start new chat in Astra").accessibilityLabel("Start new chat in \(workspace.name)")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func accessoryGlyph(_ symbol: String, size: CGFloat, weight: Font.Weight, isHovered: Bool) -> some View {
        Image(systemName: symbol)
            .font(Stanford.ui(size, weight: weight)).foregroundStyle(Stanford.lagunita)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: Stanford.radiusSmall - 1, style: .continuous).fill(Stanford.lagunita.opacity(isHovered ? 0.14 : 0)))
            .contentShape(Rectangle()).animation(hoverAnimation, value: isHovered)
    }
}

/// Textual supervision summary for a collapsed workspace or hidden-work
/// header. It names both activity states, so waiting cannot look completed.
struct WorkspaceActivityIndicator: View {
    let counts: SidebarWorkspaceActivityCounts

    private var label: String {
        [
            counts.running > 0 ? "\(counts.running) \(counts.running == 1 ? "task" : "tasks") running" : nil,
            counts.waiting > 0 ? "\(counts.waiting) \(counts.waiting == 1 ? "task" : "tasks") waiting" : nil
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 4) {
            if counts.running > 0 {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Stanford.lagunita)
                Text("\(counts.running)")
            }
            if counts.waiting > 0 {
                Image(systemName: "clock").foregroundStyle(Stanford.poppy)
                Text("\(counts.waiting)")
            }
        }
        .font(Stanford.caption(10).weight(.medium)).foregroundStyle(.secondary).fixedSize()
        .help(label).accessibilityLabel(label)
    }
}
