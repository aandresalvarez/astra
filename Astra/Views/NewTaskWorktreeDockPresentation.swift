import Foundation
import ASTRACore
import ASTRAModels

/// The new-task composer's transient worktree choice. Submission hands it to
/// `TaskWorktreeService`, which records the durable `executionRootPath` pin.
/// The repository follows the shared "where the next task runs" setting that
/// the Repository card shows; only the checkbox and base are local.
struct NewTaskWorktreeSelection {
    var isEnabled = false
    var repositoryPath: String?
    /// The checkout of the repository the task would otherwise run in: its
    /// root or one of its worktrees. "Current branch" starts from its HEAD.
    var checkoutPath: String?
    var base: TaskWorktreeBaseChoice = .defaultBranch
    var repositories: [GitRepositoryInfo] = []
    var isLoading = false
    /// Branch names for each base, e.g. "main"; nil until resolved.
    var defaultBaseLabel: String?
    var currentBaseLabel: String?

    var selectedRepository: GitRepositoryInfo? {
        repositories.first { $0.path == repositoryPath }
    }

    var canSubmit: Bool {
        !isEnabled || (!isLoading && selectedRepository != nil)
    }

    var baseLabel: String? {
        base == .defaultBranch ? defaultBaseLabel : currentBaseLabel
    }

    var request: TaskWorktreeRequest? {
        guard isEnabled, let repository = selectedRepository else { return nil }
        return TaskWorktreeRequest(repositoryPath: repository.path, checkoutPath: checkoutPath, base: base)
    }

    var requestPayload: TaskWorktreeRequestPayload {
        TaskWorktreeRequestPayload(enabled: isEnabled, base: base, repositoryPath: repositoryPath)
    }

    /// The repository follows the shared code location, so only the
    /// per-task choices reset.
    mutating func resetTaskChoice() {
        isEnabled = false
        base = .defaultBranch
    }

    mutating func updateRepositories(
        _ repositories: [GitRepositoryInfo],
        selectedPath: String?,
        checkoutPath: String? = nil
    ) {
        self.repositories = repositories
        isLoading = false
        let selected = repositories.first {
            $0.path == selectedPath.map(WorkspacePathPresentation.standardizedPath)
        } ?? repositories.first
        if selected?.path != repositoryPath {
            defaultBaseLabel = nil
            currentBaseLabel = nil
        }
        repositoryPath = selected?.path
        self.checkoutPath = selected == nil ? nil : (checkoutPath ?? selected?.path)
    }
}

/// The strip above the new-task composer. It reuses the decision dock's
/// anatomy (tone bar, status glyph, noun title, compact meta), so where the
/// task will run, worktree setup, and task-creation problems read in the same
/// place as an open task's "Result ready" and failure messages.
struct NewTaskWorktreeDockPresentation: Equatable {
    enum Glyph: Equatable {
        case symbol(String)
        case progress
    }

    struct Input {
        var selection: NewTaskWorktreeSelection
        /// Only a brand-new task chooses; a draft keeps the checkout it was pinned to.
        var allowsChoice: Bool
        var pinnedPath: String?
        /// What the draft's worktree started from, e.g. "origin/main".
        var pinnedBase: String? = nil
        var isPreparing: Bool
        var problem: String?
    }

    static let toggleTitle = "Start in a new worktree"
    static let toggleHelp = "Give this task its own branch and folder, started from the default branch. The original checkout is not changed."
    static let chooseRepositoryTitle = "Choose repository"
    static let repositorySectionTitle = "Repository"
    static let baseSectionTitle = "Start from"

    /// "Default branch (main)" or "Current branch (feature/x)" in the menu.
    static func baseOptionTitle(_ base: TaskWorktreeBaseChoice, label: String?) -> String {
        let name = base == .defaultBranch ? "Default branch" : "Current branch"
        guard let label = nonEmpty(label) else { return name }
        return "\(name) (\(label))"
    }

    /// "from main", or the base's generic name until its branch is known.
    static func startsFrom(_ base: TaskWorktreeBaseChoice, label: String?) -> String {
        if let label = nonEmpty(label) { return "from \(label)" }
        return base == .defaultBranch ? "from default branch" : "from current branch"
    }

    /// The repository chip names both choices it holds: "astra · main".
    static func chipTitle(repository: String?, baseLabel: String?) -> String {
        guard let repository = nonEmpty(repository) else { return chooseRepositoryTitle }
        guard let baseLabel = nonEmpty(baseLabel) else { return repository }
        return "\(repository) · \(baseLabel)"
    }

