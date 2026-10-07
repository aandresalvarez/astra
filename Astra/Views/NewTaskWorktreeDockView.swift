import SwiftUI
import SwiftData
import ASTRACore
import ASTRAModels

/// The new-task composer's top strip. It sits where an open task shows its
/// decision dock and wears the same row chrome: where the task will run on
/// the leading side, the worktree checkbox and repository menu on the
/// trailing side, and any task-creation problem underneath.
///
/// The repository is the shared "where the next task runs" setting the
/// Repository card also edits: the selected draft's pin, otherwise the
/// workspace default. Picking one here writes that setting; the checkbox and
/// base are mirrored to the card through `NewTaskWorktreeIntentStore`.
struct NewTaskWorktreeDockView: View {
    let workspace: Workspace?
    /// The composer's draft, if any.
    let draft: AgentTask?
    /// The draft the scene selected, whose pin is the shared setting; nil
    /// when the composer starts a new task from the workspace default.
    let pinOwner: AgentTask?
    let allowsChoice: Bool
    /// The draft's worktree once it has one.
    let binding: TaskWorktreePayload?
    let isPreparing: Bool
    let problem: String?
    @Binding var selection: NewTaskWorktreeSelection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.newTaskWorktreeIntents) private var intents
    @State private var intentOwner = UUID()
    @State private var choiceProblem: String?

    private struct ScanRequest: Hashable {
        let workspaceID: UUID
        let primaryPath: String
        let additionalPaths: [String]
        let codePath: String?
    }

    private struct IntentSnapshot: Equatable {
        let workspaceID: UUID?
        let draftID: UUID?
        let isEnabled: Bool
        let base: TaskWorktreeBaseChoice
        let baseLabel: String?
        let hasPreparedDraft: Bool
    }

    /// Where the next task runs before any worktree is created.
    private var sharedCodePath: String? {
        if let pinned = pinOwner?.executionRootPath, !pinned.isEmpty { return pinned }
        if let draft,
           let request = TaskWorktreeService.latestRequest(for: draft),
           request.enabled {
            if let checkout = request.checkoutPath, !checkout.isEmpty {
                return checkout
            }
            if let repository = request.repositoryPath, !repository.isEmpty {
                return repository
            }
        }
        return workspace?.activeWorkingPath
    }

    private var scanRequest: ScanRequest? {
        guard allowsChoice, let workspace else { return nil }
        return ScanRequest(
            workspaceID: workspace.id,
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths,
            codePath: sharedCodePath.map(WorkspacePathPresentation.standardizedPath)
        )
    }

    private var intentSnapshot: IntentSnapshot {
        IntentSnapshot(
            workspaceID: workspace?.id,
            draftID: draft?.id,
            isEnabled: allowsChoice && selection.isEnabled,
            base: selection.base,
            baseLabel: selection.baseLabel,
            hasPreparedDraft: !allowsChoice && draft != nil
        )
    }

    private var presentation: NewTaskWorktreeDockPresentation? {
        NewTaskWorktreeDockPresentation.build(.init(
            selection: selection,
            allowsChoice: allowsChoice,
            pinnedPath: binding?.worktreePath,
            pinnedBase: binding?.baseRef,
            isPreparing: isPreparing,
            problem: choiceProblem ?? problem
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
        .onAppear { claimIntent() }
        .onChange(of: workspace?.id) {
            choiceProblem = nil
            claimIntent()
        }
        .onChange(of: intentSnapshot) { publishIntent() }
        .onDisappear { intents?.release(owner: intentOwner) }
    }

    private func scanRepositories() async {
        guard let request = scanRequest else {
            selection.isLoading = false
            return
        }
        selection.isLoading = true
        let git = GitService.shared
        let repositories = await git.scanForGitRepositories(
            primaryPath: request.primaryPath,
            additionalPaths: request.additionalPaths
        )
        let match = await Self.checkout(
            request.codePath,
            primaryPath: request.primaryPath,
            in: repositories,
            git: git
        )
        guard !Task.isCancelled, request == scanRequest else { return }
        Self.applyScan(
            to: &selection,
            repositories: repositories,
            recordedRepository: recordedRepositoryPath(),
            match: match
        )
        guard let repository = selection.selectedRepository else { return }
        let base = TaskWorktreeRequest(repositoryPath: repository.path, checkoutPath: selection.checkoutPath)
        var current = base
        current.base = .currentBranch
        let defaultLabel = await TaskWorktreeService.baseLabel(for: base, git: git)
        let currentLabel = await TaskWorktreeService.baseLabel(for: current, git: git)
        guard !Task.isCancelled, request == scanRequest else { return }
        selection.defaultBaseLabel = defaultLabel
        selection.currentBaseLabel = currentLabel
    }

    /// A draft's recorded repository that is absent from `repositories` stays
    /// selected and invalid. Anything else follows `match`, including the
    /// primary-repository fallback `checkout` already computed.
    static func applyScan(
        to selection: inout NewTaskWorktreeSelection,
        repositories: [GitRepositoryInfo],
        recordedRepository: String?,
        match: (repository: GitRepositoryInfo, checkoutPath: String)?
    ) {
        if let recorded = recordedRepository.map(WorkspacePathPresentation.standardizedPath),
           !repositories.contains(where: { $0.path == recorded }) {
            selection.updateRepositories(repositories, missingSelection: recorded)
            return
        }
        selection.updateRepositories(
            repositories,
            selectedPath: match?.repository.path,
            checkoutPath: match?.checkoutPath
        )
    }

    private func recordedRepositoryPath() -> String? {
        guard let draft,
              let request = TaskWorktreeService.latestRequest(for: draft),
              request.enabled,
              let repository = request.repositoryPath,
              !repository.isEmpty else { return nil }
        return WorkspacePathPresentation.standardizedPath(repository)
    }

    /// The repository whose root or worktree is `codePath`, with that
    /// checkout; else the repository at the workspace's primary path, else the
    /// first, each with its root as the checkout.
    static func checkout(
        _ codePath: String?,
        primaryPath: String,
        in repositories: [GitRepositoryInfo],
        git: any GitRepositoryOperating
    ) async -> (repository: GitRepositoryInfo, checkoutPath: String)? {
        if let codePath {
            if let exact = repositories.first(where: { $0.path == codePath }) { return (exact, exact.path) }
            let resolved = URL(fileURLWithPath: codePath).resolvingSymlinksInPath().path
            for repository in repositories {
                let worktrees = await git.listWorktrees(at: repository.path)
                if worktrees.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolved }) {
                    return (repository, codePath)
                }
            }
        }
        let primary = WorkspacePathPresentation.standardizedPath(primaryPath)
        guard let fallback = repositories.first(where: { $0.path == primary }) ?? repositories.first else { return nil }
        return (fallback, fallback.path)
    }

    private func claimIntent() {
        guard let intents else { return }
        guard let workspace else {
            intents.release(owner: intentOwner)
            return
        }
        intents.claim(owner: intentOwner, workspaceID: workspace.id, draftID: draft?.id)
        publishIntent()
    }

    private func publishIntent() {
        let snapshot = intentSnapshot
        intents?.update(owner: intentOwner) { entry in
            if let workspaceID = snapshot.workspaceID { entry.workspaceID = workspaceID }
            entry.draftID = snapshot.draftID
            entry.isEnabled = snapshot.isEnabled
            entry.base = snapshot.base
            entry.baseLabel = snapshot.baseLabel
            entry.preparedDraft = snapshot.hasPreparedDraft ? draft : nil
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { selection.isEnabled }, set: { value in
            updateChoice { $0.isEnabled = value }
        })
    }

    private var baseBinding: Binding<TaskWorktreeBaseChoice> {
        Binding(get: { selection.base }, set: { value in
            updateChoice { $0.base = value }
        })
    }

    private func updateChoice(_ update: (inout NewTaskWorktreeSelection) -> Void) {
        let previous = selection
        update(&selection)
        guard allowsChoice,
              let draft = NewTaskWorktreeComposerFlow.liveDraft(draft, in: workspace) else { return }
        do {
            try NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: modelContext)
            choiceProblem = nil
        } catch {
            selection = previous
            choiceProblem = error.localizedDescription
        }
    }

    /// Picking a repository here moves the shared setting, exactly as the
    /// Repository card's picker does.
    private func selectRepository(_ repository: GitRepositoryInfo) {
        guard let workspace, repository.path != selection.repositoryPath else { return }
        let previous = selection
        if TaskWorktreeCheckoutReservation.isReserved(repository.path) {
            selection = previous
            choiceProblem = TaskCodeLocationPin.reservedCheckoutMessage
            return
        }
        TaskCodeLocationPin.set(repository.path, workspace: workspace, task: pinOwner)
        selection.repositoryPath = repository.path
        selection.checkoutPath = repository.path
        selection.defaultBaseLabel = nil
        selection.currentBaseLabel = nil
        guard allowsChoice,
              let draft = NewTaskWorktreeComposerFlow.liveDraft(draft, in: workspace) else { return }
        do {
            try NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: modelContext)
            choiceProblem = nil
        } catch {
            selection = previous
            TaskCodeLocationPin.set(previous.checkoutPath ?? previous.repositoryPath, workspace: workspace, task: pinOwner)
            choiceProblem = error.localizedDescription
        }
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
                Toggle(NewTaskWorktreeDockPresentation.toggleTitle, isOn: enabledBinding)
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

    /// One chip for both choices the worktree is made from: which repository
    /// and which commit it starts from.
    private var repositoryMenu: some View {
        Menu {
            Section(NewTaskWorktreeDockPresentation.repositorySectionTitle) {
                ForEach(selection.repositories) { repository in
                    Button {
                        selectRepository(repository)
                    } label: {
                        if repository.path == selection.repositoryPath {
                            Label(repository.name, systemImage: "checkmark")
                        } else {
                            Text(repository.name)
                        }
                    }
                    .accessibilityIdentifier("NewTaskWorktreeRepository:\(repository.path)")
                }
            }
            Section(NewTaskWorktreeDockPresentation.baseSectionTitle) {
                Picker(NewTaskWorktreeDockPresentation.baseSectionTitle, selection: baseBinding) {
                    ForEach(TaskWorktreeBaseChoice.allCases, id: \.self) { base in
                        Text(NewTaskWorktreeDockPresentation.baseOptionTitle(base, label: label(for: base)))
                            .tag(base)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            repositoryMenuLabel
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(NewTaskWorktreeRepositoryChipStyle())
        .fixedSize()
        .help(repositoryMenuHelp)
        .accessibilityLabel("Worktree repository and starting point")
        .accessibilityValue(chipTitle)
        .accessibilityIdentifier("NewTaskWorktreeRepositoryPicker")
    }

    private func label(for base: TaskWorktreeBaseChoice) -> String? {
        base == .defaultBranch ? selection.defaultBaseLabel : selection.currentBaseLabel
    }

    private var chipTitle: String {
        NewTaskWorktreeDockPresentation.chipTitle(
            repository: selection.selectedRepository?.name,
            baseLabel: selection.baseLabel
        )
    }

    private var repositoryMenuHelp: String {
        guard let repository = selection.selectedRepository else { return "Choose the repository to branch from" }
        let origin = NewTaskWorktreeDockPresentation.startsFrom(selection.base, label: selection.baseLabel)
        return "New branch of \(repository.path), \(origin)"
    }

    private var repositoryMenuLabel: some View {
        let repository = selection.selectedRepository
        return HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(Stanford.ui(10, weight: .semibold))
            Text(chipTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(Stanford.ui(8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(Stanford.caption(12).weight(.semibold))
        .foregroundStyle(repository == nil ? Stanford.poppy : Stanford.black.opacity(0.84))
        .frame(maxWidth: 220)
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
