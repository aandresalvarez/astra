import SwiftUI

/// Which spine the sidebar's main section uses.
///
/// `workspaces` is the folder hierarchy: one drawer per workspace, opened one
/// at a time. `tasks` drops the folders entirely and lists every task in one
/// flat, recency-ordered column — title over its workspace name, the same row
/// shape the Activity dock uses. The two alternate in the same section, so
/// switching never moves the header or the rows below it.
enum SidebarBrowseMode: String, CaseIterable, Identifiable {
    case workspaces
    case tasks

    static let `default` = SidebarBrowseMode.workspaces

    /// Unknown raw values (a downgrade, a hand-edited preference) fall back to
    /// the folder list rather than leaving the section blank.
    static func resolve(_ rawValue: String) -> SidebarBrowseMode {
        SidebarBrowseMode(rawValue: rawValue) ?? .default
    }

    var id: String { rawValue }

    var sectionTitle: String {
        switch self {
        case .workspaces: "Workspaces"
        case .tasks: "Tasks"
        }
    }

    var toggled: SidebarBrowseMode {
        switch self {
        case .workspaces: .tasks
        case .tasks: .workspaces
        }
    }

    /// Workspace sort order and the starred filter shape the folder list only.
    /// Leaving them in the header over a flat task list would offer two
    /// controls that silently do nothing.
    var showsWorkspaceListControls: Bool { self == .workspaces }

    /// Activity and Unreads are cross-workspace docks: they exist so live and
    /// unread work stays reachable without opening drawer after drawer. The
    /// flat list already *is* that surface — every task, live work first, in
    /// the same row shape — so in Tasks mode the docks would only repeat the
    /// rows immediately below them. Pinned stays: it is a hand-curated
    /// shortlist, not a view onto state the list already sorts for.
    var showsCrossWorkspaceDocks: Bool { self == .workspaces }
}

enum SidebarBrowseModePresentation {
    /// One glyph for both modes. A glyph that swapped with the mode had to
    /// show a folder over the flat list, which read as a third workspace
    /// control beside sort and star rather than a way out of them. The tint
    /// carries which mode is current; the tooltip names where the switch
    /// goes.
    static let switchGlyph = "arrow.left.arrow.right"

    static func switchHelpText(from mode: SidebarBrowseMode) -> String {
        switch mode.toggled {
        case .workspaces: "Group by workspace"
        case .tasks: "Show all tasks"
        }
    }

    static func switchAccessibilityHint(from mode: SidebarBrowseMode) -> String {
        switch mode.toggled {
        case .workspaces: "Lists workspace folders with their chats inside."
        case .tasks: "Lists every task in one flat list with its workspace."
        }
    }

    static func emptyTitle(isSearchActive: Bool) -> String {
        isSearchActive ? "No task matches" : "No tasks yet"
    }

    static func emptySubtitle(isSearchActive: Bool) -> String {
        isSearchActive ? "Try a different search." : "Start a task to see it here."
    }
}

/// Header switch between the folder list and the flat task list. Borrows the
/// sort and star icons' frame so the trailing control group stays one row of
/// evenly sized targets.
struct SidebarBrowseModeIcon: View {
    let mode: SidebarBrowseMode
    var isHovered = false

    /// With one glyph for both modes, the tint is the only thing saying which
    /// list you are looking at — so it has to track "not the default mode",
    /// the same way the starred filter lights up when it is narrowing.
    private var isActive: Bool { mode != .default }

    var body: some View {
        Image(systemName: SidebarBrowseModePresentation.switchGlyph)
            .font(Stanford.ui(12, weight: .medium))
            .foregroundStyle(isActive ? Stanford.lagunita : Color.secondary)
            .frame(
                width: SidebarWorkspaceStarPresentation.frameSize,
                height: SidebarWorkspaceStarPresentation.frameSize
            )
            .background(
                RoundedRectangle(cornerRadius: SidebarWorkspaceStarPresentation.cornerRadius)
                    .fill(Stanford.lagunita.opacity(isHovered || isActive ? 0.10 : 0))
            )
            .contentShape(Rectangle())
    }
}
