import Foundation
import ASTRAModels

/// How the Repository card reads while the new-task composer has "Start in a
/// new worktree" checked. The task will not run in the checkout the card
/// shows, so the card names where it will run and labels what it still shows
/// as the base checkout.
struct WorkspaceGitNewWorktreePreview: Equatable {
    let base: TaskWorktreeBaseChoice
    /// Branch the worktree starts from, e.g. "main"; nil until resolved.
    let baseLabel: String?

    @MainActor
    init?(entry: NewTaskWorktreeIntentStore.Entry?, contextTask: AgentTask?) {
        guard let entry, entry.isEnabled else { return nil }
        // A prepared checkout, even an unavailable one, is not a new request.
        if let contextTask, TaskWorktreeBinding.eventForInheritance(from: contextTask) != nil { return nil }
        self.init(base: entry.base, baseLabel: entry.baseLabel)
    }

    init(base: TaskWorktreeBaseChoice, baseLabel: String?) {
        let trimmed = baseLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.base = base
        self.baseLabel = trimmed.isEmpty ? nil : trimmed
    }

    /// As short as the card's other scope labels ("Workspace default"), so
    /// it fits beside the repository path at rail width.
    static let scopeLabel = "Worktree source"
    static let checkoutValue = "New worktree"
    static let checkoutHelp = "The task gets its own folder when it starts. The checkout shown here is not changed."
    static let changesCaption = "Base checkout · not copied"
    static let footerCaption = "Commit and push act on the base checkout."

    var startsFrom: String {
        if let baseLabel { return "from \(baseLabel)" }
        return base == .defaultBranch ? "from default branch" : "from current branch"
    }

    var summary: String { "New worktree · \(startsFrom)" }
    var branchValue: String { "New · \(startsFrom)" }
    var branchHelp: String {
        "The task gets a new astra/… branch \(startsFrom) when it starts."
    }
}
