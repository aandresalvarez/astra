import SwiftUI
import ASTRAModels

/// Trailing workspace metadata and controls. Its active-work summary remains
/// visible until hover swaps this slot for the available workspace actions.
struct WorkspaceRowActions: View {
    let workspace: Workspace
    /// True while the new-task composer is open on this workspace.
    let isNewTaskTarget: Bool
    let isRowHovered: Bool
    let activityCounts: SidebarWorkspaceActivityCounts
    let onNewTask: () -> Void

    /// Extra trailing room on the one row that carries the new-task mark, so it
    /// never crowds the star or the running/waiting counts out of the slot. The
    /// row's right edge does not move; its title just truncates a little earlier.
    private static let newTaskTargetExtraWidth: CGFloat = 40

    @FocusState private var isNewTaskFocused: Bool
    @State private var isNewTaskHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoverAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.10) }

    private var showsActions: Bool { isRowHovered || isNewTaskFocused }

    var body: some View {
        ZStack(alignment: .trailing) {
            metadata.opacity(showsActions ? 0 : 1).accessibilityHidden(showsActions)
                .allowsHitTesting(false)
            actions.opacity(showsActions ? 1 : 0).allowsHitTesting(showsActions)
        }
        .frame(width: Self.trailingWidth(isNewTaskTarget: isNewTaskTarget), alignment: .trailing)
        .animation(hoverAnimation, value: showsActions)
    }

    static func trailingWidth(isNewTaskTarget: Bool) -> CGFloat {
        SidebarLeanPresentation.workspaceRowTrailingSlotWidth + (isNewTaskTarget ? newTaskTargetExtraWidth : 0)
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            if isNewTaskTarget { newTaskTargetMark }
            if !activityCounts.isEmpty { WorkspaceActivityIndicator(counts: activityCounts) }
            if workspace.isStarred {
                SidebarWorkspaceStarIcon(role: .workspaceStatus).accessibilityLabel("Starred")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The sidebar half of the new-task workspace switcher: the same pencil the
    /// row's "new chat" button uses, tinted, so it reads as "a task starts here".
    private var newTaskTargetMark: some View {
        Image(systemName: "square.and.pencil")
            .font(Stanford.ui(10, weight: .semibold))
            .foregroundStyle(Stanford.lagunita)
            .frame(width: 22, height: 18)
            .background(Capsule().fill(Stanford.lagunita.opacity(Stanford.fillTint)))
            .help("A new task will start in \(workspace.name)")
            .accessibilityLabel("New task starts here")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onNewTask) {
                accessoryGlyph("square.and.pencil", size: 13, weight: .medium, isHovered: isNewTaskHovered)
            }
            .buttonStyle(.plain).onHover { isNewTaskHovered = $0 }
            .focused($isNewTaskFocused)
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
