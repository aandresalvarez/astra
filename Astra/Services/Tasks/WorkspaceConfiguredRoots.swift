import Foundation
import ASTRACore
import ASTRAModels

/// The single interactive writer for the folders a workspace is configured
/// with: its primary folder and additional folders. A checkout that worktree
/// cleanup is removing can't become one. Cleanup holds that reservation across
/// its last reference check and the removal, so refusing here is what keeps a
/// workspace from being saved on a folder that is being deleted.
@MainActor
enum WorkspaceConfiguredRoots {
    static let reservedRootMessage =
        "That folder is a worktree ASTRA is removing, so it wasn't added to the workspace. Try again once the removal finishes."

    enum Outcome: Equatable {
        case updated
        case unchanged
        /// Nothing was written because cleanup is removing `path`.
        case refused(path: String)

        var refusalMessage: String? {
            if case .refused = self { return WorkspaceConfiguredRoots.reservedRootMessage }
            return nil
        }
    }

    /// Makes `path` the workspace's primary folder.
    static func setPrimaryPath(_ path: String, on workspace: Workspace) -> Outcome {
        guard !TaskWorktreeCheckoutReservation.isReserved(path) else { return .refused(path: path) }
        guard workspace.primaryPath != path else { return .unchanged }
        workspace.primaryPath = path
        return .updated
    }

    /// Adds each folder the workspace doesn't already list. When any of them
    /// is being removed, none is added.
    static func addAdditionalPaths(_ paths: [String], to workspace: Workspace) -> Outcome {
        if let reserved = paths.first(where: { TaskWorktreeCheckoutReservation.isReserved($0) }) {
            return .refused(path: reserved)
        }
        var outcome = Outcome.unchanged
        for path in paths where !workspace.additionalPaths.contains(path) {
            workspace.additionalPaths.append(path)
            outcome = .updated
        }
        return outcome
    }
}
