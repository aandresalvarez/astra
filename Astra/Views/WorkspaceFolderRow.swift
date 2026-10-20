import SwiftUI
import ASTRAModels

/// Folder disclosure and its independent row accessories share one surface.
/// Callbacks keep scene selection and workspace mutations with their owners.
struct WorkspaceFolderRow: View {
    let workspace: Workspace
    let isExpanded: Bool
    let isSelected: Bool
    let isHovered: Bool
    let isNewTaskTarget: Bool
    let activityCounts: SidebarWorkspaceActivityCounts
    let allowsReordering: Bool
    let onToggle: () -> Void
    let onNewTask: () -> Void
    let onBeginDrag: () -> NSItemProvider

    var body: some View {
        // The disclosure button owns the whole painted surface. Accessories
        // are siblings above it, so their actions never also toggle the folder.
        disclosure
            .overlay(alignment: .trailing) {
                accessories.padding(.trailing, SidebarLeanPresentation.workspaceRowContentTrailingPadding)
            }
            .overlay(alignment: .leading) {
                if allowsReordering {
                    dragHandle.padding(.leading, SidebarLeanPresentation.workspaceRowContentLeadingPadding)
                }
            }
    }

    private var disclosure: some View {
        Button(action: onToggle) {
            folderLabel
                .padding(.leading, SidebarLeanPresentation.workspaceRowContentLeadingPadding
                         + (allowsReordering ? 20 + SidebarLeanPresentation.workspaceRowElementSpacing : 0))
                .padding(.trailing, SidebarLeanPresentation.workspaceRowContentTrailingPadding
                         + WorkspaceRowActions.trailingWidth(isNewTaskTarget: isNewTaskTarget)
                         + SidebarLeanPresentation.workspaceRowElementSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Stanford.sidebarWorkspaceRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isExpanded ? "Collapse \(workspace.name)" : "Expand \(workspace.name)")
        .accessibilityHint("Expands or collapses the workspace.")
        .help(workspace.name)
    }

    private var folderLabel: some View {
        HStack(spacing: SidebarLeanPresentation.workspaceRowElementSpacing) {
            WorkspaceFolderIcon(isExpanded: isExpanded)
                .font(Stanford.ui(13, weight: .medium))
                .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                .frame(width: SidebarLeanPresentation.workspaceFolderIconWidth, height: 22)
            Text(workspace.name)
                .font(Stanford.body(15))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var accessories: some View {
        WorkspaceRowActions(
            workspace: workspace,
            isNewTaskTarget: isNewTaskTarget,
            isRowHovered: isHovered,
            activityCounts: activityCounts,
            onNewTask: onNewTask
        )
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(Stanford.ui(10, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
            .onDrag(onBeginDrag)
            .help("Drag to reorder \(workspace.name)")
            .accessibilityLabel("Reorder \(workspace.name)")
    }
}
