import AppKit
import SwiftUI
import ASTRAModels

/// Actions are shared by the hover card and the native context menu.
struct WorkspaceSidebarActions {
    let newTask: () -> Void
    let openConfiguration: () -> Void
    let toggleStarred: () -> Void
    let rename: () -> Void
    let remove: () -> Void
}

struct WorkspaceOptionsMenu: View {
    let actions: WorkspaceSidebarActions
    let workspace: Workspace

    var body: some View {
        Button(action: actions.newTask) { Label("New Task", systemImage: "square.and.pencil") }
        if let url = WorkspaceFinderDestination.url(for: workspace.primaryPath) {
            Button { NSWorkspace.shared.open(url) } label: { Label("Open in Finder", systemImage: "folder") }
        }
        Divider()
        Button(action: actions.openConfiguration) { Label("Workspace Configuration", systemImage: "gearshape") }
        Button(action: actions.toggleStarred) {
            Label(workspace.isStarred ? "Unstar Workspace" : "Star Workspace", systemImage: workspace.isStarred ? "star.slash" : "star")
        }
        Button(action: actions.rename) { Label("Rename", systemImage: "pencil") }
        Divider()
        Button(role: .destructive, action: actions.remove) { Label("Remove from ASTRA…", systemImage: "trash") }
    }
}

struct WorkspaceHoverCard: View {
    let workspace: Workspace
    let taskCount: Int
    let actions: WorkspaceSidebarActions
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(workspace.name, systemImage: "folder")
                .font(Stanford.ui(15, weight: .semibold))
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Label("\(taskCount) \(taskCount == 1 ? "task" : "tasks")", systemImage: "bubble.left")
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            Divider()
            if let url = WorkspaceFinderDestination.url(for: workspace.primaryPath) {
                action((workspace.primaryPath as NSString).abbreviatingWithTildeInPath, icon: "folder") {
                    NSWorkspace.shared.open(url)
                }
                .help(workspace.primaryPath)
                Divider()
            }
            action("Workspace Configuration", icon: "gearshape", perform: actions.openConfiguration)
            action(workspace.isStarred ? "Unstar Workspace" : "Star Workspace",
                   icon: workspace.isStarred ? "star.slash" : "star", perform: actions.toggleStarred)
            action("Rename", icon: "pencil", perform: actions.rename)
            Divider()
            action("Remove from ASTRA…", icon: "trash", destructive: true, perform: actions.remove)
        }
        .padding(10)
        .frame(width: 340)
        .background(Stanford.cardBackground, in: RoundedRectangle(cornerRadius: Stanford.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: Stanford.radiusLarge).strokeBorder(Stanford.borderRest, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Options for \(workspace.name)")
    }

    private func action(_ title: String, icon: String, destructive: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        WorkspaceHoverAction(title: title, icon: icon, destructive: destructive) {
            dismiss()
            perform()
        }
    }
}

private struct WorkspaceHoverAction: View {
    let title: String
    let icon: String
    let destructive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Stanford.ui(13))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Stanford.errorRed : Color.primary)
        .background(isHovered ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: Stanford.radiusSmall))
        .onHover { isHovered = $0 }
    }
}
