import SwiftData
import SwiftUI
import ASTRACore
import ASTRAModels

/// The row under the new-task heading that says which workspace the task will
/// start in, and switches it in place: the current workspace and a few recent
/// ones as segments, everything else behind a "…" menu.
struct NewTaskWorkspacePickerView: View {
    let current: Workspace
    let switcher: NewTaskWorkspaceSwitcher

    @State private var rowIDs: [UUID] = []
    @State private var isMenuPresented = false

    private var displayIDs: [UUID] { rowIDs.isEmpty ? [current.id] : rowIDs }

    private var rowWorkspaces: [Workspace] {
        displayIDs.compactMap { id in switcher.workspaces.first { $0.id == id } }
    }

    private var hasMoreWorkspaces: Bool {
        switcher.workspaces.count > rowWorkspaces.count
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(Stanford.ui(11, weight: .semibold))
                Text("Workspace")
                    .font(Stanford.caption(11).weight(.semibold))
            }
            .foregroundStyle(Stanford.textTertiary)
            .accessibilityHidden(true)

            HStack(spacing: 2) {
                ForEach(rowWorkspaces) { workspace in
                    segment(workspace)
                }
                if hasMoreWorkspaces {
                    moreButton
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(Stanford.fillSoft))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Stanford.borderRest)
            )
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Start this task in workspace")

            Text(WorkspacePathPresentation.abbreviatePath(current.primaryPath))
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(current.primaryPath)
        }
        .onAppear {
            if rowIDs.isEmpty {
                rowIDs = NewTaskWorkspacePicker.initialRow(
                    current: current,
                    workspaces: switcher.workspaces,
                    state: WorkspaceSidebarOrderingStore.load()
                )
            }
        }
        .onChange(of: current.id) {
            rowIDs = NewTaskWorkspacePicker.row(displayIDs, selecting: current.id, in: switcher.workspaces)
        }
    }

    private func segment(_ workspace: Workspace) -> some View {
        let isSelected = workspace.id == current.id
        return Button {
            if !isSelected { switcher.select(workspace) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(Stanford.ui(12))
                    .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.textTertiary)
                Text(NewTaskWorkspacePicker.segmentTitle(workspace.name))
                    .font(Stanford.ui(13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Stanford.lagunita : Stanford.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Stanford.cardBackground)
                            .shadow(color: Color.black.opacity(0.14), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("NewTaskWorkspaceSegment")
        .help(isSelected ? "Tasks start in \(workspace.name)" : "Start this task in \(workspace.name)")
    }

    private var moreButton: some View {
        Button {
            isMenuPresented.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(Stanford.ui(13, weight: .semibold))
                .foregroundStyle(isMenuPresented ? Stanford.lagunita : Stanford.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background {
                    if isMenuPresented {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Stanford.cardBackground)
                            .shadow(color: Color.black.opacity(0.14), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More workspaces")
        .accessibilityIdentifier("NewTaskWorkspaceMore")
        .help("More workspaces")
        .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) {
            NewTaskWorkspaceMenu(
                switcher: switcher,
                currentID: current.id,
                row: displayIDs,
                onPick: { workspace in
                    isMenuPresented = false
                    if workspace.id != current.id { switcher.select(workspace) }
                },
                onClose: { isMenuPresented = false }
            )
        }
    }
}

/// The "…" popover: every workspace, recent ones first, with search.
/// The current one is checked; a teal dot marks workspaces with work running.
private struct NewTaskWorkspaceMenu: View {
    let switcher: NewTaskWorkspaceSwitcher
    let currentID: UUID
    let row: [UUID]
    let onPick: (Workspace) -> Void
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var query = ""
    @State private var orderingState = WorkspaceSidebarOrderingState()
    @State private var running: [UUID: Int] = [:]
    @State private var highlightedID: UUID?
    @FocusState private var isSearchFocused: Bool

    private var groups: [NewTaskWorkspacePicker.MenuGroup] {
        NewTaskWorkspacePicker.menuGroups(
            workspaces: switcher.workspaces,
            row: row,
            query: query,
            state: orderingState
        )
    }

    var body: some View {
        let groups = groups
        let visible = groups.flatMap(\.workspaces)
        return VStack(alignment: .leading, spacing: 0) {
            searchField(visible: visible)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if groups.isEmpty {
                            Text("No workspace matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                                .font(Stanford.body(13))
                                .foregroundStyle(Stanford.textSecondary)
                                .padding(14)
                        }
                        ForEach(groups) { group in
                            groupSection(group)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
                .onChange(of: highlightedID) {
                    if let highlightedID { proxy.scrollTo(highlightedID) }
                }
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            orderingState = WorkspaceSidebarOrderingStore.load()
            running = NewTaskWorkspaceActivity.runningCounts(in: modelContext)
            isSearchFocused = true
            highlightedID = currentID
        }
        .onChange(of: query) {
            highlightedID = groups.first?.workspaces.first?.id
        }
    }

    private func searchField(visible: [Workspace]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Stanford.ui(12))
                .foregroundStyle(Stanford.textTertiary)
            TextField("Find a workspace", text: $query)
                .textFieldStyle(.plain)
                .font(Stanford.body(13))
                .focused($isSearchFocused)
                .onSubmit {
                    if let workspace = visible.first(where: { $0.id == highlightedID }) ?? visible.first {
                        onPick(workspace)
                    }
                }
                .onKeyPress(.downArrow) { moveHighlight(by: 1, in: visible); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1, in: visible); return .handled }
                .accessibilityIdentifier("NewTaskWorkspaceSearch")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private func moveHighlight(by offset: Int, in visible: [Workspace]) {
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == highlightedID } ?? (offset > 0 ? -1 : visible.count)
        highlightedID = visible[min(max(index + offset, 0), visible.count - 1)].id
    }

    private func groupSection(_ group: NewTaskWorkspacePicker.MenuGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(Stanford.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(group.workspaces) { workspace in
                workspaceRow(workspace)
            }
        }
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        let isCurrent = workspace.id == currentID
        let isHighlighted = highlightedID == workspace.id
        let runningCount = running[workspace.id] ?? 0
        return Button {
            onPick(workspace)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "folder.fill" : "folder")
                    .font(Stanford.ui(13))
                    .foregroundStyle(isCurrent || isHighlighted ? Stanford.lagunita : Stanford.textSecondary)
                    .frame(width: 18)
                Text(workspace.name)
                    .font(Stanford.ui(13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent || isHighlighted ? Stanford.lagunita : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if runningCount > 0 {
                    Circle()
                        .fill(Stanford.lagunita)
                        .frame(width: 6, height: 6)
                        .help(runningCount == 1 ? "1 task running" : "\(runningCount) tasks running")
                        .accessibilityLabel("\(runningCount) running")
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                } else if isHighlighted {
                    Image(systemName: "return")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Stanford.lagunita.opacity(Stanford.fillTint) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(workspace.id)
        .onHover { hovering in
            if hovering { highlightedID = workspace.id }
        }
        .help(workspace.primaryPath)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("NewTaskWorkspaceMenuItem")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("New workspace…") {
                onClose()
                switcher.createWorkspace()
            }
            Button("Import…") {
                onClose()
                switcher.importWorkspace()
            }
            Spacer()
            Text("↑↓ · ↩ · esc")
                .foregroundStyle(Stanford.textTertiary)
        }
        .buttonStyle(.plain)
        .font(Stanford.caption(12).weight(.semibold))
        .foregroundStyle(Stanford.lagunita)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}
