import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Lifecycle operations use the queue's existing lease owner, not a separate
/// Git mutex that running tasks cannot see.
@MainActor
final class TaskWorktreeResourceLease {
    static let runMode = "worktree_lifecycle"
    private var queue: TaskQueue?
    private let claims: [TaskResourceLockClaim]

    private init(queue: TaskQueue, claims: [TaskResourceLockClaim]) {
        self.queue = queue
        self.claims = claims
    }

    static func acquire(
        repositoryPath: String, worktreePath: String? = nil, gitAccess: TaskExecutionResourceAccess = .shared,
        taskID: UUID, queue: TaskQueue?
    ) throws -> TaskWorktreeResourceLease {
        guard let queue else { throw TaskWorktreeCreationError.resourceQueueUnavailable }
        guard let commonDirectory = GitCheckoutLayout.commonDirectory(for: repositoryPath) else {
            throw TaskWorktreeCreationError.repositoryUnavailable
        }
        // Creation holds the Git directory shared, like the sibling worktree
        // tasks that run in it: Git locks each ref, the registry entry, and
        // config per operation, so adding a worktree beside running siblings
        // is safe, while a writer of the main checkout, which holds the
        // directory exclusively, still excludes it. Cleanup holds it
        // exclusively: it checks a branch, then deletes it, and a sibling must
        // not check that branch out in between. The checkout being removed is
        // held exclusively.
        var resources = [
            TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: commonDirectory, access: gitAccess),
            // Also conflicts with a legacy workspace claim containing .git.
            TaskExecutionResourceClaim(kind: .workspace, key: commonDirectory, access: gitAccess)
        ]
        if let worktreePath {
            resources.append(TaskExecutionResourceClaim(kind: .workspace, key: worktreePath, access: .exclusive))
        }
        let claims = TaskExecutionResourceBroker.lockClaims(
            for: resources, taskID: taskID, requestID: UUID(), runMode: runMode
        )
        guard queue.acquireResourceLocksIfAvailable(claims, task: nil) != nil else {
            AppLogger.audit(.resourceLockWaiting, category: "Git", taskID: taskID, fields: [
                "run_mode": runMode, "repository": repositoryPath
            ])
            throw TaskWorktreeCreationError.repositoryBusy(repositoryPath)
        }
        AppLogger.audit(.resourceLockAcquired, category: "Git", taskID: taskID, fields: [
            "run_mode": runMode, "repository": repositoryPath
        ])
        return TaskWorktreeResourceLease(queue: queue, claims: claims)
    }

    /// An exclusive claim on one checkout folder, such as a new worktree's
    /// destination, for anything whose root contains it.
    static func acquireCheckout(
        _ checkoutPath: String, taskID: UUID, queue: TaskQueue?
    ) throws -> TaskWorktreeResourceLease {
        guard let queue else { throw TaskWorktreeCreationError.resourceQueueUnavailable }
        let claims = TaskExecutionResourceBroker.lockClaims(
            for: [TaskExecutionResourceClaim(kind: .workspace, key: checkoutPath, access: .exclusive)],
            taskID: taskID, requestID: UUID(), runMode: runMode
        )
        guard queue.acquireResourceLocksIfAvailable(claims, task: nil) != nil else {
            AppLogger.audit(.resourceLockWaiting, category: "Git", taskID: taskID, fields: [
                "run_mode": runMode, "checkout": checkoutPath
            ])
            throw TaskWorktreeCreationError.repositoryBusy(checkoutPath)
        }
        return TaskWorktreeResourceLease(queue: queue, claims: claims)
    }

    func release() {
        guard let queue else { return }
        self.queue = nil
        queue.releaseResourceLocks(claims, task: nil)
        AppLogger.audit(.resourceLockReleased, category: "Git", taskID: claims.first?.taskID, fields: [
            "run_mode": Self.runMode
        ])
    }
}
