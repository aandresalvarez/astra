import Foundation
import ASTRAModels
import ASTRAPersistence

/// Resolves the immutable resources an execution request needs before it is
/// persisted. Admission and runtime enforcement must consume this same
/// snapshot so a request can never be scheduled as a reader and launched as a
/// writer.
enum TaskExecutionResourceClaimResolver {
    static func claims(
        for task: AgentTask,
        acceptedTurn: String? = nil
    ) -> [TaskExecutionResourceClaim] {
        let access = workspaceAccess(for: task, acceptedTurn: acceptedTurn)
        let keys = workspaceKeys(for: task)
        // Workspace claims stay first: `workspaceClaim(for:task:)` and the
        // drift check both treat the leading claim as the canonical boundary.
        let workspaceClaims = keys.map {
            TaskExecutionResourceClaim(kind: .workspace, key: $0, access: access)
        }
        let readOnlyClaims = readOnlyWorkspaceKeys(for: task).map {
            TaskExecutionResourceClaim(kind: .workspace, key: $0, access: .shared)
        }
        // Prepared worktrees always claim their verified shared Git directory,
        // regardless of prompt intent, but `.shared`: Git locks refs, the
        // index, and config per operation, so sibling worktree tasks of one
        // repository run together, while a writer of the main checkout, which
        // holds that directory exclusively, still waits for them and they for
        // it. Writable main checkouts claim their Git metadata because they
        // have direct write access to .git. Other checkouts retain the
        // credential grant's Git-intent predicate, including its context-only
        // known gap documented in TaskExecutionResourceClaimCoverageTests.
        let mutatesGitMetadata = task.isolationStrategy == .gitBranch
            || GitOperationIntentDetector.detectsRuntimeGitOperation(
                prompt: acceptedTurn ?? "",
                task: task
            )
        let writableMainKeys = access == .exclusive ? keys.filter { hasInternalGitDirectory(for: $0) } : []
        let credentialKeys = mutatesGitMetadata
            ? gitCommonDirectoryKeys(for: keys)
            : gitCommonDirectoryKeys(for: writableMainKeys)
        let worktreeKeys = worktreeGitMetadataKeys(for: task)
        let sharedKeys = Set(worktreeKeys)
        var seen = Set<String>()
        return workspaceClaims + readOnlyClaims + (worktreeKeys + credentialKeys).compactMap { rawKey in
            guard let key = standardizedPath(rawKey), seen.insert(key).inserted else { return nil }
            return TaskExecutionResourceClaim(
                kind: .gitCommonDirectory, key: key, access: sharedKeys.contains(key) ? .shared : access
            )
        }
    }

    /// The verified shared Git directory of a prepared worktree, as claim
    /// keys. Admission holds it `.shared` whatever the run's workspace access,
    /// so the key is exempt from every exclusive upgrade.
    static func worktreeGitMetadataKeys(for task: AgentTask) -> [String] {
        TaskWorkspaceAccess(task: task).runtimeWorktreeGitMetadataPaths.compactMap(standardizedPath)
    }

