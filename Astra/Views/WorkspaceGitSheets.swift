// Modal sheets for the repository panel: commit composer, pull-request draft,
// and worktree management. Extracted from WorkspaceGitSectionView to keep that
// owner file within its architecture-fitness line budget.

import SwiftUI
import SwiftData
import ASTRAGitContracts

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
