import Foundation

/// Single source of truth for what workspace-dependent chrome (sidebar list
/// controls, the Routines section, the titlebar creation command) should show
/// given how many workspaces exist. Replaces each surface independently
/// re-deriving "is there a workspace" from its own local state.
struct WorkspaceAvailabilityPresentation: Equatable {
    let hasWorkspaces: Bool

    init(workspaceCount: Int) {
        hasWorkspaces = workspaceCount > 0
    }

    /// Driven by the raw workspace count, not by how many are currently
    /// *visible* after a search/star filter — a filter that matches nothing
    /// must not also hide the control needed to undo it.
    var showsListControls: Bool { hasWorkspaces }
    var showsRoutinesSection: Bool { hasWorkspaces }
    var showsTitlebarCreationCommand: Bool { hasWorkspaces }

    static let sidebarEmptyPlaceholder = "Workspaces will appear here."
    static let onboardingTitle = "Add your first workspace"
    static let onboardingBody = "Create a workspace or import an existing folder."
    static let onboardingFootnote = "ASTRA reopens it automatically next time."
}