    static func workspaceClaim(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> TaskExecutionResourceClaim? {
        if let persisted = request?.resourceClaims.first(where: { $0.kind == .workspace }) {
            return persisted
        }
        // V15 rows and partially-created legacy fixtures have no V16 claim.
        // Fail closed to the existing exclusive behavior rather than deriving
        // a new, potentially weaker policy after submission.
        guard let key = workspaceKey(for: task) else { return nil }
        return TaskExecutionResourceClaim(kind: .workspace, key: key, access: .exclusive)
    }

    /// Returns the immutable admission set. Empty, malformed, and legacy
    /// snapshots fail closed to one exclusive workspace claim; a broken JSON
    /// envelope must never make a request appear resource-free.
    ///
    /// Prepared-worktree metadata is also claimed for old requests that predate
    /// that grant. Direct/no-request admission applies its fallback access to
    /// both workspace and Git claims.
    static func admissionClaims(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        let claims: [TaskExecutionResourceClaim]
        if let request, !request.resourceClaims.isEmpty {
            let persisted = request.resourceClaims
            if persisted.contains(where: { $0.kind == .workspace }) {
                claims = persisted
            } else if let fallback = workspaceClaim(for: nil, task: task) {
                // Every runtime still receives a workspace root. Additional
                // account/browser/Git claims may narrow global admission but
                // must never replace the workspace safety boundary.
                claims = persisted + [fallback]
            } else {
                claims = persisted
            }
        } else if let fallback = workspaceClaim(for: nil, task: task) {
            claims = [fallback]
        } else {
            claims = []
        }
        return applyingIntrinsicWorkflowClaims(
            applyingWritableMainCheckoutGitClaims(
                applyingWorktreeGitClaims(applyingReadOnlyWorkspaceClaims(claims, task: task), task: task),
                task: task
            ),
            request: request, task: task
        )
    }

    static func requiresExclusiveWorkflowAccess(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> Bool {
        let policy = request?.executionPolicySnapshot
        let isolation = policy.flatMap { IsolationStrategy(rawValue: $0.isolationStrategyRawValue) }
            ?? task.isolationStrategy
        let validation = policy.flatMap { ValidationStrategy(rawValue: $0.validationStrategyRawValue) }
            ?? task.validationStrategy
        let hooks = policy?.templateHooksJSON ?? task.templateHooksJSON
        return isolation == .gitBranch || validation == .runTests || (!hooks.isEmpty && hooks != "{}")
    }

    static func workspaceAccess(for request: TaskTurnRequest?) -> TaskExecutionResourceAccess {
        request?.resourceClaims.first(where: { $0.kind == .workspace })?.access ?? .exclusive
    }

    /// Compares the *full* persisted writable-resource claim set against the
    /// task's current writable set (working directory + every
    /// additionalPaths entry), not just the primary path. Drift means the
    /// launch would write a root the request never claimed; a live root equal
    /// to or beneath a claimed one is still covered by the held lease, as the
    /// broker's own path-overlap rule treats it.
    static func hasWorkspacePathDrift(request: TaskTurnRequest?, task: AgentTask) -> Bool {
        guard let request else { return false }
        let readOnlyKeys = Set(readOnlyWorkspaceKeys(for: task))
        // A shared claim on a folder the task only reads never covers a root
        // it writes. An exclusive claim covers its subtree whatever the
        // folder's current role, so a request queued before that role changed
        // is still checked against what it actually holds.
        let persistedKeys = Set(request.resourceClaims
            .filter { $0.kind == .workspace && ($0.access == .exclusive || !readOnlyKeys.contains($0.key)) }
            .map(\.key))
        let liveKeys = Set(workspaceKeys(for: task))
        guard !persistedKeys.isEmpty, !liveKeys.isEmpty else { return false }
        let covered = liveKeys.allSatisfy { live in
            persistedKeys.contains { live == $0 || live.hasPrefix($0 + "/") }
        }
        if !covered { return true }
        let persistedGitKeys = Set(request.resourceClaims.filter { $0.kind == .gitCommonDirectory }.map(\.key))
        let worktreeGitKeys = Set(worktreeGitMetadataKeys(for: task))
        return !persistedGitKeys.isEmpty && !worktreeGitKeys.isSubset(of: persistedGitKeys)
    }

    /// Git common directories the request may write: those it admitted
    /// exclusively, including intrinsic workflow claims. A pre-claim row is
    /// admitted under its fallback workspace claim, so it projects that set
    /// rather than falling through. `nil` only for a direct launch.
    static func admittedWritableGitMetadataRoots(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> [String]? {
        guard let request else { return nil }
        return admissionClaims(for: request, task: task)
            .filter { $0.kind == .gitCommonDirectory && $0.access == .exclusive }
            .map(\.key)
    }

    static func workspaceAccess(
        for task: AgentTask,
        acceptedTurn _: String? = nil
    ) -> TaskExecutionResourceAccess {
        // ASTRA itself — not the prompt — rewrites the checkout's
        // `.claude/settings.local.json` before the provider starts and restores
        // it afterwards (`TaskQueue.injectTemplateHooks`). That mutation happens
        // whatever the task declares or reads as its intent, so a hook-injecting
        // task must never resolve to a concurrently-admissible shared claim:
        // two of them would overwrite each other's backup and strand or drop
        // executable hooks while the sibling is still running.
        if injectsTemplateHooks(task) || requiresExclusiveWorkflowAccess(task) {
            return .exclusive
        }
        let declarations = (task.constraints + task.inputs).compactMap(declaredAccess)
        if declarations.contains(.exclusive) {
            return .exclusive
        }
        if declarations.contains(.shared) {
            return .shared
        }
        // A shared claim is both a concurrency promise and, while ASTRA's
        // execution boundary is enabled, a read-only filesystem contract.
        // Natural-language inference is not strong enough authority for that
        // contract: follow-ups such as "yes, proceed" can change an
        // informational task into implementation work without containing a
        // mutation keyword. Default to exclusive/write-capable admission and
        // require an explicit declaration for shared/read-only execution.
        return .exclusive
    }

    /// Every path a runtime may write must participate in admission. The
    /// primary execution root stays first because legacy drift and runtime
    /// access checks use it as the task's canonical workspace boundary.
    private static func workspaceKeys(for task: AgentTask) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        let primary = access.codeWorkingDirectory.isEmpty
            ? access.effectiveWorkspacePath
            : access.codeWorkingDirectory
        // `git checkout` accepts a repository subdirectory but changes the
        // entire containing worktree. Claim that root as well so sibling
        // subdirectory workspaces cannot switch one checkout concurrently.
        let branchRoots = task.isolationStrategy == .gitBranch
            ? [GitCheckoutLayout.worktreeRoot(containing: primary)].compactMap { $0 }
            : []
        var seen = Set<String>()
        return ([primary] + branchRoots + access.runtimeWritablePaths).compactMap { rawPath in
            guard let key = standardizedPath(rawPath), seen.insert(key).inserted else { return nil }
            return key
        }
    }

    /// Keys a prepared-worktree task holds shared and never writes through:
    /// every configured folder the run can read but not write (the replaced
    /// source checkout, folders containing it, sibling checkouts, and folders
    /// that are not the code root) and the worktree's Git directory. A writer
    /// of any of them waits for the task while readers stay parallel. Holding
    /// the Git directory as a workspace key also makes every writer whose root
    /// contains it — the main checkout or any folder above it — wait.
    ///
    /// Tasks without a prepared worktree keep their read-only folders
    /// unclaimed, so sibling linked worktrees inside a configured folder
    /// still run together.
    static func readOnlyWorkspaceKeys(for task: AgentTask) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        guard access.worktreeBinding != nil else { return [] }
        let writable = Set(workspaceKeys(for: task))
        let paths = access.runtimeReadOnlyWorkspacePaths
            + access.runtimeWorktreeSourceAncestorPaths
            + access.runtimeWorktreeGitMetadataPaths
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let key = standardizedPath(path), !writable.contains(key), seen.insert(key).inserted else { return nil }
            return key
        }
    }

