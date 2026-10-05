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
        TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: acceptedTurn).claims
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
    /// The legacy fallback stays workspace-only on purpose. It is also the
    /// direct/no-request path, whose access is supplied afterwards by
    /// `TaskExecutionResourceAdmissionPolicy.lockClaims(fallbackAccess:)` — and
    /// that override only reaches the workspace claim, so a synthesized Git
    /// claim would stay exclusive for a caller that asked for read-only work.
    static func admissionClaims(
        for request: TaskTurnRequest?,
        task: AgentTask
    ) -> [TaskExecutionResourceClaim] {
        if let scope = request?.executionPolicySnapshot?.resourceScope {
            return scope.claims
        }
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
        return applyingIntrinsicWorkflowClaims(claims, request: request, task: task)
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
        return isolation == .gitBranch || validation == .runTests
    }

    static func workspaceAccess(for request: TaskTurnRequest?) -> TaskExecutionResourceAccess {
        request?.resourceClaims.first(where: { $0.kind == .workspace })?.access ?? .exclusive
    }

    /// Compares the *full* persisted writable-resource claim set against the
    /// task's current writable set (working directory + every
    /// additionalPaths entry), not just the primary path, so an
    /// additionalPaths change since submission is detected as drift even
    /// when the primary working directory is unchanged.
    static func hasWorkspacePathDrift(request: TaskTurnRequest?, task: AgentTask) -> Bool {
        guard let request else { return false }
        if let scope = request.executionPolicySnapshot?.resourceScope {
            return !scope.isValid
        }
        let persistedKeys = Set(request.resourceClaims
            .filter { $0.kind == .workspace }
            .map(\.key))
        let liveKeys = Set(workspaceKeys(for: task))
        guard !persistedKeys.isEmpty, !liveKeys.isEmpty else { return false }
        return persistedKeys != liveKeys
    }

    static func workspaceAccess(
        for task: AgentTask,
        acceptedTurn _: String? = nil
    ) -> TaskExecutionResourceAccess {
        // Hooks are delivered as run-scoped Claude settings, not workspace writes.
        if requiresExclusiveWorkflowAccess(task) {
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

    /// Legacy fallback roots. Scoped requests use the accepted resource list.
    private static func workspaceKeys(for task: AgentTask) -> [String] {
        let access = TaskWorkspaceAccess(task: task)
        let primary = access.codeWorkingDirectory.isEmpty
            ? access.effectiveWorkspacePath
            : access.codeWorkingDirectory
        // `git checkout` accepts a repository subdirectory but changes the
        // entire containing worktree. Claim that root as well so sibling
        // subdirectory workspaces cannot switch one checkout concurrently.
        let branchRoots = task.isolationStrategy == .gitBranch
            ? [gitWorktreeRoot(for: primary)].compactMap { $0 }
            : []
        var seen = Set<String>()
        return ([primary] + branchRoots + access.runtimeWritablePaths).compactMap { rawPath in
            guard let key = standardizedPath(rawPath), seen.insert(key).inserted else { return nil }
            return key
        }
    }

    /// Shared admission covers the provider boundary only when every
    /// ASTRA-owned step is also read-only. Branch preparation changes the
    /// checkout and Git metadata before launch, while test validation may
    /// write build products after launch; neither is constrained by the
    /// provider's read-only boundary.
    private static func requiresExclusiveWorkflowAccess(_ task: AgentTask) -> Bool {
        task.isolationStrategy == .gitBranch || task.validationStrategy == .runTests
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
        var effective = claims.map { claim in
            guard claim.kind == .workspace || claim.kind == .gitCommonDirectory else {
                return claim
            }
            return TaskExecutionResourceClaim(kind: claim.kind, key: claim.key, access: .exclusive)
        }
        guard isolation == .gitBranch else { return effective }

        var seen = Set(effective.map { "\($0.kind.rawValue):\($0.key)" })
        let workspaceRoots = effective.filter { $0.kind == .workspace }.map(\.key)
        for root in workspaceRoots {
            if let worktree = gitWorktreeRoot(for: root) {
                let identity = "\(TaskExecutionResourceKind.workspace.rawValue):\(worktree)"
                if seen.insert(identity).inserted {
                    effective.append(TaskExecutionResourceClaim(
                        kind: .workspace,
                        key: worktree,
                        access: .exclusive
                    ))
                }
            }
            if let commonDirectory = gitCommonDirectory(for: root) {
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

    static func gitCommonDirectory(for root: String) -> String? {
        guard let worktreeRoot = gitWorktreeRoot(for: root) else { return nil }
        let dotGit = (worktreeRoot as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory)
        let resolvedGitDirectory = isDirectory.boolValue
            ? standardizedPath(dotGit)
            : linkedWorktreeGitDirectory(at: dotGit, root: worktreeRoot)
        guard let gitDirectory = resolvedGitDirectory else { return nil }
        // `commondir` exists only inside a linked worktree's admin directory
        // and normally holds a path relative to it (`../..`). A main checkout
        // has no such file, so its own Git directory is the common one.
        let commonDirFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let raw = try? String(contentsOfFile: commonDirFile, encoding: .utf8) else {
            return gitDirectory
        }
        return resolvedGitPath(raw, relativeTo: gitDirectory) ?? gitDirectory
    }

    static func gitWorktreeRoot(for path: String) -> String? {
        guard let standardized = standardizedPath(path) else { return nil }
        var candidate = URL(fileURLWithPath: standardized, isDirectory: true)
        while true {
            let dotGit = candidate.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: dotGit) {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private static func linkedWorktreeGitDirectory(at dotGitFile: String, root: String) -> String? {
        guard let raw = try? String(contentsOfFile: dotGitFile, encoding: .utf8),
              raw.lowercased().hasPrefix("gitdir:") else {
            return nil
        }
        return resolvedGitPath(String(raw.dropFirst("gitdir:".count)), relativeTo: root)
    }

    private static func resolvedGitPath(_ rawValue: String, relativeTo base: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return standardizedPath(value.hasPrefix("/") ? value : (base as NSString).appendingPathComponent(value))
    }

    private static func workspaceKey(for task: AgentTask) -> String? {
        workspaceKeys(for: task).first
    }

    private static func standardizedPath(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TaskExecutionResourceScope.canonicalPath(expanded)
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
