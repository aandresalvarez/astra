import SwiftUI

enum NewWorkspaceCommandPresentation {
    static let title = "New Workspace"
}

/// The fixed-size workspace-creation affordance used by the titlebar command bar.
struct NewWorkspaceCommandButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            AstraToolbarCommandIcon(
                systemImage: "folder.badge.plus",
                isActive: isHovered
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(NewWorkspaceCommandPresentation.title)
        .accessibilityIdentifier("NewWorkspaceButton")
        .accessibilityLabel(NewWorkspaceCommandPresentation.title)
        .accessibilityHint("Creates a new workspace")
    }
}