    /// Mirrors `ClaudeSettingsStore.injectTemplateHooks`' own write guard: an
    /// empty or `{}` payload never touches the settings file.
    private static func injectsTemplateHooks(_ task: AgentTask) -> Bool {
        !task.templateHooksJSON.isEmpty && task.templateHooksJSON != "{}"
    }

    /// Shared admission covers the provider boundary only when every
    /// ASTRA-owned step is also read-only. Branch preparation changes the
    /// checkout and Git metadata before launch, while test validation may
    /// write build products after launch; neither is constrained by the
    /// provider's read-only boundary.
    private static func requiresExclusiveWorkflowAccess(_ task: AgentTask) -> Bool {
        task.isolationStrategy == .gitBranch || task.validationStrategy == .runTests
    }

    private static func applyingReadOnlyWorkspaceClaims(
        _ claims: [TaskExecutionResourceClaim],
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        let existing = Set(claims.filter { $0.kind == .workspace }.map(\.key))
        return claims + readOnlyWorkspaceKeys(for: task).filter { !existing.contains($0) }.map {
            TaskExecutionResourceClaim(kind: .workspace, key: $0, access: .shared)
        }
    }

    private static func applyingWorktreeGitClaims(
        _ claims: [TaskExecutionResourceClaim],
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        var result = claims
        var seen = Set(claims.filter { $0.kind == .gitCommonDirectory }.map(\.key))
        for key in worktreeGitMetadataKeys(for: task) where seen.insert(key).inserted {
            result.append(TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: key, access: .shared))
        }
        return result
    }

    private static func applyingWritableMainCheckoutGitClaims(
        _ claims: [TaskExecutionResourceClaim],
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        var result = claims
        var seen = Set(claims.filter { $0.kind == .gitCommonDirectory }.map(\.key))
        let exclusiveWorkspaceKeys = claims.filter { $0.kind == .workspace && $0.access == .exclusive }.map(\.key)
        for root in exclusiveWorkspaceKeys where hasInternalGitDirectory(for: root) {
            guard let commonDir = GitCheckoutLayout.commonDirectory(for: root),
                  let key = standardizedPath(commonDir),
                  seen.insert(key).inserted else { continue }
            result.append(TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: key, access: .exclusive))
        }
        return result
    }

    private static func applyingIntrinsicWorkflowClaims(
        _ claims: [TaskExecutionResourceClaim],
        request: TaskTurnRequest?,
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        guard requiresExclusiveWorkflowAccess(for: request, task: task) else {
            return claims
        }
        let policy = request?.executionPolicySnapshot
        let isolation = policy.flatMap { IsolationStrategy(rawValue: $0.isolationStrategyRawValue) }
            ?? task.isolationStrategy
        // `readOnlyWorkspaceKeys` holds the prepared worktree's Git directory
        // too, so its `.gitCommonDirectory` claim stays shared here as well.
        let readOnlyKeys = Set(readOnlyWorkspaceKeys(for: task))
        var effective = claims.map { claim in
            guard claim.kind == .workspace || claim.kind == .gitCommonDirectory else {
                return claim
            }
            if readOnlyKeys.contains(claim.key) { return claim }
            return TaskExecutionResourceClaim(kind: claim.kind, key: claim.key, access: .exclusive)
        }
        guard isolation == .gitBranch else { return effective }

        var seen = Set(effective.map { "\($0.kind.rawValue):\($0.key)" })
        let workspaceRoots = effective.filter { $0.kind == .workspace && !readOnlyKeys.contains($0.key) }.map(\.key)
        for root in workspaceRoots {
            if let worktree = GitCheckoutLayout.worktreeRoot(containing: root) {
                let identity = "\(TaskExecutionResourceKind.workspace.rawValue):\(worktree)"
                if seen.insert(identity).inserted {
                    effective.append(TaskExecutionResourceClaim(
                        kind: .workspace,
                        key: worktree,
                        access: .exclusive
                    ))
                }
            }
            if let commonDirectory = GitCheckoutLayout.commonDirectory(for: root) {
                let identity = "\(TaskExecutionResourceKind.gitCommonDirectory.rawValue):\(commonDirectory)"
                if seen.insert(identity).inserted {
                    effective.append(TaskExecutionResourceClaim(
                        kind: .gitCommonDirectory,
                        key: commonDirectory,
                        access: .exclusive
                    ))
                }
            }
        }
        return effective
    }

    /// Distinct Git common directories behind the task's writable roots.
    ///
    /// A linked worktree keeps its own root but shares one ref store, object
    /// store, and config with its main checkout:
    /// `GitCredentialContextResolver.externalWritableGitPaths` publishes that
    /// common directory and `TaskLaunchResourceResolver
    /// .appendGitCredentialGrants` grants it read-write. Workspace claims for
    /// sibling worktrees never overlap, so without this claim the scheduler
    /// admits concurrent runs onto the same Git metadata. Its own kind keeps
    /// the claim from colliding with unrelated workspace roots that merely
    /// contain the directory.
    private static func gitCommonDirectoryKeys(for roots: [String]) -> [String] {
        var seen = Set<String>()
        return roots.compactMap { root in
            guard let key = GitCheckoutLayout.commonDirectory(for: root), seen.insert(key).inserted else { return nil }
            return key
        }
    }

    private static func hasInternalGitDirectory(for root: String) -> Bool {
        guard let standardized = standardizedPath(root) else { return false }
        let dotGit = (standardized as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func workspaceKey(for task: AgentTask) -> String? {
        workspaceKeys(for: task).first
    }

    private static func standardizedPath(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func declaredAccess(_ declaration: String) -> TaskExecutionResourceAccess? {
        let parts = declaration.split(
            maxSplits: 1,
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "=" || $0 == ":" }
        )
        guard parts.count == 2 else { return nil }
        let key = parts[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        guard key == "astra_resource_access" else { return nil }
        switch parts[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "read_only":
            return .shared
        case "write":
            return .exclusive
        default:
            return nil
        }
    }
}
