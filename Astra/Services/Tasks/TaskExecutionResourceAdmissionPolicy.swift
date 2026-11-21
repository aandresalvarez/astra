import Foundation
import ASTRAModels
import ASTRAPersistence

/// Projects durable claims into deterministic process-local leases and applies
/// per-resource FIFO fairness before the queue dispatches a worker.
@MainActor
enum TaskExecutionResourceAdmissionPolicy {
    static func lockClaims(
        for request: TaskTurnRequest?,
        task: AgentTask,
        runMode: String,
        fallbackAccess: TaskResourceAccessMode? = nil,
        sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
    ) -> [TaskResourceLockClaim] {
        var claims = TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task)
        if request == nil,
           !TaskExecutionResourceClaimResolver.requiresExclusiveWorkflowAccess(for: request, task: task),
           let fallbackAccess {
            // The read-only keys include a prepared worktree's Git directory,
            // whose `.gitCommonDirectory` claim is always shared.
            let readOnlyKeys = Set(TaskExecutionResourceClaimResolver.readOnlyWorkspaceKeys(for: task))
            claims = claims.map { claim in
                guard claim.kind == .workspace || claim.kind == .gitCommonDirectory else { return claim }
                if readOnlyKeys.contains(claim.key) { return claim }
                return TaskExecutionResourceClaim(
                    kind: claim.kind, key: claim.key,
                    access: fallbackAccess == .readOnly ? .shared : .exclusive
                )
            }
        }
        claims = effectiveClaims(claims, watched: watchedKeys(for: task, sandboxEnforcement: sandboxEnforcement),
                                 sandboxEnforcement: sandboxEnforcement)
            + unenforcedReadOnlyClaims(for: task, existing: claims, sandboxEnforcement: sandboxEnforcement)
        claims += unenforcedGitMetadataClaims(existing: claims, sandboxEnforcement: sandboxEnforcement)
        return TaskExecutionResourceBroker.lockClaims(
            for: claims,
            taskID: task.id,
            requestID: request?.id,
            runMode: runMode
        )
    }

    static func canAdmit(
        _ candidate: ExecutionRequestAdmissionScheduler.Candidate,
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>,
        activeClaims: [TaskResourceLockClaim],
        inheritedClaims: [TaskResourceLockClaim] = [],
        sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
    ) -> Bool {
        let claims = lockClaims(
            for: candidate.request,
            task: candidate.task,
            runMode: "request",
            sandboxEnforcement: sandboxEnforcement
        )
        // A request with no resource claims (e.g. a no-workspace task routed to the
        // direct worker path) has nothing to conflict on and must be immediately
        // admissible; only requests that hold claims go through the broker's
        // conflict check.
        guard claims.isEmpty || TaskExecutionResourceBroker.canAcquire(claims, active: activeClaims) else {
            return false
        }
        // Keeping an existing reservation is not a new FIFO acquisition.
        // New/wider resources still queue behind earlier competing requests.
        let newlyAcquired = claims.filter { claim in
            !inheritedClaims.contains { prior in
                prior.resourceKind == claim.resourceKind && prior.resourceKey == claim.resourceKey
                    && prior.coversAccess(of: claim)
            }
        }
        return earlierCompetingClaim(
            for: candidate,
            claims: newlyAcquired,
            in: projection,
            dispatchedRequestIDs: dispatchedRequestIDs,
            activeTaskIDs: activeTaskIDs,
            sandboxEnforcement: sandboxEnforcement
        ) == nil
    }

    static func earlierCompetingClaim(
        for candidate: ExecutionRequestAdmissionScheduler.Candidate,
        claims: [TaskResourceLockClaim],
        in projection: ExecutionRequestAdmissionScheduler.Projection,
        dispatchedRequestIDs: Set<UUID>,
        activeTaskIDs: Set<UUID>,
        sandboxEnforcement: ExecutionSandboxEnforcement = .bestEffort
    ) -> TaskResourceLockClaim? {
        for earlier in projection.ordered {
            if earlier.request.id == candidate.request.id { break }
            guard !dispatchedRequestIDs.contains(earlier.request.id),
                  !activeTaskIDs.contains(earlier.task.id) else { continue }
            let earlierClaims = lockClaims(
                for: earlier.request,
                task: earlier.task,
                runMode: "request",
                sandboxEnforcement: sandboxEnforcement
            )
            if let claim = claims.first(where: { requested in
                earlierClaims.contains { TaskExecutionResourceBroker.claimsCompete($0, requested) }
            }) {
                return claim
            }
        }
        return nil
    }

    static func effectiveWorkspaceAccess(
        _ access: TaskExecutionResourceAccess,
        sandboxEnforcement: ExecutionSandboxEnforcement
    ) -> TaskExecutionResourceAccess {
        sandboxEnforcement == .off && access == .shared ? .exclusive : access
    }

    static func workspaceAccess(
        from lease: [TaskResourceLockClaim]
    ) -> TaskExecutionResourceAccess? {
        let workspaceClaims = lease.filter { $0.resourceKind == .workspace }
        guard !workspaceClaims.isEmpty else { return nil }
        return workspaceClaims.allSatisfy { $0.accessMode == .readOnly }
            ? .shared
            : .exclusive
    }

    /// What a worktree task only reads and, with sandboxing Off, ASTRA watches
    /// instead of locking: the source checkout its worktree replaced, the Git
    /// directory the two share, and the workspace's own folder. Nothing
    /// enforces that the run stays out of them, so
    /// `TaskWorktreeSourceCheckoutWatch` compares the source checkout before
    /// and after the run. It is a Git working tree; Git is the undo. Every
    /// other shared claim still becomes exclusive when nothing enforces it.
    static func watchedKeys(for task: AgentTask, sandboxEnforcement: ExecutionSandboxEnforcement) -> Set<String> {
        guard sandboxEnforcement == .off else { return [] }
        let replaced = TaskWorkspaceAccess(task: task).replacedSourceCheckoutPaths
        guard !replaced.isEmpty else { return [] }
        let own = task.workspace.map { [$0.primaryPath] } ?? []
        return Set((replaced + own).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
            + TaskExecutionResourceClaimResolver.worktreeGitMetadataKeys(for: task))
    }

    /// A source checkout replaced by the task's worktree is left out of its
    /// claims because the sandbox keeps it read-only. With sandboxing Off
    /// nothing does, so it is claimed again, as a reader: sibling worktrees
    /// run together, a task that writes that checkout still waits for them
    /// and they for it, and so what `TaskWorktreeSourceCheckoutWatch` finds
    /// changed there was not another ASTRA task's work.
    private static func unenforcedReadOnlyClaims(
        for task: AgentTask,
        existing: [TaskExecutionResourceClaim],
        sandboxEnforcement: ExecutionSandboxEnforcement
    ) -> [TaskExecutionResourceClaim] {
        guard sandboxEnforcement == .off else { return [] }
        let claimed = Set(existing.filter { $0.kind == .workspace }.map(\.key))
        return TaskWorkspaceAccess(task: task).replacedSourceCheckoutPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !claimed.contains($0) }
            .map { TaskExecutionResourceClaim(kind: .workspace, key: $0, access: .shared) }
    }

    /// With sandboxing Off nothing keeps a writer away from the Git directory
    /// of the checkout containing its root. A root in the main checkout, or a
    /// folder inside it, therefore claims that directory exclusively, as a
    /// writable main checkout does, so worktree creation and cleanup and every
    /// worktree task wait for it. A root in a linked worktree claims it
    /// shared, as a prepared worktree does with sandboxing on: Git locks refs,
    /// the index and config per operation, so sibling worktrees run together
    /// while a writer of the main checkout still waits for them.
    private static func unenforcedGitMetadataClaims(
        existing: [TaskExecutionResourceClaim],
        sandboxEnforcement: ExecutionSandboxEnforcement
    ) -> [TaskExecutionResourceClaim] {
        guard sandboxEnforcement == .off else { return [] }
        // One task can hold both kinds of root in one repository: a linked
        // worktree and a folder of the main checkout. The stronger need wins,
        // whichever root comes first and whatever is claimed already.
        var needed: [String: TaskExecutionResourceAccess] = [:]
        for claim in existing where claim.kind == .workspace && claim.access == .exclusive {
            guard let commonDirectory = GitCheckoutLayout.commonDirectory(for: claim.key) else { continue }
            let key = URL(fileURLWithPath: commonDirectory).standardizedFileURL.path
            // A checkout that keeps its own Git directory elsewhere (a submodule,
            // a separate Git directory) is a main checkout, not a linked worktree.
            let linkedWorktree = GitCheckoutLayout.linkedWorktreeCommonDirectory(containing: claim.key) == commonDirectory
            if !linkedWorktree { needed[key] = .exclusive } else if needed[key] == nil { needed[key] = .shared }
        }
        let held = existing.filter { $0.kind == .gitCommonDirectory }
        return needed.sorted { $0.key < $1.key }.compactMap { key, access in
            // The broker merges claims on one directory, and exclusive wins.
            let covered = held.contains { $0.key == key && ($0.access == .exclusive || access == .shared) }
            return covered ? nil : TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: key, access: access)
        }
    }

    private static func effectiveClaims(
        _ claims: [TaskExecutionResourceClaim],
        watched: Set<String> = [],
        sandboxEnforcement: ExecutionSandboxEnforcement
    ) -> [TaskExecutionResourceClaim] {
        guard sandboxEnforcement == .off else { return claims }
        return claims.map { claim in
            guard claim.access == .shared, !watched.contains(claim.key),
                  claim.kind == .workspace || claim.kind == .gitCommonDirectory else {
                return claim
            }
            // Shared admission is only safe while a read-only execution
            // boundary can uphold it. With sandboxing explicitly Off, preserve
            // safety by serializing the run as a writer instead of silently
            // turning Seatbelt back on.
            return TaskExecutionResourceClaim(
                kind: claim.kind,
                key: claim.key,
                access: .exclusive
            )
        }
    }
}
