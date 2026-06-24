import SwiftUI

/// Search-aware filtering for the sidebar's inline app rows. Mirrors how chat rows behave
/// during search (see `SidebarTaskIndex.reviewTasks`): with no query — or when the workspace
/// name itself matches — every app shows; otherwise only apps whose name matches the query.
/// Pure + value-typed so it's unit-tested independently of the SwiftUI row.
enum SidebarWorkspaceAppFilter {
    static func apps(
        _ apps: [WorkspaceApp],
        in workspace: Workspace,
        searchText: String,
        workspaceMatchesSearch: Bool
    ) -> [WorkspaceApp] {
        let id = workspace.id
        let owned = apps.filter { $0.workspaceID == id }
        let scoped = (searchText.isEmpty || workspaceMatchesSearch)
            ? owned
            : owned.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return scoped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether a workspace owns an app matching the active query — used to keep that workspace
    /// visible (and auto-expanded) so the matching app stays reachable during search.
    static func hasMatch(_ apps: [WorkspaceApp], in workspace: Workspace, searchText: String) -> Bool {
        guard !searchText.isEmpty else { return false }
        let id = workspace.id
        return apps.contains { $0.workspaceID == id && $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

/// A tiny group divider inside a workspace drawer ("Apps" / "Tasks"), shown only when both groups
/// are present so durable apps read as distinct from conversational task runs. Lives here (not in
/// `TaskSidebarView`) to keep that file within its architecture-fitness line budget.
struct SidebarGroupLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Stanford.caption(11))
            .foregroundStyle(.tertiary)
            .padding(.leading, SidebarLeanPresentation.childTaskContentLeadingPadding)
            .padding(.top, 4)
            .padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A workspace app rendered inline in the sidebar, directly under its workspace and
/// alongside that workspace's chats. It deliberately reuses the chat row's chrome
/// (`SidebarThreadRowLayout` metrics, selection/hover fill, row height) but swaps the
/// thread/status glyph for the app's own icon, so apps read as durable surfaces you
/// switch to — not conversations. Extracted to its own file to keep `TaskSidebarView`
/// within its architecture-fitness line budget.
struct SidebarWorkspaceAppRow: View {
    let app: WorkspaceApp
    let isSelected: Bool
    var contentLeadingPadding: CGFloat = 0
    let onOpen: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Only non-published apps carry a subtitle; a published app is just icon + name,
    /// the same visual weight as a chat row.
    private var statusSubtitle: String? {
        switch app.lifecycleStatus {
        case .published: return nil
        case .draft:     return "Draft"
        case .disabled:  return "Disabled"
        case .blocked:   return "Needs setup"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: SidebarThreadRowLayout.statusIconTitleSpacing) {
                Image(systemName: app.icon.isEmpty ? "square.grid.2x2" : app.icon)
                    .font(Stanford.ui(13))
                    .foregroundStyle(isSelected ? Stanford.lagunita : .secondary)
                    .frame(
                        width: SidebarThreadRowLayout.statusIconWidth,
                        height: SidebarThreadRowLayout.statusIconWidth
                    )
                    .padding(.leading, contentLeadingPadding)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(Stanford.ui(SidebarThreadRowLayout.titleFontSize, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Stanford.black)
                        .lineLimit(1)
                    if let statusSubtitle {
                        Text(statusSubtitle)
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                // Version badge: a published app shows its current version (v1, v2, …) so its
                // history is legible at a glance — editing-in-place bumps this rather than minting
                // a "Home Notes 2" sibling. The full history lives in the app detail view.
                if app.latestVersionNumber >= 1 {
                    Text("v\(app.latestVersionNumber)")
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .accessibilityLabel("Version \(app.latestVersionNumber)")
                }
            }
            .padding(.horizontal, SidebarThreadRowLayout.rowHorizontalPadding)
            .padding(.vertical, 5)
            .frame(minHeight: Stanford.sidebarThreadRowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                    .fill(isSelected ? Stanford.selectionFill : (isHovered ? Color.primary.opacity(0.052) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Stanford.radiusSmall + 1, style: .continuous)
                    .stroke(
                        isSelected ? Color.primary.opacity(0.10) : (isHovered ? Color.primary.opacity(0.055) : .clear),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { isHovered = hovering }
        }
        .help(app.name)
        .accessibilityIdentifier("SidebarAppRow_\(app.name)")
    }
}
