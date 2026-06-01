import SwiftUI
import SwiftData

// MARK: - Repository Panel (Git Panel v3)
//
// Honest, lean Git panel rendered in the workspace right rail.
// Rows: Branch · Sync (combined pull+push) · Changes drawer · Open Pull Request.
// Helper-model assists for commit messages and PR drafts via AgentUtilityRuntimeRunner.

enum WorkspaceGitPanelPresentation {
    static let startsCollapsed = false
    static let collapsedVisibleRowCount = 1
    static let expandedDetailRowCount = 6
    static let repositorySelectorRowMinHeight: CGFloat = 50
    static let detailRowMinHeight: CGFloat = 44
    static let showDetailsActionTitle = "Show all"
    static let hideDetailsActionTitle = "Hide"
}

private enum WorkspaceGitDetailsMode {
    case summary
    case details
}

struct WorkspaceGitSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject var viewModel = WorkspaceGitViewModel()
    let workspace: Workspace
    var selectedTask: AgentTask?
    var isCompact: Bool = false
    var onTaskCreated: ((AgentTask) -> Void)?
    var onOpenWorkspaceFile: ((String) -> Void)?

    @State private var isChangesDrawerExpanded = false
    @State private var showCommitSheet = false
    @State private var showPRDraftSheet = false
    @State private var showRepositoryPopover = false
    @State private var showLocationPopover = false
    @State private var showPRCommentsPopover = false
    @State private var repositoryDetailsMode: WorkspaceGitDetailsMode =
        WorkspaceGitPanelPresentation.startsCollapsed ? .summary : .details

    // Row scale shared with the sibling rail panels (Capabilities, Workspace
    // setup) so the Repository card reads as part of the same vertical menu.
    private static let rowIconGlyphSize = CapabilityRailLayout.leadingIconFontSize
    private static let rowIconFrame = CapabilityRailLayout.leadingIconFrame
    private static let rowIconSpacing = CapabilityRailLayout.leadingIconSpacing
    private static let rowMinHeight = WorkspaceGitPanelPresentation.detailRowMinHeight
    private static let repositoryRowMinHeight = WorkspaceGitPanelPresentation.repositorySelectorRowMinHeight

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: isCompact
                ? CapabilityRailLayout.compactSectionContentSpacing
                : CapabilityRailLayout.regularSectionContentSpacing
        ) {
            header

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            if repositoryDetailsMode == .details {
                repositoryDetailRows
                collapseDetailsButton
            } else {
                repositorySummaryRow
            }
        }
        .onAppear {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
            applyInitialRepositoryPresentation()
        }
        .onChange(of: selectedTask?.id) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
            applyInitialRepositoryPresentation()
        }
        .onChange(of: selectedTask?.executionRootPath) {
            viewModel.setup(for: workspace, selectedTask: selectedTask)
            applyInitialRepositoryPresentation()
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
        .sheet(item: $viewModel.selectedFileDiff, onDismiss: {
            viewModel.clearSelectedFileDiff()
        }) { diff in
            ChangedFileDiffSheet(
                diff: diff,
                isLoading: viewModel.isLoadingFileDiff,
                onOpenFile: { openChangedFileInShelf(diff.file) },
                onCopyDiff: { copyDiff(diff.diff) },
                onApplyHunk: { patch in viewModel.applyDiffHunk(patch, from: diff) },
                onStageToggle: {
                    if diff.file.isStaged {
                        viewModel.unstage(file: diff.file)
                    } else {
                        viewModel.stage(file: diff.file)
                    }
                    viewModel.clearSelectedFileDiff()
                },
                onDismiss: { viewModel.clearSelectedFileDiff() }
            )
        }
        .sheet(isPresented: $viewModel.isManagingWorktrees) {
            WorktreeSheet(viewModel: viewModel)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Repository")
                .font(Stanford.ui(CapabilityRailLayout.sectionTitleFontSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if viewModel.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                refreshButton
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
                .font(Stanford.ui(CapabilityRailLayout.sectionActionFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 20)
        .help("Refresh status")
    }

    private func applyInitialRepositoryPresentation() {
        repositoryDetailsMode = WorkspaceGitPanelPresentation.startsCollapsed ? .summary : .details
        isChangesDrawerExpanded = false
        showRepositoryPopover = false
        showLocationPopover = false
        viewModel.showBranchPickerPopover = false
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
    /// sibling rail panels (`checklistDivider`): start after the leading icon
    /// frame, low opacity, no table-like trailing rule.
    private var rowDivider: some View {
        Divider()
            .opacity(0.22)
            .padding(.leading, Self.rowIconFrame)
    }

    /// Shared leading icon for every collapsed row, sized to the rail's row
    /// grammar so the Repository card
    /// scans at the same rhythm as Capabilities and Workspace setup.
    private func rowIcon(_ name: String, color: Color = Stanford.lagunita) -> some View {
        Image(systemName: name)
            .font(Stanford.ui(Self.rowIconGlyphSize, weight: .medium))
            .foregroundStyle(color)
            .frame(width: Self.rowIconFrame)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(Stanford.ui(CapabilityRailLayout.rowTitleFontSize, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private var rowDisclosureChevron: some View {
        Image(systemName: "chevron.down")
            .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private var repositorySummaryRow: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                repositoryDetailsMode = .details
            }
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon("folder")

                VStack(alignment: .leading, spacing: CapabilityRailLayout.titleSubtitleSpacing) {
                    rowTitle(repositorySummaryTitle)
                    Text(repositorySummarySubtitle)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Text(WorkspaceGitPanelPresentation.showDetailsActionTitle)
                    .font(Stanford.caption(CapabilityRailLayout.rowActionFontSize).weight(.medium))
                    .foregroundStyle(Stanford.lagunita)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: CapabilityRailLayout.summaryRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show repository controls")
    }

    private var repositoryDetailRows: some View {
        VStack(spacing: 0) {
            repositoryRow
            rowDivider

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
            if let pr = viewModel.openPullRequest {
                pullRequestLinkRow(pr)
            } else {
                createPullRequestRow
            }
        }
    }

    private var collapseDetailsButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                repositoryDetailsMode = .summary
                isChangesDrawerExpanded = false
            }
        } label: {
            Text(WorkspaceGitPanelPresentation.hideDetailsActionTitle)
                .font(Stanford.caption(11).weight(.medium))
                .foregroundStyle(Stanford.lagunita)
                .padding(.leading, Self.rowIconFrame)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("Hide repository controls")
    }

    private var repositorySummaryTitle: String {
        let name = viewModel.selectedRepositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "No repository" ? "Repository" : name
    }

    private var repositorySummarySubtitle: String {
        guard viewModel.selectedRepository != nil else {
            return viewModel.selectedRepositorySubtitle
        }

        var parts: [String] = []
        let branch = viewModel.currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty, branch != "unknown" {
            parts.append(branch)
        }
        parts.append(workingLocationLabel)
        parts.append(changesSummaryCompactText)

        if let pr = viewModel.openPullRequest {
            parts.append("PR #\(pr.number)")
        } else if let issue = viewModel.pullRequestReadinessIssue {
            parts.append(shortPullRequestIssue(issue))
        }

        return parts.joined(separator: " · ")
    }

    private var changesSummaryCompactText: String {
        switch viewModel.changesSummary {
        case .clean:
            return "Clean"
        case let .modified(additions, deletions, fileCount):
            let stats = [
                additions > 0 ? "+\(additions)" : nil,
                deletions > 0 ? "-\(deletions)" : nil
            ].compactMap { $0 }
            return stats.isEmpty ? "\(fileCount) changed" : stats.joined(separator: " ")
        }
    }

    // MARK: - Repository row

    private var repositoryRow: some View {
        Button {
            showRepositoryPopover = true
        } label: {
            HStack(spacing: Self.rowIconSpacing) {
                rowIcon("folder")
                VStack(alignment: .leading, spacing: 1) {
                    rowTitle("Repository")
                    Text(viewModel.activeSelectionScopeLabel)
                        .font(Stanford.caption(10).weight(.medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(viewModel.selectedRepositoryName)
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(viewModel.selectedRepositorySubtitle)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                rowDisclosureChevron
            }
            .frame(minHeight: Self.repositoryRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .popover(isPresented: $showRepositoryPopover, arrowEdge: .trailing) {
            RepositoryPickerPopoverView(viewModel: viewModel) {
                showRepositoryPopover = false
            }
        }
        .help(viewModel.canChangeActiveCodePath ? "Choose active repository" : "This task is pinned to its repository")
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
                    .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.medium))
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
                rowTitle("Checkout")

                Spacer(minLength: 8)

                Text(workingLocationLabel)
                    .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.medium))
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
                .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.medium))
                .foregroundStyle(Stanford.statusHealthy)
        } else if viewModel.pushableCommitCount > 0 {
            Label("\(viewModel.pushableCommitCount)", systemImage: viewModel.hasUpstream ? "arrow.up" : "arrow.up.to.line")
                .labelStyle(.titleAndIcon)
                .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.semibold))
                .foregroundStyle(Stanford.lagunita)
        } else if viewModel.behind > 0 {
            Label("\(viewModel.behind)", systemImage: "arrow.down")
                .labelStyle(.titleAndIcon)
                .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.semibold))
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
                    .font(Stanford.ui(CapabilityRailLayout.rowChevronFontSize, weight: .semibold))
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
                .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.medium))
                .foregroundStyle(Stanford.statusHealthy)
        case let .modified(additions, deletions, fileCount):
            if additions == 0 && deletions == 0 {
                Text("\(fileCount) changed")
                    .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    if additions > 0 {
                        Text("+\(additions)")
                            .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.semibold))
                            .foregroundStyle(Stanford.statusHealthy)
                    }
                    if deletions > 0 {
                        Text("-\(deletions)")
                            .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.semibold))
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
                        if viewModel.hasConflicts {
                            Label("Resolve conflicts before creating a pull request.", systemImage: "exclamationmark.triangle.fill")
                                .font(Stanford.caption(11).weight(.medium))
                                .foregroundStyle(Stanford.statusError)
                                .padding(.bottom, 2)
                        }

                        if !unstaged.isEmpty {
                            fileGroup(
                                title: "Changes (\(unstaged.count))",
                                actionLabel: "Stage all",
                                action: { viewModel.stageAll() },
                                files: unstaged,
                                rowAction: { viewModel.stage(file: $0) },
                                openFile: openChangedFileDiff,
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
                                openFile: openChangedFileDiff,
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
        openFile: @escaping (GitStatusFile) -> Void,
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
                fileRow(
                    file: file,
                    openAction: { openFile(file) },
                    rowAction: { rowAction(file) },
                    icon: icon,
                    help: rowHelp
                )
            }
        }
    }

    // MARK: - Create pull request row

    private var createPullRequestRow: some View {
        Button {
            Task { await viewModel.suggestPullRequest() }
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

                if let issue = viewModel.pullRequestReadinessIssue {
                    Text(shortPullRequestIssue(issue))
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let issue = viewModel.pullRequestLookupIssue {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.statusWarn)
                        .help("Could not check for an existing pull request: \(issue)")
                } else {
                    Image(systemName: "sparkles")
                        .font(Stanford.ui(CapabilityRailLayout.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: Self.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(viewModel.isSuggestingPR)
        .help(viewModel.pullRequestReadinessIssue ?? "Draft and create a pull request")
        .contextMenu {
            Button("Open GitHub without draft") {
                viewModel.openPullRequestURL(with: nil)
            }
        }
    }

    private func shortPullRequestIssue(_ issue: String) -> String {
        if issue.localizedCaseInsensitiveContains("publish") { return "Publish first" }
        if issue.localizedCaseInsensitiveContains("push") { return "Push first" }
        if issue.localizedCaseInsensitiveContains("commit")
            || issue.localizedCaseInsensitiveContains("stash") {
            return "Commit first"
        }
        return "Not ready"
    }

    // MARK: - Existing pull request row

    /// When the current branch already has an open PR, link to it instead of
    /// offering to create a duplicate. Reuses the row grammar with the PR number
    /// as the trailing value and an external-link affordance.
    private func pullRequestLinkRow(_ pr: GitHubPullRequestRef) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.openExistingPullRequest()
            } label: {
                HStack(spacing: Self.rowIconSpacing) {
                    rowIcon("arrow.triangle.pull")
                    rowTitle("Pull request")

                    Spacer(minLength: 8)

                    if pr.isDraft {
                        Text("Draft")
                            .font(Stanford.caption(12).weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Text("#\(pr.number)")
                        .font(Stanford.caption(CapabilityRailLayout.rowSubtitleFontSize).weight(.semibold))
                        .foregroundStyle(Stanford.lagunita)

                    Image(systemName: "arrow.up.right")
                        .font(Stanford.ui(11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: Self.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .layoutPriority(1)

            pullRequestCheckStatus
            pullRequestCommentStatus
        }
        .help(pr.title.isEmpty ? "Open pull request #\(pr.number)" : "Open #\(pr.number): \(pr.title)")
        .contextMenu {
            Button("Copy PR URL") { viewModel.copyPullRequestURL() }
            if viewModel.pullRequestComments?.hasComments == true {
                Button("Address in Chat") { createAddressCommentsTask() }
            }
        }
    }

    @ViewBuilder
    private var pullRequestCheckStatus: some View {
        if viewModel.isRefreshingPullRequestChecks {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.62)
                .frame(width: 18, height: Self.rowMinHeight)
        } else if let summary = viewModel.pullRequestChecks, summary.totalCount > 0 {
            checkBubble(summary)
                .frame(minHeight: Self.rowMinHeight)
        } else if viewModel.pullRequestChecksIssue != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: Self.rowMinHeight)
                .help(viewModel.pullRequestChecksIssue ?? "Could not load pull request checks")
        }
    }

    private func checkBubble(_ summary: GitHubPullRequestCheckSummary) -> some View {
        Label(checkBubbleText(summary), systemImage: checkBubbleIcon(summary))
            .labelStyle(.titleAndIcon)
            .font(Stanford.caption(11).weight(.semibold))
            .foregroundStyle(checkBubbleColor(summary))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(checkBubbleColor(summary).opacity(0.12)))
            .help(checkBubbleHelp(summary))
    }

    private func checkBubbleText(_ summary: GitHubPullRequestCheckSummary) -> String {
        switch summary.state {
        case .none:
            return "0"
        case .passing:
            return "\(summary.passingCount)"
        case .pending:
            return "\(summary.pendingCount)"
        case .failing:
            return "\(summary.failingCount)"
        }
    }

    private func checkBubbleIcon(_ summary: GitHubPullRequestCheckSummary) -> String {
        switch summary.state {
        case .none:
            return "circle"
        case .passing:
            return "checkmark.circle.fill"
        case .pending:
            return "clock.fill"
        case .failing:
            return "xmark.octagon.fill"
        }
    }

    private func checkBubbleColor(_ summary: GitHubPullRequestCheckSummary) -> Color {
        switch summary.state {
        case .none:
            return .secondary
        case .passing:
            return Stanford.statusHealthy
        case .pending:
            return Stanford.statusWarn
        case .failing:
            return Stanford.statusError
        }
    }

    private func checkBubbleHelp(_ summary: GitHubPullRequestCheckSummary) -> String {
        switch summary.state {
        case .none:
            return "No pull request checks reported"
        case .passing:
            return "\(summary.passingCount) pull request check\(summary.passingCount == 1 ? "" : "s") passing"
        case .pending:
            return "\(summary.pendingCount) pull request check\(summary.pendingCount == 1 ? "" : "s") pending"
        case .failing:
            return "\(summary.failingCount) pull request check\(summary.failingCount == 1 ? "" : "s") failing"
        }
    }

    @ViewBuilder
    private var pullRequestCommentStatus: some View {
        if viewModel.isRefreshingPullRequestComments {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.62)
                .frame(width: 18, height: Self.rowMinHeight)
        } else if let summary = viewModel.pullRequestComments, summary.hasComments {
            commentBubble(summary)
                .frame(minHeight: Self.rowMinHeight)
        } else if viewModel.pullRequestCommentsIssue != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Stanford.ui(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: Self.rowMinHeight)
                .help(viewModel.pullRequestCommentsIssue ?? "Could not load pull request comments")
        }
    }

    private func commentBubble(_ summary: GitHubPullRequestCommentSummary) -> some View {
        let newCount = viewModel.newPullRequestCommentCount
        return Button {
            showPRCommentsPopover.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                        .font(Stanford.ui(10, weight: .semibold))
                    Text("\(summary.totalCommentCount)")
                        .font(Stanford.caption(11).weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Stanford.lagunita)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Stanford.lagunita.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Stanford.lagunita.opacity(0.18), lineWidth: 1)
                )

                if newCount > 0 {
                    Circle()
                        .fill(Stanford.statusInfo)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Stanford.cardBackground, lineWidth: 1)
                        )
                        .offset(x: 2, y: -2)
                        .accessibilityLabel("\(newCount) new pull request comments")
                }
            }
        }
        .buttonStyle(.plain)
        .help(commentBubbleHelp(summary, newCount: newCount))
        .popover(isPresented: $showPRCommentsPopover, arrowEdge: .leading) {
            PullRequestCommentsPopover(
                summary: summary,
                newCommentCount: newCount,
                onOpenPR: { viewModel.openExistingPullRequest() },
                onRefresh: { viewModel.refreshPullRequestCommentsNow() },
                onMarkRead: { viewModel.markPullRequestCommentsSeen() },
                onAddress: {
                    showPRCommentsPopover = false
                    createAddressCommentsTask()
                }
            )
        }
    }

    private func commentBubbleHelp(_ summary: GitHubPullRequestCommentSummary, newCount: Int) -> String {
        let comments = "\(summary.totalCommentCount) pull request comment\(summary.totalCommentCount == 1 ? "" : "s")"
        guard newCount > 0 else { return comments }
        return "\(comments), \(newCount) new"
    }

    private func createAddressCommentsTask() {
        guard let task = viewModel.createPullRequestCommentTask(modelContext: modelContext) else { return }
        onTaskCreated?(task)
    }

    private struct PullRequestCommentsPopover: View {
        let summary: GitHubPullRequestCommentSummary
        let newCommentCount: Int
        let onOpenPR: () -> Void
        let onRefresh: () -> Void
        let onMarkRead: () -> Void
        let onAddress: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(summary.comments.prefix(8)) { comment in
                            commentRow(comment)
                        }
                        if summary.comments.count > 8 {
                            Text("+\(summary.comments.count - 8) more")
                                .font(Stanford.caption(12).weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 34)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 300)
            }
            .frame(width: 360)
            .background(Stanford.cardBackground)
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(Stanford.ui(16, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.pullRequest.title.isEmpty ? "Pull request #\(summary.pullRequest.number)" : summary.pullRequest.title)
                            .font(Stanford.ui(15, weight: .semibold))
                            .lineLimit(1)
                        Text(summaryLine)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Button("Address in Chat", action: onAddress)
                        .font(Stanford.caption(12).weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Stanford.lagunita)
                }

                HStack(spacing: 8) {
                    Button(action: onOpenPR) {
                        Label("View PR", systemImage: "arrow.up.right.square")
                            .font(Stanford.caption(12).weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(Stanford.caption(12).weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    if newCommentCount > 0 {
                        Button(action: onMarkRead) {
                            Label("Mark read", systemImage: "checkmark.circle")
                                .font(Stanford.caption(12).weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }

        private var summaryLine: String {
            let comments = "\(summary.totalCommentCount) comment\(summary.totalCommentCount == 1 ? "" : "s")"
            var parts = [comments]
            if summary.unresolvedThreadCount > 0 {
                parts.append("\(summary.unresolvedThreadCount) unresolved")
            }
            if newCommentCount > 0 {
                parts.append("\(newCommentCount) new")
            }
            if summary.isTruncated {
                parts.append("truncated")
            }
            return parts.joined(separator: " · ")
        }

        private func commentRow(_ comment: GitHubPullRequestComment) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(Stanford.ui(18, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 5) {
                    Text(comment.preview)
                        .font(Stanford.ui(13, design: .monospaced))
                        .lineLimit(3)
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Text(comment.locationLabel)
                            .font(Stanford.caption(12).weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("@\(comment.author)")
                            .font(Stanford.caption(12))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    // MARK: - File row

    @ViewBuilder
    private func fileRow(
        file: GitStatusFile,
        openAction: @escaping () -> Void,
        rowAction: @escaping () -> Void,
        icon: String,
        help: String
    ) -> some View {
        HStack(spacing: 5) {
            Button(action: openAction) {
                HStack(spacing: 5) {
                    statusBadge(for: file.status)

                    Text(file.displayPath)
                        .font(Stanford.ui(11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("View diff")

            Spacer(minLength: 4)

            Button(action: rowAction) {
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
        .contextMenu {
            Button {
                openAction()
            } label: {
                Label("View Diff", systemImage: "plus.forwardslash.minus")
            }
            Button {
                openChangedFileInShelf(file)
            } label: {
                Label("Open in Files Shelf", systemImage: "doc.text")
            }
            if let absolutePath = viewModel.absolutePath(for: file) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(absolutePath, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: absolutePath))
                } label: {
                    Label("Open in Default App", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private func openChangedFileDiff(_ file: GitStatusFile) {
        viewModel.loadDiff(for: file)
    }

    private func openChangedFileInShelf(_ file: GitStatusFile) {
        guard let absolutePath = viewModel.absolutePath(for: file) else { return }
        let exists = FileManager.default.fileExists(atPath: absolutePath)
        viewModel.noteChangedFileOpenedInShelf(file, absolutePath: absolutePath, exists: exists)
        guard exists else { return }
        onOpenWorkspaceFile?(absolutePath)
    }

    private func copyDiff(_ diff: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diff, forType: .string)
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
        if status.contains("U") || ["AA", "DD"].contains(status) {
            return Stanford.statusError
        }
        switch status {
        case "A", "?": return Stanford.statusHealthy
        case "M": return Stanford.statusWarn
        case "D": return Stanford.statusError
        case "R", "C": return Stanford.statusInfo
        default: return Stanford.statusInfo
        }
    }
}

// MARK: - Changed file diff sheet

private struct ChangedFileDiffSheet: View {
    let diff: GitFileDiff
    let isLoading: Bool
    let onOpenFile: () -> Void
    let onCopyDiff: () -> Void
    let onApplyHunk: (String) -> Void
    let onStageToggle: () -> Void
    let onDismiss: () -> Void

    @State private var isExpanded = false

    private var stageLabel: String {
        diff.file.isStaged ? "Unstage file" : "Stage file"
    }

    private var canOpenFile: Bool {
        !diff.file.isDeleted && diff.kind != .unavailable
    }

    private var canCopyDiff: Bool {
        diff.hasDiff
    }

    private var hunkActionLabel: String {
        diff.kind == .staged ? "Unstage hunk" : "Stage hunk"
    }

    private var canApplyHunks: Bool {
        diff.hasDiff
            && !diff.file.isConflict
            && diff.kind != .untracked
            && diff.kind != .unavailable
    }

    private var hunks: [RepositoryDiffPresentation.Hunk] {
        guard canApplyHunks else { return [] }
        return RepositoryDiffPresentation.hunks(from: diff.diff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: isExpanded ? 900 : 660,
            idealWidth: isExpanded ? 1120 : 820,
            maxWidth: isExpanded ? 1400 : 980,
            minHeight: isExpanded ? 640 : 440,
            idealHeight: isExpanded ? 820 : 560,
            maxHeight: isExpanded ? 1000 : 720
        )
        .background(Stanford.cardBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            statusBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(diff.file.displayPath)
                    .font(Stanford.ui(14, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(Stanford.ui(11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Use compact diff view" : "Expand diff view")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(Stanford.ui(11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !diff.hasDiff {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading diff...")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diff.hasDiff {
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    diffScrollContent(availableWidth: proxy.size.width)
                        .frame(minWidth: max(0, proxy.size.width), alignment: .topLeading)
                }
                .background(Stanford.panelBackground.opacity(0.72))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: messageIcon)
                    .font(Stanford.ui(22, weight: .medium))
                    .foregroundStyle(messageColor)
                Text(diff.message ?? "No textual diff is available for this file.")
                    .font(Stanford.body(13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func diffScrollContent(availableWidth: CGFloat) -> some View {
        if hunks.isEmpty {
            DiffLinesView(
                lines: RepositoryDiffPresentation.lines(from: diff.diff),
                minimumWidth: max(0, availableWidth - 24)
            )
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(hunks) { hunk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Hunk")
                                .font(Stanford.caption(11).weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(hunkActionLabel) {
                                onApplyHunk(hunk.patch)
                            }
                            .font(Stanford.caption(11).weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .frame(minWidth: max(0, availableWidth - 44), alignment: .leading)

                        DiffLinesView(lines: hunk.lines, minimumWidth: max(0, availableWidth - 44))
                    }
                    .padding(10)
                    .frame(minWidth: max(0, availableWidth - 24), alignment: .leading)
                    .background(Stanford.panelBackground.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if diff.isTruncated {
                Label("Diff truncated", systemImage: "scissors")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.statusWarn)
            } else if diff.file.isDeleted {
                Label("File deleted", systemImage: "trash")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.statusError)
            } else if diff.file.isConflict {
                Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                    .font(Stanford.caption(11).weight(.medium))
                    .foregroundStyle(Stanford.statusError)
            }

            Spacer(minLength: 10)

            Button(action: onCopyDiff) {
                Label("Copy diff", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canCopyDiff)

            Button(action: onOpenFile) {
                Label("Open file", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canOpenFile)

            Button(action: onStageToggle) {
                Label(stageLabel, systemImage: diff.file.isStaged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(diff.file.isConflict)
        }
        .font(Stanford.caption(12).weight(.medium))
        .padding(12)
    }

    private var statusBadge: some View {
        Text(diff.file.status)
            .font(Stanford.caption(10).weight(.bold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var subtitle: String {
        switch diff.kind {
        case .staged: "Staged diff"
        case .unstaged: "Working tree diff"
        case .untracked: "Untracked file preview"
        case .unavailable: "Diff unavailable"
        }
    }

    private var statusColor: Color {
        if diff.file.isConflict { return Stanford.statusError }
        switch diff.file.status {
        case "A", "?": return Stanford.statusHealthy
        case "M": return Stanford.statusWarn
        case "D": return Stanford.statusError
        default: return Stanford.statusInfo
        }
    }

    private var messageIcon: String {
        diff.kind == .unavailable ? "exclamationmark.triangle" : "doc.text.magnifyingglass"
    }

    private var messageColor: Color {
        diff.kind == .unavailable ? Stanford.statusWarn : .secondary
    }
}

struct RepositoryDiffPresentation {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case addition
            case deletion
            case hunkHeader
            case fileHeader
            case context
        }

        let id: Int
        let text: String
        let kind: Kind
    }

    struct Hunk: Identifiable, Equatable {
        let id: Int
        let patch: String
        let lines: [Line]
    }

    static func lines(from text: String) -> [Line] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .enumerated()
            .map { offset, line in
                Line(id: offset, text: line, kind: kind(for: line))
            }
    }

    static func hunks(from diff: String) -> [Hunk] {
        let diffLines = diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var header: [String] = []
        var current: [String] = []
        var result: [Hunk] = []

        func finishCurrent() {
            guard !current.isEmpty else { return }
            let patch = (header + current).joined(separator: "\n") + "\n"
            result.append(Hunk(id: result.count, patch: patch, lines: lines(from: current.joined(separator: "\n"))))
            current = []
        }

        for line in diffLines {
            if line.hasPrefix("diff --git ") {
                finishCurrent()
                header = [line]
            } else if line.hasPrefix("@@ ") {
                finishCurrent()
                current = [line]
            } else if current.isEmpty {
                header.append(line)
            } else {
                current.append(line)
            }
        }
        finishCurrent()
        return result
    }

    static func kind(for line: String) -> Line.Kind {
        if line.hasPrefix("@@ ") {
            return .hunkHeader
        }
        if line.hasPrefix("diff --git ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode ")
            || line.hasPrefix("deleted file mode ") {
            return .fileHeader
        }
        if line.hasPrefix("+") {
            return .addition
        }
        if line.hasPrefix("-") {
            return .deletion
        }
        return .context
    }
}

private struct DiffLinesView: View {
    let lines: [RepositoryDiffPresentation.Line]
    let minimumWidth: CGFloat

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(lines) { line in
                DiffLineRow(line: line, minimumWidth: minimumWidth)
            }
        }
        .textSelection(.enabled)
        .frame(minWidth: minimumWidth, alignment: .leading)
    }
}

private struct DiffLineRow: View {
    let line: RepositoryDiffPresentation.Line
    let minimumWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(prefix)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .trailing)

            Text(displayText)
                .font(Stanford.ui(11, design: .monospaced))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(minWidth: minimumWidth, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var displayText: String {
        line.text.isEmpty ? " " : line.text
    }

    private var prefix: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .hunkHeader: "@@"
        case .fileHeader: ">"
        case .context: " "
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .addition: Stanford.diffAdded
        case .deletion: Stanford.diffRemoved
        case .hunkHeader: Stanford.lagunita
        case .fileHeader: .secondary
        case .context: .primary.opacity(0.92)
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .addition: Stanford.diffAdded
        case .deletion: Stanford.diffRemoved
        case .hunkHeader: Stanford.lagunita
        case .fileHeader: Stanford.statusInfo
        case .context: .secondary.opacity(0.55)
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: Stanford.diffAdded.opacity(0.13)
        case .deletion: Stanford.diffRemoved.opacity(0.13)
        case .hunkHeader: Stanford.lagunita.opacity(0.15)
        case .fileHeader: Color.primary.opacity(0.045)
        case .context: Color.clear
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

// MARK: - Repository picker

struct RepositoryPickerPopoverView: View {
    @ObservedObject var viewModel: WorkspaceGitViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Active repository")
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if !viewModel.canChangeActiveCodePath {
                Label(viewModel.activeCodePathChangeBlockedMessage, systemImage: "lock")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(12)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if viewModel.repositories.isEmpty {
                        Text("No configured path contains a git repository.")
                            .font(Stanford.caption(11))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(viewModel.repositories) { repo in
                            repositoryRow(repo)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: RepoPopover.listMaxHeight)
        }
        .frame(width: RepoPopover.width)
    }

    private func repositoryRow(_ repo: GitRepositoryInfo) -> some View {
        let isActive = repo.path == viewModel.selectedRepository?.path
        return Button {
            viewModel.selectRepository(repo)
            onClose()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder")
                    .font(Stanford.ui(11))
                    .foregroundStyle(isActive ? Stanford.lagunita : .secondary)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(Stanford.body(12.5).weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(repo.subtitle.isEmpty ? WorkspacePathPresentation.abbreviatePath(repo.path) : repo.subtitle)
                        .font(Stanford.caption(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                if isActive {
                    Image(systemName: "checkmark")
                        .font(Stanford.ui(10, weight: .bold))
                        .foregroundStyle(Stanford.lagunita)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, RepoPopover.rowVerticalPadding)
            .background(Color.primary.opacity(isActive ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canChangeActiveCodePath)
        .help(repo.path)
    }
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

            if !viewModel.canChangeActiveCodePath {
                Label(viewModel.activeCodePathChangeBlockedMessage, systemImage: "lock")
                    .font(Stanford.caption(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(12)
                Divider()
            }

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
        .disabled(!viewModel.canChangeActiveCodePath)
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
