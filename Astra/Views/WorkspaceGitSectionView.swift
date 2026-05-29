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
    @State private var showPRDraftSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            VStack(spacing: 1) {
                branchRow
                Divider().padding(.horizontal, 8)

                changesRow
                if isChangesDrawerExpanded {
                    changesDrawer
                }

                Divider().padding(.horizontal, 8)
                commitOrPushRow

                Divider().padding(.horizontal, 8)
                createPullRequestRow
            }
            .background(Color.primary.opacity(0.015))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    onCopyAndOpen: { edited in
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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(Stanford.lagunita)
                Text("Repository")
                    .font(Stanford.ui(13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Spacer()
            if viewModel.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button {
                        Task { await viewModel.scanRepositories() }
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }

                    if viewModel.errorMessage != nil {
                        Button { viewModel.errorMessage = nil } label: {
                            Label("Dismiss Errors", systemImage: "xmark.circle")
                        }
                    }

                    if viewModel.repositories.count > 1 {
                        Divider()
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
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(Stanford.ui(13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18, height: 18)
            }
        }
        .padding(.bottom, 2)
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
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stanford.errorRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Branch row

    private var branchRow: some View {
        Button {
            viewModel.showBranchPickerPopover = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(Stanford.ui(13, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 16)

                Text(viewModel.currentBranch.isEmpty ? "Select Branch" : viewModel.currentBranch)
                    .font(Stanford.body(13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.down")
                    .font(Stanford.ui(9, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .popover(isPresented: $viewModel.showBranchPickerPopover, arrowEdge: .trailing) {
            BranchPickerPopoverView(viewModel: viewModel)
        }
    }

    // MARK: - Commit or push row

    private var commitOrPushRow: some View {
        Button {
            viewModel.commitOrPush()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle")
                    .font(Stanford.ui(13, weight: .medium))
                    .foregroundStyle(Stanford.lagunita)
                    .frame(width: 16)

                Text("Commit or push")
                    .font(Stanford.body(13))
                    .foregroundStyle(.primary)

                Spacer()

                commitOrPushBadge
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!viewModel.canCommitOrPush || viewModel.isSyncing)
        .help(commitOrPushHelpText)
    }

    private var commitOrPushHelpText: String {
        let hasStaged = viewModel.statusFiles.contains(where: { $0.isStaged })
        let hasMessage = !viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasStaged && hasMessage && viewModel.ahead > 0 {
            return "Commit staged changes, then push"
        } else if hasStaged && hasMessage {
            return "Commit staged changes"
        } else if viewModel.ahead > 0 {
            return "Push \(viewModel.ahead) commit\(viewModel.ahead == 1 ? "" : "s") to remote"
        }
        return "Stage changes and write a commit message, or push pending commits"
    }

    @ViewBuilder
    private var commitOrPushBadge: some View {
        let hasStaged = viewModel.statusFiles.contains(where: { $0.isStaged })
        let hasMessage = !viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasStaged && hasMessage {
            Text("Ready")
                .font(Stanford.caption(12).weight(.medium))
                .foregroundStyle(Stanford.statusHealthy)
        } else if viewModel.ahead > 0 {
            Label("\(viewModel.ahead)", systemImage: "arrow.up")
                .labelStyle(.titleAndIcon)
                .font(Stanford.caption(12).weight(.semibold))
                .foregroundStyle(Stanford.lagunita)
        } else if viewModel.behind > 0 {
            Label("\(viewModel.behind)", systemImage: "arrow.down")
                .labelStyle(.titleAndIcon)
                .font(Stanford.caption(12).weight(.semibold))
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
            HStack(spacing: 10) {
                Image(systemName: isChangesDrawerExpanded ? "chevron.down" : "chevron.right")
                    .font(Stanford.ui(11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text("Changes")
                    .font(Stanford.body(13))
                    .foregroundStyle(.primary)

                Spacer()

                if viewModel.additions == 0 && viewModel.deletions == 0 {
                    Text("Clean")
                        .font(Stanford.caption(12).weight(.medium))
                        .foregroundStyle(Stanford.statusHealthy)
                } else {
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(isExpanded: isChangesDrawerExpanded))
    }

    private var changesDrawer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.horizontal, 8)

            if viewModel.statusFiles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(Stanford.ui(12))
                        .foregroundStyle(Stanford.statusHealthy)
                    Text("Working tree clean")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
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
                                icon: "plus"
                            )
                        }

                        if !staged.isEmpty {
                            fileGroup(
                                title: "Staged (\(staged.count))",
                                actionLabel: "Unstage all",
                                action: { viewModel.unstageAll() },
                                files: staged,
                                rowAction: { viewModel.unstage(file: $0) },
                                icon: "minus"
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 320)

                Divider().padding(.horizontal, 8)
                commitComposer(hasStaged: !staged.isEmpty)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 6)
        .background(Color.primary.opacity(0.01))
    }

    @ViewBuilder
    private func fileGroup(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void,
        files: [GitStatusFile],
        rowAction: @escaping (GitStatusFile) -> Void,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(Stanford.caption(10).weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(actionLabel, action: action)
                    .buttonStyle(.plain)
                    .font(Stanford.caption(9))
                    .foregroundStyle(Stanford.lagunita)
            }
            .padding(.bottom, 2)

            ForEach(files) { file in
                fileRow(file: file, action: { rowAction(file) }, icon: icon)
            }
        }
    }

    @ViewBuilder
    private func commitComposer(hasStaged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                TextField("Commit message…", text: $viewModel.commitMessage)
                    .textFieldStyle(.plain)
                    .font(Stanford.body(11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Button {
                    Task { await viewModel.suggestCommitMessage() }
                } label: {
                    if viewModel.isSuggestingCommit {
                        ProgressView().controlSize(.mini)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "sparkles")
                            .font(Stanford.ui(11))
                            .foregroundStyle(Stanford.lagunita)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSuggestingCommit || !hasStaged)
                .help(hasStaged
                      ? "Suggest commit message from staged diff"
                      : "Stage changes first")
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
            HStack(spacing: 10) {
                if viewModel.isSuggestingPR {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                } else {
                    Image(systemName: "arrow.triangle.pull")
                        .font(Stanford.ui(13, weight: .medium))
                        .foregroundStyle(Stanford.lagunita)
                        .frame(width: 16)
                }

                Text("Create pull request")
                    .font(Stanford.body(13))
                    .foregroundStyle(.primary)

                Spacer()

                if viewModel.hasUpstream {
                    Image(systemName: "sparkles")
                        .font(Stanford.ui(11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(viewModel.isSuggestingPR)
        .contextMenu {
            Button("Open GitHub without draft") {
                viewModel.openPullRequestURL(with: nil)
            }
        }
    }

    // MARK: - File row

    @ViewBuilder
    private func fileRow(file: GitStatusFile, action: @escaping () -> Void, icon: String) -> some View {
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
        .frame(width: 220)
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
                                        .font(Stanford.body(12.5))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Spacer()

                                    if branch == viewModel.currentBranch {
                                        Image(systemName: "checkmark")
                                            .font(Stanford.ui(10, weight: .bold))
                                            .foregroundStyle(Stanford.lagunita)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(Color.primary.opacity(branch == viewModel.currentBranch ? 0.04 : 0))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 180)

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
        .frame(width: 220)
    }
}

// MARK: - PR draft sheet

struct PRDraftSheet: View {
    let draft: PRSuggestion
    let onCopyAndOpen: (PRSuggestion) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var bodyText: String

    init(draft: PRSuggestion, onCopyAndOpen: @escaping (PRSuggestion) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onCopyAndOpen = onCopyAndOpen
        self.onCancel = onCancel
        self._title = State(initialValue: draft.title)
        self._bodyText = State(initialValue: draft.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request")
                .font(Stanford.ui(14, weight: .bold))

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
                    .frame(minHeight: 200)
                    .padding(4)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onCopyAndOpen(PRSuggestion(title: title, body: bodyText))
                } label: {
                    Label("Copy & Open GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(Stanford.lagunita)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }
}

