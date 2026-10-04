import Foundation
import ASTRACore

/// The new-task composer's transient worktree choice. Submission hands it to
/// `TaskWorktreeService`, which records the durable `executionRootPath` pin.
struct NewTaskWorktreeSelection {
    var isEnabled = false
    var repositoryPath: String?
    var repositories: [GitRepositoryInfo] = []
    var isLoading = false

    var selectedRepository: GitRepositoryInfo? {
        repositories.first { $0.path == repositoryPath }
    }

    var canSubmit: Bool {
        !isEnabled || (!isLoading && selectedRepository != nil)
    }

    mutating func updateRepositories(_ repositories: [GitRepositoryInfo], preferredPath: String?) {
        self.repositories = repositories
        isLoading = false
        guard repositoryPath == nil || !isEnabled else { return }
        repositoryPath = repositories.first {
            $0.path == preferredPath.map(WorkspacePathPresentation.standardizedPath)
        }?.path ?? repositories.first?.path
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
        var isPreparing: Bool
        var problem: String?
    }

    static let toggleTitle = "Start in a new worktree"
    static let toggleHelp = "Give this task its own branch and folder. The original checkout is not changed."
    static let chooseRepositoryTitle = "Choose repository"

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
            return make(
                tone: .success,
                glyph: .symbol("arrow.triangle.branch"),
                title: "Task worktree",
                meta: WorkspacePathPresentation.abbreviatePath(pinnedPath),
                help: "This draft is pinned to \(pinnedPath). Start a new task to choose another checkout."
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
        if input.isPreparing {
            return make(
                tone: .running,
                glyph: .progress,
                title: "Creating worktree",
                meta: selection.selectedRepository?.name,
                help: "ASTRA is creating this task's branch and folder. The original checkout is not changed."
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

        return make(
            tone: .success,
            glyph: .symbol("arrow.triangle.branch"),
            title: "New worktree",
            meta: "new branch from current commit",
            help: "ASTRA creates an astra/… branch from \(repository.name)'s current commit in its own folder. Uncommitted changes stay in the original checkout."
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
