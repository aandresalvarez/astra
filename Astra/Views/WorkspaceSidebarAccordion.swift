import Foundation

/// Accordion policy for the sidebar's workspace drawers: at most one
/// workspace is open by user intent, so the rail always reads as a single
/// open task list. Selection follows focus — selecting a workspace opens
/// its drawer and, by exclusivity, closes every other one.
///
/// Live search layers a non-destructive reveal on top of that intent:
/// matching drawers open while the query is active without touching
/// `openWorkspaceID`, so clearing the query restores the single-open rail.
/// A reveal the user explicitly closes stays closed for the rest of that
/// query (`dismissedWorkspaceIDs`), otherwise the toggle would appear
/// dead on search-revealed rows.
enum WorkspaceSidebarAccordion {
    struct State: Equatable {
        /// The single user-opened drawer; nil when every drawer is closed.
        var openWorkspaceID: UUID?
        /// Drawers the user explicitly closed. Two duties: keeps a dismissed
        /// search reveal closed for the rest of the query, and stops the
        /// deferred selection `onChange` (a collapse click also selects the
        /// workspace it closed) from reopening the drawer one frame later.
        /// Cleared per drawer on reopen and wholesale on query changes.
        var dismissedWorkspaceIDs: Set<UUID> = []
    }

    static func isExpanded(
        workspaceID: UUID,
        state: State,
        isSearchActive: Bool,
        matchesSearch: () -> Bool
    ) -> Bool {
        if state.openWorkspaceID == workspaceID { return true }
        guard isSearchActive, !state.dismissedWorkspaceIDs.contains(workspaceID) else {
            return false
        }
        return matchesSearch()
    }

    /// Header click. `wasExpanded` is the rendered state, so closing works
    /// on search-revealed drawers too — not just the user-opened one.
    static func toggling(_ workspaceID: UUID, in state: State, wasExpanded: Bool) -> State {
        var next = state
        if wasExpanded {
            if next.openWorkspaceID == workspaceID { next.openWorkspaceID = nil }
            next.dismissedWorkspaceIDs.insert(workspaceID)
        } else {
            next.openWorkspaceID = workspaceID
            next.dismissedWorkspaceIDs.remove(workspaceID)
        }
        return next
    }

    /// Direct "work here" intent — open a workspace, start a task in it,
    /// star it while selected. Always opens, clearing any dismissal.
    static func selecting(_ workspaceID: UUID?, in state: State) -> State {
        guard let workspaceID else { return state }
        var next = state
        next.openWorkspaceID = workspaceID
        next.dismissedWorkspaceIDs.remove(workspaceID)
        return next
    }

    /// Observed selection change (the `onChange` echo). Unlike `selecting`,
    /// this respects an explicit dismissal: the collapse click that closed a
    /// drawer also selected its workspace, and that echo must not undo the
    /// collapse one frame later.
    static func selectionChanged(_ workspaceID: UUID?, in state: State) -> State {
        guard let workspaceID, !state.dismissedWorkspaceIDs.contains(workspaceID) else {
            return state
        }
        return selecting(workspaceID, in: state)
    }

    /// Query edits invalidate per-query reveal dismissals.
    static func searchChanged(in state: State) -> State {
        var next = state
        next.dismissedWorkspaceIDs = []
        return next
    }
}
