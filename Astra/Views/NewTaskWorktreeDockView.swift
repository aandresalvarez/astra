import SwiftUI
import ASTRACore
import ASTRAModels

/// The new-task composer's top strip. It sits where an open task shows its
/// decision dock and wears the same row chrome: where the task will run on
/// the leading side, the worktree checkbox and repository menu on the
/// trailing side, and any task-creation problem underneath.
struct NewTaskWorktreeDockView: View {
    let workspace: Workspace?
    let allowsChoice: Bool
    let pinnedPath: String?
    let isPreparing: Bool
    let problem: String?
    @Binding var selection: NewTaskWorktreeSelection

    private struct ScanRequest: Hashable {
        let workspaceID: UUID
        let primaryPath: String
        let additionalPaths: [String]
    }

    private var scanRequest: ScanRequest? {
        guard allowsChoice, let workspace else { return nil }
        return ScanRequest(
            workspaceID: workspace.id,
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
    }

    private var presentation: NewTaskWorktreeDockPresentation? {
        NewTaskWorktreeDockPresentation.build(.init(
            selection: selection,
            allowsChoice: allowsChoice,
            pinnedPath: pinnedPath,
            isPreparing: isPreparing,
            problem: problem
        ))
    }

    var body: some View {
        // The frame keeps this view (and its repository scan) alive while
        // there is nothing to show yet.
        VStack(spacing: 0) {
            if let presentation {
                dockRow(presentation)
                    .padding(.horizontal, TaskComposerPresentation.decisionDockHorizontalPadding)
                    .padding(.top, TaskComposerPresentation.decisionDockTopPadding)
                    .padding(.bottom, TaskComposerPresentation.decisionDockBottomPadding)

                SubtleDivider()
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: scanRequest) {
            await scanRepositories()
        }
    }

    private func scanRepositories() async {
        guard let request = scanRequest else {
            selection.isLoading = false
            return
        }
        selection.isLoading = true
        let repositories = await GitService.shared.scanForGitRepositories(
            primaryPath: request.primaryPath,
            additionalPaths: request.additionalPaths
        )
        guard !Task.isCancelled, request == scanRequest else { return }
        selection.updateRepositories(repositories, preferredPath: workspace?.activeWorkingPath)
    }

    private func dockRow(_ presentation: NewTaskWorktreeDockPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: TaskComposerPresentation.decisionRowSpacing) {
                    statusCluster(presentation)
                        .layoutPriority(1)
                    Spacer(minLength: 12)
                    controls(presentation)
                }

                VStack(alignment: .leading, spacing: 8) {
                    statusCluster(presentation)
                    if presentation.showsToggle {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            controls(presentation)
                        }
                    }
                }
            }

            if let problem = presentation.problem {
                Text(problem)
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.errorRed)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TaskComposerPresentation.decisionIconFrame + 7)
                    .help(problem)
                    .accessibilityIdentifier("NewTaskWorktreeDockProblem")
            }
        }
        .composerDockRowChrome(tone: presentation.tone)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NewTaskWorktreeDock")
    }

    private func statusCluster(_ presentation: NewTaskWorktreeDockPresentation) -> some View {
        HStack(alignment: .center, spacing: 7) {
            statusGlyph(presentation)
                .frame(
                    width: TaskComposerPresentation.decisionIconFrame,
                    height: TaskComposerPresentation.decisionIconFrame
                )
            Text(presentation.title)
                .font(Stanford.body(TaskComposerPresentation.decisionTitleFontSize).weight(.semibold))
                .foregroundStyle(Stanford.black)
                .lineLimit(1)
            if let meta = presentation.meta {
                Text("· \(meta)")
                    .font(Stanford.caption(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(presentation.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.meta ?? "")
        .accessibilityHint(presentation.help)
    }

    @ViewBuilder
    private func statusGlyph(_ presentation: NewTaskWorktreeDockPresentation) -> some View {
        switch presentation.glyph {
        case .progress:
            ProgressView()
                .controlSize(.mini)
        case .symbol(let name):
            Image(systemName: name)
                .font(Stanford.ui(TaskComposerPresentation.decisionIconFontSize, weight: .semibold))
                .foregroundStyle(presentation.tone.dockStatusIconColor)
        }
    }

    /// The checkbox stays rightmost so it does not move under the pointer
    /// when checking it reveals the repository menu to its left.
    @ViewBuilder
    private func controls(_ presentation: NewTaskWorktreeDockPresentation) -> some View {
        if presentation.showsToggle {
            HStack(alignment: .center, spacing: 10) {
                if presentation.showsRepositoryMenu {
                    repositoryMenu
                }
                Toggle(NewTaskWorktreeDockPresentation.toggleTitle, isOn: $selection.isEnabled)
                    .toggleStyle(.checkbox)
                    .font(Stanford.caption(12).weight(.medium))
                    .foregroundStyle(Stanford.black.opacity(0.84))
                    .help(NewTaskWorktreeDockPresentation.toggleHelp)
                    .accessibilityIdentifier("NewTaskWorktreeToggle")
            }
            .fixedSize()
            .disabled(presentation.controlsDisabled)
        }
    }

    private var repositoryMenu: some View {
        Menu {
            Picker("Repository", selection: $selection.repositoryPath) {
                ForEach(selection.repositories) { repository in
                    Text(repository.name)
                        .tag(Optional(repository.path))
                        .accessibilityIdentifier("NewTaskWorktreeRepository:\(repository.path)")
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            repositoryMenuLabel
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(NewTaskWorktreeRepositoryChipStyle())
        .fixedSize()
        .help(selection.selectedRepository.map { "Branch from \($0.path)" } ?? "Choose the repository to branch from")
        .accessibilityLabel("Worktree repository")
        .accessibilityValue(selection.selectedRepository?.name ?? NewTaskWorktreeDockPresentation.chooseRepositoryTitle)
        .accessibilityIdentifier("NewTaskWorktreeRepositoryPicker")
    }

    private var repositoryMenuLabel: some View {
        let repository = selection.selectedRepository
        return HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(Stanford.ui(10, weight: .semibold))
            Text(repository?.name ?? NewTaskWorktreeDockPresentation.chooseRepositoryTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(Stanford.ui(8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(Stanford.caption(12).weight(.semibold))
        .foregroundStyle(repository == nil ? Stanford.poppy : Stanford.black.opacity(0.84))
        .frame(maxWidth: 180)
    }
}

/// Matches the decision dock's secondary buttons: soft fill, rest stroke.
private struct NewTaskWorktreeRepositoryChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
        return configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(shape.fill(Color.primary.opacity(configuration.isPressed ? Stanford.fillPressed : 0.025)))
            .overlay(shape.stroke(Stanford.borderRest, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
    }
}
