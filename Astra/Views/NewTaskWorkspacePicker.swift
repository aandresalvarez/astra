import Foundation
import SwiftData
import SwiftUI
import ASTRAModels

/// Presentation rules for the new-task workspace switcher: which workspaces sit
/// in the segmented row and how the "…" menu groups the rest. Everything is
/// derived from the sidebar's ordering rules and the live workspace list; the
/// row is a per-screen presentation and is never persisted.
enum NewTaskWorkspacePicker {
    /// Segments in the row, the current workspace included.
    static let segmentLimit = 4

    /// The row on first appearance: the current workspace, then the workspaces
    /// the sidebar would list first under "Recently used" (starred first).
    static func initialRow(
        current: Workspace,
        workspaces: [Workspace],
        state: WorkspaceSidebarOrderingState,
        limit: Int = segmentLimit
    ) -> [UUID] {
        let others = workspaces.filter { $0.id != current.id }
        let recent = WorkspaceSidebarOrdering.ordered(others, mode: .recent, state: state)
        return ([current] + recent).prefix(max(limit, 1)).map(\.id)
    }

    /// The row after the selection moves. A workspace already in the row leaves
    /// it untouched, so segments never reshuffle under the pointer. A workspace
    /// from the menu joins the row: appended while there is room, otherwise it
    /// takes the last slot. Ids of deleted workspaces are dropped first.
    static func row(
        _ row: [UUID],
        selecting id: UUID,
        in workspaces: [Workspace],
        limit: Int = segmentLimit
    ) -> [UUID] {
        let live = Set(workspaces.map(\.id))
        var next = row.filter(live.contains)
        guard live.contains(id), !next.contains(id) else { return next }
        if next.count >= max(limit, 1) {
            next[next.count - 1] = id
        } else {
            next.append(id)
        }
        return next
    }

    /// A segment hugs its title, so a long workspace name is shortened (the
    /// full name stays in the tooltip and the accessibility label).
    static func segmentTitle(_ name: String, limit: Int = 24) -> String {
        name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
    }

    /// The first `count` segments of the row, always keeping the current
    /// workspace: if it would be cut off it takes the last visible slot. Used
    /// when the pane is too narrow for the whole row.
    static func visibleRow(_ row: [UUID], keeping current: UUID, count: Int) -> [UUID] {
        let count = max(count, 1)
        guard row.count > count else { return row }
        var visible = Array(row.prefix(count))
        if !visible.contains(current), row.contains(current) {
            visible[visible.count - 1] = current
        }
        return visible
    }

    /// Workspaces in the menu's "Recent" section.
    static let recentLimit = 5

    /// One section of the "…" menu.
    struct MenuGroup: Identifiable {
        enum Kind { case recent, all }

        let kind: Kind
        let workspaces: [Workspace]

        var id: Kind { kind }
        var title: String { kind == .recent ? "Recent" : "All workspaces" }
    }

    /// Every workspace, in two sections: the ones opened most recently (from
    /// the sidebar's usage history, newest first), then the rest by name. The
    /// menu is a complete switcher, so nothing is collapsed and a workspace
    /// appears once. Workspaces already in the segmented row never take a
    /// "Recent" slot, since the row is already the quick way to reach them;
    /// they are listed under "All workspaces" like any other. A search keeps
    /// only the names that match, in both.
    static func menuGroups(
        workspaces: [Workspace],
        row: [UUID] = [],
        query: String,
        state: WorkspaceSidebarOrderingState
    ) -> [MenuGroup] {
        let inRow = Set(row)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty
            ? workspaces
            : workspaces.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        let recent = matches
            .filter { state.recentUseDates[$0.id] != nil && !inRow.contains($0.id) }
            .sorted { (state.recentUseDates[$0.id] ?? .distantPast) > (state.recentUseDates[$1.id] ?? .distantPast) }
            .prefix(recentLimit)
        let recentIDs = Set(recent.map(\.id))
        let rest = matches
            .filter { !recentIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return [
            recent.isEmpty ? nil : MenuGroup(kind: .recent, workspaces: Array(recent)),
            rest.isEmpty ? nil : MenuGroup(kind: .all, workspaces: rest)
        ].compactMap { $0 }
    }
}

/// Which workspaces have work running right now, for the menu's running mark.
/// Read from the store when the menu opens and never cached on the workspace,
/// so it cannot drift from the tasks themselves.
enum NewTaskWorkspaceActivity {
    /// Running tasks per workspace id. SwiftData cannot predicate on a
    /// `TaskStatus` value (a captured enum throws `unsupportedPredicate`, a
    /// literal does not compile), so "running" is decided in memory over the
    /// tasks that have not finished, which is a small set.
    @MainActor
    static func runningCounts(in context: ModelContext) -> [UUID: Int] {
        let unfinished = (try? context.fetch(FetchDescriptor<AgentTask>(
            predicate: #Predicate<AgentTask> { $0.completedAt == nil }
        ))) ?? []
        return Dictionary(
            grouping: unfinished.filter { $0.status == .running }.compactMap { $0.workspace?.id },
            by: { $0 }
        ).mapValues(\.count)
    }
}

/// What the new-task screen needs to switch its workspace in place. The scene
/// owns the selection; this only carries the list and the intents, through the
/// environment, so the three view layers between them stay unchanged.
struct NewTaskWorkspaceSwitcher {
    let workspaces: [Workspace]
    let select: (Workspace) -> Void
    let createWorkspace: () -> Void
    let importWorkspace: () -> Void
}

/// The workspace the open new-task composer will start in, nil when no task is
/// being composed. The sidebar reads it to mark that workspace's row, so the two
/// surfaces describe the same choice.
private struct NewTaskComposerWorkspaceIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

private struct NewTaskWorkspaceSwitcherKey: EnvironmentKey {
    static let defaultValue: NewTaskWorkspaceSwitcher? = nil
}

extension EnvironmentValues {
    var newTaskComposerWorkspaceID: UUID? {
        get { self[NewTaskComposerWorkspaceIDKey.self] }
        set { self[NewTaskComposerWorkspaceIDKey.self] = newValue }
    }

    var newTaskWorkspaceSwitcher: NewTaskWorkspaceSwitcher? {
        get { self[NewTaskWorkspaceSwitcherKey.self] }
        set { self[NewTaskWorkspaceSwitcherKey.self] = newValue }
    }
}
