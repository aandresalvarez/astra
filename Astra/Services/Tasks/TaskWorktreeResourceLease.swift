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
        repositoryPath: String, worktreePath: String? = nil, taskID: UUID, queue: TaskQueue?
    ) throws -> TaskWorktreeResourceLease {
        guard let queue else { throw TaskWorktreeCreationError.resourceQueueUnavailable }
        guard let commonDirectory = GitCheckoutLayout.commonDirectory(for: repositoryPath) else {
            throw TaskWorktreeCreationError.repositoryUnavailable
        }
        var resources = [
            TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: commonDirectory, access: .exclusive),
            // Also conflicts with a legacy workspace claim containing .git.
            TaskExecutionResourceClaim(kind: .workspace, key: commonDirectory, access: .exclusive)
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

    func release() {
        guard let queue else { return }
        self.queue = nil
        queue.releaseResourceLocks(claims, task: nil)
        AppLogger.audit(.resourceLockReleased, category: "Git", taskID: claims.first?.taskID, fields: [
            "run_mode": Self.runMode
        ])
    }
}