    let tone: TaskDecisionDockTone
    let glyph: Glyph
    let title: String
    let meta: String?
    let help: String
    let problem: String?
    /// The checkbox and repository menu sit on the strip's trailing edge.
    let showsToggle: Bool
    let showsRepositoryMenu: Bool
    let controlsDisabled: Bool

    static func build(_ input: Input) -> NewTaskWorktreeDockPresentation? {
        let selection = input.selection
        let offersChoice = input.allowsChoice && (!selection.repositories.isEmpty || selection.isEnabled)
        let showsRepositoryMenu = offersChoice && selection.isEnabled && !selection.repositories.isEmpty

        func make(
            tone: TaskDecisionDockTone,
            glyph: Glyph,
            title: String,
            meta: String?,
            help: String,
            problem: String? = nil
        ) -> NewTaskWorktreeDockPresentation {
            NewTaskWorktreeDockPresentation(
                tone: tone,
                glyph: glyph,
                title: title,
                meta: meta,
                help: help,
                problem: problem,
                showsToggle: offersChoice,
                showsRepositoryMenu: showsRepositoryMenu,
                controlsDisabled: input.isPreparing
            )
        }

        // A failed start keeps the choice controls so the user can fix the
        // selection and retry from the same strip.
        if let problem = nonEmpty(input.problem) {
            return make(
                tone: .failed,
                glyph: .symbol("exclamationmark.triangle.fill"),
                title: "Task not started",
                meta: nil,
                help: problem,
                problem: problem
            )
        }

        guard input.allowsChoice else {
            guard let pinnedPath = nonEmpty(input.pinnedPath) else { return nil }
            let location = WorkspacePathPresentation.abbreviatePath(pinnedPath)
            let base = nonEmpty(input.pinnedBase)
            return make(
                tone: .success,
                glyph: .symbol("arrow.triangle.branch"),
                title: "Task worktree",
                meta: base.map { "\(location) · from \($0)" } ?? location,
                help: "This draft has its own worktree at \(pinnedPath)"
                    + (base.map { ", started from \($0)" } ?? "")
                    + ". Start over or delete the draft to choose another checkout."
            )
        }

        guard offersChoice else { return nil }

        guard selection.isEnabled else {
            return make(
                tone: .neutral,
                glyph: .symbol("folder"),
                title: selection.repositories.count > 1 ? "Current checkouts" : "Current checkout",
                meta: repositorySummary(selection.repositories),
                help: "The task runs in the workspace's current checkout. Check \"\(toggleTitle)\" to give it its own branch and folder."
            )
        }

        // Every submission briefly sets `isPreparing`; only an enabled
        // worktree choice actually creates one.
        let origin = Self.startsFrom(selection.base, label: selection.baseLabel)
        if input.isPreparing {
            return make(
                tone: .running,
                glyph: .progress,
                title: "Creating worktree",
                meta: selection.selectedRepository.map { repository in
                    nonEmpty(selection.baseLabel).map { "\(repository.name) · from \($0)" } ?? repository.name
                },
                help: "ASTRA is creating this task's branch and folder \(origin). The original checkout is not changed."
            )
        }

        if selection.isLoading {
            return make(
                tone: .neutral,
                glyph: .progress,
                title: "New worktree",
                meta: "checking repositories…",
                help: "ASTRA is looking for Git repositories in this workspace."
            )
        }

        guard let repository = selection.selectedRepository else {
            let hasRepositories = !selection.repositories.isEmpty
            return make(
                tone: .attention,
                glyph: .symbol("exclamationmark.circle.fill"),
                title: "New worktree",
                meta: hasRepositories ? "choose a repository" : "no Git repositories found",
                help: hasRepositories
                    ? "Choose the repository to branch from before starting the task."
                    : "This workspace has no available Git repository. Uncheck \"\(toggleTitle)\" to use the current checkout."
            )
        }

        let help = switch selection.base {
        case .defaultBranch:
            "Before any agent runs, ASTRA fetches \(repository.name)'s default branch and creates an astra/… branch \(origin) in its own folder. Work on the current branch and uncommitted changes are not included."
        case .currentBranch:
            "Before any agent runs, ASTRA creates an astra/… branch \(origin) of \(repository.name) in its own folder. Its commits are included; uncommitted changes stay in the original checkout."
        }
        return make(
            tone: .success,
            glyph: .symbol("arrow.triangle.branch"),
            title: "New worktree",
            meta: origin,
            help: help
        )
    }

    /// Names the associated repositories compactly: "A", "A, B", or "A, B +2".
    static func repositorySummary(_ repositories: [GitRepositoryInfo]) -> String? {
        let names = repositories.map(\.name)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
