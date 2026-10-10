import Foundation
import ASTRAModels
import ASTRAPersistence

extension AgentRuntimeProcessRunner {
    /// Writable roots for a command ASTRA confines with its own Seatbelt
    /// outside a provider launch, such as validation. A task worktree's shared
    /// Git directory is added, as the launch plan adds it for the agent, so Git
    /// works there as in a normal checkout. Provider-native sandboxes keep
    /// `runtimeWritablePaths`: Codex keeps `.git` read-only by design, and a
    /// writable root over the shared Git directory would undo that.
    static func confinedCommandWritablePaths(for task: AgentTask) -> [String] {
        let paths = runtimeWritablePaths(for: task) + TaskWorkspaceAccess(task: task).runtimeWorktreeGitMetadataPaths
        return Array(Set(paths)).sorted()
    }
}
