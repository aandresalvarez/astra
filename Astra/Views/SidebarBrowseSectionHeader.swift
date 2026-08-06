import SwiftUI

/// Header for the sidebar's main browse section, shared by both modes so the
/// switch between the folder list and the flat task list changes only the
/// title and the count — the control group underneath the cursor stays put.
struct SidebarBrowseSectionHeader: View {
    let mode: SidebarBrowseMode
    let count: Int
    /// Live work whose own row cannot signal right now — the section is
    /// collapsed, or the row is filtered out. Rendered here so running and
    /// waiting work is never invisible. See `SidebarLivenessSignal`.
    let activityCounts: SidebarWorkspaceActivityCounts
    let isExpanded: Bool
    let showsListControls: Bool
    @Binding var sortMode: WorkspaceSidebarSortMode
    let showsStarredOnly: Bool
    let onToggleExpanded: () -> Void
    let onSwitchMode: () -> Void
    let onToggleStarredOnly: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHeaderHovered = false
    @State private var isModeHovered = false
    @State private var isSortHovered = false
    @State private var isFilterHovered = false

    private var disclosureAnimation: Animation? {
        AstraMotion.disclosure(reduceMotion: reduceMotion)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    var body: some View {
        HStack(spacing: 10) {
            title
            Spacer()
            modeSwitch
            if showsListControls && mode.showsWorkspaceListControls {
                sortControl
                starFilter
            }
        }
        .padding(.horizontal, SidebarLeanPresentation.workspaceSectionHorizontalInset)
        // See Routines section — 20pt top creates visual rhythm
        // between top-level sections (Pinned / Workspaces / Routines).
        .padding(.top, 20)
        .padding(.bottom, 4)
        .textCase(nil)
    }

    private var title: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: 5) {
                Text(mode.sectionTitle)
                    .font(Stanford.caption(14))
                    .foregroundStyle(.secondary)
                if count > 0 {
                    SidebarCountBadge(count: count)
                }
                if !activityCounts.isEmpty {
                    WorkspaceActivityIndicator(counts: activityCounts)
                }
                // Hover-only disclosure cue. Lives next to the label rather
                // than at the right edge so the chevron clearly belongs to
                // the section name. Rotation tracks expansion state; opacity
                // tracks header hover so the section reads as pure typography
                // at rest but signals "collapsible" the moment the cursor
                // lands.
                Image(systemName: "chevron.right")
                    .font(Stanford.ui(9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isHeaderHovered ? 1 : 0)
                    .animation(disclosureAnimation, value: isExpanded)
                    .animation(hoverAnimation, value: isHeaderHovered)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
    }

    private var modeSwitch: some View {
        Button(action: onSwitchMode) {
            SidebarBrowseModeIcon(mode: mode, isHovered: isModeHovered)
        }
        .buttonStyle(.plain)
        .onHover { isModeHovered = $0 }
        .help(SidebarBrowseModePresentation.switchHelpText(from: mode))
        .accessibilityLabel(SidebarBrowseModePresentation.switchHelpText(from: mode))
        .accessibilityHint(SidebarBrowseModePresentation.switchAccessibilityHint(from: mode))
        // Without list controls beside it the switch would otherwise sit
        // hard against the rail's rounded edge.
        .padding(.trailing, trailingControlInset)
    }

    private var sortControl: some View {
        Menu {
            Picker("Sort workspaces", selection: $sortMode) {
                ForEach(WorkspaceSidebarSortMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
        } label: {
            SidebarWorkspaceSortIcon(mode: sortMode, isHovered: isSortHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isSortHovered = $0 }
        .help("Sort workspaces: \(sortMode.title)")
        .accessibilityLabel("Sort workspaces, current: \(sortMode.title)")
        .accessibilityHint("Choose name, recently used, or manual order.")
    }

    private var starFilter: some View {
        Button {
            withAnimation(disclosureAnimation) { onToggleStarredOnly() }
        } label: {
            SidebarWorkspaceStarIcon(
                role: .filter(isEnabled: showsStarredOnly),
                isHovered: isFilterHovered
            )
        }
        .buttonStyle(.plain)
        .onHover { isFilterHovered = $0 }
        .help(WorkspaceSidebarFilterPresentation.helpText(isEnabled: showsStarredOnly))
        .accessibilityLabel(WorkspaceSidebarFilterPresentation.helpText(isEnabled: showsStarredOnly))
        .accessibilityHint(WorkspaceSidebarFilterPresentation.accessibilityHint)
        .padding(.trailing, SidebarLeanPresentation.workspaceRowContentTrailingPadding)
    }

    private var trailingControlInset: CGFloat {
        showsListControls && mode.showsWorkspaceListControls
            ? 0
            : SidebarLeanPresentation.workspaceRowContentTrailingPadding
    }
}
