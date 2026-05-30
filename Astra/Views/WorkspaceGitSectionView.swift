import SwiftUI
import SwiftData

// MARK: - Repository Panel (Git Panel v3)
//
// Honest, lean Git panel rendered in the workspace right rail.
// Rows: Branch · Sync (combined pull+push) · Changes drawer · Open Pull Request.
// Helper-model assists for commit messages and PR drafts via AgentUtilityRuntimeRunner.

struct WorkspaceGitSectionView: View {
    @StateObject var viewModel = WorkspaceGitViewModel()
    let workspace: Workspace
    var isCompact: Bool = false

    @State private var isChangesDrawerExpanded = false
    @State private var showCommitSheet = false
    @State private var showPRDraftSheet = false
    @State private var showLocationPopover = false

    // Row scale shared with the sibling rail panels (Capabilities, Workspace
    // setup) so the Repository card reads as part of the same vertical menu.
    private static let rowIconGlyphSize: CGFloat = 20
    private static let rowIconFrame: CGFloat = 40
    private static let rowIconSpacing: CGFloat = 14
    private static let rowMinHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 14 : Stanford.railSectionContentSpacing) {
            header

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            VStack(spacing: 0) {
                branchRow
                rowDivider

                workingLocationRow
                rowDivider

                changesRow
                if isChangesDrawerExpanded {
                    changesDrawer
                }

                rowDivider
                commitOrPushRow

                rowDivider
                createPullRequestRow
            }
        }
        .onAppear {
            viewModel.setup(for: workspace)
        }
        .onChange(of: viewModel.prDraft) { _, newValue in
            showPRDraftSheet = newValue != nil
        }
        .sheet(isPresented: $showPRDraftSheet, onDismiss: {
            viewModel.dismissPRDraft()
        }) {
            if let draft = viewModel.prDraft {
                PRDraftSheet(
                    draft: draft,
                    onCreate: { edited in
                        viewModel.createPullRequest(with: edited)
                        showPRDraftSheet = false
                    },
                    onOpenInBrowser: { edited in
                        viewModel.openPullRequestURL(with: edited)
                        showPRDraftSheet = false
                    },
                    onCancel: {
                        viewModel.dismissPRDraft()
                        showPRDraftSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCommitSheet) {
            CommitSheet(viewModel: viewModel, onDismiss: {
                showCommitSheet = false
            })
        }
        .sheet(isPresented: $viewModel.isManagingWorktrees) {
            WorktreeSheet(viewModel: viewModel)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Repository")
                .font(Stanford.ui(17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if viewModel.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 12) {
                    if viewModel.repositories.count > 1 {
                        repositoryMenu
                    }
                    refreshButton
                }
            }
        }
    }

    /// Direct refresh action — surfaced inline rather than buried in a menu,
    /// since it is the only always-available header function.
    private var refreshButton: some View {
        Button {
            Task { await viewModel.scanRepositories() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(Stanford.ui(15, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .help("Refresh status")
    }

    /// Repository switcher — shown only when more than one repository exists,
    /// so it earns its place as a menu instead of padding a single-item one.
    private var repositoryMenu: some View {
        Menu {
            ForEach(viewModel.repositories) { repo in
                Button {
                    viewModel.selectedRepository = repo
                } label: {
                    HStack {
                        Text(repo.name)
                        if repo.path == viewModel.selectedRepository?.path {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "folder")
                .font(Stanford.ui(15, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch repository")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Stanford.errorRed)
                .font(Stanford.ui(12))
            Text(message)
                .font(Stanford.caption(11))
                .foregroundStyle(Stanford.errorRed)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Stanford.ui(10, weight: .bold))
                    .foregroundStyle(Stanford.errorRed.opacity(0.8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.errorRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Row separator that begins after the leading icon column, matching the
    /// sibling rail panels (`checklistDivider`): start after the 40pt icon
    /// frame, low opacity, no table-like trailing rule.
    private var rowDivider: some View {
        Divider()
            .opacity(0.22)
            .padding(.leading, Self.rowIconFrame)
    }

    /// Shared leading icon for every collapsed row, sized to the rail's row
    /// grammar (20pt glyph centered in a 40pt column) so the Repository card
    /// scans at the same rhythm as Capabilities and Workspace setup.
    private func rowIcon(_ name: String, color: Color = Stanford.lagunita) -> some View {
        Image(systemName: name)
            .font(Stanford.ui(Self.rowIconGlyphSize, weight: .medium))
            .foregroundStyle(color)
            .frame(width: Self.rowIconFrame)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(Stanford.ui(16, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private var rowDisclosureChevron: some View {
        Image(systemName: "chevron.down")
            .font(Stanford.ui(11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Branch row

    private var branchRow: some View {
        Button {
            viewModel.showBranchPickerPopover = true
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon("arrow.triangle.branch")
                rowTitle("Branch")

                Spacer(minLength: 8)

                Text(viewModel.currentBranch.isEmpty ? "Select…" : viewModel.currentBranch)
                    .font(Stanford.caption(13).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                rowDisclosureChevron
            }
            .frame(minHeight: Self.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .popover(isPresented: $viewModel.showBranchPickerPopover, arrowEdge: .trailing) {
            BranchPickerPopoverView(viewModel: viewModel)
        }
    }

    // MARK: - Working location row

    /// Shows the checkout new chats run in (Root or a worktree). Tapping opens
    /// a popover to switch location or open full worktree management — the same
    /// Button+popover grammar as the branch row. Existing threads keep their own
    /// pinned location; this only steers new work.
    private var workingLocationRow: some View {
        Button {
            showLocationPopover = true
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon(viewModel.isUsingWorktree ? "square.split.2x1" : "house")
                rowTitle("Working in")

                Spacer(minLength: 8)

                Text(workingLocationLabel)
                    .font(Stanford.caption(13).weight(.medium))
                    .foregroundStyle(viewModel.isUsingWorktree ? Stanford.lagunita : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                rowDisclosureChevron
            }
            .frame(minHeight: Self.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .popover(isPresented: $showLocationPopover, arrowEdge: .trailing) {
            WorktreeLocationPopoverView(viewModel: viewModel) {
                showLocationPopover = false
            }
        }
        .help("Choose the checkout new chats run in")
    }

    private var workingLocationLabel: String {
        guard viewModel.isUsingWorktree else { return "Root" }
        return viewModel.activeWorktree?.displayName
            ?? URL(fileURLWithPath: viewModel.activeWorkingPath ?? "").lastPathComponent
    }

    // MARK: - Commit or push row

    private var commitOrPushRow: some View {
        Button {
            showCommitSheet = true
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon("arrow.up.circle")
                rowTitle("Commit or push")

                Spacer(minLength: 8)

                commitOrPushBadge
            }
            .frame(minHeight: Self.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!viewModel.canOpenCommitSheet || viewModel.isSyncing)
    }

    @ViewBuilder
    private var commitOrPushBadge: some View {
        let hasStaged = viewModel.statusFiles.contains(where: { $0.isStaged })
        let hasMessage = !viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasStaged && hasMessage {
            Text("Ready")
                .font(Stanford.caption(13).weight(.medium))
                .foregroundStyle(Stanford.statusHealthy)
        } else if viewModel.pushableCommitCount > 0 {
            Label("\(viewModel.pushableCommitCount)", systemImage: viewModel.hasUpstream ? "arrow.up" : "arrow.up.to.line")
                .labelStyle(.titleAndIcon)
                .font(Stanford.caption(13).weight(.semibold))
                .foregroundStyle(Stanford.lagunita)
        } else if viewModel.behind > 0 {
            Label("\(viewModel.behind)", systemImage: "arrow.down")
                .labelStyle(.titleAndIcon)
                .font(Stanford.caption(13).weight(.semibold))
                .foregroundStyle(Stanford.statusInfo)
        }
    }

    // MARK: - Changes row + drawer

    private var changesRow: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isChangesDrawerExpanded.toggle()
            }
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon("plus.forwardslash.minus")
                rowTitle("Changes")

                Spacer(minLength: 8)

                changesBadge

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isChangesDrawerExpanded ? 90 : 0))
            }
            .frame(minHeight: Self.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(isExpanded: isChangesDrawerExpanded))
        .help(isChangesDrawerExpanded ? "Hide changed files" : "Show changed files")
    }

    @ViewBuilder
    private var changesBadge: some View {
        switch viewModel.changesSummary {
        case .clean:
            Text("Clean")
                .font(Stanford.caption(13).weight(.medium))
                .foregroundStyle(Stanford.statusHealthy)
        case let .modified(additions, deletions, fileCount):
            if additions == 0 && deletions == 0 {
                Text("\(fileCount) changed")
                    .font(Stanford.caption(13).weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .font(Stanford.caption(13).weight(.semibold))
                            .foregroundStyle(Stanford.statusHealthy)
                    }
                    if deletions > 0 {
                        Text("-\(deletions)")
                            .font(Stanford.caption(13).weight(.semibold))
                            .foregroundStyle(Stanford.statusError)
                    }
                }
            }
        }
    }

    private var changesDrawer: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowDivider

            if viewModel.statusFiles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.statusHealthy)
                    Text("Working tree clean")
                        .font(Stanford.caption(12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, Self.rowIconFrame)
                .padding(.vertical, 8)
            } else {
                let staged = viewModel.statusFiles.filter { $0.isStaged }
                let unstaged = viewModel.statusFiles.filter { !$0.isStaged }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !unstaged.isEmpty {
                            fileGroup(
                                title: "Changes (\(unstaged.count))",
                                actionLabel: "Stage all",
                                action: { viewModel.stageAll() },
                                files: unstaged,
                                rowAction: { viewModel.stage(file: $0) },
                                icon: "plus",
                                rowHelp: "Stage file"
                            )
                        }

                        if !staged.isEmpty {
                            fileGroup(
                                title: "Staged (\(staged.count))",
                                actionLabel: "Unstage all",
                                action: { viewModel.unstageAll() },
                                files: staged,
                                rowAction: { viewModel.unstage(file: $0) },
                                icon: "minus",
                                rowHelp: "Unstage file"
                            )
                        }
                    }
                    .padding(.leading, Self.rowIconFrame)
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func fileGroup(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void,
        files: [GitStatusFile],
        rowAction: @escaping (GitStatusFile) -> Void,
        icon: String,
        rowHelp: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(Stanford.caption(11).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(actionLabel, action: action)
                    .buttonStyle(.plain)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.lagunita)
            }
            .padding(.bottom, 2)

            ForEach(files) { file in
                fileRow(file: file, action: { rowAction(file) }, icon: icon, help: rowHelp)
            }
        }
    }

    // MARK: - Create pull request row

    private var createPullRequestRow: some View {
        Button {
            if viewModel.hasUpstream {
                Task { await viewModel.suggestPullRequest() }
            } else {
                viewModel.openPullRequestURL(with: nil)
            }
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                if viewModel.isSuggestingPR {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Self.rowIconFrame)
                } else {
                    rowIcon("arrow.triangle.pull")
                }

                rowTitle("Create pull request")

                Spacer(minLength: 8)

                if viewModel.hasUpstream {
                    Image(systemName: "sparkles")
                        .font(Stanford.ui(13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: Self.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(viewModel.isSuggestingPR)
        .help(viewModel.hasUpstream ? "Draft and create a pull request" : "Open GitHub to start a pull request")
        .contextMenu {
            Button("Open GitHub without draft") {
                viewModel.openPullRequestURL(with: nil)
            }
        }
    }

    // MARK: - File row

    @ViewBuilder
    private func fileRow(file: GitStatusFile, action: @escaping () -> Void, icon: String, help: String) -> some View {
        HStack(spacing: 5) {
            statusBadge(for: file.status)

            Text(file.relativePath)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 4)

            Button(action: action) {
                Image(systemName: icon)
                    .font(Stanford.ui(8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: String) -> some View {
        let displayColor = badgeColor(for: status)
        Text(status)
            .font(Stanford.caption(9).weight(.bold))
            .foregroundStyle(displayColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(displayColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func badgeColor(for status: String) -> Color {
        switch status {
        case "A", "?": return Stanford.statusHealthy
        case "M": return Stanford.statusWarn
        case "D": return Stanford.statusError
        default: return Stanford.statusInfo
        }
    }
}

// MARK: - Row button style

struct RowButtonStyle: ButtonStyle {
    var isExpanded: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isExpanded || configuration.isPressed
                    ? Color.primary.opacity(0.06)
                    : Color.clear
            )
    }
}

// MARK: - Shared popover metrics

/// Shared geometry for the two row-selector popovers (Branch and Working in)
/// so both read as one component family and branch/worktree names stop
/// truncating at narrow widths.
private enum RepoPopover {
    static let width: CGFloat = 280
    static let rowVerticalPadding: CGFloat = 6
    static let listMaxHeight: CGFloat = 200
}

// MARK: - Branch picker

struct BranchPickerPopoverView: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    @State private var searchText = ""
    @State private var showingCreateForm = false

    var body: some View {
        VStack(spacing: 0) {
            if showingCreateForm {
                createForm
            } else {
                pickerList
            }
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    showingCreateForm = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(Stanford.ui(11, weight: .bold))
                        Text("Back")
                            .font(Stanford.caption(11))
                    }
                    .foregroundStyle(Stanford.lagunita)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("New Branch")
                    .font(Stanford.ui(12, weight: .bold))
            }

            TextField("Branch name…", text: $viewModel.newBranchName)
                .textFieldStyle(.roundedBorder)
                .font(Stanford.body(12))
                .controlSize(.small)

            Button {
                viewModel.createAndCheckoutBranch()
                showingCreateForm = false
            } label: {
                Text("Create & Checkout")
                    .font(Stanford.ui(12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(viewModel.newBranchName.isEmpty ? Stanford.sandstone : Stanford.lagunita)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.newBranchName.isEmpty)
        }
        .padding(12)
        .frame(width: RepoPopover.width)
    }

    private var pickerList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(Stanford.ui(11))
                TextField("Search branches", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Stanford.ui(12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Divider().padding(.top, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let filtered = viewModel.branches.filter {
                        searchText.isEmpty ? true : $0.localizedCaseInsensitiveContains(searchText)
                    }

                    if filtered.isEmpty {
                        Text("No branches found")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(filtered, id: \.self) { branch in
                            Button {
                                viewModel.checkout(branch: branch)
                                viewModel.showBranchPickerPopover = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(Stanford.ui(11))
                                        .foregroundStyle(.secondary)

                                    Text(branch)
                                        .font(Stanford.body(12.5).weight(branch == viewModel.currentBranch ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()

                                    if branch == viewModel.currentBranch {
                                        Image(systemName: "checkmark")
                                            .font(Stanford.ui(10, weight: .bold))
                                            .foregroundStyle(Stanford.lagunita)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, RepoPopover.rowVerticalPadding)
                                .background(Color.primary.opacity(branch == viewModel.currentBranch ? 0.04 : 0))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: RepoPopover.listMaxHeight)

            Divider()

            Button {
                showingCreateForm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(Stanford.ui(10, weight: .bold))
                    Text("Create and checkout branch…")
                        .font(Stanford.caption(11.5).weight(.medium))
                }
                .foregroundStyle(Stanford.lagunita)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: RepoPopover.width)
    }
}

// MARK: - Working location picker

/// Quick switcher for the checkout new chats run in. Mirrors the branch
/// picker's popover grammar so both row selectors feel identical, and hands
/// off to the full management sheet for create/remove.
struct WorktreeLocationPopoverView: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    let onClose: () -> Void

    private var secondaryWorktrees: [GitWorktreeInfo] {
        viewModel.worktrees.filter { !$0.isPrimary }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Working location")
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    locationRow(
                        icon: "house",
                        title: "Root",
                        isActive: !viewModel.isUsingWorktree
                    ) {
                        viewModel.switchToRoot()
                        onClose()
                    }

                    ForEach(secondaryWorktrees) { worktree in
                        locationRow(
                            icon: "arrow.triangle.branch",
                            title: worktree.displayName,
                            isActive: viewModel.activeWorkingPath == worktree.path
                        ) {
                            viewModel.switchWorkingLocation(to: worktree)
                            onClose()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: RepoPopover.listMaxHeight)

            Divider()

            Button {
                onClose()
                viewModel.isManagingWorktrees = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.split.2x1")
                        .font(Stanford.ui(10, weight: .bold))
                    Text("Manage worktrees…")
                        .font(Stanford.caption(11.5).weight(.medium))
                }
                .foregroundStyle(Stanford.lagunita)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: RepoPopover.width)
    }

    @ViewBuilder
    private func locationRow(
        icon: String,
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(Stanford.ui(11))
                    .foregroundStyle(isActive ? Stanford.lagunita : .secondary)
                    .frame(width: 16)

                Text(title)
                    .font(Stanford.body(12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .font(Stanford.ui(10, weight: .bold))
                        .foregroundStyle(Stanford.lagunita)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, RepoPopover.rowVerticalPadding)
            .background(Color.primary.opacity(isActive ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Commit sheet

struct CommitSheet: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    let onDismiss: () -> Void

    @State private var message = ""
    @State private var includeUnstaged = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text(viewModel.currentBranch)
                    .font(Stanford.ui(15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if viewModel.additions > 0 {
                        Text("+\(viewModel.additions)")
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(Stanford.statusHealthy)
                    }
                    if viewModel.deletions > 0 {
                        Text("-\(viewModel.deletions)")
                            .font(Stanford.caption(12).weight(.semibold))
                            .foregroundStyle(Stanford.statusError)
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(Stanford.body(13))
                    .scrollContentBackground(.hidden)
                    .padding(6)

                if message.isEmpty {
                    Text("Commit message (leave blank to generate)…")
                        .font(Stanford.body(13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 100)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Toggle("Include unstaged changes", isOn: $includeUnstaged)
                .font(Stanford.body(12))
                .toggleStyle(.checkbox)

            Divider()

            actionColumn
        }
        .padding(16)
        .frame(width: 380, height: 392)
    }

    // MARK: - Action column

    /// A single full-width column of actions so every label reads in full.
    /// Only the actions that are meaningful for the current state are shown,
    /// with one clear primary action emphasized.
    @ViewBuilder
    private var actionColumn: some View {
        VStack(spacing: 8) {
            if viewModel.hasChanges {
                commitButton(label: "Commit and push", icon: "arrow.up.circle.fill", andPush: true, prominent: true)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])

                commitButton(label: "Commit", icon: "checkmark.circle", andPush: false, prominent: false)
                    .keyboardShortcut(.return, modifiers: .command)

                if viewModel.canPush {
                    pushButton(prominent: false)
                }
            } else if viewModel.canPush {
                pushButton(prominent: true)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            Button(action: onDismiss) {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func commitButton(label: String, icon: String, andPush: Bool, prominent: Bool) -> some View {
        let button = Button {
            viewModel.commitFromSheet(message: message, includeUnstaged: includeUnstaged, andPush: andPush)
            onDismiss()
        } label: {
            actionLabel(label, icon: icon, busy: andPush)
        }
        .controlSize(.large)
        .disabled(!viewModel.hasChanges || viewModel.isSyncing || viewModel.isSuggestingCommit)

        if prominent {
            button.buttonStyle(.borderedProminent).tint(Stanford.lagunita)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func pushButton(prominent: Bool) -> some View {
        let title = viewModel.hasUpstream ? "Push" : "Publish branch"
        let icon = viewModel.hasUpstream ? "arrow.up" : "arrow.up.to.line"
        let button = Button {
            viewModel.pushOnly()
            onDismiss()
        } label: {
            actionLabel(title, icon: icon, busy: false)
        }
        .controlSize(.large)
        .disabled(!viewModel.canPush || viewModel.isSyncing)

        if prominent {
            button.buttonStyle(.borderedProminent).tint(Stanford.lagunita)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// Full-width label that swaps in inline progress while a long-running
    /// commit/suggestion is in flight.
    @ViewBuilder
    private func actionLabel(_ title: String, icon: String, busy: Bool) -> some View {
        Group {
            if busy && (viewModel.isSyncing || viewModel.isSuggestingCommit) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.isSuggestingCommit ? "Generating message…" : "Working…")
                }
            } else {
                Label(title, systemImage: icon)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - PR draft sheet

struct PRDraftSheet: View {
    let draft: PRSuggestion
    let onCreate: (PRSuggestion) -> Void
    let onOpenInBrowser: (PRSuggestion) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var bodyText: String

    init(
        draft: PRSuggestion,
        onCreate: @escaping (PRSuggestion) -> Void,
        onOpenInBrowser: @escaping (PRSuggestion) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onCreate = onCreate
        self.onOpenInBrowser = onOpenInBrowser
        self.onCancel = onCancel
        self._title = State(initialValue: draft.title)
        self._bodyText = State(initialValue: draft.body)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentDraft: PRSuggestion {
        PRSuggestion(title: title, body: bodyText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull")
                    .font(Stanford.ui(15, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("Open Pull Request")
                    .font(Stanford.ui(15, weight: .bold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.secondary)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.body(13))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Body")
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $bodyText)
                    .font(Stanford.body(12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .padding(6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onOpenInBrowser(currentDraft)
                } label: {
                    Label("Open in GitHub", systemImage: "arrow.up.right.square")
                }
                .disabled(trimmedTitle.isEmpty)

                Button {
                    onCreate(currentDraft)
                } label: {
                    Label("Create Pull Request", systemImage: "arrow.triangle.pull")
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }
}

// MARK: - Worktree management sheet

/// Create, switch, and remove git worktrees. Switching here only steers where
/// *new* chats run — existing threads stay pinned to the worktree they were
/// created in, which is what makes parallel agent work safe.
struct WorktreeSheet: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            createSection

            Divider()

            Text("Worktrees")
                .font(Stanford.caption(10).weight(.bold))
                .foregroundStyle(.secondary)

            worktreeList

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(Stanford.caption(11))
                    .foregroundStyle(Stanford.errorRed)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            HStack {
                Text("New chats start in the active location.")
                    .font(Stanford.caption(10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 460)
        .alert(
            "Discard uncommitted changes?",
            isPresented: Binding(
                get: { viewModel.worktreePendingForceRemoval != nil },
                set: { if !$0 { viewModel.worktreePendingForceRemoval = nil } }
            ),
            presenting: viewModel.worktreePendingForceRemoval
        ) { worktree in
            Button("Remove anyway", role: .destructive) {
                viewModel.removeWorktree(worktree, force: true)
            }
            Button("Cancel", role: .cancel) { viewModel.worktreePendingForceRemoval = nil }
        } message: { worktree in
            Text("\(worktree.displayName) has uncommitted changes. Removing it deletes the checkout on disk. The branch and its commits are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.split.2x1")
                .font(Stanford.ui(15, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
            Text("Worktrees")
                .font(Stanford.ui(15, weight: .bold))
            Spacer()
            if viewModel.isSyncing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New worktree")
                .font(Stanford.caption(10).weight(.bold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("branch-name", text: $viewModel.newWorktreeBranch)
                    .textFieldStyle(.roundedBorder)
                    .font(Stanford.body(12))
                    .controlSize(.small)
                    .onSubmit(create)

                Button(action: create) {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .controlSize(.small)
                .disabled(trimmedBranch.isEmpty || viewModel.isSyncing)
            }
            Text("Creates a new branch off \(viewModel.currentBranch.isEmpty ? "HEAD" : viewModel.currentBranch) and focuses new chats on it.")
                .font(Stanford.caption(10))
                .foregroundStyle(.tertiary)
        }
    }

    private var worktreeList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(viewModel.worktrees) { worktree in
                    worktreeRow(worktree)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color.primary.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func worktreeRow(_ worktree: GitWorktreeInfo) -> some View {
        let isActive = worktree.isPrimary
            ? !viewModel.isUsingWorktree
            : viewModel.activeWorkingPath == worktree.path
        HStack(spacing: 10) {
            Image(systemName: worktree.isPrimary ? "house" : "arrow.triangle.branch")
                .font(Stanford.ui(12, weight: .medium))
                .foregroundStyle(isActive ? Stanford.lagunita : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.isPrimary ? "Root" : worktree.displayName)
                    .font(Stanford.body(12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(worktree.path)
                    .font(Stanford.ui(10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if isActive {
                Text("Active")
                    .font(Stanford.caption(10).weight(.semibold))
                    .foregroundStyle(Stanford.lagunita)
            } else {
                Button("Switch") {
                    if worktree.isPrimary {
                        viewModel.switchToRoot()
                    } else {
                        viewModel.switchWorkingLocation(to: worktree)
                    }
                }
                .buttonStyle(.plain)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
            }

            if !worktree.isPrimary {
                Button {
                    attemptRemoval(worktree)
                } label: {
                    Image(systemName: "trash")
                        .font(Stanford.ui(11))
                        .foregroundStyle(viewModel.hasActiveTaskPinned(to: worktree) ? Color.secondary : Stanford.errorRed)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.hasActiveTaskPinned(to: worktree))
                .help(viewModel.hasActiveTaskPinned(to: worktree)
                      ? "A running task is using this worktree"
                      : "Remove worktree")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var trimmedBranch: String {
        viewModel.newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedBranch.isEmpty else { return }
        viewModel.createWorktree(branch: trimmedBranch)
    }

    /// Removing a clean worktree succeeds immediately; a dirty one routes through
    /// the view model's confirmation state before forcing, so we never silently
    /// discard work.
    private func attemptRemoval(_ worktree: GitWorktreeInfo) {
        viewModel.errorMessage = nil
        viewModel.removeWorktree(worktree, force: false)
    }
}

