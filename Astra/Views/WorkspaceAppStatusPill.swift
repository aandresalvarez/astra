import SwiftUI

// Shared status pill used by WorkspaceAppDetailView (and, later, the workspace
// home app card). Extracted into its own file during the F5 re-land so the
// detail view does not depend on the workspace-home wiring landing first.
struct WorkspaceAppStatusPill: View {
    let label: String
    let systemImage: String
    var isWarning = false

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(Stanford.caption(11).weight(.semibold))
            .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            .lineLimit(1)
    }
}
